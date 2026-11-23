import Foundation
import SwiftData
import Testing
@testable import Grada

/// Records whether each read reached it on the main thread, then forwards to `base` (#117).
private final class ThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Bool] = []
    func record() { lock.withLock { calls.append(Thread.isMainThread) } }
    var mainThreadCalls: Int { lock.withLock { calls.filter { $0 }.count } }
    var count: Int { lock.withLock { calls.count } }
}

private struct ProbedSource: HealthDataSource {
    let base: HealthDataSource
    let probe: ThreadProbe

    func heartRate(in interval: DateInterval) async throws -> [TimedValue] { probe.record(); return try await base.heartRate(in: interval) }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { probe.record(); return try await base.sleepPeriods(in: interval) }
    func age() async throws -> Int? { try await base.age() }
    func biologicalSex() async throws -> BiologicalSex? { try await base.biologicalSex() }
    func highestHeartRate(days: Int) async throws -> Double? { probe.record(); return try await base.highestHeartRate(days: days) }
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] { probe.record(); return try await base.daily(metric, days: days) }
    func standHours(days: Int) async throws -> [DayValue] { probe.record(); return try await base.standHours(days: days) }
    func overnight(days: Int) async throws -> [OvernightVitals] { probe.record(); return try await base.overnight(days: days) }
    func sleepNights(days: Int) async throws -> [SleepNight] { probe.record(); return try await base.sleepNights(days: days) }
    func workouts(days: Int) async throws -> [WorkoutSummary] { probe.record(); return try await base.workouts(days: days) }
    func workoutDetail(_ workout: WorkoutSummary) async throws -> WorkoutDetail { try await base.workoutDetail(workout) }
    @MainActor func providesProfile() -> (age: Bool, sex: Bool) { base.providesProfile() }
}

extension HealthStoreWriter {
    func runsOnMainThread() -> Bool { Thread.isMainThread }
}

@MainActor
struct BackgroundStoreTests {
    private let container: ModelContainer
    private let importer: HealthImporter
    private let calendar = Calendar.current

    init() throws {
        container = try ModelStores.makeInMemoryContainer()
        importer = HealthImporter(sources: [], fitFiles: FITFileSource(timelineURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")), container: container)
    }

    private func steps(_ value: Double) -> HealthBatch {
        let today = calendar.startOfDay(for: .now)
        var batch = HealthBatch(days: DateInterval(start: today, end: calendar.date(byAdding: .day, value: 1, to: today)!))
        batch.daily[.steps] = [DayValue(day: today, value: value)]
        return batch
    }

    /// The main context isn't told to refresh: a row saved on the writer's context must show up in it by itself,
    /// which is what lets `@Query` views follow imports.
    @Test func mainContextSeesBackgroundSaves() async throws {
        let main = container.mainContext
        #expect(try main.fetchCount(FetchDescriptor<DaySummary>()) == 0)
        let revision = importer.revision
        try await importer.save(steps(4000), from: "appleHealth")
        #expect(importer.revision == revision + 1)
        #expect(try main.fetch(FetchDescriptor<DaySummary>()).map(\.steps) == [4000])
        try await importer.save(steps(5000), from: "appleHealth")
        #expect(try main.fetch(FetchDescriptor<DaySummary>()).map(\.steps) == [5000])
    }

    /// A refresh that re-reads a workout stored before types were kept saves its type, and one without a type doesn't
    /// clear it (#196).
    @Test func refreshFillsInAStoredWorkoutsType() async throws {
        let main = container.mainContext
        let today = calendar.startOfDay(for: .now)
        func batch(type: Int?) -> HealthBatch {
            var batch = HealthBatch(days: DateInterval(start: today, end: calendar.date(byAdding: .day, value: 1, to: today)!))
            batch.workouts = [WorkoutSummary(id: "w1", start: today.addingTimeInterval(3600), duration: 1800, name: "Walk",
                                             symbol: "figure.walk", energyKcal: nil, averageHeartRate: nil, activityType: type)]
            return batch
        }
        main.insert(WorkoutRecord(batch(type: nil).workouts[0]))
        try main.save()

        try await importer.save(batch(type: 52), from: "appleHealth")
        #expect(try main.fetch(FetchDescriptor<WorkoutRecord>()).map(\.activityType) == [52])
        try await importer.save(batch(type: nil), from: "appleHealth")
        #expect(try main.fetch(FetchDescriptor<WorkoutRecord>()).map(\.activityType) == [52])
    }

    @Test func importSavesRunOffTheMainThread() async throws {
        #expect(await importer.withWriter { await $0.runsOnMainThread() } == false)
    }

    @Test func homeCardsReadAndScoreOffTheMainThread() async throws {
        try await importer.save(steps(4000), from: "appleHealth")
        let probe = ThreadProbe()
        let source = ProbedSource(base: StoredHealthData(container: container), probe: probe)
        let model = HomeModel(source: source)
        await model.reload([CardID(kind: .steps), CardID(kind: .recovery), CardID(kind: .sleepScore)], goals: GoalHistory())
        #expect(probe.count > 0)
        #expect(probe.mainThreadCalls == 0)
        #expect(model.snapshots[CardID(kind: .steps)] != nil)
    }

    @Test func calendarReadsAndRatesOffTheMainThread() async throws {
        try await importer.save(steps(4000), from: "appleHealth")
        let probe = ThreadProbe()
        let model = CalendarModel(source: ProbedSource(base: StoredHealthData(container: container), probe: probe))
        await model.load(.recovery, goals: GoalHistory())
        #expect(probe.count > 0)
        #expect(probe.mainThreadCalls == 0, "load")
        let day = await model.snapshots(for: .now.addingTimeInterval(-86_400), cards: [CardID(kind: .steps)], goals: GoalHistory())
        #expect(probe.count > 0)
        #expect(probe.mainThreadCalls == 0)
        #expect(day[.steps] != nil)
    }
}
