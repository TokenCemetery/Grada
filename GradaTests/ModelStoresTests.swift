import Foundation
import SwiftData
import Testing
@testable import Grada

@MainActor
struct ModelStoresTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ModelStoresTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Before #111 every model shared one file. Its app data moves to the app store, and health data stays put.
    @Test func movesAppDataOutOfTheSharedStore() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let legacy = try ModelContainer(for: ModelStores.schema,
                                            configurations: ModelConfiguration(url: directory.appending(path: "default.store"),
                                                                               cloudKitDatabase: .none))
            let context = legacy.mainContext
            context.insert(HomeCard(CardID(kind: .steps), position: 2))
            context.insert(GoalChange(GoalEntry(metric: .steps, value: 9_000, effectiveFrom: day, reason: .edit)))
            context.insert(JournalEntry(day: day, tag: .alcohol, amount: 2))
            context.insert(DaySummary(day: day, dayKey: "2023-11-14", source: "garmin"))
            try context.save()
        }

        let container = try ModelStores.makeContainer(in: directory)
        let context = container.mainContext
        #expect(try context.fetch(FetchDescriptor<HomeCard>()).map(\.kind) == [.steps])
        #expect(try context.fetch(FetchDescriptor<GoalChange>()).map(\.value) == [9_000])
        #expect(try context.fetch(FetchDescriptor<JournalEntry>()).map(\.tag) == [.alcohol])
        #expect(try context.fetch(FetchDescriptor<DaySummary>()).map(\.source) == ["garmin"])
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "App.store").path))
    }

    /// A launch that copied the shared store but quit before saving the move moves the data on the next launch,
    /// even though the app store file now exists (#145).
    @Test func interruptedMoveFinishesOnTheNextLaunch() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let copy = try ModelContainer(for: ModelStores.schema,
                                          configurations: ModelConfiguration(url: directory.appending(path: "AppMigration.store"),
                                                                             cloudKitDatabase: .none))
            copy.mainContext.insert(HomeCard(CardID(kind: .steps), position: 0))
            try copy.mainContext.save()
            _ = try ModelContainer(for: HomeCard.self, configurations: ModelConfiguration(url: directory.appending(path: "App.store"),
                                                                                          cloudKitDatabase: .none))
        }

        let container = try ModelStores.makeContainer(in: directory)
        #expect(try container.mainContext.fetch(FetchDescriptor<HomeCard>()).map(\.kind) == [.steps])
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "AppMigration.store").path))
    }

    /// Health models go only to the store that never syncs (5.1.3).
    @Test func healthModelsStayInTheLocalStore() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelStores.makeContainer(in: directory)
        let local = container.configurations.first { $0.name == "Health" }
        let synced = container.configurations.first { $0.name == "App" }
        #expect(local?.cloudKitContainerIdentifier == nil)
        #expect(Set(local?.schema?.entities.map(\.name) ?? []) == ["DaySummary", "WorkoutRecord"])
        #expect(Set(synced?.schema?.entities.map(\.name) ?? []) == ["HomeCard", "GoalChange", "JournalEntry"])
    }

    /// Opening again neither copies app data twice nor loses it.
    @Test func secondLaunchKeepsAppDataOnce() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let container = try ModelStores.makeContainer(in: directory)
            container.mainContext.insert(JournalEntry(day: .now, tag: .caffeine, amount: nil))
            try container.mainContext.save()
        }
        let container = try ModelStores.makeContainer(in: directory)
        #expect(try container.mainContext.fetch(FetchDescriptor<JournalEntry>()).count == 1)
    }
}
