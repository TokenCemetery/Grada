import Foundation

/// The reports' sentences, written like a friend's: praise when advice was followed, a calm next step when it
/// wasn't, never a verdict. Each situation has a few versions, so the wording changes from day to day but
/// stays the same all day, however often a report is rebuilt.
nonisolated enum ReportText {
    /// Whether a sentence looks back on yesterday (morning) or on the day so far (evening).
    enum When {
        case yesterday, today
    }

    static func pick(_ options: [String], day: Date, calendar: Calendar) -> String {
        let index = calendar.ordinality(of: .day, in: .era, for: day) ?? 0
        return options[index % options.count]
    }

    static func training(_ level: TrainingPlan.Level, _ outcome: FollowUp.Outcome, _ when: When,
                         day: Date, calendar: Calendar) -> String {
        let options: [String] = switch (level, outcome, when) {
        case (.rest, .followed, .yesterday), (.easy, .followed, .yesterday):
            [String(localized: "You kept yesterday easy, just what your body asked for."),
             String(localized: "Yesterday stayed easy. Good call.")]
        case (.rest, .missed, .yesterday), (.easy, .missed, .yesterday):
            [String(localized: "Yesterday turned out harder than planned. No worries, just listen to your body today."),
             String(localized: "Yesterday was harder than suggested. Today's plan takes it into account.")]
        case (.moderate, .followed, .yesterday), (.hard, .followed, .yesterday):
            [String(localized: "You got your workout in yesterday. Nice work! 💪"),
             String(localized: "Workout done yesterday. Well done!")]
        case (.moderate, .missed, .yesterday), (.hard, .missed, .yesterday):
            [String(localized: "No workout yesterday, and that's okay. Today is a fresh chance."),
             String(localized: "Yesterday's workout didn't happen. Today's plan has you covered.")]
        case (.rest, .followed, .today), (.easy, .followed, .today):
            [String(localized: "You kept it easy today, just as planned."),
             String(localized: "An easy day, as your body asked. Nicely done.")]
        case (.rest, .missed, .today), (.easy, .missed, .today):
            [String(localized: "Today turned out harder than planned. A good night's sleep is the best recovery now."),
             String(localized: "A harder day than suggested. Tonight's sleep will help you bounce back.")]
        case (.moderate, .followed, .today), (.hard, .followed, .today):
            [String(localized: "Workout done today. 💪 You've earned a good rest tonight."),
             String(localized: "You got today's workout in. Great job!")]
        case (.moderate, .missed, .today), (.hard, .missed, .today):
            [String(localized: "No workout today, and that's fine. Tomorrow works too."),
             String(localized: "Today's workout didn't fit in. Rest well, and tomorrow is another chance.")]
        }
        return pick(options, day: day, calendar: calendar)
    }

    static func steps(goal: Double, steps: Double, _ outcome: FollowUp.Outcome, _ when: When,
                      day: Date, calendar: Calendar) -> String {
        let (goalText, stepsText, leftText) = (whole(goal), whole(steps), whole(max(goal - steps, 0)))
        let options: [String] = switch (outcome, when) {
        case (.followed, .yesterday):
            [String(localized: "You reached \(goalText) steps yesterday. 👏"),
             String(localized: "Steps goal done yesterday, \(stepsText) in total. Nice!")]
        case (.missed, .yesterday):
            [String(localized: "Yesterday ended at \(stepsText) of \(goalText) steps. An early walk today gets you ahead."),
             String(localized: "\(leftText) steps short yesterday. A short walk this morning makes today easier.")]
        case (.followed, .today):
            [String(localized: "Steps goal reached today. 👏"),
             String(localized: "\(stepsText) steps today, goal done. Nice!")]
        case (.missed, .today):
            [String(localized: "\(leftText) steps short of your goal today. Tomorrow's another go."),
             String(localized: "\(stepsText) of \(goalText) steps today. Every bit counts; tomorrow's a fresh start.")]
        }
        return pick(options, day: day, calendar: calendar)
    }

    /// Last night against the bedtime the evening report gave.
    static func bedtime(actual: Date, _ outcome: FollowUp.Outcome, sleptWell: Bool, day: Date, calendar: Calendar) -> String {
        let time = actual.formatted(date: .omitted, time: .shortened)
        switch outcome {
        case .followed:
            let line = pick([String(localized: "You were in bed by \(time), right on plan. 🌙"),
                             String(localized: "In bed by \(time) last night. Nice early night.")], day: day, calendar: calendar)
            return sleptWell ? line + " " + String(localized: "Your sleep score shows it.") : line
        case .missed:
            return pick([String(localized: "Later night than planned (\(time)). An earlier night tonight will help you catch up."),
                         String(localized: "Bedtime slipped to \(time) last night. Tonight is a fresh chance.")], day: day, calendar: calendar)
        }
    }

    static func morningTitle(_ outcome: FollowUp.Outcome?, bodyWarning: Bool, day: Date, calendar: Calendar) -> String {
        if bodyWarning {
            return pick([String(localized: "Take it easy today"), String(localized: "A gentle day today")], day: day, calendar: calendar)
        }
        if outcome == .followed {
            return pick([String(localized: "Nice work yesterday"), String(localized: "Great start to the day")], day: day, calendar: calendar)
        }
        return pick([String(localized: "Good morning"), String(localized: "Your plan for today")], day: day, calendar: calendar)
    }

    static func eveningTitle(_ outcome: FollowUp.Outcome?, day: Date, calendar: Calendar) -> String {
        if outcome == .followed {
            return pick([String(localized: "Nice day"), String(localized: "Well done today")], day: day, calendar: calendar)
        }
        return pick([String(localized: "Time to wind down"), String(localized: "Evening check-in")], day: day, calendar: calendar)
    }

    static func morningFocus(_ focus: Recommendation) -> String {
        String(localized: "Today: \(focus.text).", comment: "Morning notification line with today's focus, e.g. Today: Easy session, 30–40 minutes.")
    }

    static func eveningBedtime(_ bedtime: Date) -> String {
        String(localized: "Bed by \(bedtime.formatted(date: .omitted, time: .shortened)) sets you up for tomorrow.")
    }

    static func checkInTitle(day: Date, calendar: Calendar) -> String {
        pick([String(localized: "Still time today"), String(localized: "Afternoon check-in")], day: day, calendar: calendar)
    }

    static func checkInSteps(left: Double, minutes: Int, day: Date, calendar: Calendar) -> String {
        let leftText = whole(left)
        return pick([String(localized: "\(leftText) steps to your goal: a \(minutes)-minute walk gets you there."),
                     String(localized: "Just \(leftText) steps to go. A \(minutes)-minute walk this evening does it.")], day: day, calendar: calendar)
    }

    static func checkInTraining(_ level: TrainingPlan.Level, day: Date, calendar: Calendar) -> String {
        pick([String(localized: "There's still time for today's session: \(level.text)."),
              String(localized: "Today's session is still ahead: \(level.text). You've got this.")], day: day, calendar: calendar)
    }

    /// What drained and what restored Resources today, the two biggest of each. Nil when nothing moved it.
    static func resources(_ amounts: [Resources.Cause: Double]) -> String? {
        let percent = { (value: Double) in value.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always())) + "%" }
        let named = { (items: ArraySlice<(key: Resources.Cause, value: Double)>) in
            items.map { "\($0.key.title) (\(percent($0.value)))" }.formatted(.list(type: .and))
        }
        let drains = amounts.filter { $0.value <= -1 }.sorted { $0.value < $1.value }.prefix(2)
        let gains = amounts.filter { $0.value >= 1 }.sorted { $0.value > $1.value }.prefix(2)
        switch (drains.isEmpty, gains.isEmpty) {
        case (false, false): return String(localized: "What drained you today: \(named(drains)). What recharged you: \(named(gains)).")
        case (false, true): return String(localized: "What drained you today: \(named(drains)).")
        case (true, false): return String(localized: "What recharged you today: \(named(gains)).")
        case (true, true): return nil
        }
    }

    /// What the week still needs, as a look at tomorrow. Nil without a workouts goal or intensity minutes to go on.
    static func tomorrow(workouts: Int, workoutsGoal: Double?, intensityMinutes: Double?, intensityGoal: Double?) -> String? {
        if let goal = workoutsGoal, Double(workouts) < goal {
            let left = Int((goal - Double(workouts)).rounded(.up))
            return left == 1
                ? String(localized: "Tomorrow: your week still needs 1 more workout. A good night tonight sets it up.")
                : String(localized: "Tomorrow: your week still needs \(left) more workouts. A good night tonight sets them up.")
        }
        if let minutes = intensityMinutes, let goal = intensityGoal, minutes < goal {
            return String(localized: "Tomorrow: your week still needs \(whole(goal - minutes)) intensity minutes. A good night tonight sets them up.")
        }
        guard workoutsGoal != nil || intensityMinutes != nil else { return nil }
        return String(localized: "Tomorrow: your week's training goals are met, so it can be whatever feels right.")
    }

    private static func whole(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}
