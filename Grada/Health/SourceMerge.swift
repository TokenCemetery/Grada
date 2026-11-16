import Foundation

/// Rules for keeping one copy when several apps or sources record the same thing: between Grada's
/// sources, and between apps writing to Apple Health. The thresholds are Grada's choice, not from a study.
nonisolated enum SourceMerge {
    /// How far back `rankByCoverage` looks to pick an app's readings over another's.
    static let coverageDays = 30

    /// Workouts recorded twice (e.g. by a watch and by an app syncing from another device) collapse to one:
    /// the preferred one wins when two overlap by more than half of the shorter one. Newest first.
    static func uniqueWorkouts(_ workouts: [WorkoutSummary],
                               preferring isPreferred: (WorkoutSummary, WorkoutSummary) -> Bool = mostDetail) -> [WorkoutSummary] {
        var kept: [WorkoutSummary] = []
        for workout in workouts.sorted(by: isPreferred) where !kept.contains(where: { overlaps($0, workout) }) {
            kept.append(workout)
        }
        return kept.sorted { $0.start > $1.start }
    }

    /// Prefers the workout with heart rate, then with energy, then the longer one.
    static func mostDetail(_ lhs: WorkoutSummary, _ rhs: WorkoutSummary) -> Bool {
        if (lhs.averageHeartRate != nil) != (rhs.averageHeartRate != nil) { return lhs.averageHeartRate != nil }
        if (lhs.energyKcal != nil) != (rhs.energyKcal != nil) { return lhs.energyKcal != nil }
        if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
        return lhs.id < rhs.id
    }

    static func overlaps(_ lhs: WorkoutSummary, _ rhs: WorkoutSummary) -> Bool {
        let overlap = min(lhs.start + lhs.duration, rhs.start + rhs.duration).timeIntervalSince(max(lhs.start, rhs.start))
        return overlap > min(lhs.duration, rhs.duration) / 2
    }

    /// Sources ordered by how many days they have a value in the last `coverageDays` days up to `end`,
    /// most first; ties by name so the order is stable. Using the same app every day keeps baselines from
    /// jumping between devices that measure differently, as HRV does.
    static func rankByCoverage(_ values: [String: [DayValue]], endingBefore end: Date, calendar: Calendar) -> [String] {
        let start = calendar.date(byAdding: .day, value: -coverageDays, to: end)!
        let counts = values.mapValues { days in days.filter { $0.value != nil && $0.day >= start && $0.day < end }.count }
        return counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
    }

    /// For each of `days`, the value of the first source in `order` that has one.
    static func firstAvailable(_ values: [String: [DayValue]], order: [String], days: [Date]) -> [DayValue] {
        let byDay = values.mapValues { Dictionary($0.map { ($0.day, $0.value) }, uniquingKeysWith: { first, _ in first }) }
        return days.map { day in
            DayValue(day: day, value: order.lazy.compactMap { byDay[$0]?[day] ?? nil }.first)
        }
    }
}
