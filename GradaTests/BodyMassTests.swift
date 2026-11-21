import Foundation
import SwiftData
import Testing
@testable import Grada

struct BodyMassTests {
    @Test func bmiIsWeightOverHeightSquared() {
        #expect(abs(BodyMass.bmi(kilograms: 70, centimeters: 175) - 22.857) < 0.001)
    }

    @Test func whoClassesStartAtTheirBounds() {
        #expect(BodyMass.BMIClass(18.4) == .underweight)
        #expect(BodyMass.BMIClass(18.5) == .normal)
        #expect(BodyMass.BMIClass(24.9) == .normal)
        #expect(BodyMass.BMIClass(25) == .preObese)
        #expect(BodyMass.BMIClass(29.9) == .preObese)
        #expect(BodyMass.BMIClass(30) == .obese)
    }

    @Test func classMatchesTheBMIAsShown() {
        // 24.96 shows as 25.0, so it must read as pre-obese, not normal.
        #expect(BodyMass.BMIClass(24.96) == .preObese)
        #expect(BodyMass.BMIClass(24.94) == .normal)
        #expect(BodyMass.BMIClass(18.46) == .normal)
        #expect(BodyMass.BMIClass(29.96) == .obese)
        // The chart's normal band holds exactly what the class calls normal.
        for bmi in stride(from: 18.0, through: 26.0, by: 0.01) {
            #expect(BodyMass.normalBMI.contains(bmi) == (BodyMass.BMIClass(bmi) == .normal) || abs(bmi - 18.45) < 0.001 || abs(bmi - 24.95) < 0.001)
        }
    }

    @Test func weightFollowsTheLocalesUnits() {
        #expect(BodyMass.display(70, usesMetric: true) == 70)
        #expect(abs(BodyMass.display(70, usesMetric: false) - 154.32) < 0.01)
        #expect(BodyMass.unit(usesMetric: true) == "kg")
        #expect(BodyMass.unit(usesMetric: false) == "lb")
    }

    @Test func cardShowsTheLatestWeightAndItsChange() async throws {
        var builder = SnapshotBuilder(source: SampleDataSource())
        builder.usesMetric = true
        let snapshot = try await builder.snapshot(for: .weight)
        let weight = try #require(snapshot.value.flatMap { try? Double($0, format: .number) })
        #expect((73...75).contains(weight))
        #expect(snapshot.unit == "kg")
        // Sample data has a height of 178 cm.
        let bmi = BodyMass.bmi(kilograms: weight, centimeters: 178)
        #expect(snapshot.comparison == "BMI \(bmi.formatted(.number.precision(.fractionLength(1)))) · Normal")
        guard case .line(let values, _) = snapshot.chart else { Issue.record("Expected a line"); return }
        #expect(values.count == 30)
        #expect(snapshot.rating == nil, "Weight isn't rated")

        builder.usesMetric = false
        let pounds = try #require(try await builder.snapshot(for: .weight).value.flatMap { try? Double($0, format: .number) })
        #expect(abs(pounds - weight * BodyMass.poundsPerKilogram) < 0.2)
    }

    @Test func withoutAHeightTheCardShowsTheChange() async throws {
        var builder = SnapshotBuilder(source: NoHeightSource())
        builder.usesMetric = true
        let snapshot = try await builder.snapshot(for: .weight)
        #expect(snapshot.comparison?.hasSuffix("kg in 30 days") == true)
    }

    @MainActor
    @Test func detailAddsBodyFatBMIAndLeanMass() async throws {
        var builder = TrendBuilder(source: SampleDataSource())
        builder.usesMetric = true
        let trends = try await builder.extraTrends(for: .weight, period: .month)
        #expect(trends.count == 3)
        #expect(trends[0].title == "Body Fat Percentage")
        // 74 kg at 178 cm.
        #expect(trends[1].title == "Body Mass Index · Normal")
        #expect(trends[1].normalRange == BodyMass.normalBMI)
        #expect(trends[2].title == "Lean Body Mass")
        #expect(try await builder.extraTrends(for: .steps, period: .month).isEmpty)
    }

    @Test func latestHeightComesFromAnyStoredDay() async throws {
        let container = try ModelContainer(for: DaySummary.self, WorkoutRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        for (offset, height) in [(-2000, 176.0), (-400, 178.0)] {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let row = DaySummary(day: day, dayKey: DayKey.make(day, calendar: calendar), source: HealthKitReader.sourceID)
            row.height = height
            context.insert(row)
        }
        try context.save()
        #expect(try await StoredHealthData(container: container).latest(.height) == 178)
        #expect(try await StoredHealthData(container: container).latest(.bodyMass) == nil)
    }

    @MainActor
    @Test func latestHeightOnADayFollowsTheSourceOrder() async throws {
        let container = try ModelContainer(for: DaySummary.self, WorkoutRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -10, to: calendar.startOfDay(for: .now))!
        let key = DayKey.make(day, calendar: calendar)
        // The other source's row is stored a few hours later, as from a time zone further west (#118).
        for (source, offset, height) in [("garmin", 5.0 * 3600, 190.0), (HealthKitReader.sourceID, 0, 178.0)] {
            let row = DaySummary(day: day.addingTimeInterval(offset), dayKey: key, source: source)
            row.height = height
            context.insert(row)
        }
        try context.save()
        let health = RankOnlySource(id: HealthKitReader.sourceID)
        #expect(try await StoredHealthData(container: container, sources: [health, RankOnlySource(id: "garmin")]).latest(.height) == 178)
        #expect(try await StoredHealthData(container: container, sources: [RankOnlySource(id: "garmin"), health]).latest(.height) == 190)
    }

    @Test func weightCardListsItsData() {
        #expect(CardKind.weight.dataKinds == [.bodyMass, .bodyFat, .leanBodyMass, .height])
        #expect(CardKind.weight.category == .body)
        #expect(CardKind.weight.sources == [.who2000])
    }
}

/// A live source that only sets the merge order.
private final class RankOnlySource: LiveHealthSource {
    let id: String
    init(id: String) { self.id = id }
}

/// Sample data without any height, so there's no BMI.
private struct NoHeightSource: HealthDataSource {
    let base = SampleDataSource()
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] {
        let series = try await base.daily(metric, days: days)
        return metric == .height ? series.map { DayValue(day: $0.day, value: nil) } : series
    }
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
