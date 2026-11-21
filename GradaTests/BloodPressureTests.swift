import Foundation
import SwiftData
import Testing
@testable import Grada

struct BloodPressureTests {
    /// 2017 ACC/AHA: normal below 120/80, elevated 120–129 over below 80, stage 1 130–139 or 80–89, stage 2 from
    /// 140 or 90; the higher of the two numbers' categories counts.
    @Test func categoriesFollowTheGuideline() {
        typealias Category = BloodPressure.Category
        #expect(Category(systolic: 119, diastolic: 79) == .normal)
        #expect(Category(systolic: 120, diastolic: 79) == .elevated)
        #expect(Category(systolic: 129, diastolic: 79) == .elevated)
        #expect(Category(systolic: 130, diastolic: 70) == .stage1)
        #expect(Category(systolic: 115, diastolic: 80) == .stage1, "Diastolic alone makes stage 1")
        #expect(Category(systolic: 125, diastolic: 85) == .stage1, "Elevated systolic, stage 1 diastolic")
        #expect(Category(systolic: 140, diastolic: 70) == .stage2)
        #expect(Category(systolic: 118, diastolic: 90) == .stage2)
        #expect(Category(systolic: 119.6, diastolic: 79.4) == .elevated, "Classed as shown: 120/79")
        #expect(Category(systolic: 129.5, diastolic: 79) == .stage1, "Shown as 130")
        #expect(Category(systolic: 139.5, diastolic: 79) == .stage2, "Shown as 140")
        #expect(Category(systolic: 119, diastolic: 89.5) == .stage2, "Shown as 90")
        #expect(Category(systolic: 120, diastolic: 80) == .stage1, "Stage 1 by diastolic")
        #expect(Category.stage2.rating == .poor)
        #expect(Category.elevated.rating == .fair)
        #expect(Category.normal.rating == .good)
    }

    @Test func readingsNeedBothNumbers() {
        let day = Calendar.current.startOfDay(for: .now)
        let earlier = day.addingTimeInterval(-86_400)
        let readings = BloodPressure.readings(
            systolic: [DayValue(day: earlier, value: 130), DayValue(day: day, value: 121)],
            diastolic: [DayValue(day: earlier, value: nil), DayValue(day: day, value: 79)]
        )
        #expect(readings.count == 1)
        #expect(readings.first?.day == day)
        #expect(BloodPressure.reading(systolic: 121.4, diastolic: 78.6) == "121/79")
    }

    @Test func cardShowsTheLatestReadingAndItsCategory() async throws {
        let source = SampleDataSource()
        let snapshot = try await SnapshotBuilder(source: source).snapshot(for: .bloodPressure)
        let readings = BloodPressure.readings(systolic: try await source.daily(.bloodPressureSystolic, days: 30),
                                              diastolic: try await source.daily(.bloodPressureDiastolic, days: 30))
        let latest = try #require(readings.last)
        let category = BloodPressure.Category(systolic: latest.systolic, diastolic: latest.diastolic)
        #expect(snapshot.value == BloodPressure.reading(systolic: latest.systolic, diastolic: latest.diastolic))
        #expect(snapshot.unit == "mmHg")
        #expect(snapshot.rating == category.rating)
        #expect(snapshot.comparison?.hasPrefix("\(category.title) · 30-day avg ") == true, "\(snapshot.comparison ?? "")")
        #expect(CardKind.bloodPressure.category == .heart)
        #expect(CardKind.bloodPressure.sources == [.whelton2018])
    }

    @Test func cardAveragesTheDaysWithReadings() async throws {
        let store = try store([(0, ["health": (120, 80)]), (-2, ["health": (130, 70)])])
        let snapshot = try await SnapshotBuilder(source: StoredHealthData(container: store)).snapshot(for: .bloodPressure)
        #expect(snapshot.value == "120/80")
        #expect(snapshot.comparison == "Stage 1 · 30-day avg 125/75")
        #expect(snapshot.rating == .fair)
    }

    @Test func aMissingDiastolicShowsNoData() async throws {
        let store = try store([(0, ["health": (120, nil)])])
        #expect(try await SnapshotBuilder(source: StoredHealthData(container: store)).snapshot(for: .bloodPressure).value == nil)
    }

    @Test func anOldReadingShowsWithoutColor() async throws {
        let store = try store([(-10, ["health": (145, 95)])])
        let snapshot = try await SnapshotBuilder(source: StoredHealthData(container: store)).snapshot(for: .bloodPressure)
        #expect(snapshot.value == "145/95")
        #expect(snapshot.rating == nil, "Over a week old")
    }

    /// The first source in order has only systolic that day, so both numbers come from the next one.
    @MainActor
    @Test func aDaysPairComesFromOneSource() async throws {
        let store = try store([(0, ["first": (150, nil), "second": (118, 76)])])
        let data = StoredHealthData(container: store, sources: [RankSource(id: "first"), RankSource(id: "second")])
        #expect(try await data.daily(.bloodPressureSystolic, days: 1).last?.value == 118)
        #expect(try await data.daily(.bloodPressureDiastolic, days: 1).last?.value == 76)
    }

    /// Rows by day offset from today and source: (systolic, diastolic).
    private func store(_ days: [(offset: Int, bySource: [String: (Double?, Double?)])]) throws -> ModelContainer {
        let container = try ModelContainer(for: DaySummary.self, WorkoutRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let calendar = Calendar.current
        for (offset, bySource) in days {
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now))!
            for (source, (systolic, diastolic)) in bySource {
                let row = DaySummary(day: day, dayKey: DayKey.make(day, calendar: calendar), source: source)
                row.bloodPressureSystolic = systolic
                row.bloodPressureDiastolic = diastolic
                context.insert(row)
            }
        }
        try context.save()
        return container
    }

    @Test func noReadingsShowNoData() async throws {
        let container = try ModelContainer(for: DaySummary.self, WorkoutRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let snapshot = try await SnapshotBuilder(source: StoredHealthData(container: container)).snapshot(for: .bloodPressure)
        #expect(snapshot.value == nil)
    }

    @MainActor
    @Test func detailTrendsBothAndListsReadingsNewestFirst() async throws {
        let source = SampleDataSource()
        let builder = TrendBuilder(source: source)
        #expect(try await builder.trend(for: .bloodPressure, period: .month)?.title == "Systolic")
        #expect(try await builder.extraTrends(for: .bloodPressure, period: .month).map(\.title) == ["Diastolic"])
        let breakdown = try await Breakdown.load(for: .bloodPressure, day: Calendar.current.startOfDay(for: .now),
                                                 period: .month, source: source, calendar: .current)
        guard case .bloodPressure(let readings) = breakdown else { Issue.record("Expected readings"); return }
        #expect(!readings.isEmpty)
        #expect(zip(readings, readings.dropFirst()).allSatisfy { $0.day > $1.day })
    }
}

/// A live source that only sets the merge order.
private final class RankSource: LiveHealthSource {
    let id: String
    init(id: String) { self.id = id }
}
