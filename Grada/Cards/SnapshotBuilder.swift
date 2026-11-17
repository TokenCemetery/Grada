import Foundation

/// Turns raw Apple Health data into card snapshots. All calculations run on the device.
struct SnapshotBuilder {
    let source: HealthDataSource
    var calendar: Calendar = .current
    var now: Date = .now
    var usesMetric: Bool = Locale.current.measurementSystem != .us
    /// The user's goals; cards for goal metrics compare with the goal in effect on the shown day.
    var goals = GoalHistory()

    /// History used for personal normal ranges.
    private let baselineDays = 30

    /// Cards with a single variant ignore `variant`.
    func snapshot(for kind: CardKind, variant: CardVariant = .current) async throws -> CardSnapshot {
        switch kind {
        case .healthStatus: try await healthStatus()
        case .recovery: try await recovery(variant)
        case .resources: try await resources()
        case .healthAge: try await healthAge()
        case .sleepNeed: try await sleepNeed()
        case .sleepConsistency: try await sleepConsistency()
        case .sleepScore: try await sleepScore()
        case .racePredictor: try await racePredictor()
        case .trainingReadiness: try await trainingReadiness()
        case .loadFocus: try await loadFocus()
        case .heartRate: try await heartRate()
        case .sleepDuration: try await sleep(withStages: false, variant)
        case .sleepStages: try await sleep(withStages: true, .current)
        case .restingHeartRate: try await vital(.restingHeartRate, variant)
        case .hrv: try await vital(.hrv, variant)
        case .hrvStatus: try await hrvStatus(variant)
        case .oxygenSaturation: try await vital(.oxygenSaturation, .current)
        case .respiratoryRate: try await vital(.respiratoryRate, .current)
        case .wristTemperature: try await wristTemperature(variant)
        case .steps: try await cumulative(.steps, goal: .steps, variant)
        case .activeEnergy: try await cumulative(.activeEnergy, goal: .activeEnergy, variant)
        case .exerciseMinutes: try await cumulative(.exerciseMinutes, variant)
        case .intensityMinutes: try await intensityMinutes()
        case .dayIntensity: try await dayIntensity()
        case .distance: try await cumulative(.distance, variant)
        case .floors: try await cumulative(.floors, goal: .floors, variant)
        case .standHours: totals(try await source.standHours(days: 8), decimals: 0, unit: "h", variant: variant)
        case .lastWorkout: try await lastWorkout()
        case .weeklyTraining: try await weeklyTraining()
        case .strain: try await strain()
        case .recoveryTime: try await recoveryTime()
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

    /// One value per day for a vital, oldest first. HRV is the night's, as Recovery and HRV status use: one series
    /// per night, from readings taken asleep, and the only HRV that Garmin and FIT files provide.
    static func vitalSeries(_ metric: QuantityMetric, days: Int, source: HealthDataSource) async throws -> [DayValue] {
        guard metric == .hrv else { return try await source.daily(metric, days: days) }
        return try await source.overnight(days: days).map { DayValue(day: $0.wakeDay, value: $0.hrv) }
    }

    /// Vitals from the night that ended today. Until it has (e.g. just after midnight),
    /// the previous night is shown instead, labelled "Yesterday".
    private func healthStatus() async throws -> CardSnapshot {
        var allSeries: [(QuantityMetric, String, [DayValue])] = []
        for (metric, name) in Self.vitals {
            allSeries.append((metric, name, try await Self.vitalSeries(metric, days: baselineDays + 1, source: source)))
        }
        let todayIndex = baselineDays
        let hasToday = allSeries.contains { $0.2.last?.value != nil }
        let nightIndex = hasToday ? todayIndex : todayIndex - 1
        let period = hasToday ? lastNightLabel : yesterdayLabel

        var statuses: [VitalStatus] = []
        for (metric, name, series) in allSeries {
            let state: VitalStatus.State
            var rating: DayRating?
            if let value = series[nightIndex].value {
                let history = series[..<nightIndex].compactMap(\.value)
                if let range = Baseline.normalRange(history: history, minimumHalfWidth: metric.minimumHalfWidth) {
                    state = range.contains(value) ? .inRange : .outOfRange
                    rating = DayRatings.vital(value, normal: range)
                } else {
                    state = .calibrating
                }
            } else {
                state = .noData
            }
            statuses.append(VitalStatus(name: name, state: state, rating: rating))
        }

        let measured = statuses.filter { $0.state != .noData }
        guard !measured.isEmpty else { return .noData(period: lastNightLabel) }
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
    /// Current marks it on the range; 7 days draws the line through the range.
    private func vital(_ metric: QuantityMetric, _ variant: CardVariant) async throws -> CardSnapshot {
        let series = try await source.daily(metric, days: baselineDays + 1)
        guard let latestIndex = series.indices.suffix(2).last(where: { series[$0].value != nil }),
              let latest = series[latestIndex].value
        else { return .noData(period: todayLabel) }

        let history = series[..<latestIndex].compactMap(\.value)
        let range = Baseline.normalRange(history: history, minimumHalfWidth: metric.minimumHalfWidth)
        let comparison = range.map {
            "Normal \(format($0.lowerBound, metric.decimals))–\(format($0.upperBound, metric.decimals))"
        } ?? "Calibrating"
        // Low blood oxygen or HRV is the worry; for the others, a high reading is.
        let higherIsBetter = metric == .oxygenSaturation || metric == .hrv
        let isTodays = isToday && latestIndex == series.count - 1

        return CardSnapshot(
            period: dayLabel(series[latestIndex].day),
            value: format(latest, metric.decimals),
            unit: metric.unit,
            comparison: comparison,
            tone: range.map { $0.contains(latest) ? .neutral : .warning } ?? .neutral,
            rating: range.map { DayRatings.range(latest, normal: $0, higherIsBetter: higherIsBetter) },
            chart: variant == .week
                ? .line(series.suffix(7).map(\.value), normalRange: range)
                : range.map { .range(value: latest, normalRange: $0, higherIsBetter: higherIsBetter, decimals: 0) } ?? .none,
            recommendation: metric == .restingHeartRate && isTodays
                ? range.flatMap { Recommendations.restingHeartRate(latest, normal: $0) } : nil
        )
    }

    /// The 7 nights ending last night; until last night is recorded, the 7 ending yesterday.
    /// Current shows the 7-night average on a gauge: yellow above the baseline ("Unbalanced"), yellow then red
    /// below it ("Low" from twice the half-width under the mean). 7 days draws the line through the baseline.
    private func hrvStatus(_ variant: CardVariant) async throws -> CardSnapshot {
        let period = "Last \(HRVStatus.window) nights"
        let chartDays = 7
        let nights = try await source.overnight(days: HRVStatus.baselineNights + HRVStatus.window + chartDays - 1).map(\.hrv)
        guard nights.suffix(HRVStatus.window + 1).contains(where: { $0 != nil }) else { return .noData(period: period) }

        let last = nights.count - 1
        let end = nights[last] == nil ? last - 1 : last
        guard let shown = HRVStatus.status(nights: nights, endingAt: end) else {
            return CardSnapshot(period: period, value: "Calibrating",
                                comparison: "Needs \(HRVStatus.minimumBaselineNights + HRVStatus.window) nights of data")
        }
        let baseline = "\(format(shown.baseline.lowerBound, 0))–\(format(shown.baseline.upperBound, 0))"
        let halfWidth = (shown.baseline.upperBound - shown.baseline.lowerBound) / 2
        return CardSnapshot(
            period: period,
            value: format(shown.average, 0),
            unit: QuantityMetric.hrv.unit,
            comparison: "\(shown.state.word) · baseline \(baseline)",
            tone: shown.state.tone,
            rating: shown.state.rating,
            chart: variant == .week
                ? .line((end - chartDays + 1...end).map { HRVStatus.status(nights: nights, endingAt: $0)?.average },
                        normalRange: shown.baseline)
                : .range(value: shown.average, normalRange: shown.baseline, below: halfWidth, above: .infinity),
            recommendation: isToday ? Recommendations.hrv(shown.state) : nil
        )
    }

    /// Last night's wrist temperature against the personal normal range, colored by how far it rose.
    /// Current shows it on a gauge; 7 days draws the last 7 nights through the range.
    private func wristTemperature(_ variant: CardVariant) async throws -> CardSnapshot {
        let series = try await source.daily(.wristTemperature, days: baselineDays + 1)
        guard let latestIndex = series.indices.suffix(2).last(where: { series[$0].value != nil }),
              let latest = series[latestIndex].value
        else { return .noData(period: lastNightLabel) }

        let toDisplay: (Double) -> Double = { usesMetric ? $0 : $0 * 1.8 + 32 }
        let unit = usesMetric ? "°C" : "°F"
        let history = series[..<latestIndex].compactMap(\.value)
        let period = latestIndex == series.count - 1 ? lastNightLabel : dayLabel(series[latestIndex].day)

        let week = series.suffix(7).map { $0.value.map(toDisplay) }
        guard history.count >= Baseline.minimumDays, let mean = Baseline.average(history) else {
            return CardSnapshot(period: period, value: format(toDisplay(latest), 1), unit: unit, comparison: "Calibrating",
                                chart: variant == .week ? .line(week, normalRange: nil) : .none)
        }
        let range = Baseline.normalRange(history: history, minimumHalfWidth: QuantityMetric.wristTemperature.minimumHalfWidth)
        let shownRange = range.map { toDisplay($0.lowerBound)...toDisplay($0.upperBound) }
        let deviation = (latest - mean) * (usesMetric ? 1 : 1.8)
        let chart: CardSnapshot.Chart = if variant == .week {
            .line(week, normalRange: shownRange)
        } else {
            // A rise can mean illness or a cycle phase; a cooler night is no concern.
            shownRange.map { .range(value: toDisplay(latest), normalRange: $0, higherIsBetter: false, decimals: 1) } ?? .none
        }
        return CardSnapshot(
            period: period,
            value: format(toDisplay(latest), 1),
            unit: unit,
            comparison: "\(format(deviation, 1, signed: true))° vs baseline",
            rating: range.map { DayRatings.range(latest, normal: $0, higherIsBetter: false) },
            chart: chart
        )
    }

    private func vo2Max() async throws -> CardSnapshot {
        let readings = try await source.daily(.vo2Max, days: 90).filter { $0.value != nil }
        guard let latest = readings.last, let value = latest.value else { return .noData(period: "Latest") }
        guard let age = try await source.age(), let sex = try await source.biologicalSex() else {
            let points = readings.suffix(7).map(\.value)
            return CardSnapshot(
                period: dayLabel(latest.day),
                value: format(value, 1),
                unit: QuantityMetric.vo2Max.unit,
                comparison: "Add your age and sex in Apple Health",
                chart: .line(Array(repeating: nil, count: 7 - points.count) + points, normalRange: nil)
            )
        }
        let bounds = VO2MaxZones.bounds(age: age, sex: sex)
        let zone = VO2MaxZones.zone(value, bounds: bounds)
        return CardSnapshot(
            period: dayLabel(latest.day),
            value: format(value, 1),
            unit: QuantityMetric.vo2Max.unit,
            comparison: zone.word,
            rating: zone.rating,
            chart: .zones(value: value, bounds: bounds)
        )
    }

    // MARK: - Scores

    /// This morning's recovery. Until last night's vitals arrive, yesterday's, like Health status.
    private func recovery(_ variant: CardVariant) async throws -> CardSnapshot {
        let days = try await recoveryDays(7)
        let last = days.count - 1
        let hasToday = days[last].hasData
        let shownIndex = hasToday ? last : last - 1
        guard days[shownIndex].hasData else { return .noData(period: todayLabel) }
        let period = hasToday ? todayLabel : yesterdayLabel
        guard let shown = days[shownIndex].result else {
            return CardSnapshot(period: period, value: "Calibrating", comparison: "Needs \(Baseline.minimumDays) nights of data")
        }
        return CardSnapshot(
            period: period,
            value: shown.rating.title,
            comparison: shown.reason,
            tone: Self.tone(shown.rating),
            rating: shown.rating,
            // Each bar is the share of inputs within their threshold; a full bar means none was off.
            chart: .bars(days.map { $0.result.map { Double($0.inRange) / Double($0.measured) } }, target: 1,
                         ratings: days.map { $0.result?.rating })
        )
    }

    static func tone(_ rating: DayRating) -> CardSnapshot.Tone {
        switch rating {
        case .good: .good
        case .fair: .neutral
        case .poor: .warning
        }
    }

    /// Recovery for each of the last `count` days, oldest first, with each input's check. `hasData` is false
    /// without overnight HRV or heart rate; `result` is also nil while calibrating, and `checks` empty.
    func recoveryDays(_ count: Int) async throws
        -> [(day: Date, hasData: Bool, result: Recovery.Result?, checks: [Recovery.Check])] {
        let overnight = try await source.overnight(days: baselineDays + count)
        let breathing = try await source.daily(.respiratoryRate, days: overnight.count)
        let nights = try await source.sleepNights(days: overnight.count)
        let asleep = Dictionary(nights.map { ($0.wakeDay, $0.asleep) }, uniquingKeysWith: { first, _ in first })

        return (overnight.count - count..<overnight.count).map { index in
            let history = (index - baselineDays)..<index
            let input = Recovery.Input(
                hrv: overnight[index].hrv,
                hrvHistory: overnight[history].compactMap(\.hrv),
                restingHeartRate: overnight[index].heartRate,
                restingHeartRateHistory: overnight[history].compactMap(\.heartRate),
                asleep: asleep[overnight[index].wakeDay],
                respiratoryRate: breathing[index].value,
                respiratoryRateHistory: breathing[history].compactMap(\.value)
            )
            let hasData = overnight[index].hrv != nil || overnight[index].heartRate != nil
            return (overnight[index].wakeDay, hasData, Recovery.status(input), Recovery.checks(input) ?? [])
        }
    }

    /// Resources now, simulated from three days back so the starting guess no longer matters.
    private func resources() async throws -> CardSnapshot {
        let today = calendar.startOfDay(for: now)
        let interval = DateInterval(start: calendar.date(byAdding: .day, value: -3, to: today)!, end: now)
        let heartRate = try await source.heartRate(in: interval)
        guard heartRate.contains(where: { $0.date >= today }) else { return .noData(period: nowLabel) }

        guard let (steps, sleep) = try await resourcesSteps(interval: interval, heartRate: heartRate) else {
            return CardSnapshot(period: nowLabel, value: "Calibrating", comparison: "Needs resting and max heart rate")
        }
        let todayLevels = steps.filter { $0.date >= today }.map { TimedValue(date: $0.date, value: $0.level) }
        guard let current = todayLevels.last, let midnight = todayLevels.first else { return .noData(period: nowLabel) }

        // Change since this morning's wake-up; before then, since midnight.
        let noon = calendar.date(byAdding: .hour, value: 12, to: today)!
        let wake = sleep.last { $0.stage != .awake && $0.end > today && $0.end <= min(noon, now) }?.end
        let reference = wake.flatMap { wake in todayLevels.last { $0.date <= wake } } ?? midnight
        let change = Int((current.value - reference.value).rounded())
        let since = wake.map { $0.formatted(date: .omitted, time: .shortened) } ?? "midnight"
        let comparison = change == 0 ? "No change since \(since)" : "\(change > 0 ? "▲" : "▼") \(abs(change))% since \(since)"
        let level = Int(current.value.rounded())

        return CardSnapshot(
            period: nowLabel,
            value: "\(level)",
            unit: "%",
            comparison: comparison,
            tone: Self.tone(Resources.rating(level)),
            rating: Resources.rating(level),
            chart: .intraday(todayLevels.map { (hour: $0.date.timeIntervalSince(today) / 3600, value: $0.value) }, domain: 0...100)
        )
    }

    /// Today's readiness and the share of inputs in range on each of the last 7 days.
    private func trainingReadiness() async throws -> CardSnapshot {
        let days = try await readinessDays(7)
        guard let shown = days.last?.result else {
            return CardSnapshot(period: todayLabel, value: "Calibrating",
                                comparison: "Needs \(TrainingReadiness.minimumInputs) inputs, like sleep and HRV")
        }
        return CardSnapshot(
            period: todayLabel,
            value: shown.word,
            comparison: shown.reason,
            tone: Self.tone(shown.rating),
            rating: shown.rating,
            chart: .bars(days.map { $0.result.map { Double($0.inRange) / Double($0.measured) } }, target: 1,
                         ratings: days.map { $0.result?.rating })
        )
    }

    /// Training readiness on each of the last `count` days, oldest first: today as of now, earlier days as of
    /// their end. Nil while fewer than `TrainingReadiness.minimumInputs` inputs are measured.
    func readinessDays(_ count: Int) async throws -> [(day: Date, result: TrainingReadiness.Result?)] {
        let days = lastDays(count)
        let history = TrainingReadiness.historyDays
        let sleepScores = try await sleepScoreDays(count)
        let strain = try await strainDays(count)
        let recovery = try await recoveryDays(count)
        let overnight = try await source.overnight(days: HRVStatus.baselineNights + HRVStatus.window + count - 1)
        let hrv = overnight.map(\.hrv)
        let nights = try await source.sleepNights(days: count + history - 1)
        let asleep = Dictionary(nights.map { ($0.wakeDay, $0.asleep) }, uniquingKeysWith: { first, _ in first })
        let needs = sleepGoals(count + history - 1)
        let maxHeartRate = Resources.maxHeartRate(age: try await source.age(),
                                                  highestRecorded: try await source.highestHeartRate(days: 365))
        let workouts = try await source.workouts(days: count + 3)
            .map { RecoveryTime.Workout(end: $0.start.addingTimeInterval($0.duration), averageHeartRate: $0.averageHeartRate) }

        return days.indices.map { index in
            let at = min(now, calendar.date(byAdding: .day, value: 1, to: days[index])!)
            let night = overnight.count - count + index
            var input = TrainingReadiness.Input()
            input.sleepScore = sleepScores[index].result?.rating
            if let maxHeartRate {
                let wake = overnight[night].wakeTime.flatMap { $0 <= at ? $0 : nil }
                input.recovering = RecoveryTime.recoveredAt(workouts: workouts, maxHeartRate: maxHeartRate, now: at,
                                                            wake: wake, morningRecovery: recovery[index].result?.rating) != nil
            }
            input.hrvStatus = HRVStatus.status(nights: hrv, endingAt: night)?.state
            input.loadRatio = strain?[index].ratio?.value
            // The 3 nights ending on this one; the history arrays start `history - 1` days earlier.
            let window = index...(index + history - 1)
            let slept = window.compactMap { asleep[needs[$0].day].flatMap { $0 > 0 ? $0 : nil } }
            input.recentSleep = slept.count == history ? Baseline.average(slept) : nil
            input.recentNeed = Baseline.average(window.compactMap { needs[$0].value }) ?? SleepNeed.baseline
            return (days[index], TrainingReadiness.status(input))
        }
    }

    /// The Resources simulation over `interval`, and the sleep it used. Nil until resting and max heart rate are known.
    private func resourcesSteps(interval: DateInterval, heartRate: [TimedValue]) async throws
        -> (steps: [Resources.Step], sleep: [SleepPeriod])? {
        let restingHeartRate = Baseline.average(try await source.daily(.restingHeartRate, days: 8).compactMap(\.value))
        let maxHeartRate = Resources.maxHeartRate(age: try await source.age(),
                                                  highestRecorded: try await source.highestHeartRate(days: 365))
        guard let restingHeartRate, let maxHeartRate, maxHeartRate > restingHeartRate + 20 else { return nil }
        let sleep = try await source.sleepPeriods(in: interval)
        let workouts = try await source.workouts(days: 4).map { DateInterval(start: $0.start, duration: $0.duration) }
        return (Resources.steps(interval: interval, heartRate: heartRate, sleep: sleep, workouts: workouts,
                                restingHeartRate: restingHeartRate, maxHeartRate: maxHeartRate), sleep)
    }

    /// Today's Resources at midnight and now, and how much each cause moved it in between. Nil without
    /// heart rate today or while calibrating.
    func resourcesContributions() async throws -> (midnight: Double, now: Double, amounts: [Resources.Cause: Double])? {
        let today = calendar.startOfDay(for: now)
        let interval = DateInterval(start: calendar.date(byAdding: .day, value: -3, to: today)!, end: now)
        let heartRate = try await source.heartRate(in: interval)
        guard heartRate.contains(where: { $0.date >= today }),
              let steps = try await resourcesSteps(interval: interval, heartRate: heartRate)?.steps,
              let midnight = steps.first(where: { $0.date >= today }), let last = steps.last
        else { return nil }
        return (midnight.level, last.level, Resources.contributions(steps, from: today))
    }

    /// Health age from the last 30 days, against the user's age, with the three inputs that move it most.
    /// It changes too slowly for a 7-day chart to say anything.
    private func healthAge() async throws -> CardSnapshot {
        let period = "Last 30 days"
        guard let age = try await source.age() else {
            return CardSnapshot(period: period, value: "Needs your age", comparison: "Add your birth date in Apple Health")
        }
        guard let recentInput = try await healthAgeInputs(age: age, count: 1).last?.input,
              let recent = HealthAge.age(recentInput) else {
            return CardSnapshot(period: period, value: "Calibrating",
                                comparison: "Needs \(HealthAge.minimumInputs) of: steps, sleep, resting HR, VO₂ max, exercise")
        }
        return CardSnapshot(
            period: period,
            value: format(recent, 1),
            unit: "yrs",
            comparison: "\(format(recent - Double(age), 1, signed: true)) yrs vs your age",
            detail: .rows(HealthAge.impacts(recentInput).sorted { abs($0.years) > abs($1.years) }.prefix(3).map {
                (label: $0.name, value: "\(format($0.years, 1, signed: true)) yrs",
                 rating: $0.years < 0 ? .good : $0.years > 0 ? .poor : nil)
            })
        )
    }

    /// Health age's inputs for each of the last `count` days, oldest first, each from the 30 days ending on it.
    /// One read of each daily series, then a sliding window, so a year of points stays cheap.
    func healthAgeInputs(age: Int, count: Int) async throws -> [(day: Date, input: HealthAge.Input)] {
        let window = HealthAge.windowDays
        let days = lastDays(count + window - 1)
        let steps = try await source.daily(.steps, days: days.count).map(\.value)
        let resting = try await source.daily(.restingHeartRate, days: days.count).map(\.value)
        let vo2Max = try await source.daily(.vo2Max, days: days.count).map(\.value)
        let exercise = try await source.daily(.exerciseMinutes, days: days.count).map(\.value)
        let nights = try await source.sleepNights(days: days.count)
        let asleep = Dictionary(nights.map { ($0.wakeDay, $0.asleep) }, uniquingKeysWith: { first, _ in first })
        let sex = try await source.biologicalSex()
        return (window - 1..<days.count).map { end in
            let range = (end - window + 1)...end
            let minutes = exercise[range].compactMap { $0 }
            return (days[end], HealthAge.Input(
                age: age,
                sex: sex,
                sleepHours: Baseline.average(range.compactMap { asleep[days[$0]] }.filter { $0 > 0 }).map { $0 / 3600 },
                dailySteps: Baseline.average(steps[range].compactMap { $0 }),
                restingHeartRate: Baseline.average(resting[range].compactMap { $0 }),
                vo2Max: vo2Max[range].compactMap { $0 }.last,
                exerciseMinutesPerWeek: minutes.isEmpty ? nil : minutes.reduce(0, +) / (Double(window) / 7)
            ))
        }
    }

    /// The last 4 weeks of workout time by intensity zone, against the 80% low-intensity target.
    private func loadFocus() async throws -> CardSnapshot {
        let period = "Last 4 weeks"
        guard let days = try await loadFocusDays(1) else {
            return CardSnapshot(period: period, value: "Calibrating", comparison: "Needs your age or max heart rate")
        }
        guard let shares = days.last.flatMap({ LoadFocus.shares($0.seconds) }) else { return .noData(period: period) }
        let rating = LoadFocus.rating(lowShare: shares[0])
        let percent = { (share: Double) in "\(Int((share * 100).rounded()))%" }
        return CardSnapshot(
            period: period,
            value: percent(shares[0]),
            unit: "low",
            comparison: "Target \(percent(LoadFocus.lowTarget)) or more low",
            tone: Self.tone(rating),
            rating: rating,
            detail: .rows(IntensityZones.Zone.allCases.map { zone in
                let bound = zone == .low ? "<\(percent(IntensityZones.lowerBounds[0]))"
                    : "≥\(percent(IntensityZones.lowerBounds[zone.rawValue - 1]))"
                return (label: "\(zone.title) · \(bound) max HR", value: percent(shares[zone.rawValue]),
                        rating: zone == .low ? rating : nil)
            })
        )
    }

    /// Seconds of workout heart rate in low, threshold and high over the 4 weeks ending on each of the last
    /// `count` days, oldest first. Nil without a max heart rate to set the zones.
    func loadFocusDays(_ count: Int) async throws -> [(day: Date, seconds: [TimeInterval])]? {
        guard let maxHeartRate = Resources.maxHeartRate(age: try await source.age(),
                                                        highestRecorded: try await source.highestHeartRate(days: 365))
        else { return nil }
        let days = lastDays(count + LoadFocus.days - 1)
        var byDay: [Date: [TimeInterval]] = [:]
        for workout in try await source.workouts(days: days.count) {
            let heartRate = try await source.workoutDetail(workout).heartRate
            let seconds = IntensityZones.time(heartRate, end: workout.start.addingTimeInterval(workout.duration),
                                              maxHeartRate: maxHeartRate)
            byDay[calendar.startOfDay(for: workout.start), default: [0, 0, 0]] =
                zip(byDay[calendar.startOfDay(for: workout.start)] ?? [0, 0, 0], seconds).map { $0 + $1 }
        }
        return (days.count - count..<days.count).map { end in
            let window = days[(end - LoadFocus.days + 1)...end].compactMap { byDay[$0] }
            return (days[end], window.reduce([0, 0, 0]) { zip($0, $1).map { $0 + $1 } })
        }
    }

    /// Today's heart rate from midnight: range of the 5-minute averages, and their mean.
    /// Workouts make the range itself unratable, so the color comes from today's resting heart rate
    /// against its personal normal range: green at or below it, yellow slightly above, red well above.
    private func heartRate() async throws -> CardSnapshot {
        let today = calendar.startOfDay(for: now)
        let values = try await source.heartRate(in: DateInterval(start: today, end: max(now, today)))
        guard let low = values.map(\.value).min(), let high = values.map(\.value).max(),
              let average = Baseline.average(values.map(\.value))
        else { return .noData(period: todayLabel) }

        let resting = try await source.daily(.restingHeartRate, days: baselineDays + 1)
        var comparison = "Avg \(format(average, 0)) bpm"
        var rating: DayRating?
        if let todayResting = resting.last?.value {
            comparison = "Avg \(format(average, 0)) · Resting \(format(todayResting, 0))"
            let history = resting.dropLast().compactMap(\.value)
            if let normal = Baseline.normalRange(history: history, minimumHalfWidth: QuantityMetric.restingHeartRate.minimumHalfWidth) {
                rating = DayRatings.range(todayResting, normal: normal, higherIsBetter: false)
            }
        }
        return CardSnapshot(
            period: todayLabel,
            value: "\(format(low, 0))–\(format(high, 0))",
            unit: "bpm",
            comparison: comparison,
            rating: rating,
            chart: .intraday(values.map { (hour: $0.date.timeIntervalSince(today) / 3600, value: $0.value) }, domain: nil)
        )
    }

    // MARK: - Activity

    private func cumulative(_ metric: QuantityMetric, goal: GoalMetric? = nil, _ variant: CardVariant) async throws -> CardSnapshot {
        var series = try await source.daily(metric, days: 8)
        if metric == .distance, !usesMetric {
            series = series.map { DayValue(day: $0.day, value: $0.value.map { $0 * 0.621_371 }) }
        }
        let goalValue = goal.flatMap { goals.value($0, on: calendar.startOfDay(for: now)) }
        var snapshot = totals(series, decimals: metric.decimals, unit: metric == .distance && !usesMetric ? "mi" : metric.unit,
                              goal: goalValue, variant: variant)
        if metric == .steps, isToday, let goalValue, snapshot.value != nil {
            snapshot.recommendation = Recommendations.steps(today: series.last?.value ?? 0, goal: goalValue)
        }
        return snapshot
    }

    /// The last 7 days' total against the weekly goal, or the WHO target without one.
    private func intensityMinutes() async throws -> CardSnapshot {
        let period = "Last 7 days"
        let days = try await intensityDays(7)
        guard days.contains(where: { $0.value != nil }) else { return .noData(period: period) }

        let total = days.compactMap(\.value).reduce(0, +)
        let target = goals.value(.intensityMinutes, on: calendar.startOfDay(for: now)) ?? IntensityMinutes.weeklyTarget
        return CardSnapshot(
            period: period,
            value: format(total, 0),
            unit: "min",
            comparison: Self.goalComparison(total, goal: target, decimals: 0),
            tone: total >= target ? .good : .neutral,
            chart: .progress(value: total, goal: target)
        )
    }

    /// Today's waking time at light effort or harder, with the last 7 days split by ACSM band.
    private func dayIntensity() async throws -> CardSnapshot {
        guard let days = try await dayIntensityDays(7) else {
            return CardSnapshot(period: todayLabel, value: "Calibrating", comparison: "Needs resting and max heart rate")
        }
        guard let today = days.last?.seconds else { return .noData(period: todayLabel) }
        let active = today.filter { $0.key != .veryLight }.values.reduce(0, +)
        return CardSnapshot(
            period: todayLabel,
            value: Self.hoursMinutes(active),
            comparison: "\(Self.hoursMinutes(today[.veryLight] ?? 0)) very light",
            chart: .intensity(days.map(\.seconds))
        )
    }

    /// Seconds per ACSM band for each of the last `count` days, oldest first; nil on days without heart rate.
    /// Nil altogether until resting and max heart rate are known.
    func dayIntensityDays(_ count: Int) async throws -> [(day: Date, seconds: [DayIntensity.Band: TimeInterval]?)]? {
        let days = lastDays(count)
        let restingHeartRate = Baseline.average(try await source.daily(.restingHeartRate, days: baselineDays).compactMap(\.value))
        let maxHeartRate = Resources.maxHeartRate(age: try await source.age(),
                                                  highestRecorded: try await source.highestHeartRate(days: 365))
        guard let restingHeartRate, let maxHeartRate, maxHeartRate > restingHeartRate + 20 else { return nil }

        let interval = DateInterval(start: days[0], end: max(now, days[count - 1]))
        let byDay = Dictionary(grouping: try await source.heartRate(in: interval)) { calendar.startOfDay(for: $0.date) }
        let sleep = try await source.sleepPeriods(in: interval)
        let workouts = try await source.workouts(days: count).map { DateInterval(start: $0.start, duration: $0.duration) }
        return days.map { day in
            (day, byDay[day].map { DayIntensity.time(heartRate: $0, sleep: sleep, workouts: workouts,
                                                      restingHeartRate: restingHeartRate, maxHeartRate: maxHeartRate) })
        }
    }

    /// Intensity minutes for each of the last `count` days, oldest first: from heart rate where the day has
    /// any, otherwise Apple's exercise minutes. Nil on days with neither.
    func intensityDays(_ count: Int) async throws -> [DayValue] {
        let days = lastDays(count)
        let heartRate = try await source.heartRate(in: DateInterval(start: days[0], end: max(now, days[count - 1])))
        let byDay = Dictionary(grouping: heartRate) { calendar.startOfDay(for: $0.date) }
        let exercise = try await source.daily(.exerciseMinutes, days: count)
        let restingHeartRate = Baseline.average(try await source.daily(.restingHeartRate, days: baselineDays).compactMap(\.value))
        let maxHeartRate = Resources.maxHeartRate(age: try await source.age(),
                                                  highestRecorded: try await source.highestHeartRate(days: 365))

        return days.indices.map { index in
            if let values = byDay[days[index]], let restingHeartRate, let maxHeartRate {
                return DayValue(day: days[index], value: IntensityMinutes.total(
                    heartRate: values, restingHeartRate: restingHeartRate, maxHeartRate: maxHeartRate))
            }
            return DayValue(day: days[index], value: exercise[index].value)
        }
    }

    /// Today's total against the goal, or without a goal, compared with the 7 days before it.
    /// Current shows a progress bar toward the goal or that average; 7 days shows bars filling toward the goal.
    // No arrow against the average: today's total is still building while the average covers full days (#39).
    private func totals(_ series: [DayValue], decimals: Int, unit: String, goal: Double? = nil,
                        variant: CardVariant) -> CardSnapshot {
        guard series.contains(where: { $0.value != nil }) else { return .noData(period: todayLabel) }
        let today = series.last?.value ?? 0
        let average = Baseline.average(series.dropLast().compactMap(\.value))
        var snapshot = CardSnapshot(period: todayLabel, value: format(today, decimals), unit: unit)
        if let goal {
            snapshot.comparison = Self.goalComparison(today, goal: goal, decimals: decimals)
            snapshot.tone = today >= goal ? .good : .neutral
        } else {
            snapshot.comparison = average.map { "7-day avg \(format($0, decimals))" }
        }
        switch variant {
        case .current:
            if let goal {
                snapshot.chart = .progress(value: today, goal: goal)
            } else if let average {
                snapshot.chart = .progress(value: today, goal: average, isAverage: true)
            }
        case .week:
            snapshot.chart = .bars(series.suffix(7).map { $0.value ?? 0 }, target: goal)
        }
        return snapshot
    }

    // MARK: - Sleep

    /// The night that ended today; until there is one (e.g. just after midnight), yesterday's.
    /// Sleep stages always shows the 7 nights; Sleep shows them only as its 7-day variant, filling toward the goal.
    private func sleep(withStages: Bool, _ variant: CardVariant) async throws -> CardSnapshot {
        let nights = try await source.sleepNights(days: 8)
        let byDay = Dictionary(nights.map { ($0.wakeDay, $0) }, uniquingKeysWith: { first, _ in first })
        let days = lastDays(7)
        let today = days[days.count - 1], yesterday = days[days.count - 2]
        let shown: (night: SleepNight, period: String)
        if let night = byDay[today], night.asleep > 0 {
            shown = (night, lastNightLabel)
        } else if let night = byDay[yesterday], night.asleep > 0 {
            shown = (night, yesterdayLabel)
        } else {
            return .noData(period: lastNightLabel)
        }

        let goalIndex = shown.night.wakeDay == today ? 1 : 0
        let goal = sleepGoals(2)[goalIndex].value ?? SleepNeed.baseline
        return CardSnapshot(
            period: shown.period,
            value: Self.hoursMinutes(shown.night.asleep),
            comparison: "\(Self.signedMinutes(shown.night.asleep - goal)) of \(Self.hoursMinutes(goal)) goal",
            chart: withStages ? .sleep(days.map { byDay[$0] })
                : variant == .week ? .sleep(days.map { byDay[$0] }, target: goal / 3600)
                : .progress(value: shown.night.asleep, goal: goal),
            detail: withStages ? .sleepStages(shown.night.stages) : .none
        )
    }

    /// The sleep need for each night ending on the last `count` days, oldest first: the user's edited goal
    /// while it holds, otherwise the 7-hour guideline.
    func sleepGoals(_ count: Int) -> [DayValue] {
        lastDays(count).map { DayValue(day: $0, value: goals.value(.sleep, on: $0) ?? SleepNeed.baseline) }
    }

    /// Each of the last `count` nights' shortfall below its need, and the sleep debt after it, oldest first.
    /// Nil when there are no sleep records at all.
    func sleepDebt(_ count: Int) async throws -> [(shortfall: TimeInterval, debt: TimeInterval)]? {
        let days = lastDays(count + SleepNeed.debtNights - 1)
        let nights = try await source.sleepNights(days: days.count)
        guard !nights.isEmpty else { return nil }
        let asleep = Dictionary(nights.map { ($0.wakeDay, $0.asleep) }, uniquingKeysWith: { first, _ in first })
        let shortfalls = SleepNeed.shortfalls(asleep: days.map { day in asleep[day].flatMap { $0 > 0 ? $0 : nil } },
                                              need: sleepGoals(days.count).map { $0.value ?? SleepNeed.baseline })
        return Array(zip(shortfalls, SleepNeed.debt(shortfalls: shortfalls)).suffix(count))
            .map { (shortfall: $0.0, debt: $0.1) }
    }

    /// Tonight's need, the debt from the last 14 nights, and each of the last 7 nights' shortfall.
    private func sleepNeed() async throws -> CardSnapshot {
        guard let nights = try await sleepDebt(7) else { return .noData(period: tonightLabel) }
        let need = goals.value(.sleep, on: calendar.startOfDay(for: now)) ?? SleepNeed.baseline
        let owed = nights[nights.count - 1].debt
        let bedtime = isToday ? try await bedtimePlan(need: need) : nil
        return CardSnapshot(
            period: tonightLabel,
            value: Self.hoursMinutes(need),
            comparison: owed >= 5 * 60 ? "Sleep debt \(Self.hoursMinutes(owed)) · \(SleepNeed.debtNights) nights" : "No sleep debt",
            chart: .bars(nights.map { $0.shortfall / 3600 }),
            recommendation: bedtime.map { Recommendations.bedtime($0, need: need) }
        )
    }

    /// Tonight's bedtime for a wake-up tomorrow, from the last `Bedtime.nights` nights.
    func bedtimePlan(need: TimeInterval) async throws -> Bedtime.Plan? {
        let asleep = Dictionary(try await source.sleepNights(days: Bedtime.nights).map { ($0.wakeDay, $0.asleep) },
                                uniquingKeysWith: { first, _ in first })
        let nights = try await source.overnight(days: Bedtime.nights).compactMap { night -> Bedtime.Night? in
            guard let start = night.bedtime, let end = night.wakeTime, let slept = asleep[night.wakeDay], slept > 0 else { return nil }
            return Bedtime.Night(wakeDay: night.wakeDay, start: start, end: end, asleep: slept)
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return Bedtime.plan(nights: nights, need: need, wakeDay: tomorrow, calendar: calendar)
    }

    /// The Sleep Regularity Index over the last week, rated against UK Biobank adults, with the last 7 days.
    private func sleepConsistency() async throws -> CardSnapshot {
        let period = "Last \(SleepConsistency.days) days"
        let days = try await sleepRegularity(7)
        guard days.contains(where: { $0.hasData }) else { return .noData(period: period) }
        guard let shown = days.last?.index ?? days.dropLast().last?.index else {
            return CardSnapshot(period: period, value: "Calibrating",
                                comparison: "Needs \(SleepConsistency.minimumDays) of \(SleepConsistency.days) nights")
        }
        let rating = SleepConsistency.rating(shown)
        return CardSnapshot(
            period: period,
            value: format(shown, 0),
            comparison: "Typical adult \(format(SleepConsistency.populationMedian, 0))",
            tone: Self.tone(rating),
            rating: rating,
            chart: .bars(days.map { $0.index.map { max($0, 0) } }, target: 100,
                         ratings: days.map { $0.index.map(SleepConsistency.rating) })
        )
    }

    /// The Sleep Regularity Index for the week ending at noon on each of the last `count` days, oldest first.
    /// Today's week ends now. `hasData` is false without any sleep record in that week.
    func sleepRegularity(_ count: Int) async throws -> [(day: Date, hasData: Bool, index: Double?)] {
        let days = lastDays(count)
        let noon = { (day: Date) in self.calendar.date(byAdding: .hour, value: 12, to: day)! }
        let first = calendar.date(byAdding: .day, value: -SleepConsistency.days, to: noon(days[0]))!
        let sleep = try await source.sleepPeriods(in: DateInterval(start: first, end: max(now, first)))
        return days.map { day in
            let start = calendar.date(byAdding: .day, value: -SleepConsistency.days, to: noon(day))!
            let hasData = sleep.contains { $0.stage != .awake && $0.end > start && $0.start < noon(day) }
            return (day, hasData, SleepConsistency.index(sleep: sleep, start: start, until: min(now, noon(day))))
        }
    }

    /// Last night's score; until last night is recorded, the night before's. Bars show the last 7 nights.
    private func sleepScore() async throws -> CardSnapshot {
        let days = try await sleepScoreDays(7)
        let last = days.count - 1
        let shownIndex = days[last].hasData ? last : last - 1
        guard days[shownIndex].hasData else { return .noData(period: lastNightLabel) }
        let period = shownIndex == last ? lastNightLabel : yesterdayLabel
        guard let shown = days[shownIndex].result else {
            return CardSnapshot(period: period, value: "Calibrating",
                                comparison: "Needs sleep stages and \(SleepConsistency.minimumDays) of \(SleepConsistency.days) nights")
        }
        return CardSnapshot(
            period: period,
            value: "\(shown.score)",
            comparison: shown.reason,
            tone: Self.tone(shown.rating),
            rating: shown.rating,
            chart: .bars(days.map { $0.result.map { Double($0.score) } }, target: 100, ratings: days.map { $0.result?.rating })
        )
    }

    /// The sleep score of the night ending on each of the last `count` days, oldest first. `hasData` is false
    /// without any sleep that night; `result` is also nil while the regularity index calibrates or without stages,
    /// from either a timeline or totals.
    func sleepScoreDays(_ count: Int) async throws -> [(day: Date, hasData: Bool, result: SleepScore.Result?)] {
        let days = lastDays(count)
        let first = calendar.date(byAdding: .day, value: -1, to: days[0])!
        let periods = try await source.sleepPeriods(in: DateInterval(start: first, end: max(now, first)))
        let byNight = Dictionary(grouping: periods) { SleepNight.wakeDay(forEnd: $0.end, calendar: calendar) }
        // Stage totals stand in for nights without a stage timeline, such as Garmin's (#100).
        let totals = Dictionary(try await source.sleepNights(days: count).map { ($0.wakeDay, $0) }) { first, _ in first }
        let regularity = try await sleepRegularity(count)
        let needs = sleepGoals(count)
        let age = try await source.age()
        return days.indices.map { index in
            let night = byNight[days[index]] ?? []
            let hasData = night.contains { $0.stage != .awake }
            let quality = SleepScore.quality(night) ?? totals[days[index]].flatMap(SleepScore.quality)
            let result = SleepScore.score(quality: quality, need: needs[index].value ?? SleepNeed.baseline,
                                          regularity: regularity[index].index, age: age)
            return (days[index], hasData, result)
        }
    }

    // MARK: - Training

    /// Race times from the latest VO₂ max, and their trend against the reading about 4 weeks before it.
    private func racePredictor() async throws -> CardSnapshot {
        let readings = try await source.daily(.vo2Max, days: 90).filter { $0.value != nil }
        guard let latest = readings.last, let vo2Max = latest.value else { return .noData(period: "Latest") }
        let monthBefore = calendar.date(byAdding: .day, value: -28, to: latest.day)!
        let earlier = readings.last(where: { $0.day <= monthBefore }) ?? (readings.count > 1 ? readings.first : nil)
        return CardSnapshot(
            period: dayLabel(latest.day),
            value: earlier?.value.map { RacePredictor.trend(from: $0, to: vo2Max) } ?? "First estimate",
            comparison: "From VO₂ max \(format(vo2Max, 1))",
            detail: .stats(RacePredictor.distances.map {
                (value: Self.raceTime(RacePredictor.time(meters: $0.meters, vo2Max: vo2Max)), label: $0.name)
            })
        )
    }

    /// Today's load so far, with the 7-day against 28-day ratio and the last 7 days' loads.
    private func strain() async throws -> CardSnapshot {
        guard let days = try await strainDays(7) else {
            return CardSnapshot(period: todayLabel, value: "Calibrating", comparison: "Needs your age or max heart rate")
        }
        guard let today = days.last, let load = today.load else { return .noData(period: todayLabel) }
        var snapshot = CardSnapshot(period: todayLabel, value: format(load, 0), unit: "TRIMP",
                                    chart: .bars(days.map { $0.load ?? 0 }))
        if let ratio = today.ratio {
            snapshot.comparison = "\(Strain.word(ratio.value)) · ratio \(format(ratio.value, 2))"
            snapshot.rating = Strain.rating(ratio.value)
            snapshot.tone = Self.tone(Strain.rating(ratio.value))
            snapshot.recommendation = isToday ? Recommendations.load(ratio: ratio.value) : nil
        } else {
            snapshot.comparison = "Ratio needs \(Strain.minimumChronicDays) days"
        }
        return snapshot
    }

    /// Each of the last `count` days' load (nil without heart rate) and its acute:chronic ratio, oldest first.
    /// Nil altogether without a max heart rate to set the zones.
    func strainDays(_ count: Int) async throws -> [(day: Date, load: Double?, ratio: Strain.Ratio?)]? {
        guard let maxHeartRate = Resources.maxHeartRate(age: try await source.age(),
                                                        highestRecorded: try await source.highestHeartRate(days: 365))
        else { return nil }
        let days = lastDays(count + Strain.chronicDays - 1)
        let heartRate = try await source.heartRate(in: DateInterval(start: days[0], end: max(now, days[0])))
        let byDay = Dictionary(grouping: heartRate) { calendar.startOfDay(for: $0.date) }
        let loads = days.map { day in
            byDay[day].map { Strain.load(heartRate: $0, end: min(now, calendar.date(byAdding: .day, value: 1, to: day)!),
                                         maxHeartRate: maxHeartRate) }
        }
        return (days.count - count..<days.count).map { (days[$0], loads[$0], Strain.ratio(loads: loads, endingAt: $0)) }
    }

    /// Hours left until recovered from the last few days' workouts, counting down with the clock.
    private func recoveryTime() async throws -> CardSnapshot {
        guard let status = try await recoveryTimeStatus() else {
            return CardSnapshot(period: nowLabel, value: "Calibrating", comparison: "Needs your age or max heart rate")
        }
        guard let recovered = status.recoveredAt, let lastEnd = status.lastWorkoutEnd else {
            if status.lastWorkoutEnd == nil, try await source.workouts(days: 30).isEmpty { return .noData(period: nowLabel) }
            return CardSnapshot(period: nowLabel, value: "Recovered", comparison: "Ready for hard training",
                                tone: .good, rating: .good, chart: .progress(value: 1, goal: 1))
        }
        let left = recovered.timeIntervalSince(now)
        let total = recovered.timeIntervalSince(lastEnd)
        let day = calendar.isDate(recovered, inSameDayAs: now) ? "" : "\(recovered.formatted(.dateTime.weekday(.abbreviated))) "
        return CardSnapshot(
            period: nowLabel,
            value: "\(Int((left / 3600).rounded(.up)))",
            unit: "h",
            comparison: "Until \(day)\(recovered.formatted(date: .omitted, time: .shortened))",
            rating: .fair,
            chart: .progress(value: total - left, goal: total)
        )
    }

    /// When recovery from the last 3 days' workouts ends (nil once recovered) and when the latest workout ended
    /// (nil without workouts). Nil altogether without a max heart rate to set the zones.
    func recoveryTimeStatus() async throws -> (recoveredAt: Date?, lastWorkoutEnd: Date?)? {
        guard let maxHeartRate = Resources.maxHeartRate(age: try await source.age(),
                                                        highestRecorded: try await source.highestHeartRate(days: 365))
        else { return nil }
        let workouts = try await source.workouts(days: 4)
            .map { RecoveryTime.Workout(end: $0.start.addingTimeInterval($0.duration), averageHeartRate: $0.averageHeartRate) }
            .filter { $0.end <= now }
        guard let lastEnd = workouts.map(\.end).max() else { return (nil, nil) }
        let today = calendar.startOfDay(for: now)
        let wake = try await source.overnight(days: 1).last.flatMap { $0.wakeDay == today ? $0.wakeTime : nil }
        let morning = try await recoveryDays(1).last?.result?.rating
        return (RecoveryTime.recoveredAt(workouts: workouts, maxHeartRate: maxHeartRate, now: now,
                                         wake: wake, morningRecovery: morning), lastEnd)
    }

    private func lastWorkout() async throws -> CardSnapshot {
        guard let workout = try await source.workouts(days: 30).first else { return .noData(period: "Last 30 days") }
        return workoutSnapshot(workout)
    }

    /// A Last Workout card for one workout.
    func workoutSnapshot(_ workout: WorkoutSummary) -> CardSnapshot {
        CardSnapshot(
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
        let goal = goals.value(.workouts, on: calendar.startOfDay(for: now))
        let count = workouts == 1 ? "1 workout" : "\(workouts) workouts"
        return CardSnapshot(
            period: "Last 7 days",
            value: Self.hoursMinutes(minutes.reduce(0, +) * 60),
            comparison: goal.map { "\(count) of \(format($0, 0))" } ?? count,
            rating: goal.map { DayRatings.goal(Double(workouts), goal: $0) },
            chart: .bars(minutes)
        )
    }

    private func last30Days() async throws -> CardSnapshot {
        let workouts = try await source.workouts(days: 30)
        // The count sits in the period line, so the calendar gets the card's height; the value isn't drawn.
        return CardSnapshot(
            period: workouts.isEmpty ? "No workouts" : workouts.count == 1 ? "1 workout" : "\(workouts.count) workouts",
            value: "\(workouts.count)",
            unit: workouts.count == 1 ? "workout" : "workouts",
            detail: .days(workoutDays(workouts, days: 30))
        )
    }

    /// Each of the last `days` days' workouts by sport, oldest first.
    private func workoutDays(_ workouts: [WorkoutSummary], days: Int) -> [WorkoutDay] {
        let byDay = WorkoutDay.byDay(workouts, calendar: calendar)
        return lastDays(days).map { byDay[$0] ?? WorkoutDay() }
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
    private var lastNightLabel: String { isToday ? "Last night" : "Night before" }
    /// Resources at the end of a past day.
    private var nowLabel: String { isToday ? "Now" : "End of day" }
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

    /// "−1,580 of 10,000", or "Goal reached" at or above it.
    static func goalComparison(_ value: Double, goal: Double, decimals: Int) -> String {
        guard value < goal else { return "Goal reached" }
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(decimals))
        return "−\((goal - value).formatted(style)) of \(goal.formatted(style))"
    }

    nonisolated static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
    }

    /// "24:10" under an hour, "1:51:20" above.
    static func raceTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
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
