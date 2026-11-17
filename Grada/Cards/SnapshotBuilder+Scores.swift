import Foundation

extension SnapshotBuilder {
    // MARK: - Scores

    /// This morning's recovery. Until last night's vitals arrive, yesterday's, like Health status.
    func recovery(_ variant: CardVariant) async throws -> CardSnapshot {
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
    func resources() async throws -> CardSnapshot {
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
    func trainingReadiness() async throws -> CardSnapshot {
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
    func healthAge() async throws -> CardSnapshot {
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
    func loadFocus() async throws -> CardSnapshot {
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
    func heartRate() async throws -> CardSnapshot {
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
}
