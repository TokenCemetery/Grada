import Foundation

nonisolated extension SnapshotBuilder {
    // MARK: - Sleep

    /// The night that ended today; until there is one (e.g. just after midnight), yesterday's.
    /// Sleep stages always shows the 7 nights; Sleep shows them only as its 7-day variant, filling toward the goal.
    func sleep(withStages: Bool, _ variant: CardVariant) async throws -> CardSnapshot {
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
            comparison: String(localized: "\(Self.signedMinutes(shown.night.asleep - goal)) of \(Self.hoursMinutes(goal)) goal"),
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
    func sleepNeed() async throws -> CardSnapshot {
        guard let nights = try await sleepDebt(7) else { return .noData(period: tonightLabel) }
        let need = goals.value(.sleep, on: calendar.startOfDay(for: now)) ?? SleepNeed.baseline
        let owed = nights[nights.count - 1].debt
        let bedtime = isToday ? try await bedtimePlan(need: need) : nil
        return CardSnapshot(
            period: tonightLabel,
            value: Self.hoursMinutes(need),
            comparison: owed >= 5 * 60
                ? String(localized: "Sleep debt \(Self.hoursMinutes(owed)) · \(SleepNeed.debtNights) nights")
                : String(localized: "No sleep debt"),
            chart: .bars(nights.map { $0.shortfall / 3600 }),
            recommendation: bedtime.map { Recommendations.bedtime($0, need: need) }
        )
    }

    /// The bedtime for a wake-up on `wakeDay` (tomorrow by default), from the last `Bedtime.nights` nights.
    func bedtimePlan(need: TimeInterval, wakeDay: Date? = nil) async throws -> Bedtime.Plan? {
        let asleep = Dictionary(try await source.sleepNights(days: Bedtime.nights).map { ($0.wakeDay, $0.asleep) },
                                uniquingKeysWith: { first, _ in first })
        let nights = try await source.overnight(days: Bedtime.nights).compactMap { night -> Bedtime.Night? in
            guard let start = night.bedtime, let end = night.wakeTime, let slept = asleep[night.wakeDay], slept > 0 else { return nil }
            return Bedtime.Night(wakeDay: night.wakeDay, start: start, end: end, asleep: slept)
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return Bedtime.plan(nights: nights, need: need, wakeDay: wakeDay ?? tomorrow, calendar: calendar)
    }

    /// The Sleep Regularity Index over the last week, rated against UK Biobank adults, with the last 7 days.
    func sleepConsistency() async throws -> CardSnapshot {
        let period = String(localized: "Last \(SleepConsistency.days) days")
        let days = try await sleepRegularity(7)
        guard days.contains(where: { $0.hasData }) else { return .noData(period: period) }
        guard let shown = days.last?.index ?? days.dropLast().last?.index else {
            return CardSnapshot(period: period, value: String(localized: "Calibrating"),
                                comparison: String(localized: "Needs \(SleepConsistency.minimumDays) of \(SleepConsistency.days) nights"))
        }
        let rating = SleepConsistency.rating(shown)
        return CardSnapshot(
            period: period,
            value: format(shown, 0),
            comparison: String(localized: "Typical adult \(format(SleepConsistency.populationMedian, 0))"),
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
    func sleepScore() async throws -> CardSnapshot {
        let days = try await sleepScoreDays(7)
        let last = days.count - 1
        let shownIndex = days[last].hasData ? last : last - 1
        guard days[shownIndex].hasData else { return .noData(period: lastNightLabel) }
        let period = shownIndex == last ? lastNightLabel : yesterdayLabel
        guard let shown = days[shownIndex].result else {
            return CardSnapshot(period: period, value: String(localized: "Calibrating"),
                                comparison: String(localized: "Needs sleep stages and \(SleepConsistency.minimumDays) of \(SleepConsistency.days) nights"))
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
            .mapValues { SleepNight.mainSleep($0, start: \.start, end: \.end) }
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
}
