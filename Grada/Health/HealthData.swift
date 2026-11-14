import Foundation

/// One calendar day's value; `value` is nil when Apple Health has nothing for that day.
nonisolated struct DayValue: Equatable {
    let day: Date
    let value: Double?
}

/// Quantity metrics read from Apple Health, in the units the app displays.
nonisolated enum QuantityMetric: CaseIterable {
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

nonisolated enum SleepStage: CaseIterable {
    case awake, rem, core, deep
}

/// Sleep that ended on `wakeDay`. Durations in seconds.
nonisolated struct SleepNight: Equatable {
    let wakeDay: Date
    var stages: [SleepStage: TimeInterval]
    /// Asleep time not split into stages (e.g. from apps without stage tracking).
    var unspecified: TimeInterval

    var asleep: TimeInterval {
        unspecified + (stages[.core] ?? 0) + (stages[.deep] ?? 0) + (stages[.rem] ?? 0)
    }

    /// The day a stretch of sleep ending at `end` counts toward. Sleep ending after 18:00 belongs to the
    /// next morning, so a night that starts before midnight stays in one piece.
    static func wakeDay(forEnd end: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: end.addingTimeInterval(6 * 3600))
    }
}

nonisolated struct WorkoutSummary: Equatable {
    /// The Apple Health sample UUID, stable across devices.
    let id: String
    let start: Date
    let duration: TimeInterval
    let name: String
    let symbol: String
    let energyKcal: Double?
    let averageHeartRate: Double?
}

/// Where cards get their data: the imported store in the app, sample data in previews and demo mode.
protocol HealthDataSource {
    /// One value per day for the `days` days ending today, oldest first.
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue]
    func standHours(days: Int) async throws -> [DayValue]
    /// Nights whose wake-up day falls in the last `days` days, oldest first.
    func sleepNights(days: Int) async throws -> [SleepNight]
    /// Workouts that started in the last `days` days, newest first.
    func workouts(days: Int) async throws -> [WorkoutSummary]
}
