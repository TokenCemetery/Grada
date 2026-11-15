import Foundation

/// Metrics the user has a goal for. The raw value is persisted, so don't rename cases.
nonisolated enum GoalMetric: String, CaseIterable, Identifiable {
    case steps, floors, activeEnergy, sleep, intensityMinutes, workouts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steps: "Steps"
        case .floors: "Floors"
        case .activeEnergy: "Active energy"
        case .sleep: "Sleep"
        case .intensityMinutes: "Intensity minutes"
        case .workouts: "Workouts"
        }
    }

    /// Weekly goals are judged on the week's total; daily goals day by day.
    var isWeekly: Bool { self == .intensityMinutes || self == .workouts }

    /// Goals are rounded to this, and an adjustment moves at least this far. Sleep is in seconds.
    var step: Double {
        switch self {
        case .steps: 250
        case .floors, .workouts: 1
        case .activeEnergy: 10
        case .intensityMinutes: 5
        case .sleep: 15 * 60
        }
    }

    var limits: ClosedRange<Double> {
        switch self {
        case .steps: 3_000...30_000
        case .floors: 1...100
        case .activeEnergy: 50...3_000
        // The WHO minimum is the floor.
        case .intensityMinutes: IntensityMinutes.weeklyTarget...1_000
        case .workouts: 1...14
        case .sleep: 5 * 3600...11 * 3600
        }
    }

    func formatted(_ value: Double) -> String {
        switch self {
        case .steps, .floors: value.formatted(.number.precision(.fractionLength(0)))
        case .activeEnergy: "\(value.formatted(.number.precision(.fractionLength(0)))) kcal"
        case .sleep: SnapshotBuilder.hoursMinutes(value)
        case .intensityMinutes: "\(value.formatted(.number.precision(.fractionLength(0)))) min a week"
        case .workouts: "\(value.formatted(.number.precision(.fractionLength(0)))) a week"
        }
    }

    func rounded(_ value: Double) -> Double {
        min(max((value / step).rounded() * step, limits.lowerBound), limits.upperBound)
    }
}

/// Starting goals for people with different needs. Sleep isn't part of a preset: it follows Sleep need.
nonisolated enum GoalPreset: String, CaseIterable, Identifiable {
    case gentle, balanced, active, athlete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gentle: "Gentle"
        case .balanced: "Balanced"
        case .active: "Active"
        case .athlete: "Athlete"
        }
    }

    var summary: String {
        switch self {
        case .gentle: "Getting moving or recovering"
        case .balanced: "General health"
        case .active: "Regular exercise"
        case .athlete: "Training for performance"
        }
    }

    var goals: [GoalMetric: Double] {
        switch self {
        case .gentle: [.steps: 5_000, .floors: 5, .intensityMinutes: 150, .activeEnergy: 250, .workouts: 2]
        case .balanced: [.steps: 7_500, .floors: 10, .intensityMinutes: 150, .activeEnergy: 400, .workouts: 3]
        case .active: [.steps: 10_000, .floors: 15, .intensityMinutes: 225, .activeEnergy: 600, .workouts: 4]
        case .athlete: [.steps: 12_500, .floors: 20, .intensityMinutes: 300, .activeEnergy: 800, .workouts: 5]
        }
    }
}

/// One goal change. `effectiveFrom` is the start of the first day it applies to.
nonisolated struct GoalEntry: Equatable {
    /// The raw value is persisted, so don't rename cases.
    enum Reason: String { case preset, lastWeek, automatic, edit }

    let metric: GoalMetric
    let value: Double
    let effectiveFrom: Date
    let reason: Reason
}

/// Every goal change, so past days are rated against the goal they had.
nonisolated struct GoalHistory: Equatable {
    /// Oldest first.
    private(set) var entries: [GoalEntry]
    var calendar: Calendar = .current

    init(_ entries: [GoalEntry] = [], calendar: Calendar = .current) {
        self.entries = entries.sorted { $0.effectiveFrom < $1.effectiveFrom }
        self.calendar = calendar
    }

    var isEmpty: Bool { entries.isEmpty }

    /// The change in effect on `day`; for sleep, only a user edit that hasn't expired yet.
    func entry(_ metric: GoalMetric, on day: Date) -> GoalEntry? {
        guard let entry = entries.last(where: { $0.metric == metric && $0.effectiveFrom <= day }) else { return nil }
        if metric == .sleep, day >= Goals.adjustmentDate(after: entry.effectiveFrom, calendar: calendar) { return nil }
        return entry
    }

    /// Nil without a goal; for sleep, nil means it follows Sleep need.
    func value(_ metric: GoalMetric, on day: Date) -> Double? {
        entry(metric, on: day)?.value
    }

    /// The latest change and the value before it, for "Raised from 8,000 to 8,500 on 10 Nov".
    func latestChange(_ metric: GoalMetric) -> (entry: GoalEntry, previous: Double?)? {
        let changes = entries.filter { $0.metric == metric }
        guard let latest = changes.last else { return nil }
        return (latest, changes.dropLast().last?.value)
    }

    mutating func append(_ entry: GoalEntry) {
        entries.append(entry)
        entries.sort { $0.effectiveFrom < $1.effectiveFrom }
    }
}

/// How goals start and how they adjust every week.
nonisolated enum Goals {
    /// A daily goal needs this many measured days in the week to adjust, so missing data doesn't lower it.
    static let minimumMeasuredDays = 4
    /// Mondays left unprocessed longer ago than this are skipped instead of caught up.
    static let maximumCatchUpWeeks = 4
    private static let change = 0.05

    /// The first week start on or after a full week from `date`: a new or edited goal holds at least a week.
    static func adjustmentDate(after date: Date, calendar: Calendar) -> Date {
        let weekLater = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: date))!
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: weekLater)!.start
        return weekStart == weekLater ? weekStart : calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart)!
    }

    /// Goals from the last 7 days: the median for daily goals, the total for weekly goals. Metrics
    /// without data use `fallback`.
    static func fromLastWeek(_ daily: [GoalMetric: [Double?]], fallback: GoalPreset) -> [GoalMetric: Double] {
        var goals = fallback.goals
        for (metric, values) in daily where metric != .sleep {
            let measured = values.compactMap { $0 }
            guard !measured.isEmpty else { continue }
            let value = metric.isWeekly ? measured.reduce(0, +) : median(measured)
            goals[metric] = metric.rounded(value)
        }
        return goals
    }

    /// Automatic changes due between the latest entry and `today`, oldest first. `daily` holds the
    /// metric's value per day start; missing days have no key.
    static func adjustments(_ metric: GoalMetric, history: GoalHistory, daily: [Date: Double],
                            today: Date, calendar: Calendar) -> [GoalEntry] {
        guard metric != .sleep else { return [] }
        let ownEntries = history.entries.filter { $0.metric == metric }
        guard let latest = ownEntries.last else { return [] }

        let earliestCatchUp = calendar.date(byAdding: .weekOfYear, value: -maximumCatchUpWeeks, to: today)!
        var history = history
        var result: [GoalEntry] = []
        var boundary = adjustmentDate(after: latest.effectiveFrom, calendar: calendar)
        while boundary <= today {
            defer { boundary = calendar.date(byAdding: .weekOfYear, value: 1, to: boundary)! }
            guard boundary >= earliestCatchUp,
                  let current = history.value(metric, on: calendar.date(byAdding: .day, value: -1, to: boundary)!),
                  let direction = direction(metric, history: history, daily: daily, weekEnding: boundary, calendar: calendar)
            else { continue }
            var next = metric.rounded(current * (1 + direction * change))
            if next == current { next = metric.rounded(current + direction * metric.step) }
            guard next != current else { continue }
            let entry = GoalEntry(metric: metric, value: next, effectiveFrom: boundary, reason: .automatic)
            history.append(entry)
            result.append(entry)
        }
        return result
    }

    /// +1 to raise, −1 to lower, nil to keep, judged on the 7 days before `weekEnding`.
    private static func direction(_ metric: GoalMetric, history: GoalHistory, daily: [Date: Double],
                                  weekEnding: Date, calendar: Calendar) -> Double? {
        let days = (1...7).reversed().map { calendar.date(byAdding: .day, value: -$0, to: weekEnding)! }
        let measured = days.compactMap { day in daily[day].map { (day, $0) } }
        if metric.isWeekly {
            guard !measured.isEmpty, let goal = history.value(metric, on: days.last!) else { return nil }
            let total = measured.reduce(0) { $0 + $1.1 }
            if total >= goal { return 1 }
            return total < 0.7 * goal ? -1 : nil
        }
        guard measured.count >= minimumMeasuredDays else { return nil }
        let hits = measured.filter { day, value in history.value(metric, on: day).map { value >= $0 } ?? false }.count
        if hits >= 5 { return 1 }
        return hits <= 2 ? -1 : nil
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
