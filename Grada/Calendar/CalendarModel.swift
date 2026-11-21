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
    /// Cycle: each loaded day with flow logged, each day's cycle day, and each night's sleeping wrist temperature.
    private(set) var flowDays: [Date: FlowDay] = [:]
    private(set) var cycleDays: [Date: Int] = [:]
    private(set) var wristTemperature: [Date: Double] = [:]
    /// Cycle, from evidence only (#138): each loaded day's logged signs, each day ovulation is likely on, the next
    /// period's likely range, and how many complete cycles are logged.
    private(set) var signs: [Date: [CycleSign]] = [:]
    private(set) var ovulationDays: [Date: Cycle.Ovulation] = [:]
    private(set) var prediction: Cycle.Prediction?
    private(set) var completeCycles = 0
    /// Whether the Cycle type shows: Female as the profile's sex.
    private(set) var showsCycle = false
    /// The type the last finished load was for, and whether a Cycle load found any period day in Apple Health,
    /// including before the loaded months.
    private(set) var loadedMetric: CalendarMetric?
    private(set) var hasPeriods = false
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
    /// Counts loads, so only the latest one's result is shown.
    @ObservationIgnored private var loads = 0

    init(source: HealthDataSource, importer: HealthImporter? = nil, calendar: Calendar = .autoupdatingCurrent) {
        self.source = source
        self.importer = importer
        self.calendar = calendar
    }

    /// What `load` reads, as plain values, so the reading and rating can run off the main actor.
    private nonisolated struct Loaded {
        var earliest: Date
        var start: Date
        var ratings: [Date: DayRating]
        var workouts: [WorkoutSummary]
        var showsCycle: Bool
        var flow: [FlowDay] = []
        var cycleDays: [Date: Int] = [:]
        var wristTemperature: [Date: Double] = [:]
        var hasPeriods = false
        var signs: [CycleSign] = []
        var ovulations: [Cycle.Ovulation] = []
        var prediction: Cycle.Prediction?
        var completeCycles = 0
    }

    func load(_ metric: CalendarMetric, goals: GoalHistory) async {
        loads += 1
        let load = loads
        do {
            let loaded = try await Self.read(metric, months: loadedMonths, goals: goals, source: source, calendar: calendar,
                                             baselineDays: baselineDays, fallbackDays: fallbackDays)
            // A later load started meanwhile, for another type, more months or newer data; let it fill in instead.
            // Reads don't all stop when cancelled, so a switch of type can't rely on cancellation (#171).
            guard load == loads else { return }
            ratings = loaded.ratings
            showsCycle = loaded.showsCycle
            flowDays = Dictionary(loaded.flow.map { ($0.day, $0) }) { first, _ in first }
            cycleDays = loaded.cycleDays
            wristTemperature = loaded.wristTemperature
            hasPeriods = loaded.hasPeriods
            signs = Dictionary(grouping: loaded.signs, by: \.day)
            // Only after the fact: a positive test yesterday marks today, not tomorrow.
            let today = calendar.startOfDay(for: .now)
            ovulationDays = Dictionary(loaded.ovulations.flatMap { ovulation in
                ovulation.days.filter { $0 <= today }.map { ($0, ovulation) }
            }) { first, _ in first }
            prediction = loaded.prediction
            completeCycles = loaded.completeCycles
            loadedMetric = metric
            workoutDays = WorkoutDay.byDay(loaded.workouts, calendar: calendar)
            workoutsByDay = Dictionary(grouping: loaded.workouts) { calendar.startOfDay(for: $0.start) }
            firstMonth = calendar.dateInterval(of: .month, for: loaded.earliest)?.start
            firstLoadedMonth = calendar.dateInterval(of: .month, for: loaded.start)?.start
        } catch {
            // Keep the last good month grid; the next load retries.
            logger.error("Loading calendar failed: \(error.localizedDescription)")
        }
    }

    @concurrent private static func read(_ metric: CalendarMetric, months: Int, goals: GoalHistory, source: HealthDataSource,
                                         calendar: Calendar, baselineDays: Int, fallbackDays: Int) async throws -> Loaded {
        let today = calendar.startOfDay(for: .now)
        let earliest = try await source.earliestDay().map { calendar.startOfDay(for: $0) }
            ?? calendar.date(byAdding: .day, value: -fallbackDays + 1, to: today)!
        let currentMonth = calendar.dateInterval(of: .month, for: today)!.start
        let loadedMonth = calendar.date(byAdding: .month, value: -(months - 1), to: currentMonth)!
        let start = max(earliest, loadedMonth)
        let days = (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1

        // Rating reads the same days once per metric, plus the baseline before them; Training only reads workouts.
        let source = metric.isRated ? try await source.withDaysLoaded(days + baselineDays) : source
        let ratings = try await ratings(metric, days: days, goals: goals, source: source, calendar: calendar,
                                        baselineDays: baselineDays)
        let workouts = try await source.workouts(days: days)
        var loaded = Loaded(earliest: earliest, start: start, ratings: ratings, workouts: workouts,
                            showsCycle: await Cycle.isShown(source: source))
        // Read live each time and kept only in memory: cycle data isn't stored (#137).
        if metric == .cycle, loaded.showsCycle {
            let flow = try await source.menstrualFlow(days: max(days + Cycle.lookbackDays, Cycle.predictionDays))
            let starts = Cycle.starts(flow, calendar: calendar)
            // A period running into the start of what was read looks like a start but may not be one.
            let readStart = calendar.date(byAdding: .day, value: 1 - max(days + Cycle.lookbackDays, Cycle.predictionDays), to: today)!
            var knownStarts = starts
            if let first = starts.first, flow.first(where: { $0.day == first })?.isCycleStart != true,
               calendar.dateComponents([.day], from: readStart, to: first).day! <= Cycle.gapDays {
                knownStarts.removeFirst()
            }
            loaded.prediction = Cycle.prediction(starts: knownStarts, today: today, calendar: calendar)
            loaded.completeCycles = Cycle.lengths(knownStarts, calendar: calendar).count
            loaded.hasPeriods = flow.contains { $0.flow.isBleeding }
            if !loaded.hasPeriods {
                loaded.hasPeriods = try await source.menstrualFlow(days: Cycle.historyDays).contains { $0.flow.isBleeding }
            }
            loaded.flow = flow.filter { $0.day >= start }
            for offset in 0..<days {
                let day = calendar.date(byAdding: .day, value: offset, to: start)!
                loaded.cycleDays[day] = Cycle.day(day, starts: starts, calendar: calendar)
            }
            // Ovulation in the first shown cycle can rest on nights before the shown months.
            var nights: [Date: Double] = [:]
            for night in try await source.daily(.wristTemperature, days: days + Cycle.lookbackDays) {
                if let value = night.value { nights[night.day] = value }
            }
            let signs = try await source.cycleSigns(days: days + Cycle.lookbackDays)
            let wristOrigin = try await source.origins()[.wristTemperature]?.max { $0.lastDay < $1.lastDay }?.name
            loaded.ovulations = Cycle.ovulations(starts: starts, signs: signs, wristTemperature: nights,
                                                 wristOrigin: wristOrigin, calendar: calendar)
            loaded.signs = signs.filter { $0.day >= start }
            loaded.wristTemperature = nights.filter { $0.key >= start }
        }
        return loaded
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

    private nonisolated static func ratings(_ metric: CalendarMetric, days: Int, goals: GoalHistory, source: HealthDataSource,
                                calendar: Calendar, baselineDays: Int) async throws -> [Date: DayRating] {
        switch metric {
        case .health:
            // Vitals need the baseline window before the first shown day.
            var series: [QuantityMetric: [DayValue]] = [:]
            for (vital, _) in SnapshotBuilder.vitals {
                series[vital] = try await SnapshotBuilder.vitalSeries(vital, days: days + baselineDays, source: source)
            }
            return DayRatings.rateHealthStatus(series, baselineDays: baselineDays)
        case .recovery:
            var builder = SnapshotBuilder(source: source)
            builder.calendar = calendar
            builder.goals = goals
            return Dictionary(try await builder.recoveryDays(days).compactMap { day in
                day.result.map { (day.day, $0.rating) }
            }, uniquingKeysWith: { first, _ in first })
        case .training, .cycle:
            return [:]
        }
    }
}
