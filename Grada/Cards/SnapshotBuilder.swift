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

    private static let vitals: [(QuantityMetric, String)] = [
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
        let period = hasToday ? "Last night" : "Yesterday"

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
        else { return .noData(period: "Today") }

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

    // MARK: - Activity

    private func cumulative(_ metric: QuantityMetric) async throws -> CardSnapshot {
        var series = try await source.daily(metric, days: 8)
        if metric == .distance, !usesMetric {
            series = series.map { DayValue(day: $0.day, value: $0.value.map { $0 * 0.621_371 }) }
        }
        return totals(series, decimals: metric.decimals, unit: metric == .distance && !usesMetric ? "mi" : metric.unit)
    }

    /// Today's total compared with the 7 days before it.
    private func totals(_ series: [DayValue], decimals: Int, unit: String) -> CardSnapshot {
        guard series.contains(where: { $0.value != nil }) else { return .noData(period: "Today") }
        let today = series.last?.value ?? 0
        let average = Baseline.average(series.dropLast().compactMap(\.value))
        return CardSnapshot(
            period: "Today",
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
            shown = (night, "Yesterday")
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
            chart: .bars(days.map { byDay[$0].map { $0.asleep / 3600 } }),
            detail: withStages ? .sleepStages(shown.night.stages) : .none
        )
    }

    // MARK: - Training

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

    private func dayLabel(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
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

    static func signedMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let sign = minutes > 0 ? "+" : (minutes < 0 ? "−" : "±")
        return sign + hoursMinutes(Double(abs(minutes)) * 60)
    }
}

extension QuantityMetric {
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
