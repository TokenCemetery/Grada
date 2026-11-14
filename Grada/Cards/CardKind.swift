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
    case healthStatus, recovery, resources, healthAge
    case sleepDuration, sleepStages, sleepNeed, sleepConsistency
    case heartRate, restingHeartRate, hrv, oxygenSaturation, respiratoryRate, wristTemperature
    case steps, activeEnergy, exerciseMinutes, distance, floors, standHours
    case lastWorkout, weeklyTraining, vo2Max, racePredictor, trainingReadiness, loadFocus
    case last30Days

    var id: String { rawValue }

    /// Cards the user can add or remove. Health status is pinned on top.
    static var gallery: [CardKind] { allCases.filter { $0 != .healthStatus && !$0.isPlanned } }

    /// Cards whose calculation isn't built yet. They stay out of the gallery until it is.
    var isPlanned: Bool {
        switch self {
        // TODO(v4): build with Strain's training-load model, then remove from this list.
        case .trainingReadiness, .loadFocus: true
        default: false
        }
    }

    static let defaultSet: [CardKind] = [
        .sleepStages, .restingHeartRate, .hrv, .steps, .activeEnergy, .lastWorkout, .last30Days,
    ]

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
        case .healthStatus, .recovery, .resources, .healthAge: .status
        case .sleepDuration, .sleepStages, .sleepNeed, .sleepConsistency: .sleep
        case .heartRate, .restingHeartRate, .hrv, .oxygenSaturation, .respiratoryRate, .wristTemperature: .heart
        case .steps, .activeEnergy, .exerciseMinutes, .distance, .floors, .standHours: .activity
        case .lastWorkout, .weeklyTraining, .vo2Max, .racePredictor, .trainingReadiness, .loadFocus: .training
        case .last30Days: .history
        }
    }

    /// Scores color their value by how good it is; plain metrics stay neutral.
    var isScore: Bool {
        switch self {
        case .healthStatus, .recovery, .resources: true
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
