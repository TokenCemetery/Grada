import Foundation

/// What Grada suggested for one day, so the next report can follow up on what was actually said rather than on
/// a recalculation with newer data. Drawn from health data, so it stays in this device's UserDefaults and never
/// goes to iCloud (#111).
nonisolated struct DayPlan: Codable, Equatable {
    enum Focus: String, Codable {
        case training, steps, bedtime
    }

    /// The morning's focus.
    var focus: Focus?
    var training: TrainingPlan.Level?
    /// Why that training, as the morning report said it.
    var trainingReason: String?
    var stepsGoal: Double?
    /// Resting heart rate or HRV was off this morning.
    var bodyWarning: Bool?
    /// Tonight's bedtime, as the evening report last gave it.
    var bedtime: Date?
}

/// Each day's plan, keyed by day. The morning part is saved the first time the day's morning report has data, so a
/// report reloaded after a workout doesn't change the plan the workout followed. Only a body warning that arrives
/// later, with last night's HRV or resting heart rate, replaces it once: that warning comes before everything else.
/// The bedtime is saved each time the evening report loads, so it's the latest one the user saw.
nonisolated enum DayPlanStore {
    static let key = "dayPlans"
    /// Only yesterday's and today's are read; a week covers clocks and time zones moving the day.
    static let keptDays = 7

    static func plan(for day: Date, defaults: UserDefaults, calendar: Calendar) -> DayPlan? {
        all(defaults)[DayKey.make(day, calendar: calendar)]
    }

    /// Saves the morning part unless the day has one, or has one without the body warning `plan` brings; returns
    /// the day's plan either way.
    @discardableResult
    static func saveMorning(_ plan: DayPlan, for day: Date, defaults: UserDefaults, calendar: Calendar) -> DayPlan {
        update(day, defaults: defaults, calendar: calendar) { saved in
            guard saved.focus == nil || (plan.bodyWarning == true && saved.bodyWarning != true) else { return }
            saved.focus = plan.focus
            saved.training = plan.training
            saved.trainingReason = plan.trainingReason
            saved.stepsGoal = plan.stepsGoal
            saved.bodyWarning = plan.bodyWarning
        }
    }

    static func saveBedtime(_ bedtime: Date, for day: Date, defaults: UserDefaults, calendar: Calendar) {
        update(day, defaults: defaults, calendar: calendar) { $0.bedtime = bedtime }
    }

    @discardableResult
    private static func update(_ day: Date, defaults: UserDefaults, calendar: Calendar,
                               _ change: (inout DayPlan) -> Void) -> DayPlan {
        var plans = all(defaults)
        let key = DayKey.make(day, calendar: calendar)
        var plan = plans[key] ?? DayPlan()
        change(&plan)
        plans[key] = plan
        // Day keys sort by date, so the oldest go first.
        for old in plans.keys.sorted().dropLast(keptDays) { plans[old] = nil }
        defaults.set(try? JSONEncoder().encode(plans), forKey: Self.key)
        return plan
    }

    private static func all(_ defaults: UserDefaults) -> [String: DayPlan] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: DayPlan].self, from: $0) } ?? [:]
    }
}

/// The day's training as a concrete session. Levels and durations are Grada's choice; the rules follow the
/// readiness, recovery and load the cards already show, so the suggestion never disagrees with them.
nonisolated enum TrainingPlan {
    enum Level: String, Codable, CaseIterable {
        case rest, easy, moderate, hard

        /// Session length, warm-up included; nil for rest.
        var minutes: ClosedRange<Int>? {
            switch self {
            case .rest: nil
            case .easy: 30...40
            case .moderate: 40...60
            case .hard: 45...60
            }
        }

        var symbol: String {
            switch self {
            case .rest: "bed.double"
            case .easy: "figure.walk"
            case .moderate: "figure.run"
            case .hard: "flame"
            }
        }

        var text: String {
            switch self {
            case .rest: String(localized: "Rest day")
            case .easy: String(localized: "Easy session, 30–40 minutes")
            case .moderate: String(localized: "Moderate session, 40–60 minutes")
            case .hard: String(localized: "Hard session, 45–60 minutes")
            }
        }
    }

    struct Input {
        var readiness: TrainingReadiness.Result?
        /// The reason of a resting heart rate or HRV warning this morning.
        var bodyWarning: String?
        var loadRatio: Double?
        /// When recovery from recent workouts ends; nil once recovered.
        var recoveredAt: Date?
        var workouts = 0
        var workoutsGoal: Double?
        var intensityMinutes: Double?
        var intensityGoal: Double?
    }

    struct Suggestion: Equatable {
        let level: Level
        let reason: String
        /// A body warning or a weekly goal behind: training is then the day's focus.
        let isPriority: Bool
    }

    static func suggest(_ input: Input) -> Suggestion {
        let workoutsBehind = input.workoutsGoal.map { Double(input.workouts) < $0 } ?? false
        var intensityBehind = false
        if let minutes = input.intensityMinutes, let goal = input.intensityGoal { intensityBehind = minutes < goal }
        let behind = workoutsBehind || intensityBehind
        let ratio = input.loadRatio ?? 0
        let ratioText = ratio.formatted(.number.precision(.fractionLength(1)))

        if let warning = input.bodyWarning {
            let rest = input.readiness?.rating == .poor || ratio >= Strain.dangerRatio
            return Suggestion(level: rest ? .rest : .easy, reason: warning, isPriority: true)
        }
        if ratio >= Strain.dangerRatio {
            return Suggestion(level: .rest, reason: String(localized: "This week's load is \(ratioText)× your 4-week average, so give it a few calmer days."),
                              isPriority: behind)
        }
        if let readiness = input.readiness, readiness.rating == .poor {
            return Suggestion(level: .easy, reason: String(localized: "Training readiness is low (\(readiness.reason))."), isPriority: behind)
        }
        if let recovered = input.recoveredAt {
            return Suggestion(level: .easy, reason: String(localized: "Still recovering from your last workout until \(recovered.formatted(date: .omitted, time: .shortened))."),
                              isPriority: behind)
        }
        if ratio > Strain.sweetSpot.upperBound {
            return Suggestion(level: .easy, reason: String(localized: "This week's load is \(ratioText)× your 4-week average, so hold it steady."),
                              isPriority: behind)
        }
        guard behind else {
            // Met only when there's data to say so; without a workouts goal or intensity minutes, nothing is known.
            let met = input.workoutsGoal != nil || input.intensityMinutes != nil
            return Suggestion(level: input.readiness?.rating == .good ? .moderate : .easy,
                              reason: met ? String(localized: "Your week's training goals are met, so today's session is a bonus.")
                                  : String(localized: "A comfortable session keeps you moving."),
                              isPriority: false)
        }
        let week = workoutsBehind
            ? weekWorkouts(input.workouts, goal: input.workoutsGoal ?? 0)
            : String(localized: "\(whole(input.intensityMinutes ?? 0)) of \(whole(input.intensityGoal ?? 0)) intensity minutes in the last 7 days.")
        return Suggestion(level: input.readiness?.rating == .good ? .hard : .moderate,
                          reason: input.readiness?.rating == .good ? String(localized: "Training readiness is high. \(week)") : week,
                          isPriority: true)
    }

    static func recommendation(_ level: Level, reason: String) -> Recommendation {
        Recommendation(symbol: level.symbol, text: level.text, reason: reason)
    }

    static func weekWorkouts(_ done: Int, goal: Double) -> String {
        done == 1 ? String(localized: "1 of \(whole(goal)) workouts in the last 7 days.")
            : String(localized: "\(done) of \(whole(goal)) workouts in the last 7 days.")
    }

    private static func whole(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

/// Whether a day's advice was followed, judged only from Health data. Nil when the data can't say.
nonisolated enum FollowUp {
    enum Outcome: Equatable {
        case followed, missed
    }

    /// A bedtime within this of the planned one counts as on time. Grada's choice.
    static let bedtimeLeeway: TimeInterval = 15 * 60
    /// A workout this long counts as the planned session. Grada's choice.
    static let sessionMinutes: TimeInterval = 20 * 60

    static func bedtime(planned: Date, actual: Date?) -> Outcome? {
        actual.map { $0 <= planned.addingTimeInterval(bedtimeLeeway) ? .followed : .missed }
    }

    static func steps(goal: Double, steps: Double?) -> Outcome? {
        steps.map { $0 >= goal ? .followed : .missed }
    }

    /// Rest and easy days hold if no workout reached the threshold zone; moderate and hard ones need a workout
    /// of `sessionMinutes`. Workouts without heart rate, or no max heart rate, can't tell an easy day.
    static func training(_ level: TrainingPlan.Level, workouts: [WorkoutSummary], maxHeartRate: Double?) -> Outcome? {
        switch level {
        case .rest, .easy:
            var unknown = false
            for workout in workouts {
                guard let average = workout.averageHeartRate, let maxHeartRate else { unknown = true; continue }
                if IntensityZones.zone(average, maxHeartRate: maxHeartRate) != .low { return .missed }
            }
            return unknown ? nil : .followed
        case .moderate, .hard:
            return workouts.contains { $0.duration >= sessionMinutes } ? .followed : .missed
        }
    }
}
