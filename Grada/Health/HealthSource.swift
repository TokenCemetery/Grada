import Foundation

/// Something `StoredHealthData` reads intraday data, workout screens and the profile from live rather than from
/// storage. A source serves only what it has: every read defaults to nothing (#122). `StoredHealthData` takes heart
/// rate per day, and hourly values (one day), the profile and max heart rate from the first source with any,
/// the profile falling back to `EnteredProfile`; each sleep's periods from the first source with that
/// sleep; workout detail from the workout's own source, with heart rate over its time when that source has none;
/// activity time from the first source with any.
protocol LiveHealthSource: AnyObject {
    /// Stored with every value from this source, so it must never change once shipped.
    nonisolated var id: String { get }
    func heartRate(in interval: DateInterval) async throws -> [TimedValue]
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod]
    func hourly(_ metric: QuantityMetric, in interval: DateInterval) async throws -> [TimedValue]
    func workoutDetail(_ summary: WorkoutSummary) async throws -> WorkoutDetail
    func highestHeartRate(days: Int) async throws -> Double?
    func age() -> Int?
    func biologicalSex() -> BiologicalSex?
    /// Seconds of `activity` in `interval`; nil without any record of it.
    func time(in activity: TimedActivity, during interval: DateInterval) async throws -> TimeInterval?
}

extension LiveHealthSource {
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] { [] }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { [] }
    func hourly(_ metric: QuantityMetric, in interval: DateInterval) async throws -> [TimedValue] { [] }
    func workoutDetail(_ summary: WorkoutSummary) async throws -> WorkoutDetail { WorkoutDetail() }
    func highestHeartRate(days: Int) async throws -> Double? { nil }
    func age() -> Int? { nil }
    func biologicalSex() -> BiologicalSex? { nil }
    func time(in activity: TimedActivity, during interval: DateInterval) async throws -> TimeInterval? { nil }
}

/// Somewhere Grada imports health data from: Apple Health, or a direct connection to a device's service.
/// Imported data is stored per source and merged when cards read it, in the order sources are listed.
protocol HealthSource: LiveHealthSource {
    /// Shown to the user, e.g. while its history imports.
    var name: String { get }
    var isAvailable: Bool { get }
    /// Shortest time between imports of recent days, for sources that charge a network call per import.
    var refreshInterval: TimeInterval { get }
    func requestAuthorization() async throws
    /// Date of the oldest data the source can import.
    func earliestSampleDate() async throws -> Date?
    /// Everything the store keeps for `days` (start of day ..< start of day).
    func batch(for days: DateInterval) async throws -> HealthBatch
    /// Calls `onChange` when the source gets new data; `onChange` must call its completion handler when done.
    func observeChanges(_ onChange: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws
}

extension HealthSource {
    var refreshInterval: TimeInterval { 0 }

    /// Sources without change notifications are refreshed when the app asks for recent data.
    func observeChanges(_ onChange: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws {}
}
