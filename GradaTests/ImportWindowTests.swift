import Foundation
import SwiftData
import Testing
@testable import Grada

@MainActor
struct ImportWindowTests {
    private let calendar = Calendar.current
    private let container: ModelContainer
    private let defaults: UserDefaults
    private let source = ImportSource()
    private let importer: HealthImporter

    init() throws {
        container = try ModelStores.makeInMemoryContainer()
        let suite = "HealthImporterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        importer = HealthImporter(sources: [source], fitFiles: FITFileSource(timelineURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")), container: container, defaults: defaults)
    }

    private var today: Date { calendar.startOfDay(for: .now) }
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
    private func month(_ offset: Int) -> Date {
        calendar.date(byAdding: .month, value: offset, to: calendar.dateInterval(of: .month, for: .now)!.start)!
    }

    /// Apple Health reads nothing while access is denied, so history must import once access is allowed (#141).
    @Test func historyImportsOnceDataBecomesReadable() async {
        await importer.importHistoryIfNeeded()
        #expect(source.batches.isEmpty)

        source.earliest = day(-10)
        await importer.importHistoryIfNeeded()
        #expect(source.batches.first?.start == day(-10))
        // Recent days belong to the refresh, so a slow history read can't overwrite newer data for them (#143).
        #expect(source.batches.first?.end == day(-(HealthImporter.recentDays - 1)))
    }

    /// Days between the last refresh and the recent window are re-imported too, as they may have synced late (#142).
    @Test func refreshReachesBackToTheLastImportedDay() async {
        await importer.importRecent()
        #expect(source.batches.last?.start == day(-(HealthImporter.recentDays - 1)))

        defaults.set(day(-10), forKey: "recentImportedThrough.\(source.id)")
        await importer.importRecent()
        #expect(source.batches.last?.start == day(-10))
        #expect(defaults.object(forKey: "recentImportedThrough.\(source.id)") as? Date == today)
    }

    /// Past months that fill in after the history import, e.g. from a slow iCloud sync, are imported again once a
    /// day's check sees their totals change; unchanged months and the current month aren't (#191).
    @Test func monthsThatFillInLaterAreImportedAgain() async throws {
        source.earliest = month(-3)
        source.totals = [month(-3): ["steps": 100], month(-2): ["steps": 200]]
        await importer.importHistoryIfNeeded()
        let afterHistory = source.batches.count
        await importer.importRecent()
        // The history import saved each month's totals, so the first check only imports the recent days.
        #expect(source.batches.count == afterHistory + 1)

        source.totals[month(-2)] = ["steps": 5_000]
        source.totals[month(-1)] = ["steps": 300]
        source.totals[month(0)] = ["steps": 9]
        await importer.importRecent()
        // Checked once a day.
        #expect(source.batches.count == afterHistory + 2)

        try await importer.reimportChangedMonths(of: source)
        #expect(source.batches.last == DateInterval(start: month(-2), end: month(0)))
        let afterCheck = source.batches.count
        try await importer.reimportChangedMonths(of: source)
        #expect(source.batches.count == afterCheck)
    }

    /// Installs whose history imported before the check have no saved totals, so their past months import once more,
    /// a year at most per read (#191).
    @Test func monthsWithoutSavedTotalsImportOnce() async throws {
        defaults.set(true, forKey: "historyImportDone.\(source.id).v7")
        source.totals = Dictionary(uniqueKeysWithValues: (1...13).map { (month(-$0), ["steps": Double($0)]) })
        try await importer.reimportChangedMonths(of: source)
        #expect(source.batches == [DateInterval(start: month(-12), end: month(0)), DateInterval(start: month(-13), end: month(-12))])

        try await importer.reimportChangedMonths(of: source)
        #expect(source.batches.count == 2)
    }

    @Test func totalsDifferingOnlyByRoundingAreTheSame() {
        #expect(HealthImporter.sameTotals(["steps": 1_000_000], ["steps": 1_000_000.000_001]))
        #expect(!HealthImporter.sameTotals(["steps": 1_000], ["steps": 1_001]))
        #expect(!HealthImporter.sameTotals(["steps": 1_000], ["steps": 1_000, "hrv": 40]))
    }

    /// At launch there's no window for a permission sheet, so background updates wait until the app asked on
    /// screen (#177).
    @Test func backgroundUpdatesWaitForThePermissionSheet() async {
        source.needsSheet = true
        await importer.startBackgroundUpdates()
        #expect(source.authorizations == 0)
        #expect(!source.observing)

        source.needsSheet = false
        await importer.startBackgroundUpdates()
        #expect(source.authorizations == 1)
        #expect(source.observing)
    }
}

private final class ImportSource: HealthSource {
    let id = "importTest"
    var earliest: Date?
    var totals: [Date: [String: Double]] = [:]
    var needsSheet = false
    private(set) var batches: [DateInterval] = []
    private(set) var authorizations = 0
    private(set) var observing = false
    var name: String { id }
    var isAvailable: Bool { true }
    func requestAuthorization() async throws { authorizations += 1 }
    func needsAuthorizationSheet() async -> Bool { needsSheet }
    func observeChanges(_ onChange: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws {
        observing = true
    }
    func earliestSampleDate() async throws -> Date? { earliest }
    func monthlyTotals(before end: Date) async throws -> [Date: [String: Double]] { totals.filter { $0.key < end } }
    func batch(for days: DateInterval) async throws -> HealthBatch {
        batches.append(days)
        return HealthBatch(days: days)
    }
}
