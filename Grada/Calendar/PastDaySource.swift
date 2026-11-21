import Foundation

/// A data source as it looked at the end of a past day, so `SnapshotBuilder` can build that day's cards.
/// Requests for "the last n days ending today" get the n days ending on that day instead.
nonisolated struct PastDaySource: HealthDataSource {
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

    func time(in activity: TimedActivity, on day: Date) async throws -> TimeInterval? {
        try await base.time(in: activity, on: day)
    }

    func intake(_ intake: Intake, on day: Date) async throws -> Double? {
        try await base.intake(intake, on: day)
    }

    func heartRateRecovery(days: Int) async throws -> [DayValue] {
        Array(try await base.heartRateRecovery(days: days + daysAgo).dropLast(daysAgo))
    }

    func age() async throws -> Int? {
        try await base.age()
    }

    func biologicalSex() async throws -> BiologicalSex? {
        try await base.biologicalSex()
    }

    @MainActor func providesProfile() -> (age: Bool, sex: Bool) {
        base.providesProfile()
    }

    func hourly(_ metric: QuantityMetric, on day: Date) async throws -> [TimedValue] {
        try await base.hourly(metric, on: day)
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

    func workoutDetail(_ workout: WorkoutSummary) async throws -> WorkoutDetail {
        try await base.workoutDetail(workout)
    }
}

nonisolated extension PastDaySource {
    /// `base` as it looked at the end of `day`; `base` itself for today.
    static func asOf(_ day: Date, base: HealthDataSource, calendar: Calendar) -> HealthDataSource {
        let start = calendar.startOfDay(for: day)
        let daysAgo = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: .now)).day ?? 0
        guard daysAgo > 0 else { return base }
        return PastDaySource(base: base, daysAgo: daysAgo, dayEnd: calendar.date(byAdding: .day, value: 1, to: start)!)
    }
}

nonisolated extension SnapshotBuilder {
    /// Builds cards for `day` as they looked at the end of that day, or live for today.
    static func forDay(_ day: Date, source: HealthDataSource, calendar: Calendar) -> SnapshotBuilder {
        var builder = SnapshotBuilder(source: PastDaySource.asOf(day, base: source, calendar: calendar))
        builder.calendar = calendar
        if !calendar.isDateInToday(day) {
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
            builder.now = dayEnd.addingTimeInterval(-1)
        }
        return builder
    }
}
