import Foundation
import Observation
import os
import SwiftData

/// Raw data from one source for a range of days, ready to save.
struct HealthBatch {
    /// Start of the first day ..< start of the day after the last.
    var days: DateInterval
    var daily: [QuantityMetric: [DayValue]] = [:]
    var standHours: [DayValue] = []
    var sleepNights: [SleepNight] = []
    var overnight: [OvernightVitals] = []
    var workouts: [WorkoutSummary] = []
    /// Names of the apps and devices inside the source that each day's values came from.
    var origins: [DataKind: [Date: [String]]] = [:]
}

/// Copies each source's data into the app's store: the whole history on first launch,
/// then the last few days on every refresh.
@Observable
final class HealthImporter {
    /// 0...1 while the first-launch history import runs, nil otherwise.
    private(set) var historyProgress: Double?
    /// The `HealthSource.name` whose history is importing now, while `historyProgress` is set.
    private(set) var historySource: String?
    /// Changes whenever new data is saved, so screens know to reload.
    private(set) var revision = 0

    /// In order of preference, which is also the order cards merge them in.
    @ObservationIgnored let sources: [any HealthSource]
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let calendar = Calendar.current
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var authorization: Task<Void, Never>?
    @ObservationIgnored private var recentImport: Task<Void, Never>?
    @ObservationIgnored private var recentImportPending = false
    @ObservationIgnored private var didStartBackgroundUpdates = false
    /// Runs after each import of recent days, e.g. to send the morning report.
    @ObservationIgnored var onRecentImport: (() async -> Void)?
    /// When each source's recent days were last imported, for `HealthSource.refreshInterval`.
    @ObservationIgnored private var lastRecentImport: [String: Date] = [:]
    private let logger = Logger(subsystem: "Grada", category: "HealthImporter")

    /// Oldest day imported so far, per source; lets an interrupted history import resume.
    /// Versioned: bumping it re-imports the whole history once, e.g. v2 added overnight vitals and
    /// bed and wake times; v3 removes workouts and readings that several apps wrote to Apple Health;
    /// v4 keeps which app or device each value came from.
    private static func importedFromKey(_ source: any HealthSource) -> String { "historyImportedFrom.\(source.id).v4" }
    private static func historyDoneKey(_ source: any HealthSource) -> String { "historyImportDone.\(source.id).v4" }
    /// Re-imported on every refresh: today, plus nights and late-syncing watches from the days before.
    static let recentDays = 3

    init(sources: [any HealthSource], context: ModelContext) {
        self.sources = sources
        self.context = context
    }

    private var availableSources: [any HealthSource] { sources.filter(\.isAvailable) }

    func authorize() async {
        if authorization == nil {
            authorization = Task {
                for source in availableSources {
                    do { try await source.requestAuthorization() }
                    catch { logger.error("Authorization for \(source.id) failed: \(error.localizedDescription)") }
                }
            }
        }
        await authorization?.value
    }

    /// Imports everything each source has, a year at a time, newest first so recent cards fill in quickly.
    func importHistoryIfNeeded() async {
        let pending = availableSources.filter { !defaults.bool(forKey: Self.historyDoneKey($0)) }
        guard !pending.isEmpty, historyProgress == nil else { return }
        await authorize()
        historyProgress = 0
        defer {
            historyProgress = nil
            historySource = nil
        }

        for (index, source) in pending.enumerated() {
            historySource = source.name
            await importHistory(of: source) { progress in
                self.historyProgress = (Double(index) + progress) / Double(pending.count)
            }
        }
    }

    private func importHistory(of source: any HealthSource, progress: (Double) -> Void) async {
        do {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
            guard let earliestSample = try await source.earliestSampleDate() else {
                defaults.set(true, forKey: Self.historyDoneKey(source))
                return
            }
            let earliest = calendar.startOfDay(for: earliestSample)
            var end = (defaults.object(forKey: Self.importedFromKey(source)) as? Date) ?? tomorrow
            let total = max(tomorrow.timeIntervalSince(earliest), 1)

            while end > earliest {
                let start = max(earliest, calendar.date(byAdding: .year, value: -1, to: end)!)
                try await importDays(DateInterval(start: start, end: end), from: source)
                defaults.set(start, forKey: Self.importedFromKey(source))
                progress(tomorrow.timeIntervalSince(start) / total)
                end = start
            }
            defaults.set(true, forKey: Self.historyDoneKey(source))
            logger.info("History import from \(source.id) finished from \(earliest)")
        } catch {
            // Resumes from the last saved year on the next launch.
            logger.error("History import from \(source.id) stopped: \(error.localizedDescription)")
        }
    }

    /// Re-imports the last few days whenever a source gets new data, including in the background.
    func startBackgroundUpdates() async {
        guard !availableSources.isEmpty, !didStartBackgroundUpdates else { return }
        didStartBackgroundUpdates = true
        await authorize()
        for source in availableSources {
            do {
                try await source.observeChanges { [weak self] completion in
                    Task { @MainActor in
                        await self?.importRecent()
                        completion()
                    }
                }
            } catch {
                logger.error("Background updates from \(source.id) unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Several data types often change together (a workout brings energy, distance and heart rate),
    /// so overlapping calls share one import, plus one more pass if data changed while it ran.
    func importRecent() async {
        guard !availableSources.isEmpty else { return }
        if let running = recentImport {
            recentImportPending = true
            await running.value
            return
        }
        let task = Task {
            // The hook runs inside the loop, so a call that arrives while it runs still gets its pass.
            repeat {
                recentImportPending = false
                await importRecentDays()
                await onRecentImport?()
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
        for source in availableSources {
            if let last = lastRecentImport[source.id], Date.now.timeIntervalSince(last) < source.refreshInterval { continue }
            do {
                try await importDays(DateInterval(start: start, end: end), from: source)
                lastRecentImport[source.id] = .now
            } catch {
                logger.error("Recent import from \(source.id) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Imports a source the user just connected: its whole history, then the latest days.
    func sourceConnected(_ source: any HealthSource) async {
        lastRecentImport[source.id] = nil
        await importHistoryIfNeeded()
        await importRecent()
    }

    /// Forgets how far a disconnected source's history import got, so connecting again imports it all.
    /// Its stored data stays.
    func sourceDisconnected(_ source: any HealthSource) {
        defaults.removeObject(forKey: Self.importedFromKey(source))
        defaults.removeObject(forKey: Self.historyDoneKey(source))
        lastRecentImport[source.id] = nil
    }

#if DEBUG && targetEnvironment(simulator)
    /// Throws away imported data and imports the whole history again, after seeding sample data.
    func reimportHistory() async {
        do {
            try context.delete(model: DaySummary.self)
            try context.delete(model: WorkoutRecord.self)
            try context.save()
        } catch {
            logger.error("Clearing imported data failed: \(error.localizedDescription)")
        }
        for source in sources {
            defaults.removeObject(forKey: Self.importedFromKey(source))
            defaults.removeObject(forKey: Self.historyDoneKey(source))
        }
        revision += 1
        await importHistoryIfNeeded()
    }
#endif

    private func importDays(_ days: DateInterval, from source: any HealthSource) async throws {
        let batch = try await source.batch(for: days)
        // Everything below is synchronous, so concurrent imports can't interleave their writes.
        try save(batch, from: source.id)
    }

    /// Reads FIT files the user picked and adds what they hold to what earlier imports saved.
    func importFiles(_ urls: [URL]) async throws -> FITImport {
        let files = await FITImport.read(urls, calendar: calendar)
        if let batch = files.batch(calendar: calendar) { try save(batch, from: FITImport.sourceID, merging: true) }
        return files
    }

    /// Upserts one source's batch: one summary per day, one record per workout. Touches only that
    /// source's rows. Removes duplicates (e.g. from two devices importing the same history) and
    /// workouts deleted from the source. With `merging`, as for file imports that each hold only some
    /// days and kinds of data, values and workouts the batch lacks are kept instead.
    func save(_ batch: HealthBatch, from source: String, merging: Bool = false) throws {
        let start = batch.days.start, end = batch.days.end

        var summaries: [String: DaySummary] = [:]
        let summaryDescriptor = FetchDescriptor<DaySummary>(
            predicate: #Predicate { $0.source == source && $0.day >= start && $0.day < end }
        )
        for summary in try context.fetch(summaryDescriptor) {
            if summaries[summary.dayKey] == nil { summaries[summary.dayKey] = summary } else { context.delete(summary) }
        }

        let sleepByDay = Dictionary(batch.sleepNights.map { ($0.wakeDay, $0) }, uniquingKeysWith: { first, _ in first })
        let overnightByDay = Dictionary(batch.overnight.map { ($0.wakeDay, $0) }, uniquingKeysWith: { first, _ in first })
        let standByDay = Dictionary(batch.standHours.map { ($0.day, $0.value) }, uniquingKeysWith: { first, _ in first })
        let dailyByDay = batch.daily.mapValues { values in
            Dictionary(values.map { ($0.day, $0.value) }, uniquingKeysWith: { first, _ in first })
        }

        func update<Value>(_ new: Value?, keeping old: Value?) -> Value? { merging ? new ?? old : new }

        var day = start
        while day < end {
            let key = DayKey.make(day, calendar: calendar)
            let metrics = dailyByDay.mapValues { $0[day] ?? nil }
            let stand = standByDay[day] ?? nil
            let sleep = sleepByDay[day]
            let overnight = overnightByDay[day]
            let hasData = metrics.values.contains { $0 != nil } || stand != nil || sleep != nil || overnight != nil

            if let summary = summaries[key] ?? (hasData ? DaySummary(day: day, dayKey: key, source: source) : nil) {
                if summaries[key] == nil { context.insert(summary) }
                for (metric, value) in metrics { summary.setValue(update(value, keeping: summary.value(for: metric)), for: metric) }
                summary.standHours = update(stand, keeping: summary.standHours)
                if sleep != nil || !merging { summary.setSleep(sleep) }
                summary.overnightHRV = update(overnight?.hrv, keeping: summary.overnightHRV)
                summary.sleepingHeartRate = update(overnight?.heartRate, keeping: summary.sleepingHeartRate)
                summary.bedtime = update(overnight?.bedtime, keeping: summary.bedtime)
                summary.wakeTime = update(overnight?.wakeTime, keeping: summary.wakeTime)
                let origins: [String: [String]] = batch.origins.reduce(into: [:]) { origins, entry in
                    if let names = entry.value[day], !names.isEmpty { origins[entry.key.rawValue] = names }
                }
                summary.origins = merging ? summary.origins.merging(origins) { Array(Set($0 + $1)).sorted() } : origins
                summary.updatedAt = .now
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }

        let fetched = Dictionary(batch.workouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kept = Set<String>()
        let workoutDescriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.source == source && $0.start >= start && $0.start < end }
        )
        for record in try context.fetch(workoutDescriptor) {
            if let workout = fetched[record.healthID] {
                if kept.insert(record.healthID).inserted { record.origin = workout.origin } else { context.delete(record) }
            } else if !merging {
                context.delete(record)
            }
        }
        for var workout in fetched.values where !kept.contains(workout.id) {
            workout.source = source
            context.insert(WorkoutRecord(workout))
        }

        try context.save()
        revision += 1
    }
}
