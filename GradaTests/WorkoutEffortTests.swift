import Foundation
import SwiftData
import Testing
@testable import Grada

struct WorkoutEffortTests {
    /// Foster et al. 2001: session RPE is the rating times the session's minutes.
    @Test func sessionLoadIsEffortTimesMinutes() {
        #expect(SessionRPE.load(effort: 7, duration: 45 * 60) == 315)
    }

    @Test func workoutDetailCarriesTheRating() async throws {
        let source = SampleDataSource()
        let workouts = try await source.workouts(days: 7)
        let run = try #require(workouts.first { $0.name == "Run" })
        let ride = try #require(workouts.first { $0.name == "Ride" })
        let walk = try #require(workouts.first { $0.name == "Walk" })
        #expect(try await source.workoutDetail(run).effort?.isEstimate == false)
        #expect(try await source.workoutDetail(ride).effort == WorkoutEffort(score: 5, isEstimate: true))
        #expect(try await source.workoutDetail(walk).effort == nil)
    }

    @MainActor
    @Test func strainDetailComparesEffortWithHeartRateLoad() async throws {
        let trends = try await TrendBuilder(source: SampleDataSource()).extraTrends(for: .strain, period: .month)
        let effort = try #require(trends.first { $0.title == "Effort Load of Rated Workouts" })
        let heartRate = try #require(trends.first { $0.title == "Heart Rate Load of Rated Workouts" })
        #expect(effort.points.count == heartRate.points.count)
        #expect((effort.high ?? 0) > 0)
        #expect((heartRate.high ?? 0) > 0)
        // Days without a rated workout count nothing in both.
        for (effortPoint, heartRatePoint) in zip(effort.points, heartRate.points) {
            #expect((effortPoint.value == 0) == (heartRatePoint.value == 0))
        }
    }

    @MainActor
    @Test func noComparisonWithTooFewRatings() async throws {
        let trends = try await TrendBuilder(source: TwoRatingsSource()).extraTrends(for: .strain, period: .month)
        #expect(!trends.contains { $0.title == "Effort Load of Rated Workouts" })
    }

    @MainActor
    @Test func threeOwnRatingsWithHeartRateShowTheCharts() async throws {
        let source = EffortStubSource(workouts: (1...3).map { EffortStubSource.morning(daysAgo: $0) })
        let trends = try await TrendBuilder(source: source).extraTrends(for: .strain, period: .month)
        let effort = try #require(trends.first { $0.title == "Effort Load of Rated Workouts" })
        let heartRate = try #require(trends.first { $0.title == "Heart Rate Load of Rated Workouts" })
        // Each: rated 6 for 30 minutes, and 30 minutes at 150 bpm, zone 4 at age 30.
        #expect(effort.points.compactMap(\.value).reduce(0, +) == 3 * 180)
        #expect(heartRate.points.compactMap(\.value).reduce(0, +) == 3 * 120)
    }

    @MainActor
    @Test func applesEstimatesAreLeftOut() async throws {
        var source = EffortStubSource(workouts: (1...3).map { EffortStubSource.morning(daysAgo: $0) })
        source.estimated = ["day-1"]
        #expect(try await TrendBuilder(source: source).extraTrends(for: .strain, period: .month)
            .contains { $0.title == "Effort Load of Rated Workouts" } == false, "Only 2 of your own ratings")
    }

    @MainActor
    @Test func workoutsWithoutHeartRateAreLeftOut() async throws {
        var source = EffortStubSource(workouts: (1...4).map { EffortStubSource.morning(daysAgo: $0) })
        source.withoutHeartRate = ["day-1"]
        let trends = try await TrendBuilder(source: source).extraTrends(for: .strain, period: .month)
        let effort = try #require(trends.first { $0.title == "Effort Load of Rated Workouts" })
        #expect(effort.points.compactMap(\.value).reduce(0, +) == 3 * 180, "The workout without heart rate counts in neither")

        source.withoutHeartRate = ["day-1", "day-2"]
        #expect(try await TrendBuilder(source: source).extraTrends(for: .strain, period: .month)
            .contains { $0.title == "Effort Load of Rated Workouts" } == false, "Only 2 with heart rate")
    }

    @MainActor
    @Test func workoutPastMidnightKeepsItsHeartRate() async throws {
        let calendar = Calendar.current
        let lateStart = calendar.date(byAdding: .minute, value: -30, to: calendar.date(byAdding: .day, value: -4, to: calendar.startOfDay(for: .now))!)!
        let late = WorkoutSummary(id: "late", start: lateStart, duration: 3600, name: "Run", symbol: "figure.run",
                                  energyKcal: nil, averageHeartRate: nil)
        let source = EffortStubSource(workouts: (1...2).map { EffortStubSource.morning(daysAgo: $0) } + [late])
        let trends = try await TrendBuilder(source: source).extraTrends(for: .strain, period: .month)
        let heartRate = try #require(trends.first { $0.title == "Heart Rate Load of Rated Workouts" })
        // 60 minutes in zone 4, half of them after midnight, all counted on the day it started.
        #expect(heartRate.points.first { calendar.isDate($0.date, inSameDayAs: lateStart) }?.value == 240)
    }

    @MainActor
    @Test func pastDayLeavesOutLaterWorkouts() async throws {
        let calendar = Calendar.current
        let base = EffortStubSource(workouts: (1...4).map { EffortStubSource.morning(daysAgo: $0) })
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: .now))!
        let past = PastDaySource(base: base, daysAgo: 3, dayEnd: calendar.date(byAdding: .day, value: 1, to: threeDaysAgo)!)
        #expect(try await TrendBuilder(source: past).extraTrends(for: .strain, period: .month)
            .contains { $0.title == "Effort Load of Rated Workouts" } == false, "Only 2 workouts by that day")
    }

    @Test func storedWorkoutsAskTheirOwnSource() async throws {
        let container = try ModelContainer(for: DaySummary.self, WorkoutRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(8 * 3600)
        var garmin = WorkoutSummary(id: "garmin-run", start: start, duration: 1800, name: "Run", symbol: "figure.run",
                                    energyKcal: nil, averageHeartRate: nil)
        garmin.source = "garmin"
        let apple = WorkoutSummary(id: "apple-run", start: start.addingTimeInterval(-86_400), duration: 1800, name: "Run",
                                   symbol: "figure.run", energyKcal: nil, averageHeartRate: nil)
        context.insert(WorkoutRecord(garmin))
        context.insert(WorkoutRecord(apple))
        try context.save()
        let health = EffortSource(efforts: ["apple-run": WorkoutEffort(score: 6, isEstimate: false),
                                            "garmin-run": WorkoutEffort(score: 9, isEstimate: false)])
        let efforts = try await StoredHealthData(container: container, sources: [health]).workoutEfforts(days: 2)
        #expect(efforts == ["apple-run": WorkoutEffort(score: 6, isEstimate: false)], "Garmin workouts carry no rating")
        #expect(health.asked == [["apple-run"]])
    }
}

/// 30-minute morning workouts rated 6 by the user, with heart rate at 150 bpm every 5 minutes; age 30.
private struct EffortStubSource: HealthDataSource {
    let workouts: [WorkoutSummary]
    var estimated: Set<String> = []
    var withoutHeartRate: Set<String> = []

    static func morning(daysAgo: Int) -> WorkoutSummary {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now))!
        return WorkoutSummary(id: "day-\(daysAgo)", start: day.addingTimeInterval(8 * 3600), duration: 1800, name: "Run",
                              symbol: "figure.run", energyKcal: nil, averageHeartRate: nil)
    }

    func workouts(days: Int) async throws -> [WorkoutSummary] {
        let calendar = Calendar.current
        let first = calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: .now))!
        return workouts.filter { $0.start >= first }
    }
    func workoutEfforts(days: Int) async throws -> [String: WorkoutEffort] {
        Dictionary(uniqueKeysWithValues: workouts.map { ($0.id, WorkoutEffort(score: 6, isEstimate: estimated.contains($0.id))) })
    }
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] {
        workouts.filter { !withoutHeartRate.contains($0.id) }.flatMap { workout in
            stride(from: 0, to: workout.duration, by: 300).map { TimedValue(date: workout.start + $0, value: 150) }
        }.filter { interval.contains($0.date) }.sorted { $0.date < $1.date }
    }
    func age() async throws -> Int? { 30 }
    func highestHeartRate(days: Int) async throws -> Double? { nil }
    func biologicalSex() async throws -> BiologicalSex? { nil }
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] { [] }
    func sleepNights(days: Int) async throws -> [SleepNight] { [] }
    func standHours(days: Int) async throws -> [DayValue] { [] }
    func overnight(days: Int) async throws -> [OvernightVitals] { [] }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { [] }
}

private final class EffortSource: LiveHealthSource {
    let id = HealthKitReader.sourceID
    let efforts: [String: WorkoutEffort]
    private(set) var asked: [[String]] = []
    init(efforts: [String: WorkoutEffort]) { self.efforts = efforts }

    func effort(of workouts: [WorkoutSummary]) async throws -> [String: WorkoutEffort] {
        asked.append(workouts.map(\.id).sorted())
        return efforts.filter { id, _ in workouts.contains { $0.id == id } }
    }
}

/// Sample data with only two rated workouts.
private struct TwoRatingsSource: HealthDataSource {
    let base = SampleDataSource()
    func workoutEfforts(days: Int) async throws -> [String: WorkoutEffort] {
        let all = try await base.workoutEfforts(days: days)
        return Dictionary(uniqueKeysWithValues: all.sorted { $0.key < $1.key }.prefix(2).map { ($0.key, $0.value) })
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
