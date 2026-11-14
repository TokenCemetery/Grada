import Foundation

/// A data source as it looked at the end of a past day, so `SnapshotBuilder` can build that day's cards.
/// Requests for "the last n days ending today" get the n days ending on that day instead.
struct PastDaySource: HealthDataSource {
    let base: HealthDataSource
    /// 1 for yesterday.
    let daysAgo: Int
    /// Start of the day after the shown day.
    let dayEnd: Date

    func heartRate(in interval: DateInterval) async throws -> [TimedValue] {
        try await base.heartRate(in: interval)
    }

    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] {
        try await base.sleepPeriods(in: interval)
    }

    func age() async throws -> Int? {
        try await base.age()
    }

    func highestHeartRate(days: Int) async throws -> Double? {
        try await base.highestHeartRate(days: days + daysAgo)
    }

    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] {
        Array(try await base.daily(metric, days: days + daysAgo).dropLast(daysAgo))
    }

    func standHours(days: Int) async throws -> [DayValue] {
        Array(try await base.standHours(days: days + daysAgo).dropLast(daysAgo))
    }

    func overnight(days: Int) async throws -> [OvernightVitals] {
        Array(try await base.overnight(days: days + daysAgo).dropLast(daysAgo))
    }

    func sleepNights(days: Int) async throws -> [SleepNight] {
        try await base.sleepNights(days: days + daysAgo).filter { $0.wakeDay < dayEnd }
    }

    func workouts(days: Int) async throws -> [WorkoutSummary] {
        try await base.workouts(days: days + daysAgo).filter { $0.start < dayEnd }
    }
}
