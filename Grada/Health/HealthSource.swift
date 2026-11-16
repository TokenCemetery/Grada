import Foundation

/// Somewhere Grada imports health data from: Apple Health, or a direct connection to a device's service.
/// Imported data is stored per source and merged when cards read it, in the order sources are listed.
protocol HealthSource: AnyObject {
    /// Stored with every value from this source, so it must never change once shipped.
    var id: String { get }
    var isAvailable: Bool { get }
    func requestAuthorization() async throws
    /// Date of the oldest data the source can import.
    func earliestSampleDate() async throws -> Date?
    /// Everything the store keeps for `days` (start of day ..< start of day).
    func batch(for days: DateInterval) async throws -> HealthBatch
    /// Calls `onChange` when the source gets new data; `onChange` must call its completion handler when done.
    func observeChanges(_ onChange: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws

    // Read live rather than stored: intraday data, workout screens and profile.
    func heartRate(in interval: DateInterval) async throws -> [TimedValue]
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod]
    func hourly(_ metric: QuantityMetric, in interval: DateInterval) async throws -> [TimedValue]
    func workoutDetail(_ summary: WorkoutSummary) async throws -> WorkoutDetail
    func highestHeartRate(days: Int) async throws -> Double?
    func age() -> Int?
    func biologicalSex() -> BiologicalSex?
}

extension HealthSource {
    /// Sources without change notifications are refreshed when the app asks for recent data.
    func observeChanges(_ onChange: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws {}
}
