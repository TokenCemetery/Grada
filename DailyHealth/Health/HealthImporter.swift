import Foundation
import Observation
import os
import SwiftData

/// Raw Apple Health data for a range of days, ready to save.
struct HealthBatch {
    /// Start of the first day ..< start of the day after the last.
    var days: DateInterval
    var daily: [QuantityMetric: [DayValue]] = [:]
    var standHours: [DayValue] = []
    var sleepNights: [SleepNight] = []
    var workouts: [WorkoutSummary] = []
}

/// Copies Apple Health data into the app's store: the whole history on first launch,
/// then the last few days on every refresh.
@Observable
final class HealthImporter {
    /// 0...1 while the first-launch history import runs, nil otherwise.
    private(set) var historyProgress: Double?
    /// Changes whenever new data is saved, so screens know to reload.
    private(set) var revision = 0

    @ObservationIgnored private let reader: HealthKitReader
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let calendar = Calendar.current
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var authorization: Task<Void, Never>?
    @ObservationIgnored private var recentImport: Task<Void, Never>?
    @ObservationIgnored private var recentImportPending = false
    @ObservationIgnored private var didStartBackgroundUpdates = false
    private let logger = Logger(subsystem: "DailyHealth", category: "HealthImporter")

    /// Oldest day imported so far; lets an interrupted history import resume.
    private static let importedFromKey = "historyImportedFrom"
    private static let historyDoneKey = "historyImportDone"
    /// Re-imported on every refresh: today, plus nights and late-syncing watches from the days before.
    static let recentDays = 3

    init(reader: HealthKitReader, context: ModelContext) {
        self.reader = reader
        self.context = context
    }

    func authorize() async {
        if authorization == nil {
            authorization = Task {
                do { try await reader.requestAuthorization() }
                catch { logger.error("Health authorization failed: \(error.localizedDescription)") }
            }
        }
        await authorization?.value
    }

    /// Imports everything Apple Health has, a year at a time, newest first so recent cards fill in quickly.
    func importHistoryIfNeeded() async {
        guard HealthKitReader.isAvailable, !defaults.bool(forKey: Self.historyDoneKey), historyProgress == nil else { return }
        await authorize()
        historyProgress = 0
        defer { historyProgress = nil }

        do {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
            guard let earliestSample = try await reader.earliestSampleDate() else {
                defaults.set(true, forKey: Self.historyDoneKey)
                return
            }
            let earliest = calendar.startOfDay(for: earliestSample)
            var end = (defaults.object(forKey: Self.importedFromKey) as? Date) ?? tomorrow
            let total = max(tomorrow.timeIntervalSince(earliest), 1)

            while end > earliest {
                let start = max(earliest, calendar.date(byAdding: .year, value: -1, to: end)!)
                try await importDays(DateInterval(start: start, end: end))
                defaults.set(start, forKey: Self.importedFromKey)
                historyProgress = tomorrow.timeIntervalSince(start) / total
                end = start
            }
            defaults.set(true, forKey: Self.historyDoneKey)
            logger.info("History import finished from \(earliest)")
        } catch {
            // Resumes from the last saved year on the next launch.
            logger.error("History import stopped: \(error.localizedDescription)")
        }
    }

    /// Re-imports the last few days whenever Apple Health gets new data, including in the background.
    func startBackgroundUpdates() async {
        guard HealthKitReader.isAvailable, !didStartBackgroundUpdates else { return }
        didStartBackgroundUpdates = true
        await authorize()
        do {
            try await reader.observeChanges { [weak self] completion in
                Task { @MainActor in
                    await self?.importRecent()
                    completion()
                }
            }
        } catch {
            logger.error("Background updates unavailable: \(error.localizedDescription)")
        }
    }

    /// Several data types often change together (a workout brings energy, distance and heart rate),
    /// so overlapping calls share one import, plus one more pass if data changed while it ran.
    func importRecent() async {
        guard HealthKitReader.isAvailable else { return }
        if let running = recentImport {
            recentImportPending = true
            await running.value
            return
        }
        let task = Task {
            repeat {
                recentImportPending = false
                await importRecentDays()
            } while recentImportPending
            recentImport = nil
        }
        recentImport = task
        await task.value
    }

    private func importRecentDays() async {
        await authorize()
        let today = calendar.startOfDay(for: .now)
        let start = calendar.date(byAdding: .day, value: -(Self.recentDays - 1), to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        do {
            try await importDays(DateInterval(start: start, end: end))
        } catch {
            logger.error("Recent import failed: \(error.localizedDescription)")
        }
    }

    private func importDays(_ days: DateInterval) async throws {
        var batch = HealthBatch(days: days)
        for metric in QuantityMetric.allCases {
            batch.daily[metric] = try await reader.daily(metric, in: days)
        }
        batch.standHours = try await reader.standHours(in: days)
        batch.sleepNights = try await reader.sleepNights(in: days)
        batch.workouts = try await reader.workouts(in: days)
        // Everything below is synchronous, so concurrent imports can't interleave their writes.
        try save(batch)
    }

    /// Upserts one batch: one summary per day, one record per workout. Removes duplicates
    /// (e.g. from two devices importing the same history) and workouts deleted from Apple Health.
    func save(_ batch: HealthBatch) throws {
        let start = batch.days.start, end = batch.days.end

        var summaries: [String: DaySummary] = [:]
        for summary in try context.fetch(FetchDescriptor<DaySummary>(predicate: #Predicate { $0.day >= start && $0.day < end })) {
            if summaries[summary.dayKey] == nil { summaries[summary.dayKey] = summary } else { context.delete(summary) }
        }

        let sleepByDay = Dictionary(batch.sleepNights.map { ($0.wakeDay, $0) }, uniquingKeysWith: { first, _ in first })
        let standByDay = Dictionary(batch.standHours.map { ($0.day, $0.value) }, uniquingKeysWith: { first, _ in first })
        let dailyByDay = batch.daily.mapValues { values in
            Dictionary(values.map { ($0.day, $0.value) }, uniquingKeysWith: { first, _ in first })
        }

        var day = start
        while day < end {
            let key = DayKey.make(day, calendar: calendar)
            let metrics = dailyByDay.mapValues { $0[day] ?? nil }
            let stand = standByDay[day] ?? nil
            let sleep = sleepByDay[day]
            let hasData = metrics.values.contains { $0 != nil } || stand != nil || sleep != nil

            if let summary = summaries[key] ?? (hasData ? DaySummary(day: day, dayKey: key) : nil) {
                if summaries[key] == nil { context.insert(summary) }
                for (metric, value) in metrics { summary.setValue(value, for: metric) }
                summary.standHours = stand
                summary.setSleep(sleep)
                summary.updatedAt = .now
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }

        let fetched = Dictionary(batch.workouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kept = Set<String>()
        for record in try context.fetch(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.start >= start && $0.start < end })) {
            if fetched[record.healthID] == nil || !kept.insert(record.healthID).inserted {
                context.delete(record)
            }
        }
        for workout in fetched.values where !kept.contains(workout.id) {
            context.insert(WorkoutRecord(workout))
        }

        try context.save()
        revision += 1
    }
}
