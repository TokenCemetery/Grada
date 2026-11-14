import Foundation

/// One calendar day's value; `value` is nil when Apple Health has nothing for that day.
struct DayValue: Equatable {
    let day: Date
    let value: Double?
}

/// Quantity metrics read from Apple Health, in the units the app displays.
enum QuantityMetric: CaseIterable {
    case restingHeartRate, hrv, oxygenSaturation, respiratoryRate, wristTemperature
    case steps, activeEnergy, exerciseMinutes, distance, floors, vo2Max

    /// Summed per day (steps) vs averaged per day (heart rate).
    var isCumulative: Bool {
        switch self {
        case .steps, .activeEnergy, .exerciseMinutes, .distance, .floors: true
        default: false
        }
    }
}

enum SleepStage: CaseIterable {
    case awake, rem, core, deep
}

/// Sleep that ended on `wakeDay`. Durations in seconds.
struct SleepNight: Equatable {
    let wakeDay: Date
    var stages: [SleepStage: TimeInterval]
    /// Asleep time not split into stages (e.g. from apps without stage tracking).
    var unspecified: TimeInterval

    var asleep: TimeInterval {
        unspecified + (stages[.core] ?? 0) + (stages[.deep] ?? 0) + (stages[.rem] ?? 0)
    }
}

struct WorkoutSummary: Equatable {
    let start: Date
    let duration: TimeInterval
    let name: String
    let symbol: String
    let energyKcal: Double?
    let averageHeartRate: Double?
}

/// Where raw health data comes from. HealthKit in the app, sample data in previews and demo mode.
protocol HealthDataSource {
    func requestAuthorization() async throws
    /// One value per day for the `days` days ending today, oldest first.
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue]
    func standHours(days: Int) async throws -> [DayValue]
    /// Nights whose wake-up day falls in the last `days` days, oldest first.
    func sleepNights(days: Int) async throws -> [SleepNight]
    /// Workouts that started in the last `days` days, newest first.
    func workouts(days: Int) async throws -> [WorkoutSummary]
}
