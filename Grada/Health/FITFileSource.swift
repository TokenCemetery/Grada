import Foundation
import os

/// FIT files the user picks in Settings › Import › FIT Files. Their daily values and workouts are stored with every
/// other source's; each night's sleep stage timeline is kept in a file on this device, so cards that read sleep
/// periods, such as Sleep Score, see the stages (#96). Not a `HealthSource`: the files aren't kept, so there's nothing
/// to import again on a schedule, and a scheduled import's empty batch would clear the days they filled. Files arrive
/// through `read(_:)` only, and `HealthImporter` is handed this source separately (#122).
final class FITFileSource: LiveHealthSource {
    var id: String { FITImport.sourceID }

    private let timelineURL: URL
    private let calendar: Calendar
    /// Loaded from `timelineURL` on first use.
    private var timeline: [SleepPeriod]?
    private let logger = Logger(subsystem: "Grada", category: "FITFileSource")

    static let defaultTimelineURL = URL.applicationSupportDirectory.appending(path: "FIT sleep stages.json")

    init(timelineURL: URL = defaultTimelineURL, calendar: Calendar = .current) {
        self.timelineURL = timelineURL
        self.calendar = calendar
    }

    /// Reads the FIT files in `urls` and keeps their nights' stage timelines, replacing what earlier files had for
    /// the same nights.
    func read(_ urls: [URL]) async throws -> FITImport {
        let files = await FITImport.read(urls, calendar: calendar)
        guard !files.sleepPeriods.isEmpty else { return files }
        let nights = Set(files.sleepPeriods.map(wakeDay))
        let kept = storedTimeline().filter { !nights.contains(wakeDay($0)) }
        let updated = (kept + files.sleepPeriods).sorted { $0.start < $1.start }
        try FileManager.default.createDirectory(at: timelineURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: timelineURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        timeline = updated
        return files
    }

    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] {
        storedTimeline().filter { $0.start < interval.end && $0.end > interval.start }
    }

    /// An unreadable file counts as empty, so the next import replaces it instead of every import and sleep read failing.
    private func storedTimeline() -> [SleepPeriod] {
        if let timeline { return timeline }
        var loaded: [SleepPeriod] = []
        if FileManager.default.fileExists(atPath: timelineURL.path) {
            do {
                loaded = try JSONDecoder().decode([SleepPeriod].self, from: Data(contentsOf: timelineURL))
            } catch {
                logger.error("FIT sleep stages unreadable, starting over: \(error.localizedDescription)")
            }
        }
        timeline = loaded
        return loaded
    }

    private func wakeDay(_ period: SleepPeriod) -> Date { SleepNight.wakeDay(forEnd: period.end, calendar: calendar) }
}
