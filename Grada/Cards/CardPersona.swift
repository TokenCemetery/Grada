import Foundation

/// What a fresh install's Home focuses on, picked once before goals. Each list leads with the persona's daily
/// question, leaves out what Health Status already shows and cards that need a scale or blood pressure cuff,
/// and fills every row in both 2 and 3 columns: one device switches between them, so no device check would do.
nonisolated enum CardPersona: CaseIterable, Identifiable {
    case health, recovery, training

    var id: Self { self }

    var title: String {
        switch self {
        case .health: String(localized: "Health")
        case .recovery: String(localized: "Recovery")
        case .training: String(localized: "Training")
        }
    }

    var summary: String {
        switch self {
        case .health: String(localized: "Readiness, activity and sleep at a glance")
        case .recovery: String(localized: "Sleep, recovery and readiness")
        case .training: String(localized: "Training load, workouts and fitness")
        }
    }

    /// The cards under Health Status, in order.
    var cards: [CardID] {
        let kinds: [CardKind] = switch self {
        case .health:
            [.recovery, .resources, .strain, .steps, .sleepStages, .sleepScore, .sleepNeed, .lastWorkout, .exerciseMinutes,
             .hrvStatus]
        case .recovery:
            [.recovery, .hrvStatus, .sleepNeed, .resources, .sleepStages, .sleepScore, .sleepConsistency, .lastWorkout,
             .strain, .steps]
        case .training:
            [.strain, .trainingReadiness, .recovery, .exerciseMinutes, .lastWorkout, .weeklyTraining, .vo2Max, .sleepStages,
             .sleepNeed, .hrvStatus]
        }
        return kinds.map { CardID(kind: $0, variant: $0.defaultVariant) }
    }
}
