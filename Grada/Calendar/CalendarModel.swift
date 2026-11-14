import Foundation
import Observation
import os

/// Day colours and workout days for the calendar, and cards for a selected past day.
@Observable
final class CalendarModel {
    /// Start of each rated day → its rating for the loaded metric.
    private(set) var ratings: [Date: DayRating] = [:]
    private(set) var workoutDays: Set<Date> = []
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

    func load(_ metric: CalendarMetric) async {
        do {
            let today = calendar.startOfDay(for: .now)
            let earliest = try await source.earliestDay().map { calendar.startOfDay(for: $0) }
                ?? calendar.date(byAdding: .day, value: -fallbackDays + 1, to: today)!
            let days = (calendar.dateComponents([.day], from: earliest, to: today).day ?? 0) + 1

            let newRatings = try await ratings(metric, days: days)
            let workouts = try await source.workouts(days: days)
            ratings = newRatings
            workoutDays = Set(workouts.map { calendar.startOfDay(for: $0.start) })
            firstMonth = calendar.dateInterval(of: .month, for: earliest)?.start
        } catch {
            // Keep the last good month grid; the next load retries.
            logger.error("Loading calendar failed: \(error.localizedDescription)")
        }
    }

    /// Cards for `day` as they looked at the end of that day, without the 7-day charts
    /// (the month grid already shows the trend).
    func snapshots(for day: Date, kinds: [CardKind]) async -> [CardKind: CardSnapshot] {
        let start = calendar.startOfDay(for: day)
        let daysAgo = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: .now)).day ?? 0
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: start)!
        var builder = SnapshotBuilder(source: daysAgo == 0 ? source : PastDaySource(base: source, daysAgo: daysAgo, dayEnd: dayEnd))
        builder.calendar = calendar
        builder.now = daysAgo == 0 ? .now : dayEnd.addingTimeInterval(-1)

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

    private func ratings(_ metric: CalendarMetric, days: Int) async throws -> [Date: DayRating] {
        // Vitals need the baseline window before the first shown day.
        let withBaseline = days + baselineDays
        switch metric {
        case .healthStatus:
            var series: [QuantityMetric: [DayValue]] = [:]
            for (vital, _) in SnapshotBuilder.vitals {
                series[vital] = try await source.daily(vital, days: withBaseline)
            }
            return DayRatings.rateHealthStatus(series, baselineDays: baselineDays)
        case .hrv:
            return DayRatings.rateVital(try await source.daily(.hrv, days: withBaseline), metric: .hrv,
                                        higherIsBetter: true, baselineDays: baselineDays)
        case .restingHeartRate:
            return DayRatings.rateVital(try await source.daily(.restingHeartRate, days: withBaseline), metric: .restingHeartRate,
                                        higherIsBetter: false, baselineDays: baselineDays)
        case .steps:
            let series = try await source.daily(.steps, days: days)
            return Dictionary(uniqueKeysWithValues: series.compactMap { entry in
                entry.value.map { (entry.day, DayRatings.goal($0, goal: DayRatings.stepsGoal)) }
            })
        case .sleep:
            let nights = try await source.sleepNights(days: days).filter { $0.asleep > 0 }
            return Dictionary(nights.map { ($0.wakeDay, DayRatings.goal($0.asleep, goal: DayRatings.sleepGoal)) },
                              uniquingKeysWith: { first, _ in first })
        }
    }
}
