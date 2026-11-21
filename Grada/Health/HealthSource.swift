import Foundation

/// Something `StoredHealthData` reads intraday data, workout screens and the profile from live rather than from
/// storage. A source serves only what it has: every read defaults to nothing (#122). `StoredHealthData` takes heart
/// rate per day, and hourly values (one day), the profile and max heart rate from the first source with any,
/// the profile falling back to `EnteredProfile`; each sleep's periods from the first source with that
/// sleep; workout detail from the workout's own source, with heart rate over its time when that source has none;
/// activity time, intake and menstrual flow from the first source with any; heart rate recovery and effort from each
/// workout's own source.
protocol LiveHealthSource: AnyObject {
    /// Stored with every value from this source, so it must never change once shipped.
    nonisolated var id: String { get }
    func heartRate(in interval: DateInterval) async throws -> [TimedValue]
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod]
    func hourly(_ metric: QuantityMetric, in interval: DateInterval) async throws -> [TimedValue]
    func workoutDetail(_ summary: WorkoutSummary) async throws -> WorkoutDetail
    func highestHeartRate(days: Int) async throws -> Double?
    /// Highest heart rate recorded in `interval`, for a past day that mustn't see later readings.
    func highestHeartRate(in interval: DateInterval) async throws -> Double?
    func age() -> Int?
    func biologicalSex() -> BiologicalSex?
    /// Seconds of `activity` in `interval`; nil without any record of it.
    func time(in activity: TimedActivity, during interval: DateInterval) async throws -> TimeInterval?
    /// Total `intake` in `interval`: drinks, or milligrams of caffeine; nil without any record of it.
    func intake(_ intake: Intake, during interval: DateInterval) async throws -> Double?
    /// Heart rate recovery in bpm by workout ID, for those of `workouts` that have one (#131).
    func heartRateRecovery(after workouts: [WorkoutSummary]) async throws -> [String: Double]
    /// Effort ratings by workout ID, for those of `workouts` that have one (#134).
    func effort(of workouts: [WorkoutSummary]) async throws -> [String: WorkoutEffort]
    /// Days with menstrual flow logged in `interval`, oldest first; nil without any record of it (#137).
    func menstrualFlow(during interval: DateInterval) async throws -> [FlowDay]?
    /// Basal body temperatures, ovulation tests and cervical mucus logged in `interval`, oldest first; nil without
    /// any record of them (#138).
    func cycleSigns(during interval: DateInterval) async throws -> [CycleSign]?
}

extension LiveHealthSource {
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] { [] }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { [] }
    func hourly(_ metric: QuantityMetric, in interval: DateInterval) async throws -> [TimedValue] { [] }
    func workoutDetail(_ summary: WorkoutSummary) async throws -> WorkoutDetail { WorkoutDetail() }
    func highestHeartRate(days: Int) async throws -> Double? { nil }
    func highestHeartRate(in interval: DateInterval) async throws -> Double? { nil }
    func age() -> Int? { nil }
    func biologicalSex() -> BiologicalSex? { nil }
    func time(in activity: TimedActivity, during interval: DateInterval) async throws -> TimeInterval? { nil }
    func intake(_ intake: Intake, during interval: DateInterval) async throws -> Double? { nil }
    func heartRateRecovery(after workouts: [WorkoutSummary]) async throws -> [String: Double] { [:] }
    func effort(of workouts: [WorkoutSummary]) async throws -> [String: WorkoutEffort] { [:] }
    func menstrualFlow(during interval: DateInterval) async throws -> [FlowDay]? { nil }
    func cycleSigns(during interval: DateInterval) async throws -> [CycleSign]? { nil }
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
    /// Whether `requestAuthorization()` would show a permission sheet, which needs the app on screen.
    func needsAuthorizationSheet() async -> Bool
    /// Date of the oldest data the source can import.
    func earliestSampleDate() async throws -> Date?
    /// Everything the store keeps for `days` (start of day ..< start of day).
    func batch(for days: DateInterval) async throws -> HealthBatch
    /// Calls `onChange` when the source gets new data; `onChange` must call its completion handler when done.
    func observeChanges(_ onChange: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws
}

extension HealthSource {
    var refreshInterval: TimeInterval { 0 }
    func needsAuthorizationSheet() async -> Bool { false }

    /// Sources without change notifications are refreshed when the app asks for recent data.
    func observeChanges(_ onChange: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws {}
}
