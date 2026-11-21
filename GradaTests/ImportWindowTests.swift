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

    /// Apple Health reads nothing while access is denied, so history must import once access is allowed (#141).
    @Test func historyImportsOnceDataBecomesReadable() async {
        await importer.importHistoryIfNeeded()
        #expect(source.batches.isEmpty)

        source.earliest = day(-10)
        await importer.importHistoryIfNeeded()
        #expect(source.batches.first?.start == day(-10))
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
}

private final class ImportSource: HealthSource {
    let id = "importTest"
    var earliest: Date?
    private(set) var batches: [DateInterval] = []
    var name: String { id }
    var isAvailable: Bool { true }
    func requestAuthorization() async throws {}
    func earliestSampleDate() async throws -> Date? { earliest }
    func batch(for days: DateInterval) async throws -> HealthBatch {
        batches.append(days)
        return HealthBatch(days: days)
    }
}
