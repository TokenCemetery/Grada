import Foundation
import SwiftData
import Testing
@testable import Grada

@MainActor
struct HomeModelTests {
    private let cards = [
        CardID(kind: .steps), CardID(kind: .sleepNeed), CardID(kind: .recovery), CardID(kind: .steps, variant: .week),
    ]

    @Test func reloadBuildsASnapshotForEveryPlacedCard() async {
        let model = HomeModel(source: SampleDataSource())
        #expect(model.snapshots.isEmpty)
        await model.reload(cards, goals: GoalHistory())
        #expect(Set(model.snapshots.keys) == Set(cards))
    }

    @Test func reloadOnlyBuildsPlacedCards() async {
        let model = HomeModel(source: SampleDataSource())
        await model.reload([CardID(kind: .steps)], goals: GoalHistory())
        #expect(Set(model.snapshots.keys) == [CardID(kind: .steps)])
    }

    @Test func reloadWithoutCardsLeavesNoSnapshots() async {
        let model = HomeModel(source: SampleDataSource())
        await model.reload([], goals: GoalHistory())
        #expect(model.snapshots.isEmpty)
    }

    @Test func reloadUsesTheGoalsInEffect() async {
        let model = HomeModel(source: SampleDataSource())
        let today = Calendar.current.startOfDay(for: .now)
        let goals = GoalHistory([GoalEntry(metric: .steps, value: 9_000, effectiveFrom: today, reason: .edit)])
        await model.reload([CardID(kind: .steps)], goals: goals)
        let withGoal = model.snapshots[CardID(kind: .steps)]
        await model.reload([CardID(kind: .steps)], goals: GoalHistory())
        #expect(withGoal != nil)
        #expect(withGoal?.comparison != model.snapshots[CardID(kind: .steps)]?.comparison)
    }
}

@MainActor
struct GoalStoreTests {
    private let calendar = Calendar.current

    private func store() throws -> GoalStore {
        let container = try ModelContainer(for: GoalChange.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return GoalStore(context: ModelContext(container), source: SampleDataSource())
    }

    /// Two weeks back, so at least one Monday has passed since the goal started.
    private func start(_ store: GoalStore, steps: Double) {
        let weeksAgo = calendar.date(byAdding: .day, value: -14, to: calendar.startOfDay(for: .now))!
        store.context.insert(GoalChange(GoalEntry(metric: .steps, value: steps, effectiveFrom: weeksAgo, reason: .edit)))
        try? store.context.save()
    }

    @Test func nothingAdjustsWithoutAGoal() async throws {
        let store = try store()
        #expect(try await store.adjustIfNeeded() == false)
        #expect(store.history().isEmpty)
    }

    /// Sample steps are about 9,000 a day, so a 5,000 goal is hit on every measured day: raised by 5%.
    @Test func raisesAGoalThatWasMetMostDays() async throws {
        let store = try store()
        start(store, steps: 5_000)
        #expect(try await store.adjustIfNeeded() == true)
        let automatic = store.history().entries.filter { $0.reason == .automatic && $0.metric == .steps }
        #expect(automatic.first?.value == 5_250)
        #expect(automatic.allSatisfy { $0.effectiveFrom > store.history().entries.first!.effectiveFrom })
    }

    /// A 30,000 goal is hit on no day: lowered by 5%.
    @Test func lowersAGoalThatWasMissedMostDays() async throws {
        let store = try store()
        start(store, steps: 30_000)
        #expect(try await store.adjustIfNeeded() == true)
        let automatic = store.history().entries.filter { $0.reason == .automatic && $0.metric == .steps }
        #expect(automatic.first?.value == 28_500)
    }

    @Test func adjustingTwiceDoesNotRepeatTheChange() async throws {
        let store = try store()
        start(store, steps: 5_000)
        _ = try await store.adjustIfNeeded()
        #expect(try await store.adjustIfNeeded() == false)
    }

    /// Hit 3 or 4 of 7 days: the goal holds. Weekly goals hold between 70% and 100% of the target.
    @Test func holdsAGoalMetOnSomeDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let start = calendar.date(byAdding: .day, value: -7, to: monday)!
        let goals = GoalHistory([GoalEntry(metric: .steps, value: 9_000, effectiveFrom: start, reason: .edit)], calendar: calendar)
        let values: [Double] = [9_000, 9_000, 9_000, 1_000, 1_000, 1_000, 1_000]
        let daily = Dictionary(uniqueKeysWithValues: values.enumerated().map {
            (calendar.date(byAdding: .day, value: $0.offset - 7, to: monday)!, $0.element)
        })
        #expect(Goals.adjustments(.steps, history: goals, daily: daily, today: monday, calendar: calendar).isEmpty)
    }
}
