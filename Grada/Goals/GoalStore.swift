import Foundation
import SwiftData

/// One stored goal change. Defaults on every property and no unique constraints keep it ready for
/// CloudKit sync, like `DaySummary`.
@Model
final class GoalChange {
    var metricRawValue: String = ""
    var value: Double = 0
    var effectiveFrom: Date = Date.distantPast
    var reasonRawValue: String = ""

    init(_ entry: GoalEntry) {
        metricRawValue = entry.metric.rawValue
        value = entry.value
        effectiveFrom = entry.effectiveFrom
        reasonRawValue = entry.reason.rawValue
    }

    var entry: GoalEntry? {
        guard let metric = GoalMetric(rawValue: metricRawValue), let reason = GoalEntry.Reason(rawValue: reasonRawValue) else { return nil }
        return GoalEntry(metric: metric, value: value, effectiveFrom: effectiveFrom, reason: reason)
    }
}

extension GoalHistory {
    init(_ changes: [GoalChange]) {
        self.init(changes.compactMap(\.entry))
    }
}

/// Reads and writes goals, and runs the weekly adjustment.
@MainActor
struct GoalStore {
    let context: ModelContext
    let source: HealthDataSource
    var calendar: Calendar = .current

    private var today: Date { calendar.startOfDay(for: .now) }

    func history() -> GoalHistory {
        GoalHistory((try? context.fetch(FetchDescriptor<GoalChange>())) ?? [])
    }

    /// The last 7 days per metric, for "From your last 7 days". Nil with less than a week of history.
    func lastWeek() async throws -> [GoalMetric: [Double?]]? {
        guard let earliest = try await source.earliestDay(),
              calendar.startOfDay(for: earliest) <= calendar.date(byAdding: .day, value: -7, to: today)!
        else { return nil }
        // The 7 full days before today, so a day that has just started doesn't drag the median down.
        let values = try await dailyValues(days: 8)
        return values.mapValues { Array($0.values.dropLast()) }
    }

    /// Replaces every goal with `goals`, starting today.
    func start(with goals: [GoalMetric: Double], reason: GoalEntry.Reason) {
        for (metric, value) in goals {
            context.insert(GoalChange(GoalEntry(metric: metric, value: value, effectiveFrom: today, reason: reason)))
        }
        try? context.save()
    }

    /// The user's own value, holding for a week before automatic adjustment continues from it.
    func edit(_ metric: GoalMetric, to value: Double) {
        context.insert(GoalChange(GoalEntry(metric: metric, value: metric.rounded(value), effectiveFrom: today, reason: .edit)))
        try? context.save()
    }

    /// Saves automatic changes for every Monday since the last one. Returns true if anything changed.
    @discardableResult
    func adjustIfNeeded() async throws -> Bool {
        let history = history()
        guard !history.isEmpty else { return false }
        let days = Goals.maximumCatchUpWeeks * 7 + 7
        let values = try await dailyValues(days: days)
        var changed = false
        for metric in GoalMetric.allCases {
            let daily = values[metric].map { series in
                Dictionary(zip(series.days, series.values).compactMap { day, value in value.map { (day, $0) } },
                           uniquingKeysWith: { first, _ in first })
            } ?? [:]
            for entry in Goals.adjustments(metric, history: history, daily: daily, today: today, calendar: calendar) {
                context.insert(GoalChange(entry))
                changed = true
            }
        }
        if changed { try context.save() }
        return changed
    }

    /// Each goal metric's value per day for the `days` days ending today. Sleep has no automatic steps.
    private func dailyValues(days: Int) async throws -> [GoalMetric: (days: [Date], values: [Double?])] {
        var builder = SnapshotBuilder(source: source)
        builder.calendar = calendar
        let steps = try await source.daily(.steps, days: days)
        let dayStarts = steps.map(\.day)
        let workouts = try await source.workouts(days: days)
        let workoutCounts = Dictionary(grouping: workouts) { calendar.startOfDay(for: $0.start) }.mapValues { Double($0.count) }
        return [
            .steps: (dayStarts, steps.map(\.value)),
            .floors: (dayStarts, try await source.daily(.floors, days: days).map(\.value)),
            .activeEnergy: (dayStarts, try await source.daily(.activeEnergy, days: days).map(\.value)),
            .intensityMinutes: (dayStarts, try await builder.intensityDays(days).map(\.value)),
            .workouts: (dayStarts, dayStarts.map { workoutCounts[$0] ?? 0 }),
        ]
    }
}
