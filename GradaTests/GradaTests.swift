import Foundation
import SwiftData
import Testing
@testable import Grada

@MainActor
struct HomeLayoutTests {
    @Test func squaresPairUpAndWideCardsFillARow() {
        let rows = HomeLayout.rows(for: [.sleepStages, .restingHeartRate, .hrv, .steps, .lastWorkout, .activeEnergy])
        #expect(rows == [[.sleepStages], [.restingHeartRate, .hrv], [.steps], [.lastWorkout], [.activeEnergy]])
    }

    @Test func defaultSetLayout() {
        let rows = HomeLayout.rows(for: CardKind.defaultSet)
        #expect(rows == [[.sleepStages], [.restingHeartRate, .hrv], [.steps, .activeEnergy], [.lastWorkout], [.last30Days]])
    }
}

@MainActor
struct BaselineTests {
    @Test func calibratingUntilSevenDays() {
        #expect(Baseline.normalRange(history: [50, 52, 51, 49, 50, 51], minimumHalfWidth: 1) == nil)
    }

    @Test func rangeIsMeanPlusMinusTwoStandardDeviations() throws {
        let range = try #require(Baseline.normalRange(history: [48, 50, 52, 48, 50, 52, 50], minimumHalfWidth: 0))
        // Mean 50, sample SD ≈ 1.633.
        #expect(abs(range.lowerBound - 46.73) < 0.01)
        #expect(abs(range.upperBound - 53.27) < 0.01)
    }

    @Test func rangeNeverNarrowerThanMinimum() throws {
        let range = try #require(Baseline.normalRange(history: Array(repeating: 54, count: 10), minimumHalfWidth: 3))
        #expect(range == 51...57)
    }
}

@MainActor
struct SnapshotBuilderTests {
    @Test func durationFormatting() {
        #expect(SnapshotBuilder.hoursMinutes(7 * 3600 + 42 * 60) == "7h 42m")
        #expect(SnapshotBuilder.hoursMinutes(45 * 60) == "45m")
        #expect(SnapshotBuilder.signedMinutes(18 * 60) == "+18m")
        #expect(SnapshotBuilder.signedMinutes(-75 * 60) == "−1h 15m")
    }

    @Test func everyCardBuildsFromSampleData() async throws {
        let builder = SnapshotBuilder(source: SampleDataSource())
        for kind in CardKind.allCases {
            let snapshot = try await builder.snapshot(for: kind)
            #expect(snapshot.value != nil, "\(kind) has no value")
        }
    }
}

@MainActor
struct HealthImporterTests {
    private let calendar = Calendar.current
    private let context: ModelContext
    private let importer: HealthImporter

    init() throws {
        let container = try ModelContainer(
            for: HomeCard.self, DaySummary.self, WorkoutRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        importer = HealthImporter(reader: HealthKitReader(), context: context)
    }

    private var today: Date { calendar.startOfDay(for: .now) }
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }

    private func batch(steps: [Double?], workouts: [WorkoutSummary] = []) -> HealthBatch {
        let days = DateInterval(start: day(-(steps.count - 1)), end: day(1))
        var batch = HealthBatch(days: days)
        batch.daily[.steps] = steps.enumerated().map { DayValue(day: day($0.offset - (steps.count - 1)), value: $0.element) }
        batch.workouts = workouts
        return batch
    }

    private func workout(_ id: String) -> WorkoutSummary {
        WorkoutSummary(id: id, start: day(0).addingTimeInterval(3600), duration: 1800, name: "Run",
                       symbol: "figure.run", energyKcal: 300, averageHeartRate: 140)
    }

    @Test func savesOnlyDaysWithDataAndUpdatesInPlace() throws {
        try importer.save(batch(steps: [nil, 4000, 5000]))
        #expect(try context.fetchCount(FetchDescriptor<DaySummary>()) == 2)

        try importer.save(batch(steps: [nil, 4000, 7000]))
        let summaries = try context.fetch(FetchDescriptor<DaySummary>(sortBy: [SortDescriptor(\.day)]))
        #expect(summaries.map(\.steps) == [4000, 7000])
    }

    @Test func removesDuplicateDays() throws {
        let key = DayKey.make(today, calendar: calendar)
        context.insert(DaySummary(day: today, dayKey: key))
        context.insert(DaySummary(day: today, dayKey: key))
        try importer.save(batch(steps: [6000]))
        #expect(try context.fetchCount(FetchDescriptor<DaySummary>()) == 1)
    }

    @Test func syncsWorkoutsWithAppleHealth() throws {
        try importer.save(batch(steps: [1000], workouts: [workout("a"), workout("b")]))
        try importer.save(batch(steps: [1000], workouts: [workout("b")]))
        let records = try context.fetch(FetchDescriptor<WorkoutRecord>())
        #expect(records.map(\.healthID) == ["b"])
    }

    @Test func storedDataFeedsCards() async throws {
        try importer.save(batch(steps: [8000, 9000]))
        let values = try await StoredHealthData(context: context).daily(.steps, days: 3)
        #expect(values.map(\.value) == [nil, 8000, 9000])
    }
}

/// Sample data as it looks just after midnight: nothing recorded yet for the night ending today.
private struct BeforeWakeUpSource: HealthDataSource {
    let base = SampleDataSource()
    let today = Calendar.current.startOfDay(for: .now)

    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] {
        try await base.daily(metric, days: days).map { $0.day == today ? DayValue(day: $0.day, value: nil) : $0 }
    }
    func standHours(days: Int) async throws -> [DayValue] { try await base.standHours(days: days) }
    func sleepNights(days: Int) async throws -> [SleepNight] {
        try await base.sleepNights(days: days).filter { $0.wakeDay != today }
    }
    func workouts(days: Int) async throws -> [WorkoutSummary] { try await base.workouts(days: days) }
}

@MainActor
struct AfterMidnightTests {
    private let builder = SnapshotBuilder(source: BeforeWakeUpSource())

    @Test func sleepShowsYesterdaysNight() async throws {
        for kind in [CardKind.sleepDuration, .sleepStages] {
            let snapshot = try await builder.snapshot(for: kind)
            #expect(snapshot.period == "Yesterday")
            #expect(snapshot.value != nil)
        }
    }

    @Test func healthStatusShowsYesterdaysVitals() async throws {
        let snapshot = try await builder.snapshot(for: .healthStatus)
        #expect(snapshot.period == "Yesterday")
        #expect(snapshot.value != nil)
    }

    @Test func todaysNightWinsOnceRecorded() async throws {
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .sleepStages)
        #expect(snapshot.period == "Last night")
    }
}
