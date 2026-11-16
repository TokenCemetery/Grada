import Foundation
import Observation
import os

/// Day colours and workouts for the calendar, and cards for a selected past day.
@Observable
final class CalendarModel {
    /// Start of each rated day → its rating for the loaded type. Empty for Training.
    private(set) var ratings: [Date: DayRating] = [:]
    /// Start of each day with a workout → its sports.
    private(set) var workoutDays: [Date: WorkoutDay] = [:]
    /// Start of each day with a workout → its workouts, for the Training day sheet.
    private var workoutsByDay: [Date: [WorkoutSummary]] = [:]
    /// Start of the first month shown; nil until loaded.
    private(set) var firstMonth: Date?
    /// Start of the oldest month with data loaded. Older months show no data until they scroll into view.
    private var firstLoadedMonth: Date?
    let importer: HealthImporter?

    private let source: HealthDataSource
    private let calendar: Calendar
    private let logger = Logger(subsystem: "Grada", category: "CalendarModel")
    /// Same history window the cards use for personal normal ranges.
    private let baselineDays = 30
    /// Used when the source can't say where its data starts.
    private let fallbackDays = 365
    /// Months loaded back from the current one, so years of history don't load before the calendar shows.
    private var loadedMonths = 6
    /// Months added each time the oldest loaded month scrolls into view.
    private let monthsPerStep = 6

    init(source: HealthDataSource, importer: HealthImporter? = nil, calendar: Calendar = .current) {
        self.source = source
        self.importer = importer
        self.calendar = calendar
    }

    func load(_ metric: CalendarMetric, goals: GoalHistory) async {
        do {
            let today = calendar.startOfDay(for: .now)
            let earliest = try await source.earliestDay().map { calendar.startOfDay(for: $0) }
                ?? calendar.date(byAdding: .day, value: -fallbackDays + 1, to: today)!
            let months = loadedMonths
            let currentMonth = calendar.dateInterval(of: .month, for: today)!.start
            let loadedMonth = calendar.date(byAdding: .month, value: -(months - 1), to: currentMonth)!
            let start = max(earliest, loadedMonth)
            let days = (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1

            // Rating reads the same days once per metric, plus the baseline before them; Training only reads workouts.
            let source = metric.isRated ? try source.withDaysLoaded(days + baselineDays) : source
            let newRatings = try await ratings(metric, days: days, goals: goals, source: source)
            let workouts = try await source.workouts(days: days)
            // A longer load started meanwhile; let it fill in instead.
            guard months == loadedMonths else { return }
            ratings = newRatings
            workoutDays = WorkoutDay.byDay(workouts, calendar: calendar)
            workoutsByDay = Dictionary(grouping: workouts) { calendar.startOfDay(for: $0.start) }
            firstMonth = calendar.dateInterval(of: .month, for: earliest)?.start
            firstLoadedMonth = calendar.dateInterval(of: .month, for: start)?.start
        } catch {
            // Keep the last good month grid; the next load retries.
            logger.error("Loading calendar failed: \(error.localizedDescription)")
        }
    }

    /// Loads more history once `month`, the oldest loaded month or older, scrolls into view.
    func reveal(_ month: Date, metric: CalendarMetric, goals: GoalHistory) async {
        guard let firstMonth, let firstLoadedMonth, month <= firstLoadedMonth, firstLoadedMonth > firstMonth else { return }
        let currentMonth = calendar.dateInterval(of: .month, for: .now)!.start
        let back = calendar.dateComponents([.month], from: month, to: currentMonth).month ?? 0
        loadedMonths = max(loadedMonths, back + 1) + monthsPerStep
        await load(metric, goals: goals)
    }

    /// Cards for `day` as they looked at the end of that day, with their charts ending on that day.
    func snapshots(for day: Date, cards: [CardID], goals: GoalHistory) async -> [CardKind: CardSnapshot] {
        var builder = SnapshotBuilder.forDay(day, source: source, calendar: calendar)
        builder.goals = goals

        var result: [CardKind: CardSnapshot] = [:]
        await withTaskGroup(of: (CardKind, CardSnapshot?).self) { group in
            for card in Set(cards) {
                let kind = card.kind
                group.addTask { [logger] in
                    do { return (kind, try await builder.snapshot(for: kind, variant: card.variant)) }
                    catch {
                        logger.error("Loading \(kind.rawValue) for a past day failed: \(error.localizedDescription)")
                        return (kind, nil)
                    }
                }
            }
            for await (kind, snapshot) in group {
                result[kind] = snapshot
            }
        }
        return result
    }

    /// A Last Workout card for each of `day`'s workouts, earliest first, from the workouts `load` read.
    func workoutSnapshots(for day: Date) -> [CardSnapshot] {
        let builder = SnapshotBuilder.forDay(day, source: source, calendar: calendar)
        return (workoutsByDay[calendar.startOfDay(for: day)] ?? [])
            .sorted { $0.start < $1.start }
            .map(builder.workoutSnapshot)
    }

    private func ratings(_ metric: CalendarMetric, days: Int, goals: GoalHistory,
                         source: HealthDataSource) async throws -> [Date: DayRating] {
        switch metric {
        case .health:
            // Vitals need the baseline window before the first shown day.
            var series: [QuantityMetric: [DayValue]] = [:]
            for (vital, _) in SnapshotBuilder.vitals {
                series[vital] = try await source.daily(vital, days: days + baselineDays)
            }
            return DayRatings.rateHealthStatus(series, baselineDays: baselineDays)
        case .recovery:
            var builder = SnapshotBuilder(source: source)
            builder.calendar = calendar
            builder.goals = goals
            return Dictionary(try await builder.recoveryDays(days).compactMap { day in
                day.result.map { (day.day, $0.rating) }
            }, uniquingKeysWith: { first, _ in first })
        case .training:
            return [:]
        }
    }
}
