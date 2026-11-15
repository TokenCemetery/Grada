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
    /// Start of the first month shown; nil until loaded.
    private(set) var firstMonth: Date?
    let importer: HealthImporter?

    private let source: HealthDataSource
    private let calendar: Calendar
    private let logger = Logger(subsystem: "Grada", category: "CalendarModel")
    /// Same history window the cards use for personal normal ranges.
    private let baselineDays = 30
    /// Used when the source can't say where its data starts.
    private let fallbackDays = 365

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
            let days = (calendar.dateComponents([.day], from: earliest, to: today).day ?? 0) + 1

            let newRatings = try await ratings(metric, days: days, goals: goals)
            let workouts = try await source.workouts(days: days)
            ratings = newRatings
            workoutDays = WorkoutDay.byDay(workouts, calendar: calendar)
            firstMonth = calendar.dateInterval(of: .month, for: earliest)?.start
        } catch {
            // Keep the last good month grid; the next load retries.
            logger.error("Loading calendar failed: \(error.localizedDescription)")
        }
    }

    /// Cards for `day` as they looked at the end of that day, without the 7-day charts
    /// (the month grid already shows the trend).
    func snapshots(for day: Date, kinds: [CardKind], goals: GoalHistory) async -> [CardKind: CardSnapshot] {
        var builder = SnapshotBuilder.forDay(day, source: source, calendar: calendar)
        builder.goals = goals

        var result: [CardKind: CardSnapshot] = [:]
        await withTaskGroup(of: (CardKind, CardSnapshot?).self) { group in
            for kind in Set(kinds) {
                group.addTask { [logger] in
                    do { return (kind, try await builder.snapshot(for: kind)) }
                    catch {
                        logger.error("Loading \(kind.rawValue) for a past day failed: \(error.localizedDescription)")
                        return (kind, nil)
                    }
                }
            }
            for await (kind, snapshot) in group {
                guard var snapshot else { continue }
                snapshot.chart = .none
                result[kind] = snapshot
            }
        }
        return result
    }

    /// A Last Workout card for each of `day`'s workouts, earliest first.
    func workoutSnapshots(for day: Date) async -> [CardSnapshot] {
        let builder = SnapshotBuilder.forDay(day, source: source, calendar: calendar)
        do {
            let today = calendar.startOfDay(for: .now)
            let back = (calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: today).day ?? 0) + 1
            return try await source.workouts(days: back)
                .filter { calendar.isDate($0.start, inSameDayAs: day) }
                .sorted { $0.start < $1.start }
                .map(builder.workoutSnapshot)
        } catch {
            logger.error("Loading workouts for a past day failed: \(error.localizedDescription)")
            return []
        }
    }

    private func ratings(_ metric: CalendarMetric, days: Int, goals: GoalHistory) async throws -> [Date: DayRating] {
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
                day.result.map { (day.day, Recovery.rating($0.score)) }
            }, uniquingKeysWith: { first, _ in first })
        case .training:
            return [:]
        }
    }
}
