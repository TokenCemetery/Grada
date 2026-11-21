import Foundation
import SwiftData
import Testing
@testable import Grada

struct HeartRateRecoveryTests {
    private let end = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func reading(_ seconds: TimeInterval, _ bpm: Double) -> TimedValue {
        TimedValue(date: end.addingTimeInterval(seconds), value: bpm)
    }

    private func workout(_ id: String, endingAt end: Date, minutes: Double = 30) -> WorkoutSummary {
        WorkoutSummary(id: id, start: end.addingTimeInterval(-minutes * 60), duration: minutes * 60, name: "Run",
                       symbol: "figure.run", energyKcal: nil, averageHeartRate: nil)
    }

    @Test func derivedIsTheLastMinutesPeakMinusTheReadingAMinuteLater() {
        let readings = [reading(-90, 175), reading(-40, 168), reading(-5, 165), reading(30, 150), reading(62, 146), reading(120, 120)]
        // 175 is before the last minute, so the peak is 168.
        #expect(HeartRateRecovery.derived(readings, end: end) == 22)
    }

    @Test func derivedNeedsReadingsOnBothSides() {
        #expect(HeartRateRecovery.derived([reading(-10, 160)], end: end) == nil, "Nothing after the end")
        #expect(HeartRateRecovery.derived([reading(60, 140)], end: end) == nil, "Nothing in the last minute")
        #expect(HeartRateRecovery.derived([reading(0, 160)], end: end) == nil, "A reading at the end is the peak, not the minute after")
    }

    @Test func readingAfterMayBeUpToFifteenSecondsOffTheMinute() {
        #expect(HeartRateRecovery.derived([reading(-10, 160), reading(75, 140)], end: end) == 20)
        #expect(HeartRateRecovery.derived([reading(-10, 160), reading(45, 140)], end: end) == 20)
        #expect(HeartRateRecovery.derived([reading(-10, 160), reading(76, 140)], end: end) == nil)
        #expect(HeartRateRecovery.derived([reading(-10, 160), reading(44, 140)], end: end) == nil)
    }

    @Test func risingHeartRateIsNoRecovery() {
        #expect(HeartRateRecovery.derived([reading(-10, 150), reading(60, 156)], end: end) == nil)
        #expect(HeartRateRecovery.derived([reading(-10, 150), reading(60, 150)], end: end) == 0)
    }

    @Test func aWorkoutStartingInTheMinuteAfterTakesItsReadings() {
        #expect(HeartRateRecovery.isFollowed(end: end, byStarts: [end.addingTimeInterval(10)]))
        #expect(HeartRateRecovery.isFollowed(end: end, byStarts: [end.addingTimeInterval(75)]))
        #expect(!HeartRateRecovery.isFollowed(end: end, byStarts: [end.addingTimeInterval(-1800), end.addingTimeInterval(76)]),
                "Its own start and a later workout don't count")
    }

    @Test func appleSamplesGoToTheWorkoutTheyFollow() {
        let first = (id: "a", end: end)
        let second = (id: "b", end: end.addingTimeInterval(3 * 3600))
        let samples = [TimedValue(date: end.addingTimeInterval(30), value: 25),
                       TimedValue(date: end.addingTimeInterval(3600), value: 99)]
        #expect(HeartRateRecovery.match(samples, to: [first, second]) == ["a": 25], "A sample an hour off belongs to neither")
    }

    @Test func aSampleGoesToTheWorkoutThatEndedLastBeforeIt() {
        // A run ends, a cool-down walk ends 3 minutes later, and Apple's sample comes after the walk.
        let run = (id: "run", end: end)
        let walk = (id: "walk", end: end.addingTimeInterval(180))
        let sample = TimedValue(date: end.addingTimeInterval(200), value: 21)
        #expect(HeartRateRecovery.match([sample], to: [run, walk]) == ["walk": 21])
    }

    @Test func aWorkoutKeepsItsFirstSample() {
        let samples = [TimedValue(date: end.addingTimeInterval(90), value: 30),
                       TimedValue(date: end.addingTimeInterval(20), value: 24)]
        #expect(HeartRateRecovery.match(samples, to: [(id: "a", end: end)]) == ["a": 24])
    }

    @Test func eachDayShowsItsLastWorkoutWithARecovery() {
        let day = calendar.startOfDay(for: end)
        let morning = workout("morning", endingAt: day.addingTimeInterval(8 * 3600))
        let evening = workout("evening", endingAt: day.addingTimeInterval(19 * 3600))
        let late = workout("late", endingAt: day.addingTimeInterval(21 * 3600))
        let previous = calendar.date(byAdding: .day, value: -1, to: day)!
        let series = HeartRateRecovery.byDay(["morning": 30, "evening": 18], workouts: [morning, evening, late],
                                             days: [previous, day], calendar: calendar)
        #expect(series == [DayValue(day: previous, value: nil), DayValue(day: day, value: 18)])
    }

    @Test func aWorkoutAcrossMidnightCountsOnTheDayItStarted() {
        let day = calendar.startOfDay(for: end)
        let next = calendar.date(byAdding: .day, value: 1, to: day)!
        let overnight = workout("overnight", endingAt: next.addingTimeInterval(1800), minutes: 60)
        let series = HeartRateRecovery.byDay(["overnight": 20], workouts: [overnight], days: [day, next], calendar: calendar)
        #expect(series == [DayValue(day: day, value: 20), DayValue(day: next, value: nil)])
    }

    @Test func coleCutOffMarksSlowRecoveries() {
        #expect(HeartRateRecovery.rating(12) == .fair)
        #expect(HeartRateRecovery.rating(13) == .good)
    }

    @Test func pastDaysEndOnTheShownDay() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!
        let source = PastDaySource(base: SampleDataSource(), daysAgo: 3,
                                   dayEnd: calendar.date(byAdding: .day, value: 1, to: threeDaysAgo)!)
        let series = try await source.heartRateRecovery(days: 8)
        #expect(series.count == 8)
        #expect(series.last?.day == threeDaysAgo)
    }

    @MainActor
    @Test func storedWorkoutsAskTheirOwnSource() async throws {
        let container = try ModelContainer(for: DaySummary.self, WorkoutRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var garmin = workout("garmin-run", endingAt: today.addingTimeInterval(9 * 3600))
        garmin.source = "garmin"
        let apple = workout("apple-run", endingAt: calendar.date(byAdding: .day, value: -1, to: today)!.addingTimeInterval(9 * 3600))
        context.insert(WorkoutRecord(garmin))
        context.insert(WorkoutRecord(apple))
        try context.save()
        let health = RecoverySource(id: HealthKitReader.sourceID, values: ["apple-run": 24, "garmin-run": 99])
        let series = try await StoredHealthData(container: container, sources: [health]).heartRateRecovery(days: 2)
        #expect(series.map(\.value) == [24, nil], "Only Apple Health's own workout; Garmin isn't a live source here")
        #expect(health.asked == [["apple-run"]])
    }

    @Test func cardShowsTheLatestRecoveryOfTheLastTwoWeeks() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let slow = try await SnapshotBuilder(source: FixedRecoverySource(values: [-20: 30, -3: 12])).snapshot(for: .heartRateRecovery)
        #expect(slow.value == "12")
        #expect(slow.rating == .fair)
        #expect(slow.comparison == "Slow: 12 bpm or less")
        #expect(slow.period == calendar.date(byAdding: .day, value: -3, to: today)!.formatted(.dateTime.month(.abbreviated).day()))
        let old = try await SnapshotBuilder(source: FixedRecoverySource(values: [-20: 30])).snapshot(for: .heartRateRecovery)
        #expect(old.value == nil, "A recovery from 20 days ago isn't shown as the latest")
    }

    /// The chart is the last 7 days under their weekdays, not the last 7 readings pushed to the right (#164).
    @Test func cardChartsReadingsOnTheirDays() async throws {
        let snapshot = try await SnapshotBuilder(source: FixedRecoverySource(values: [-10: 25, -5: 20, -1: 22]))
            .snapshot(for: .heartRateRecovery)
        guard case .line(let values, _) = snapshot.chart else { Issue.record("Expected a line chart"); return }
        #expect(values == [nil, 20, nil, nil, nil, 22, nil])
    }
}

/// A live source with fixed recoveries, recording which workouts it was asked about.
private final class RecoverySource: LiveHealthSource {
    let id: String
    let values: [String: Double]
    private(set) var asked: [[String]] = []
    init(id: String, values: [String: Double]) {
        self.id = id
        self.values = values
    }
    func heartRateRecovery(after workouts: [WorkoutSummary]) async throws -> [String: Double] {
        asked.append(workouts.map(\.id).sorted())
        return values.filter { id, _ in workouts.contains { $0.id == id } }
    }
}

/// Sample data with recoveries on fixed days, by offset from today.
private struct FixedRecoverySource: HealthDataSource {
    let base = SampleDataSource()
    let values: [Int: Double]
    func heartRateRecovery(days: Int) async throws -> [DayValue] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<days).reversed().map { offset in
            DayValue(day: calendar.date(byAdding: .day, value: -offset, to: today)!, value: values[-offset])
        }
    }
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] { try await base.daily(metric, days: days) }
    func sleepNights(days: Int) async throws -> [SleepNight] { try await base.sleepNights(days: days) }
    func standHours(days: Int) async throws -> [DayValue] { try await base.standHours(days: days) }
    func overnight(days: Int) async throws -> [OvernightVitals] { try await base.overnight(days: days) }
    func workouts(days: Int) async throws -> [WorkoutSummary] { try await base.workouts(days: days) }
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] { try await base.heartRate(in: interval) }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { try await base.sleepPeriods(in: interval) }
    func age() async throws -> Int? { try await base.age() }
    func biologicalSex() async throws -> BiologicalSex? { try await base.biologicalSex() }
    func highestHeartRate(days: Int) async throws -> Double? { try await base.highestHeartRate(days: days) }
}
