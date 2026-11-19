import SwiftUI

nonisolated enum CardSize {
    /// One column.
    case square
    /// Two columns with a square beside it when one is available, otherwise the full width.
    case wide
    /// Like wide, but two squares tall: two stacked squares sit beside it when available.
    case big
}

nonisolated enum CardCategory: CaseIterable {
    case status, sleep, heart, activity, training, history

    var title: String {
        switch self {
        case .status: String(localized: "Status")
        case .sleep: String(localized: "Sleep")
        case .heart: String(localized: "Heart and vitals")
        case .activity: String(localized: "Activity")
        case .training: String(localized: "Training")
        case .history: String(localized: "History")
        }
    }

    /// The Customize section header, a whole phrase so languages can inflect the category.
    var addTitle: String {
        switch self {
        case .status: String(localized: "Add status")
        case .sleep: String(localized: "Add sleep")
        case .heart: String(localized: "Add heart and vitals")
        case .activity: String(localized: "Add activity")
        case .training: String(localized: "Add training")
        case .history: String(localized: "Add history")
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
nonisolated enum CardVariant: String, CaseIterable {
    /// Today against the goal or the personal normal range.
    case current
    /// The last 7 days, today last.
    case week

    var title: String {
        switch self {
        case .current: String(localized: "Current", comment: "Card chart variant: today against the goal or normal range")
        case .week: String(localized: "7 days", comment: "Card chart variant: the last 7 days")
        }
    }
}

/// One card on Home: a metric and the variant it shows. A metric can sit on Home once per variant.
nonisolated struct CardID: Hashable, Identifiable {
    let kind: CardKind
    var variant: CardVariant = .current

    var id: Self { self }

    /// Every card the user can add, one per metric and variant.
    static var gallery: [CardID] {
        CardKind.gallery.flatMap { kind in kind.variants.map { CardID(kind: kind, variant: $0) } }
    }
}

/// Every card the home screen can show. The raw value is persisted, so don't rename cases.
nonisolated enum CardKind: String, CaseIterable, Identifiable {
    case healthStatus, recovery, resources, healthAge
    case sleepDuration, sleepStages, sleepNeed, sleepConsistency, sleepScore
    case heartRate, restingHeartRate, hrv, hrvStatus, oxygenSaturation, respiratoryRate, wristTemperature
    case steps, activeEnergy, exerciseMinutes, intensityMinutes, distance, floors, standHours, dayIntensity
    case lastWorkout, weeklyTraining, strain, recoveryTime, vo2Max, racePredictor, trainingReadiness, loadFocus
    case last30Days

    var id: String { rawValue }

    /// Cards the user can add or remove. Health status is pinned on top.
    static var gallery: [CardKind] { allCases.filter { $0 != .healthStatus && !$0.isRetired } }

    /// Cards no longer offered. HRV (the 7-night status) replaced them, and Health status already flags a
    /// single night's HRV or resting heart rate. Saved copies disappear from Home; the cases stay because
    /// the raw value is persisted.
    var isRetired: Bool { self == .restingHeartRate || self == .hrv }

    /// The card that shows a retired card's input now: HRV for nightly HRV, and Heart Rate, which shows and
    /// charts resting heart rate, for Resting HR.
    var replacement: CardKind? {
        switch self {
        case .hrv: .hrvStatus
        case .restingHeartRate: .heartRate
        default: nil
        }
    }

    /// What a fresh install shows under Health Status: WHOOP's Recovery and Strain, Garmin's Body Battery
    /// (Resources) and Steps, then last night's sleep and the latest workout.
    static let defaultSet: [CardID] = [CardKind.recovery, .resources, .strain, .steps, .sleepStages, .lastWorkout]
        .map { CardID(kind: $0, variant: $0.defaultVariant) }

    /// Cards where today and the last 7 days answer different questions offer both; the rest only Current.
    var variants: [CardVariant] {
        switch self {
        case .steps, .activeEnergy, .exerciseMinutes, .distance, .floors, .standHours, .hrvStatus, .wristTemperature:
            [.current, .week]
        case .sleepDuration, .recovery, .dayIntensity:
            [.week]
        default:
            [.current]
        }
    }

    /// The variant matching what the card showed before variants existed, so cards saved then keep their look.
    var defaultVariant: CardVariant {
        switch self {
        case .exerciseMinutes, .distance, .standHours, .sleepDuration, .wristTemperature, .recovery, .hrvStatus, .dayIntensity:
            .week
        default:
            .current
        }
    }

    var title: String {
        switch self {
        case .healthStatus: String(localized: "Health Status")
        case .recovery: String(localized: "Recovery")
        case .resources: String(localized: "Resources")
        case .heartRate: String(localized: "Heart Rate")
        case .sleepDuration, .sleepStages: String(localized: "Sleep")
        case .sleepNeed: String(localized: "Sleep Need")
        case .sleepConsistency: String(localized: "Sleep Consistency")
        case .sleepScore: String(localized: "Sleep Score")
        case .healthAge: String(localized: "Health Age")
        case .racePredictor: String(localized: "Race Predictor")
        case .trainingReadiness: String(localized: "Training Readiness")
        case .loadFocus: String(localized: "Load Focus")
        case .restingHeartRate: String(localized: "Resting HR")
        case .hrv: String(localized: "Nightly HRV")
        case .hrvStatus: String(localized: "HRV")
        case .oxygenSaturation: String(localized: "Blood Oxygen")
        case .respiratoryRate: String(localized: "Respiratory Rate")
        case .wristTemperature: String(localized: "Wrist Temp")
        case .steps: String(localized: "Steps")
        case .activeEnergy: String(localized: "Active Energy")
        case .exerciseMinutes: String(localized: "Exercise")
        case .intensityMinutes: String(localized: "Intensity Minutes")
        case .distance: String(localized: "Distance")
        case .floors: String(localized: "Floors")
        case .standHours: String(localized: "Stand Hours")
        case .dayIntensity: String(localized: "Day Intensity")
        case .lastWorkout: String(localized: "Last Workout")
        case .weeklyTraining: String(localized: "Training Volume")
        case .strain: String(localized: "Strain")
        case .recoveryTime: String(localized: "Recovery Time")
        case .vo2Max: String(localized: "VO₂ Max")
        case .last30Days: String(localized: "Workouts Calendar")
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
        case .sleepScore: "moon.stars"
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
        case .dayIntensity: "figure.walk.motion"
        case .lastWorkout: "stopwatch"
        case .weeklyTraining: "chart.bar"
        case .strain: "bolt.horizontal.circle"
        case .recoveryTime: "timer"
        case .vo2Max: "bolt.heart"
        case .last30Days: "calendar"
        }
    }

    var category: CardCategory {
        switch self {
        case .healthStatus, .recovery, .resources, .healthAge: .status
        case .sleepDuration, .sleepStages, .sleepNeed, .sleepConsistency, .sleepScore: .sleep
        case .heartRate, .restingHeartRate, .hrv, .hrvStatus, .oxygenSaturation, .respiratoryRate, .wristTemperature: .heart
        case .steps, .activeEnergy, .exerciseMinutes, .intensityMinutes, .distance, .floors, .standHours, .dayIntensity: .activity
        case .lastWorkout, .weeklyTraining, .strain, .recoveryTime, .vo2Max, .racePredictor, .trainingReadiness, .loadFocus: .training
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
        case .racePredictor: true
        default: false
        }
    }

    var size: CardSize {
        switch self {
        case .healthStatus, .sleepStages, .lastWorkout, .racePredictor, .loadFocus: .wide
        case .last30Days: .big
        default: .square
        }
    }

    /// Shown when Apple Health has no data for this card.
    var missingDataHint: String {
        switch category {
        case .heart: String(localized: "Recorded by Apple Watch or a watch that syncs to Apple Health.")
        case .sleep: String(localized: "Wear a watch to bed or track sleep in a sleep app.")
        case .activity: String(localized: "Recorded by your iPhone or watch.")
        case .training, .history: String(localized: "Record a workout on your watch or in a fitness app.")
        case .status: String(localized: "Needs heart rate and overnight vitals from Apple Watch or a compatible watch.")
        }
    }
}
