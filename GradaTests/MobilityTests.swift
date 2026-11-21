import Foundation
import HealthKit
import SwiftData
import Testing
@testable import Grada

struct MobilityTests {
    /// Studenski et al. 2011: 1.0 m/s or faster, longer survival; below 0.6 m/s, a possible higher risk.
    @Test func speedBandsFollowStudenski() {
        #expect(Mobility.rating(metersPerSecond: 1.0) == .good)
        #expect(Mobility.rating(metersPerSecond: 0.99) == .fair)
        #expect(Mobility.rating(metersPerSecond: 0.6) == .fair)
        #expect(Mobility.rating(metersPerSecond: 0.59) == .poor)
        #expect(abs(Mobility.speed(1, usesMetric: true) - 3.6) < 0.000_1)
        #expect(abs(Mobility.speed(1, usesMetric: false) - 2.237) < 0.001)
    }

    /// Apple's own classes, from HealthKit's thresholds.
    @Test func steadinessUsesApplesClasses() {
        #expect(Mobility.Steadiness(percent: 95) == .ok)
        #expect(Mobility.Steadiness(percent: 5) == .veryLow)
        let classes = stride(from: 0.0, through: 100, by: 1).compactMap(Mobility.Steadiness.init(percent:))
        #expect(classes.contains(.low))
        // Lower percentages never class steadier than higher ones.
        let order: [Mobility.Steadiness] = [.veryLow, .low, .ok]
        #expect(zip(classes, classes.dropFirst()).allSatisfy { order.firstIndex(of: $0)! <= order.firstIndex(of: $1)! })
    }

    @Test func cardShowsSpeedAndApplesSteadiness() async throws {
        var builder = SnapshotBuilder(source: AgedSource(age: 70))
        builder.usesMetric = true
        let snapshot = try await builder.snapshot(for: .mobility)
        let speeds = try await SampleDataSource().daily(.walkingSpeed, days: 30).suffix(7).compactMap(\.value)
        let average = speeds.reduce(0, +) / Double(speeds.count)
        #expect(snapshot.period == "Last 7 days")
        #expect(snapshot.value == (average * 3.6).formatted(.number.precision(.fractionLength(1))))
        #expect(snapshot.unit == "km/h")
        #expect(snapshot.rating == Mobility.rating(metersPerSecond: average))
        #expect(snapshot.comparison?.hasPrefix("Steadiness ") == true && snapshot.comparison?.hasSuffix(" (Apple)") == true)
        #expect(CardKind.mobility.sources == [.studenski2011, .appleMobility2022])
    }

    @Test func speedIsntRatedBelowTheStudiedAge() async throws {
        #expect(try await SnapshotBuilder(source: AgedSource(age: 64)).snapshot(for: .mobility).rating == nil)
        #expect(try await SnapshotBuilder(source: AgedSource(age: 65)).snapshot(for: .mobility).rating != nil)
        #expect(try await SnapshotBuilder(source: AgedSource(age: nil)).snapshot(for: .mobility).rating == nil)
    }

    /// A speed and steadiness from 20 days ago: the speed shows plain with its date, the steadiness not at all.
    @Test func anOldSpeedShowsWithoutColor() async throws {
        let container = try ModelContainer(for: DaySummary.self, WorkoutRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -20, to: calendar.startOfDay(for: .now))!
        let row = DaySummary(day: day, dayKey: DayKey.make(day, calendar: calendar), source: "health")
        row.walkingSpeed = 0.5
        row.walkingSteadiness = 10
        context.insert(row)
        try context.save()
        var builder = SnapshotBuilder(source: AgedStored(base: StoredHealthData(container: container)))
        builder.usesMetric = true
        let snapshot = try await builder.snapshot(for: .mobility)
        #expect(snapshot.value == 1.8.formatted(.number.precision(.fractionLength(1))))
        #expect(snapshot.period != "Last 7 days")
        #expect(snapshot.rating == nil)
        #expect(snapshot.comparison == nil)
    }

    /// HealthKit keeps percentages as fractions; the store keeps them as percent.
    @Test func healthKitUnitsConvert() {
        #expect(QuantityMetric.walkingSteadiness.convert(HKQuantity(unit: .percent(), doubleValue: 0.92)) == 92)
        #expect(QuantityMetric.walkingAsymmetry.convert(HKQuantity(unit: .percent(), doubleValue: 0.03)) == 3)
        #expect(QuantityMetric.walkingSpeed.convert(HKQuantity(unit: .meter().unitDivided(by: .second()), doubleValue: 1.3)) == 1.3)
        #expect(abs(QuantityMetric.walkingStepLength.convert(HKQuantity(unit: .meter(), doubleValue: 0.72)) - 72) < 0.000_1)
        #expect(Mobility.Steadiness(percent: 120) == nil)
        #expect(Mobility.Steadiness(percent: -5) == nil)
    }

    @Test func noWalkingSpeedShowsNoData() async throws {
        let container = try ModelContainer(for: DaySummary.self, WorkoutRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        #expect(try await SnapshotBuilder(source: StoredHealthData(container: container)).snapshot(for: .mobility).value == nil)
    }

    @MainActor
    @Test func detailTrendsSpeedSteadinessStepLengthAndAsymmetry() async throws {
        var builder = TrendBuilder(source: SampleDataSource())
        builder.usesMetric = true
        #expect(try await builder.trend(for: .mobility, period: .year)?.unit == "km/h")
        let titles = try await builder.extraTrends(for: .mobility, period: .year).compactMap(\.title)
        #expect(titles.count == 3)
        #expect(titles[0].hasPrefix("Walking Steadiness · "))
        #expect(titles[1] == "Walking Step Length")
        #expect(titles[2] == "Walking Asymmetry")
    }
}

/// Sample data with a set age.
private struct AgedSource: HealthDataSource {
    let age: Int?
    let base = SampleDataSource()
    func age() async throws -> Int? { age }
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] { try await base.daily(metric, days: days) }
    func sleepNights(days: Int) async throws -> [SleepNight] { try await base.sleepNights(days: days) }
    func standHours(days: Int) async throws -> [DayValue] { try await base.standHours(days: days) }
    func overnight(days: Int) async throws -> [OvernightVitals] { try await base.overnight(days: days) }
    func workouts(days: Int) async throws -> [WorkoutSummary] { try await base.workouts(days: days) }
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] { try await base.heartRate(in: interval) }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { try await base.sleepPeriods(in: interval) }
    func biologicalSex() async throws -> BiologicalSex? { try await base.biologicalSex() }
    func highestHeartRate(days: Int) async throws -> Double? { try await base.highestHeartRate(days: days) }
}

/// Stored data with age 70.
private struct AgedStored: HealthDataSource {
    let base: StoredHealthData
    func age() async throws -> Int? { 70 }
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] { try await base.daily(metric, days: days) }
    func sleepNights(days: Int) async throws -> [SleepNight] { [] }
    func standHours(days: Int) async throws -> [DayValue] { [] }
    func overnight(days: Int) async throws -> [OvernightVitals] { [] }
    func workouts(days: Int) async throws -> [WorkoutSummary] { [] }
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] { [] }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { [] }
    func biologicalSex() async throws -> BiologicalSex? { nil }
    func highestHeartRate(days: Int) async throws -> Double? { nil }
}
