import Foundation

/// Turns raw Apple Health data into card snapshots. All calculations run on the device.
struct SnapshotBuilder {
    let source: HealthDataSource
    var calendar: Calendar = .current
    var now: Date = .now
    var usesMetric: Bool = Locale.current.measurementSystem != .us

    /// History used for personal normal ranges.
    private let baselineDays = 30

    func snapshot(for kind: CardKind) async throws -> CardSnapshot {
        switch kind {
        case .healthStatus: try await healthStatus()
        case .recovery: try await recovery()
        case .resources: try await resources()
        case .healthAge: try await healthAge()
        case .sleepNeed: try await sleepNeed()
        case .sleepConsistency: try await sleepConsistency()
        case .racePredictor: try await racePredictor()
        case .trainingReadiness: trainingReadiness()
        case .loadFocus: loadFocus()
        case .heartRate: try await heartRate()
        case .sleepDuration: try await sleep(withStages: false)
        case .sleepStages: try await sleep(withStages: true)
        case .restingHeartRate: try await vital(.restingHeartRate)
        case .hrv: try await vital(.hrv)
        case .oxygenSaturation: try await vital(.oxygenSaturation)
        case .respiratoryRate: try await vital(.respiratoryRate)
        case .wristTemperature: try await wristTemperature()
        case .steps: try await cumulative(.steps)
        case .activeEnergy: try await cumulative(.activeEnergy)
        case .exerciseMinutes: try await cumulative(.exerciseMinutes)
        case .distance: try await cumulative(.distance)
        case .floors: try await cumulative(.floors)
        case .standHours: totals(try await source.standHours(days: 8), decimals: 0, unit: "h")
        case .lastWorkout: try await lastWorkout()
        case .weeklyTraining: try await weeklyTraining()
        case .vo2Max: try await vo2Max()
        case .last30Days: try await last30Days()
        }
    }

    // MARK: - Vitals

    /// The vitals behind Health status; the calendar rates days with the same set.
    static let vitals: [(QuantityMetric, String)] = [
        (.hrv, "HRV"), (.restingHeartRate, "RHR"), (.respiratoryRate, "Resp"),
        (.oxygenSaturation, "SpO₂"), (.wristTemperature, "Temp"),
    ]

    /// Vitals from the night that ended today. Until it has (e.g. just after midnight),
    /// the previous night is shown instead, labelled "Yesterday".
    private func healthStatus() async throws -> CardSnapshot {
        var allSeries: [(QuantityMetric, String, [DayValue])] = []
        for (metric, name) in Self.vitals {
            allSeries.append((metric, name, try await source.daily(metric, days: baselineDays + 1)))
        }
        let todayIndex = baselineDays
        let hasToday = allSeries.contains { $0.2.last?.value != nil }
        let nightIndex = hasToday ? todayIndex : todayIndex - 1
        let period = hasToday ? "Last night" : yesterdayLabel

        var statuses: [VitalStatus] = []
        for (metric, name, series) in allSeries {
            let state: VitalStatus.State
            if let value = series[nightIndex].value {
                let history = series[..<nightIndex].compactMap(\.value)
                if let range = Baseline.normalRange(history: history, minimumHalfWidth: metric.minimumHalfWidth) {
                    state = range.contains(value) ? .inRange : .outOfRange
                } else {
                    state = .calibrating
                }
            } else {
                state = .noData
            }
            statuses.append(VitalStatus(name: name, state: state))
        }

        let measured = statuses.filter { $0.state != .noData }
        guard !measured.isEmpty else { return .noData(period: "Last night") }
        let outOfRange = statuses.filter { $0.state == .outOfRange }.count
        let inRange = statuses.filter { $0.state == .inRange }.count

        var snapshot = CardSnapshot(period: period, value: nil, detail: .vitals(statuses))
        if outOfRange > 0 {
            snapshot.value = outOfRange == 1 ? "1 vital out of range" : "\(outOfRange) vitals out of range"
            snapshot.tone = .warning
        } else if inRange == 0 {
            snapshot.value = "Calibrating"
            snapshot.comparison = "Needs \(Baseline.minimumDays) nights of data"
        } else {
            snapshot.value = "All in range"
            snapshot.tone = .good
        }
        if snapshot.comparison == nil {
            snapshot.comparison = "\(inRange) of \(measured.count) vitals normal"
        }
        return snapshot
    }

    /// Discrete vitals: latest value from today or yesterday, compared with the personal normal range.
    private func vital(_ metric: QuantityMetric) async throws -> CardSnapshot {
        let series = try await source.daily(metric, days: baselineDays + 1)
        guard let latestIndex = series.indices.suffix(2).last(where: { series[$0].value != nil }),
              let latest = series[latestIndex].value
        else { return .noData(period: todayLabel) }

        let history = series[..<latestIndex].compactMap(\.value)
        let range = Baseline.normalRange(history: history, minimumHalfWidth: metric.minimumHalfWidth)
        let comparison = range.map {
            "Normal \(format($0.lowerBound, metric.decimals))–\(format($0.upperBound, metric.decimals))"
        } ?? "Calibrating"

        return CardSnapshot(
            period: dayLabel(series[latestIndex].day),
            value: format(latest, metric.decimals),
            unit: metric.unit,
            comparison: comparison,
            tone: range.map { $0.contains(latest) ? .neutral : .warning } ?? .neutral,
            chart: .line(series.suffix(7).map(\.value), normalRange: range)
        )
    }

    /// Shown as the change from the personal baseline, like the Health app does.
    private func wristTemperature() async throws -> CardSnapshot {
        let series = try await source.daily(.wristTemperature, days: baselineDays + 1)
        guard let latestIndex = series.indices.suffix(2).last(where: { series[$0].value != nil }),
              let latest = series[latestIndex].value
        else { return .noData(period: "Last night") }

        let toDisplay: (Double) -> Double = { usesMetric ? $0 : $0 * 1.8 }
        let unit = usesMetric ? "°C" : "°F"
        let history = series[..<latestIndex].compactMap(\.value)
        let period = latestIndex == series.count - 1 ? "Last night" : dayLabel(series[latestIndex].day)

        guard history.count >= Baseline.minimumDays, let mean = Baseline.average(history) else {
            let absolute = usesMetric ? latest : latest * 1.8 + 32
            return CardSnapshot(period: period, value: format(absolute, 1), unit: unit, comparison: "Calibrating",
                                chart: .line(series.suffix(7).map(\.value), normalRange: nil))
        }
        let deviation = toDisplay(latest - mean)
        let range = Baseline.normalRange(history: history, minimumHalfWidth: QuantityMetric.wristTemperature.minimumHalfWidth)
        return CardSnapshot(
            period: period,
            value: deviation.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false))),
            unit: unit,
            comparison: "vs your baseline",
            tone: range.map { $0.contains(latest) ? .neutral : .warning } ?? .neutral,
            chart: .line(series.suffix(7).map { $0.value.map { toDisplay($0 - mean) } }, normalRange: nil)
        )
    }

    private func vo2Max() async throws -> CardSnapshot {
        let readings = try await source.daily(.vo2Max, days: 90).filter { $0.value != nil }
        guard let latest = readings.last, let value = latest.value else { return .noData(period: "Latest") }
        var comparison = "First reading"
        if readings.count > 1, let previous = readings[readings.count - 2].value {
            let change = value - previous
            comparison = abs(change) < 0.05 ? "Same as before" : "\(format(change, 1, signed: true)) since last"
        }
        let points = readings.suffix(7).map(\.value)
        return CardSnapshot(
            period: dayLabel(latest.day),
            value: format(value, 1),
            unit: QuantityMetric.vo2Max.unit,
            comparison: comparison,
            chart: .line(Array(repeating: nil, count: 7 - points.count) + points, normalRange: nil)
        )
    }

    // MARK: - Scores

    /// This morning's recovery. Until last night's vitals arrive, yesterday's, like Health status.
    private func recovery() async throws -> CardSnapshot {
        let days = try await recoveryDays(7)
        let last = days.count - 1
        let hasToday = days[last].hasData
        let shownIndex = hasToday ? last : last - 1
        guard days[shownIndex].hasData else { return .noData(period: todayLabel) }
        let period = hasToday ? todayLabel : yesterdayLabel
        guard let shown = days[shownIndex].result else {
            return CardSnapshot(period: period, value: "Calibrating", comparison: "Needs \(Baseline.minimumDays) nights of data")
        }
        let status = Recovery.status(shown.score)
        return CardSnapshot(
            period: period,
            value: "\(shown.score)",
            unit: "%",
            comparison: "\(status.word) · \(shown.reason)",
            tone: status.tone,
            chart: .bars(days.map { $0.result.map { Double($0.score) } ?? 0 })
        )
    }

    /// Recovery for each of the last `count` days, oldest first. `hasData` is false without overnight
    /// HRV or heart rate; `result` is also nil while calibrating.
    func recoveryDays(_ count: Int) async throws -> [(day: Date, hasData: Bool, result: Recovery.Result?)] {
        let overnight = try await source.overnight(days: baselineDays + count)
        let breathing = try await source.daily(.respiratoryRate, days: overnight.count)
        let nights = try await source.sleepNights(days: overnight.count)
        let asleep = Dictionary(nights.map { ($0.wakeDay, $0.asleep) }, uniquingKeysWith: { first, _ in first })
        let debt = SleepNeed.debt(asleep: overnight.map { asleep[$0.wakeDay] })
        let training = workoutMinutesPerDay(try await source.workouts(days: overnight.count), days: overnight.count)

        return (overnight.count - count..<overnight.count).map { index in
            let history = (index - baselineDays)..<index
            // The need for the night ending on `index` comes from the debt and training of the day before.
            let result = Recovery.score(Recovery.Input(
                hrv: overnight[index].hrv,
                hrvHistory: overnight[history].compactMap(\.hrv),
                restingHeartRate: overnight[index].heartRate,
                restingHeartRateHistory: overnight[history].compactMap(\.heartRate),
                asleep: asleep[overnight[index].wakeDay],
                sleepNeed: SleepNeed.need(debt: debt[index - 1], trainingTime: training[index - 1] * 60),
                respiratoryRate: breathing[index].value,
                respiratoryRateHistory: breathing[history].compactMap(\.value)
            ))
            let hasData = overnight[index].hrv != nil || overnight[index].heartRate != nil
            return (overnight[index].wakeDay, hasData, result)
        }
    }

    /// Resources now, simulated from three days back so the starting guess no longer matters.
    private func resources() async throws -> CardSnapshot {
        let today = calendar.startOfDay(for: now)
        let interval = DateInterval(start: calendar.date(byAdding: .day, value: -3, to: today)!, end: now)
        let heartRate = try await source.heartRate(in: interval)
        guard heartRate.contains(where: { $0.date >= today }) else { return .noData(period: "Now") }

        let restingHeartRate = Baseline.average(try await source.daily(.restingHeartRate, days: 8).compactMap(\.value))
        let maxHeartRate = Resources.maxHeartRate(age: try await source.age(),
                                                  highestRecorded: try await source.highestHeartRate(days: 365))
        guard let restingHeartRate, let maxHeartRate, maxHeartRate > restingHeartRate + 20 else {
            return CardSnapshot(period: "Now", value: "Calibrating", comparison: "Needs resting and max heart rate")
        }

        let sleep = try await source.sleepPeriods(in: interval)
        let workouts = try await source.workouts(days: 4).map { DateInterval(start: $0.start, duration: $0.duration) }
        let timeline = Resources.timeline(interval: interval, heartRate: heartRate, sleep: sleep, workouts: workouts,
                                          restingHeartRate: restingHeartRate, maxHeartRate: maxHeartRate)
        let todayLevels = timeline.filter { $0.date >= today }
        guard let current = todayLevels.last, let midnight = todayLevels.first else { return .noData(period: "Now") }

        // Change since this morning's wake-up; before then, since midnight.
        let noon = calendar.date(byAdding: .hour, value: 12, to: today)!
        let wake = sleep.last { $0.stage != .awake && $0.end > today && $0.end <= min(noon, now) }?.end
        let reference = wake.flatMap { wake in todayLevels.last { $0.date <= wake } } ?? midnight
        let change = Int((current.value - reference.value).rounded())
        let since = wake.map { $0.formatted(date: .omitted, time: .shortened) } ?? "midnight"
        let comparison = change == 0 ? "No change since \(since)" : "\(change > 0 ? "▲" : "▼") \(abs(change))% since \(since)"
        let level = Int(current.value.rounded())

        return CardSnapshot(
            period: "Now",
            value: "\(level)",
            unit: "%",
            comparison: comparison,
            tone: Recovery.status(level).tone,
            chart: .intraday(todayLevels.map { (hour: $0.date.timeIntervalSince(today) / 3600, value: $0.value) }, domain: 0...100)
        )
    }

    /// Health age from the last 30 days, and pace of aging against the last 6 months.
    private func healthAge() async throws -> CardSnapshot {
        let period = "Last 30 days"
        guard let age = try await source.age() else {
            return CardSnapshot(period: period, value: "Needs your age", comparison: "Add your birth date in Apple Health")
        }
        let recentInput = try await healthAgeInput(age: age, days: 30)
        guard let recent = HealthAge.age(recentInput) else {
            return CardSnapshot(period: period, value: "Calibrating",
                                comparison: "Needs \(HealthAge.minimumInputs) of: steps, sleep, resting HR, VO₂ max, exercise")
        }
        let baseline = HealthAge.age(try await healthAgeInput(age: age, days: 180)) ?? recent
        let pace = HealthAge.pace(recent: recent, baseline: baseline)
        let contributors = HealthAge.impacts(recentInput).sorted { abs($0.years) > abs($1.years) }.prefix(4)
        return CardSnapshot(
            period: period,
            value: format(recent, 1),
            unit: "yrs",
            comparison: "\(format(recent - Double(age), 1, signed: true)) yrs vs your age · pace \(format(pace, 1))×",
            detail: .stats(contributors.map { (value: format($0.years, 1, signed: true), label: $0.name) })
        )
    }

    private func healthAgeInput(age: Int, days: Int) async throws -> HealthAge.Input {
        let weeks = Double(days) / 7
        let exercise = try await source.daily(.exerciseMinutes, days: days).compactMap(\.value)
        let workouts = try await source.workouts(days: days)
        let maxHeartRate = Resources.maxHeartRate(age: age, highestRecorded: nil) ?? 220
        let hasTraining = !workouts.isEmpty || !exercise.isEmpty
        let overnight = try await source.overnight(days: days)
        let consistency = overnight.indices.dropFirst(SleepConsistency.nights - 1).compactMap { end in
            let window = overnight[(end - SleepConsistency.nights + 1)...end]
            return SleepConsistency.score(bedtimes: window.compactMap { $0.bedtime.map(minutesAfterMidnight) },
                                          wakeTimes: window.compactMap { $0.wakeTime.map(minutesAfterMidnight) })
                .map { Double($0.score) }
        }
        return HealthAge.Input(
            age: age,
            sleepHours: Baseline.average(try await source.sleepNights(days: days).map(\.asleep).filter { $0 > 0 }).map { $0 / 3600 },
            sleepConsistency: Baseline.average(consistency),
            dailySteps: Baseline.average(try await source.daily(.steps, days: days).compactMap(\.value)),
            restingHeartRate: Baseline.average(try await source.daily(.restingHeartRate, days: days).compactMap(\.value)),
            vo2Max: try await source.daily(.vo2Max, days: days).compactMap(\.value).last,
            moderateMinutesPerWeek: exercise.isEmpty ? nil : exercise.reduce(0, +) / weeks,
            vigorousMinutesPerWeek: hasTraining ? workouts.filter { ($0.averageHeartRate ?? 0) >= 0.8 * maxHeartRate }
                .reduce(0) { $0 + $1.duration / 60 } / weeks : nil,
            strengthMinutesPerWeek: hasTraining ? workouts.filter { $0.name == "Strength" }
                .reduce(0) { $0 + $1.duration / 60 } / weeks : nil
        )
    }

    // TODO(#31, v4): Garmin-style readiness from sleep score, recovery time, HRV status, acute load,
    // 3-night sleep history and 3-day stress history. Needs Strain's training-load model.
    private func trainingReadiness() -> CardSnapshot {
        .noData(period: todayLabel)
    }

    // TODO(#32, v4): the last 4 weeks of training load split into low aerobic, high aerobic and anaerobic
    // by heart rate zone, against target ranges, like Garmin. Needs Strain's training-load model.
    private func loadFocus() -> CardSnapshot {
        .noData(period: "Last 4 weeks")
    }

    /// Today's heart rate from midnight: range of the 5-minute averages, and their mean.
    private func heartRate() async throws -> CardSnapshot {
        let today = calendar.startOfDay(for: now)
        let values = try await source.heartRate(in: DateInterval(start: today, end: max(now, today)))
        guard let low = values.map(\.value).min(), let high = values.map(\.value).max(),
              let average = Baseline.average(values.map(\.value))
        else { return .noData(period: todayLabel) }
        return CardSnapshot(
            period: todayLabel,
            value: "\(format(low, 0))–\(format(high, 0))",
            unit: "bpm",
            comparison: "Avg \(format(average, 0)) bpm",
            chart: .intraday(values.map { (hour: $0.date.timeIntervalSince(today) / 3600, value: $0.value) }, domain: nil)
        )
    }

    // MARK: - Activity

    private func cumulative(_ metric: QuantityMetric) async throws -> CardSnapshot {
        var series = try await source.daily(metric, days: 8)
        if metric == .distance, !usesMetric {
            series = series.map { DayValue(day: $0.day, value: $0.value.map { $0 * 0.621_371 }) }
        }
        return totals(series, decimals: metric.decimals, unit: metric == .distance && !usesMetric ? "mi" : metric.unit)
    }

    /// Today's total compared with the 7 days before it.
    // TODO(#38, v2, Goals): for metrics with a goal (steps, exercise, sleep), compare with the goal instead,
    // e.g. "−1,580 of 10,000", and show a goal progress bar (CardSnapshot.Chart) instead of the 7-day bars.
    // TODO(#39, later): show the change as an arrow and amount, e.g. "▲ 1,200 vs 7-day avg", like Resources does.
    private func totals(_ series: [DayValue], decimals: Int, unit: String) -> CardSnapshot {
        guard series.contains(where: { $0.value != nil }) else { return .noData(period: todayLabel) }
        let today = series.last?.value ?? 0
        let average = Baseline.average(series.dropLast().compactMap(\.value))
        return CardSnapshot(
            period: todayLabel,
            value: format(today, decimals),
            unit: unit,
            comparison: average.map { "7-day avg \(format($0, decimals))" },
            chart: .bars(series.suffix(7).map { $0.value ?? 0 })
        )
    }

    // MARK: - Sleep

    /// The night that ended today; until there is one (e.g. just after midnight), yesterday's.
    private func sleep(withStages: Bool) async throws -> CardSnapshot {
        let nights = try await source.sleepNights(days: 8)
        let byDay = Dictionary(nights.map { ($0.wakeDay, $0) }, uniquingKeysWith: { first, _ in first })
        let days = lastDays(7)
        let today = days[days.count - 1], yesterday = days[days.count - 2]
        let shown: (night: SleepNight, period: String)
        if let night = byDay[today], night.asleep > 0 {
            shown = (night, "Last night")
        } else if let night = byDay[yesterday], night.asleep > 0 {
            shown = (night, yesterdayLabel)
        } else {
            return .noData(period: "Last night")
        }

        let previous = nights.filter { $0.wakeDay < shown.night.wakeDay }.map(\.asleep)
        let comparison = Baseline.average(previous).map {
            "\(Self.signedMinutes(shown.night.asleep - $0)) vs 7-day avg"
        }
        return CardSnapshot(
            period: shown.period,
            value: Self.hoursMinutes(shown.night.asleep),
            comparison: comparison,
            chart: .sleep(days.map { byDay[$0] }),
            detail: withStages ? .sleepStages(shown.night.stages) : .none
        )
    }

    /// Tonight's need: baseline, plus part of the sleep debt, plus extra after today's training.
    private func sleepNeed() async throws -> CardSnapshot {
        let days = lastDays(21)
        let nights = try await source.sleepNights(days: days.count)
        guard !nights.isEmpty else { return .noData(period: tonightLabel) }
        let asleep = Dictionary(nights.map { ($0.wakeDay, $0.asleep) }, uniquingKeysWith: { first, _ in first })
        let debt = SleepNeed.debt(asleep: days.map { day in asleep[day].flatMap { $0 > 0 ? $0 : nil } })
        let trainingToday = workoutMinutesPerDay(try await source.workouts(days: 1), days: 1)[0] * 60
        let owed = debt[debt.count - 1]
        return CardSnapshot(
            period: tonightLabel,
            value: Self.hoursMinutes(SleepNeed.need(debt: owed, trainingTime: trainingToday)),
            comparison: owed >= 5 * 60 ? "Sleep debt \(Self.hoursMinutes(owed))" : "No sleep debt",
            chart: .bars(debt.suffix(7).map { $0 / 3600 })
        )
    }

    /// Bed and wake time regularity over the last 4 nights.
    private func sleepConsistency() async throws -> CardSnapshot {
        let period = "Last \(SleepConsistency.nights) nights"
        let overnight = try await source.overnight(days: 7 + SleepConsistency.nights - 1)
        guard overnight.contains(where: { $0.wakeTime != nil }) else { return .noData(period: period) }

        func result(endingAt end: Int) -> SleepConsistency.Result? {
            let window = overnight[max(end - SleepConsistency.nights + 1, 0)...end]
            return SleepConsistency.score(bedtimes: window.compactMap { $0.bedtime.map(minutesAfterMidnight) },
                                          wakeTimes: window.compactMap { $0.wakeTime.map(minutesAfterMidnight) })
        }
        let last = overnight.count - 1
        // Until last night is recorded, the window ending yesterday.
        guard let shown = result(endingAt: last) ?? result(endingAt: last - 1) else {
            return CardSnapshot(period: period, value: "Calibrating", comparison: "Needs 3 nights of data")
        }
        return CardSnapshot(
            period: period,
            value: "\(shown.score)",
            unit: "%",
            comparison: "Bed ±\(Int(shown.bedtimeSpread.rounded()))m · wake ±\(Int(shown.wakeSpread.rounded()))m",
            chart: .bars((last - 6...last).map { result(endingAt: $0).map { Double($0.score) } ?? 0 })
        )
    }

    // MARK: - Training

    /// Race times from the latest VO₂ max.
    private func racePredictor() async throws -> CardSnapshot {
        guard let latest = try await source.daily(.vo2Max, days: 90).last(where: { $0.value != nil }),
              let vo2Max = latest.value
        else { return .noData(period: "Latest") }
        let times = RacePredictor.distances.map { (name: $0.name, time: RacePredictor.time(meters: $0.meters, vo2Max: vo2Max)) }
        return CardSnapshot(
            period: dayLabel(latest.day),
            value: Self.raceTime(times[0].time),
            comparison: "\(times[0].name) · from VO₂ max \(format(vo2Max, 1))",
            detail: .stats(times.dropFirst().map { (value: Self.raceTime($0.time), label: $0.name) })
        )
    }

    private func lastWorkout() async throws -> CardSnapshot {
        guard let workout = try await source.workouts(days: 30).first else { return .noData(period: "Last 30 days") }
        return CardSnapshot(
            period: "\(dayLabel(workout.start)), \(workout.start.formatted(date: .omitted, time: .shortened))",
            value: Self.hoursMinutes(workout.duration),
            comparison: workout.name,
            detail: .workout(workout)
        )
    }

    private func weeklyTraining() async throws -> CardSnapshot {
        let recent = try await source.workouts(days: 7)
        let workouts = recent.count
        guard workouts > 0 else { return .noData(period: "Last 7 days") }
        let minutes = workoutMinutesPerDay(recent, days: 7)
        return CardSnapshot(
            period: "Last 7 days",
            value: Self.hoursMinutes(minutes.reduce(0, +) * 60),
            comparison: workouts == 1 ? "1 workout" : "\(workouts) workouts",
            chart: .bars(minutes)
        )
    }

    private func last30Days() async throws -> CardSnapshot {
        let workouts = try await source.workouts(days: 30)
        return CardSnapshot(
            period: "Workouts",
            value: "\(workouts.count)",
            unit: workouts.count == 1 ? "workout" : "workouts",
            detail: .days(workoutMinutesPerDay(workouts, days: 30))
        )
    }

    private func workoutMinutesPerDay(_ workouts: [WorkoutSummary], days: Int) -> [Double] {
        let dayStarts = lastDays(days)
        var minutes = Array(repeating: 0.0, count: days)
        for workout in workouts {
            if let index = dayStarts.firstIndex(of: calendar.startOfDay(for: workout.start)) {
                minutes[index] += workout.duration / 60
            }
        }
        return minutes
    }

    // MARK: - Helpers

    /// Start of each of the last `count` days, oldest first, ending today.
    private func lastDays(_ count: Int) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today)! }
    }

    /// False when building a past day's cards for the calendar, where "Today" would be wrong.
    private var isToday: Bool { calendar.isDateInToday(now) }
    private var todayLabel: String { isToday ? "Today" : "That day" }
    private var tonightLabel: String { isToday ? "Tonight" : "That night" }
    private var yesterdayLabel: String { dayLabel(calendar.date(byAdding: .day, value: -1, to: now)!) }

    private func dayLabel(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return todayLabel }
        if isToday, let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func format(_ value: Double, _ decimals: Int, signed: Bool = false) -> String {
        value.formatted(.number.precision(.fractionLength(decimals))
            .sign(strategy: signed ? .always(includingZero: false) : .automatic))
    }

    static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
    }

    /// "24:10" under an hour, "1:51:20" above.
    static func raceTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    private func minutesAfterMidnight(_ date: Date) -> Double {
        date.timeIntervalSince(calendar.startOfDay(for: date)) / 60
    }

    static func signedMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let sign = minutes > 0 ? "+" : (minutes < 0 ? "−" : "±")
        return sign + hoursMinutes(Double(abs(minutes)) * 60)
    }
}

nonisolated extension QuantityMetric {
    var unit: String {
        switch self {
        case .restingHeartRate: "bpm"
        case .hrv: "ms"
        case .oxygenSaturation: "%"
        case .respiratoryRate: "br/min"
        case .wristTemperature: "°C"
        case .steps, .floors: ""
        case .activeEnergy: "kcal"
        case .exerciseMinutes: "min"
        case .distance: "km"
        case .vo2Max: "ml/kg·min"
        }
    }

    var decimals: Int {
        switch self {
        case .respiratoryRate, .wristTemperature, .distance, .vo2Max: 1
        default: 0
        }
    }

    /// Smallest half-width of the normal range, so normal day-to-day noise isn't flagged.
    var minimumHalfWidth: Double {
        switch self {
        case .restingHeartRate: 3
        case .hrv: 6
        case .oxygenSaturation: 1.5
        case .respiratoryRate: 1
        case .wristTemperature: 0.4
        default: 0
        }
    }
}
