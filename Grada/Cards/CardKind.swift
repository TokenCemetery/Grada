import SwiftUI

enum CardSize {
    /// Half the screen width.
    case square
    /// Full screen width.
    case wide
}

enum CardCategory: CaseIterable {
    case status, sleep, heart, activity, training, history

    var title: String {
        switch self {
        case .status: "Status"
        case .sleep: "Sleep"
        case .heart: "Heart and vitals"
        case .activity: "Activity"
        case .training: "Training"
        case .history: "History"
        }
    }

    /// System colors already adapt to light and dark mode.
    var color: Color {
        switch self {
        case .status: .green
        case .sleep: .indigo
        case .heart: .red
        case .activity: .green
        case .training: .orange
        case .history: .teal
        }
    }
}

/// What a card's chart shows. The raw value is persisted, so don't rename cases.
enum CardVariant: String, CaseIterable {
    /// Today against the goal or the personal normal range.
    case current
    /// The last 7 days, today last.
    case week

    var title: String {
        switch self {
        case .current: "Current"
        case .week: "7 days"
        }
    }
}

/// One card on Home: a metric and the variant it shows. A metric can sit on Home once per variant.
struct CardID: Hashable, Identifiable {
    let kind: CardKind
    var variant: CardVariant = .current

    var id: Self { self }

    /// Every card the user can add, one per metric and variant.
    static var gallery: [CardID] {
        CardKind.gallery.flatMap { kind in kind.variants.map { CardID(kind: kind, variant: $0) } }
    }
}

/// Every card the home screen can show. The raw value is persisted, so don't rename cases.
enum CardKind: String, CaseIterable, Identifiable {
    case healthStatus, recovery, resources, healthAge
    case sleepDuration, sleepStages, sleepNeed, sleepConsistency
    case heartRate, restingHeartRate, hrv, hrvStatus, oxygenSaturation, respiratoryRate, wristTemperature
    case steps, activeEnergy, exerciseMinutes, intensityMinutes, distance, floors, standHours
    case lastWorkout, weeklyTraining, vo2Max, racePredictor, trainingReadiness, loadFocus
    case last30Days

    var id: String { rawValue }

    /// Cards the user can add or remove. Health status is pinned on top.
    static var gallery: [CardKind] { allCases.filter { $0 != .healthStatus && !$0.isPlanned } }

    /// Cards whose calculation isn't built yet. They stay out of the gallery until it is.
    var isPlanned: Bool {
        switch self {
        // TODO(#31, #32, v4): build with Strain's training-load model, then remove from this list.
        case .trainingReadiness, .loadFocus: true
        default: false
        }
    }

    static let defaultSet: [CardID] = [CardKind.sleepStages, .restingHeartRate, .hrv, .steps, .activeEnergy, .lastWorkout, .last30Days]
        .map { CardID(kind: $0, variant: $0.defaultVariant) }

    /// Cards where today and the last 7 days answer different questions offer both; the rest only Current.
    var variants: [CardVariant] {
        switch self {
        case .steps, .activeEnergy, .exerciseMinutes, .distance, .floors, .standHours,
             .sleepDuration, .restingHeartRate, .hrv, .wristTemperature, .recovery:
            [.current, .week]
        default:
            [.current]
        }
    }

    /// The variant matching what the card showed before variants existed, so cards saved then keep their look.
    var defaultVariant: CardVariant {
        switch self {
        case .exerciseMinutes, .distance, .standHours, .sleepDuration, .restingHeartRate, .hrv, .wristTemperature, .recovery:
            .week
        default:
            .current
        }
    }

    var title: String {
        switch self {
        case .healthStatus: "Health status"
        case .recovery: "Recovery"
        case .resources: "Resources"
        case .heartRate: "Heart rate"
        case .sleepDuration: "Sleep"
        case .sleepStages: "Sleep stages"
        case .sleepNeed: "Sleep need"
        case .sleepConsistency: "Consistency"
        case .healthAge: "Health age"
        case .racePredictor: "Race predictor"
        case .trainingReadiness: "Training readiness"
        case .loadFocus: "Load focus"
        case .restingHeartRate: "Resting HR"
        case .hrv: "HRV"
        case .hrvStatus: "HRV status"
        case .oxygenSaturation: "Blood oxygen"
        case .respiratoryRate: "Respiratory rate"
        case .wristTemperature: "Wrist temp"
        case .steps: "Steps"
        case .activeEnergy: "Active energy"
        case .exerciseMinutes: "Exercise"
        case .intensityMinutes: "Intensity minutes"
        case .distance: "Distance"
        case .floors: "Floors"
        case .standHours: "Stand hours"
        case .lastWorkout: "Last workout"
        case .weeklyTraining: "Training volume"
        case .vo2Max: "VO₂ max"
        case .last30Days: "Last 30 days"
        }
    }

    var symbol: String {
        switch self {
        case .healthStatus: "checkmark.shield"
        case .recovery: "arrow.clockwise.heart"
        case .resources: "battery.75percent"
        case .heartRate: "heart.circle"
        case .sleepDuration, .sleepStages: "moon.zzz"
        case .sleepNeed: "bed.double"
        case .sleepConsistency: "clock.arrow.circlepath"
        case .healthAge: "hourglass"
        case .racePredictor: "flag.checkered"
        case .trainingReadiness: "gauge.with.dots.needle.67percent"
        case .loadFocus: "chart.bar.xaxis"
        case .restingHeartRate: "heart"
        case .hrv: "waveform.path.ecg"
        case .hrvStatus: "waveform.path.ecg.rectangle"
        case .oxygenSaturation: "drop"
        case .respiratoryRate: "lungs"
        case .wristTemperature: "thermometer.medium"
        case .steps: "figure.walk"
        case .activeEnergy: "flame"
        case .exerciseMinutes: "figure.run"
        case .intensityMinutes: "bolt.circle"
        case .distance: "point.topleft.down.to.point.bottomright.curvepath"
        case .floors: "stairs"
        case .standHours: "figure.stand"
        case .lastWorkout: "stopwatch"
        case .weeklyTraining: "chart.bar"
        case .vo2Max: "bolt.heart"
        case .last30Days: "calendar"
        }
    }

    var category: CardCategory {
        switch self {
        case .healthStatus, .recovery, .resources, .healthAge: .status
        case .sleepDuration, .sleepStages, .sleepNeed, .sleepConsistency: .sleep
        case .heartRate, .restingHeartRate, .hrv, .hrvStatus, .oxygenSaturation, .respiratoryRate, .wristTemperature: .heart
        case .steps, .activeEnergy, .exerciseMinutes, .intensityMinutes, .distance, .floors, .standHours: .activity
        case .lastWorkout, .weeklyTraining, .vo2Max, .racePredictor, .trainingReadiness, .loadFocus: .training
        case .last30Days: .history
        }
    }

    /// Scores color their value by how good it is; plain metrics stay neutral.
    var isScore: Bool {
        switch self {
        case .healthStatus, .recovery, .resources, .hrvStatus: true
        default: false
        }
    }

    /// Wide cards whose value sits on the title row, just left of the icon, leaving the full width below for details.
    var valueBesideTitle: Bool {
        switch self {
        case .healthAge, .lastWorkout, .racePredictor: true
        default: false
        }
    }

    var size: CardSize {
        switch self {
        case .healthStatus, .sleepStages, .lastWorkout, .last30Days, .healthAge, .racePredictor, .loadFocus: .wide
        default: .square
        }
    }

    /// Shown when Apple Health has no data for this card.
    var missingDataHint: String {
        switch category {
        case .heart: "Recorded by Apple Watch or a watch that syncs to Apple Health."
        case .sleep: "Wear a watch to bed or track sleep in a sleep app."
        case .activity: "Recorded by your iPhone or watch."
        case .training, .history: "Record a workout on your watch or in a fitness app."
        case .status: "Needs heart rate and overnight vitals from Apple Watch or a compatible watch."
        }
    }
}
