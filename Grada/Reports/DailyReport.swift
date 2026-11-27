import Foundation

/// A day's morning or evening report. Morning plans the day: how yesterday's advice went, today's focus and
/// training. Evening wraps it up and looks ahead: how the focus went, what drained and restored Resources,
/// what the week still needs and tonight's bedtime. Both keep a few cards and their recommendations.
struct DailyReport {
    enum Kind {
        /// Last night's sleep, recovery, vitals and readiness.
        case morning
        /// Today's activity and training against goals, and tonight's bedtime.
        case evening

        var title: String {
            switch self {
            case .morning: String(localized: "Morning Report")
            case .evening: String(localized: "Evening Report")
            }
        }

        /// The cards it shows, in order.
        var kinds: [CardKind] {
            switch self {
            case .morning: [.sleepScore, .sleepDuration, .recovery, .healthStatus, .trainingReadiness]
            case .evening: [.steps, .activeEnergy, .intensityMinutes, .weeklyTraining, .strain]
            }
        }

        /// Cards it doesn't show but takes recommendations from, besides its own.
        var adviceKinds: [CardKind] {
            switch self {
            case .morning: [.restingHeartRate, .hrvStatus, .strain]
            // Tonight's bedtime; the recommendation already says the sleep need, so no row repeats it.
            case .evening: [.sleepNeed]
            }
        }
    }

    let kind: Kind
    /// False when there's nothing to report: the morning report waits for the night that ended on its day.
    var hasData = false
    var day: Date = .distantPast
    /// Picks each sentence's wording for `day`.
    var calendar: Calendar = .current
    var snapshots: [CardKind: CardSnapshot] = [:]
    var recommendations: [Recommendation] = []
    /// Today only: the one thing that matters most. Morning: the training on a body warning or with a weekly
    /// goal behind, else the steps goal. Evening: tonight's bedtime.
    var focus: Recommendation?
    /// Morning, today only: the day's training when it isn't the focus.
    var training: Recommendation?
    /// How the advice before it went, focus first: yesterday's in the morning, this morning's in the evening.
    var followUps: [String] = []
    /// How the focus being followed up on went, for the notification's title.
    var focusOutcome: FollowUp.Outcome?
    /// Morning: resting heart rate or HRV is off.
    var bodyWarning = false
    /// Evening, today only.
    var resourcesRecap: String?
    var tomorrow: String?
    var bedtime: Date?

    /// The report for the builder's day. Like the cards' recommendations, the plan and follow-ups come only for
    /// today, and loading today's saves its plan for tomorrow's follow-up. The evening's follow-up waits for the
    /// evening report's time, so a morning look at Journal doesn't judge a day that's only begun; a notification
    /// built ahead of that time, for it, passes `forNotification`.
    /// Cards whose advice the reports give in their own words: the morning's session and the evening's
    /// look at what the week still needs.
    static let ownAdvice: Set<CardKind> = [.trainingReadiness, .intensityMinutes]

    static func load(_ kind: Kind, _ builder: SnapshotBuilder, defaults: UserDefaults = .standard,
                     forNotification: Bool = false) async throws -> DailyReport {
        let day = builder.calendar.startOfDay(for: builder.now)
        if kind == .morning {
            let nights = try await builder.source.sleepNights(days: 1)
            guard nights.contains(where: { $0.wakeDay == day && $0.asleep > 0 }) else { return DailyReport(kind: kind) }
        }
        var report = DailyReport(kind: kind, hasData: true, day: day, calendar: builder.calendar)
        var warning: String?
        // Advice-only cards first: the evening's bedtime matters most.
        for card in kind.adviceKinds + kind.kinds {
            let snapshot = try await builder.snapshot(for: card)
            if kind.kinds.contains(card) { report.snapshots[card] = snapshot }
            if card == .restingHeartRate || card == .hrvStatus, warning == nil { warning = snapshot.recommendation?.reason }
            // Both reports take Strain's, so a card's advice is listed once.
            if let recommendation = snapshot.recommendation, !Self.ownAdvice.contains(card),
               !report.recommendations.contains(recommendation) {
                report.recommendations.append(recommendation)
            }
        }
        guard builder.isToday else { return report }
        switch kind {
        case .morning: try await report.planDay(builder, warning: warning, defaults: defaults)
        case .evening: try await report.wrapUpDay(builder, defaults: defaults, forNotification: forNotification)
        }
        return report
    }

    private mutating func planDay(_ builder: SnapshotBuilder, warning: String?, defaults: UserDefaults) async throws {
        let suggestion = try await builder.trainingSuggestion(warning: warning)
        let stepsGoal = builder.goals.value(.steps, on: day)
        let plan = DayPlanStore.saveMorning(
            DayPlan(focus: suggestion.isPriority || stepsGoal == nil ? .training : .steps, training: suggestion.level,
                    trainingReason: suggestion.reason, stepsGoal: stepsGoal, bodyWarning: warning != nil),
            for: day, defaults: defaults, calendar: calendar)
        // From the saved plan, so the report keeps saying what it said this morning.
        let training = TrainingPlan.recommendation(plan.training ?? suggestion.level, reason: plan.trainingReason ?? suggestion.reason)
        if plan.focus == .steps, let goal = plan.stepsGoal {
            focus = Recommendations.stepsGoal(goal)
            self.training = training
        } else {
            focus = training
        }
        bodyWarning = plan.bodyWarning == true

        let yesterday = calendar.date(byAdding: .day, value: -1, to: day)!
        guard let past = DayPlanStore.plan(for: yesterday, defaults: defaults, calendar: calendar) else { return }
        let lastNight = try await builder.source.overnight(days: 1).last.flatMap { $0.wakeDay == day ? $0.bedtime : nil }
        let checks = try await DayChecks(builder, day: yesterday)
        for item in Self.followUpOrder(past.focus) {
            var result: (text: String, outcome: FollowUp.Outcome)?
            if item == .bedtime, let planned = past.bedtime, let lastNight,
               let outcome = FollowUp.bedtime(planned: planned, actual: lastNight) {
                result = (ReportText.bedtime(actual: lastNight, outcome, sleptWell: snapshots[.sleepScore]?.rating == .good,
                                             day: day, calendar: calendar), outcome)
            } else {
                result = checks.followUp(item, plan: past, .yesterday, day: day)
            }
            guard let result else { continue }
            if item == past.focus { focusOutcome = result.outcome }
            followUps.append(result.text)
        }
    }

    private mutating func wrapUpDay(_ builder: SnapshotBuilder, defaults: UserDefaults, forNotification: Bool) async throws {
        let tonight = try await builder.bedtimePlan(need: try await builder.tonightsNeed(),
                                                    debt: try await builder.sleepDebt(1)?.last?.debt ?? 0)
        let usualBedtime = SleepSchedule.bedtime(on: day, usual: tonight?.usualBedtime, defaults: defaults, calendar: calendar)
        let isEvening = builder.now >= usualBedtime.addingTimeInterval(-SleepSchedule.windDown(defaults))
        if forNotification || isEvening, let plan = DayPlanStore.plan(for: day, defaults: defaults, calendar: calendar),
           let planned = plan.focus,
           let result = try await DayChecks(builder, day: day).followUp(planned, plan: plan, .today, day: day) {
            focusOutcome = result.outcome
            followUps.append(result.text)
        }
        resourcesRecap = try await builder.resourcesContributions().flatMap { ReportText.resources($0.amounts) }
        let week = try await builder.weekTraining()
        tomorrow = ReportText.tomorrow(workouts: week.workouts, workoutsGoal: week.workoutsGoal,
                                       intensityMinutes: week.intensityMinutes, intensityGoal: week.intensityGoal)
        if let tonight {
            bedtime = tonight.bedtime
            focus = Recommendations.bedtime(tonight, calendar: calendar)
            DayPlanStore.saveBedtime(tonight.bedtime, for: day, defaults: defaults, calendar: calendar)
        }
    }

    /// The focus first, then last night's bedtime.
    static func followUpOrder(_ focus: DayPlan.Focus?) -> [DayPlan.Focus] {
        guard let focus, focus != .bedtime else { return [.bedtime] }
        return [focus, .bedtime]
    }

    var notificationTitle: String {
        switch kind {
        case .morning: ReportText.morningTitle(focusOutcome, bodyWarning: bodyWarning, day: day, calendar: calendar)
        case .evening: ReportText.eveningTitle(focusOutcome, day: day, calendar: calendar)
        }
    }

    /// How the advice before it went, then the one thing for now: today's focus, or tonight's bedtime.
    var notificationBody: String {
        let next = switch kind {
        case .morning: focus.map(ReportText.morningFocus)
        case .evening: bedtime.map(ReportText.eveningBedtime)
        }
        let lines = [followUps.first, next].compactMap { $0 }
        return lines.isEmpty ? String(localized: "Your report is ready in Journal.") : lines.joined(separator: "\n")
    }
}

/// A day's steps and workouts, to follow up on its plan.
private struct DayChecks {
    let steps: Double?
    let workouts: [WorkoutSummary]
    let maxHeartRate: Double?
    let calendar: Calendar

    /// `day` is today or yesterday.
    init(_ builder: SnapshotBuilder, day: Date) async throws {
        let calendar = builder.calendar
        let isToday = calendar.isDate(day, inSameDayAs: builder.now)
        let series = try await builder.source.daily(.steps, days: 2)
        steps = isToday ? series.last?.value : series.dropLast().last?.value
        workouts = try await builder.source.workouts(days: 2).filter { calendar.isDate($0.start, inSameDayAs: day) }
        maxHeartRate = Resources.maxHeartRate(age: try await builder.source.age(),
                                              highestRecorded: try await builder.source.highestHeartRate(days: 365))
        self.calendar = calendar
    }

    /// Training and steps; the bedtime needs the night after, so the morning report checks it itself.
    func followUp(_ item: DayPlan.Focus, plan: DayPlan, _ when: ReportText.When, day: Date) -> (text: String, outcome: FollowUp.Outcome)? {
        switch item {
        case .training:
            guard let level = plan.training,
                  let outcome = FollowUp.training(level, workouts: workouts, maxHeartRate: maxHeartRate) else { return nil }
            return (ReportText.training(level, outcome, when, day: day, calendar: calendar), outcome)
        case .steps:
            guard let goal = plan.stepsGoal, let steps, let outcome = FollowUp.steps(goal: goal, steps: steps) else { return nil }
            return (ReportText.steps(goal: goal, steps: steps, outcome, when, day: day, calendar: calendar), outcome)
        case .bedtime:
            return nil
        }
    }
}

/// The afternoon check-in: a nudge while a goal is behind but still reachable today, and silence otherwise.
nonisolated enum CheckIn {
    static let id = "afternoonCheckIn"
    /// How long before bedtime it comes: early enough for a walk or a session after work. Grada's choice.
    static let beforeBedtime: TimeInterval = 6 * 3600
    /// The longest walk worth suggesting; with more steps to go, the goal waits for tomorrow. Grada's choice.
    static let longestWalkMinutes = 90

    /// Minutes of brisk walking for `left` steps; nil when there's nothing left or it's longer than worth suggesting.
    static func walkMinutes(left: Double) -> Int? {
        guard left > 0 else { return nil }
        let minutes = Int((left / Recommendations.stepsPerMinute).rounded(.up))
        return minutes <= longestWalkMinutes ? minutes : nil
    }

    /// Today's planned session if it hasn't happened yet, else the steps to the goal. Nil when nothing's left to nudge.
    static func message(_ builder: SnapshotBuilder, defaults: UserDefaults = .standard) async throws -> (title: String, body: String)? {
        let calendar = builder.calendar
        let day = calendar.startOfDay(for: builder.now)
        let plan = DayPlanStore.plan(for: day, defaults: defaults, calendar: calendar)
        let title = ReportText.checkInTitle(day: day, calendar: calendar)
        if plan?.focus == .training, let level = plan?.training, level == .moderate || level == .hard {
            let workouts = try await builder.source.workouts(days: 1).filter { calendar.isDate($0.start, inSameDayAs: day) }
            if FollowUp.training(level, workouts: workouts, maxHeartRate: nil) == .missed {
                return (title, ReportText.checkInTraining(level, day: day, calendar: calendar))
            }
        }
        guard let goal = plan?.stepsGoal ?? builder.goals.value(.steps, on: day),
              let steps = try await builder.source.daily(.steps, days: 1).last?.value,
              let minutes = walkMinutes(left: goal - steps) else { return nil }
        return (title, ReportText.checkInSteps(left: goal - steps, minutes: minutes, day: day, calendar: calendar))
    }
}

nonisolated extension SnapshotBuilder {
    /// Today's session from what the cards show. `warning` is the reason of a resting heart rate or HRV warning.
    func trainingSuggestion(warning: String?) async throws -> TrainingPlan.Suggestion {
        let week = try await weekTraining()
        var input = TrainingPlan.Input()
        input.readiness = try await readinessDays(7).last?.result
        input.bodyWarning = warning
        input.loadRatio = try await strainDays(1)?.last?.ratio?.value
        input.recoveredAt = try await recoveryTimeStatus()?.recoveredAt
        (input.workouts, input.workoutsGoal) = (week.workouts, week.workoutsGoal)
        (input.intensityMinutes, input.intensityGoal) = (week.intensityMinutes, week.intensityGoal)
        return TrainingPlan.suggest(input)
    }

    /// Training Readiness's advice: the session the morning report would suggest now, with the same warnings it takes.
    func trainingRecommendation() async throws -> Recommendation {
        var warning = try await vital(.restingHeartRate, .current).recommendation?.reason
        if warning == nil { warning = try await hrvStatus(.current).recommendation?.reason }
        let suggestion = try await trainingSuggestion(warning: warning)
        return TrainingPlan.recommendation(suggestion.level, reason: suggestion.reason)
    }

    /// Workouts and intensity minutes over the last 7 days, as the cards count them, with their goals.
    func weekTraining() async throws -> (workouts: Int, workoutsGoal: Double?, intensityMinutes: Double?, intensityGoal: Double) {
        let day = calendar.startOfDay(for: now)
        let intensity = try await intensityDays(7).compactMap(\.value)
        return (try await source.workouts(days: 7).count, goals.value(.workouts, on: day),
                intensity.isEmpty ? nil : intensity.reduce(0, +),
                goals.value(.intensityMinutes, on: day) ?? IntensityMinutes.weeklyTarget)
    }
}

/// When the user sleeps and wakes, for the reports: their own times, or the usual ones from recent nights.
/// Kept on this device.
nonisolated enum SleepSchedule {
    static let usesUsualTimesKey = "sleepSchedule.usesUsualTimes"
    /// Minutes after midnight.
    static let wakeMinutesKey = "sleepSchedule.wakeMinutes"
    /// Minutes after midnight; before noon means after midnight.
    static let bedtimeMinutesKey = "sleepSchedule.bedtimeMinutes"
    /// Minutes before bedtime that the evening report comes.
    static let windDownMinutesKey = "sleepSchedule.windDownMinutes"
    static let morningReportKey = "sleepSchedule.morningReport"
    static let eveningReportKey = "sleepSchedule.eveningReport"
    static let checkInKey = "sleepSchedule.checkIn"
    /// Until there are enough nights for usual times.
    static let defaultWakeMinutes = 7 * 60
    static let defaultBedtimeMinutes = 23 * 60
    /// No study sets how long before bed to wind down (Irish et al. 2015 found sleep hygiene advice largely
    /// untested), so this is Grada's choice.
    static let defaultWindDownMinutes = 60

    /// The wake-up on `day`: the user's own time, else `usual`, else the default.
    static func wake(on day: Date, usual: Date?, defaults: UserDefaults = .standard, calendar: Calendar) -> Date {
        if usesUsualTimes(defaults), let usual { return usual }
        let minutes = usesUsualTimes(defaults) ? defaultWakeMinutes : defaults.object(forKey: wakeMinutesKey) as? Int ?? defaultWakeMinutes
        return time(minutes, on: day, calendar: calendar)
    }

    /// The bedtime on the evening of `day`: the user's own time, else `usual`, else the default.
    static func bedtime(on day: Date, usual: Date?, defaults: UserDefaults = .standard, calendar: Calendar) -> Date {
        if usesUsualTimes(defaults), let usual { return usual }
        let minutes = usesUsualTimes(defaults) ? defaultBedtimeMinutes
            : defaults.object(forKey: bedtimeMinutesKey) as? Int ?? defaultBedtimeMinutes
        // A bedtime before noon is after midnight, so on the next calendar day.
        let start = calendar.startOfDay(for: day)
        let evening = minutes < 12 * 60 ? calendar.date(byAdding: .day, value: 1, to: start)! : start
        return time(minutes, on: evening, calendar: calendar)
    }

    /// The clock time `minutes` after midnight on `day`. Adding seconds to midnight would be an hour off on the
    /// days clocks change.
    static func time(_ minutes: Int, on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)!
    }

    static func windDown(_ defaults: UserDefaults = .standard) -> TimeInterval {
        Double(defaults.object(forKey: windDownMinutesKey) as? Int ?? defaultWindDownMinutes) * 60
    }

    private static func usesUsualTimes(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: usesUsualTimesKey) as? Bool ?? true
    }
}
