import Foundation
import Observation
import os
import SwiftData

/// Raw data from one source for a range of days, ready to save.
nonisolated struct HealthBatch {
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
    @ObservationIgnored private let fitFiles: FITFileSource
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let writer: HealthStoreWriter
    @ObservationIgnored private let calendar = Calendar.current
    @ObservationIgnored private let defaults: UserDefaults
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
    /// v4 keeps which app or device each value came from; v5 adds weight, body fat, lean body mass and height;
    /// v6 adds blood pressure; v7 walking speed, step length, asymmetry and Walking Steadiness.
    private static func importedFromKey(_ source: any HealthSource) -> String { "historyImportedFrom.\(source.id).v7" }
    private static func historyDoneKey(_ source: any HealthSource) -> String { "historyImportDone.\(source.id).v7" }
    /// Re-imported on every refresh: today, plus nights and late-syncing watches from the days before.
    static let recentDays = 3
    /// The day each source's recent days were last imported through, so a refresh after days away also re-imports
    /// the days in between, which may have synced late or never been imported.
    private static func recentImportedKey(_ source: any HealthSource) -> String { "recentImportedThrough.\(source.id)" }
    /// How far back a refresh after a long absence reaches, matching one history chunk.
    static let maximumCatchUpDays = 366

    /// What cards read live, in merge order: the importing `sources`, then FIT files.
    var liveSources: [any LiveHealthSource] { sources + [fitFiles] }

    init(sources: [any HealthSource], fitFiles: FITFileSource, container: ModelContainer, defaults: UserDefaults = .standard) {
        self.sources = sources
        self.defaults = defaults
        self.fitFiles = fitFiles
        self.container = container
        writer = HealthStoreWriter(modelContainer: container)
    }

    private var availableSources: [any HealthSource] { sources.filter(\.isAvailable) }

    func authorize() async {
        if authorization == nil {
            authorization = Task {
                var failed = false
                for source in availableSources {
                    do { try await source.requestAuthorization() }
                    catch {
                        failed = true
                        logger.error("Authorization for \(source.id) failed: \(error.localizedDescription)")
                    }
                }
                // Lets the next call ask again: the Apple Health sheet times out if left unanswered (#128).
                if failed { authorization = nil }
            }
        }
        await authorization?.value
    }

    /// Imports everything each source has, a year at a time, newest first so recent cards fill in quickly.
    func importHistoryIfNeeded() async {
        // Checked after authorizing, so overlapping calls can't both pass the guard while it waits.
        await authorize()
        let pending = availableSources.filter { !defaults.bool(forKey: Self.historyDoneKey($0)) }
        guard !pending.isEmpty, historyProgress == nil else { return }
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
            let today = calendar.startOfDay(for: .now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            // The recent days are left to `importRecent`: a year-long read can take minutes, and saving it would
            // overwrite anything newer a refresh saved for those days meanwhile.
            let recentStart = calendar.date(byAdding: .day, value: -(Self.recentDays - 1), to: today)!
            // Nothing readable also means access was denied or not yet granted, so it's asked again next launch rather
            // than marked done; otherwise allowing access later in Settings would never bring in the history.
            guard let earliestSample = try await source.earliestSampleDate() else { return }
            let earliest = calendar.startOfDay(for: earliestSample)
            var end = (defaults.object(forKey: Self.importedFromKey(source)) as? Date) ?? recentStart
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
        let recentStart = calendar.date(byAdding: .day, value: -(Self.recentDays - 1), to: today)!
        let earliestCatchUp = calendar.date(byAdding: .day, value: -(Self.maximumCatchUpDays - 1), to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        for source in availableSources {
            if let last = lastRecentImport[source.id], Date.now.timeIntervalSince(last) < source.refreshInterval { continue }
            let lastDay = (defaults.object(forKey: Self.recentImportedKey(source)) as? Date).map { calendar.startOfDay(for: $0) }
            let start = max(earliestCatchUp, min(recentStart, lastDay ?? recentStart))
            do {
                try await importDays(DateInterval(start: start, end: end), from: source)
                lastRecentImport[source.id] = .now
                defaults.set(today, forKey: Self.recentImportedKey(source))
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
        defaults.removeObject(forKey: Self.recentImportedKey(source))
        lastRecentImport[source.id] = nil
    }

#if DEBUG && targetEnvironment(simulator)
    /// Throws away imported data and imports the whole history again, after seeding sample data.
    func reimportHistory() async {
        do {
            let context = ModelContext(container)
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
        try await save(batch, from: source.id)
    }

    /// Reads FIT files the user picked, and adds what they hold to what earlier imports saved.
    func importFiles(_ urls: [URL]) async throws -> FITImport {
        let files = try await fitFiles.read(urls)
        if let batch = files.batch(calendar: calendar) { try await save(batch, from: FITImport.sourceID, merging: true) }
        return files
    }

    /// Saves one source's batch on the background `writer`, then bumps `revision` so screens reload.
    func save(_ batch: HealthBatch, from source: String, merging: Bool = false) async throws {
        let calendar = calendar
        try await withWriter { try await $0.save(batch, from: source, merging: merging, calendar: calendar) }
        revision += 1
    }

    /// Calls the writer from off the main actor. A `@ModelActor` called from the main thread runs there, not on
    /// its own queue, so the hop has to come first.
    @concurrent func withWriter<T>(_ work: (HealthStoreWriter) async throws -> T) async rethrows -> T {
        try await work(writer)
    }
}
