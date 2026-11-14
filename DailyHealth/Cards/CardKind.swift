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

/// Every card the home screen can show. The raw value is persisted, so don't rename cases.
enum CardKind: String, CaseIterable, Identifiable {
    case healthStatus
    case sleepDuration, sleepStages
    case restingHeartRate, hrv, oxygenSaturation, respiratoryRate, wristTemperature
    case steps, activeEnergy, exerciseMinutes, distance, floors, standHours
    case lastWorkout, weeklyTraining, vo2Max
    case last30Days

    var id: String { rawValue }

    /// Cards the user can add or remove. Health status is pinned on top.
    static var gallery: [CardKind] { allCases.filter { $0 != .healthStatus } }

    static let defaultSet: [CardKind] = [
        .sleepStages, .restingHeartRate, .hrv, .steps, .activeEnergy, .lastWorkout, .last30Days,
    ]

    var title: String {
        switch self {
        case .healthStatus: "Health status"
        case .sleepDuration: "Sleep"
        case .sleepStages: "Sleep stages"
        case .restingHeartRate: "Resting HR"
        case .hrv: "HRV"
        case .oxygenSaturation: "Blood oxygen"
        case .respiratoryRate: "Respiratory rate"
        case .wristTemperature: "Wrist temp"
        case .steps: "Steps"
        case .activeEnergy: "Active energy"
        case .exerciseMinutes: "Exercise"
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
        case .sleepDuration, .sleepStages: "moon.zzz"
        case .restingHeartRate: "heart"
        case .hrv: "waveform.path.ecg"
        case .oxygenSaturation: "drop"
        case .respiratoryRate: "lungs"
        case .wristTemperature: "thermometer.medium"
        case .steps: "figure.walk"
        case .activeEnergy: "flame"
        case .exerciseMinutes: "figure.run"
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
        case .healthStatus: .status
        case .sleepDuration, .sleepStages: .sleep
        case .restingHeartRate, .hrv, .oxygenSaturation, .respiratoryRate, .wristTemperature: .heart
        case .steps, .activeEnergy, .exerciseMinutes, .distance, .floors, .standHours: .activity
        case .lastWorkout, .weeklyTraining, .vo2Max: .training
        case .last30Days: .history
        }
    }

    var size: CardSize {
        switch self {
        case .healthStatus, .sleepStages, .lastWorkout, .last30Days: .wide
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
        case .status: "Needs overnight vitals from Apple Watch or a compatible watch."
        }
    }
}
