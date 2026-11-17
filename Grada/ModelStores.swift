import Foundation
import os
import SwiftData

/// The app's SwiftData stores. App data (home layout, goals, journal) may sync through the user's private
/// iCloud database; health data never does, because App Review 5.1.3 forbids keeping personal health
/// information in iCloud (#111).
///
/// The app store uses `.automatic`, which syncs with the iCloud container from the app's entitlements and
/// stays local-only without one. iCloud is off for now: personal (free) teams can't sign the iCloud capability.
/// To turn it on with a paid team, add in Signing & Capabilities: iCloud › CloudKit with container
/// `iCloud.com.GitHub.TokenCemetery.Grada`, and Background Modes › Remote notifications (#20).
enum ModelStores {
    static let appModels: [any PersistentModel.Type] = [HomeCard.self, GoalChange.self, JournalEntry.self]
    static let healthModels: [any PersistentModel.Type] = [DaySummary.self, WorkoutRecord.self]
    static var schema: Schema { Schema(appModels + healthModels) }

    private static let logger = Logger(subsystem: "Grada", category: "Storage")

    /// Health data stays in the file every model used to share, so imported Garmin and FIT days are kept;
    /// app data moves out of it into its own file the first time, before the shared file drops its tables.
    static func makeContainer(in directory: URL = .applicationSupportDirectory) throws -> ModelContainer {
        let healthURL = directory.appending(path: "default.store")
        let appURL = directory.appending(path: "App.store")
        // Read before either store opens: opening the health store drops the app tables from the shared file.
        let moved = FileManager.default.fileExists(atPath: appURL.path) ? nil : try legacyAppData(at: healthURL)

        func open(cloudKit: Bool) throws -> ModelContainer {
            let app = ModelConfiguration("App", schema: Schema(appModels), url: appURL,
                                         cloudKitDatabase: cloudKit ? .automatic : .none)
            let health = ModelConfiguration("Health", schema: Schema(healthModels), url: healthURL, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: app, health)
        }
        let container: ModelContainer
        do {
            container = try open(cloudKit: true)
        } catch {
            logger.error("iCloud store unavailable, using local store: \(error.localizedDescription)")
            container = try open(cloudKit: false)
        }
        if let moved {
            moved.insert(into: container.mainContext)
            try container.mainContext.save()
        }
        return container
    }

    /// In memory, for tests and for a launch whose store can't be opened.
    static func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// App data from the store all models shared before #111, copied out so it survives the move.
    private static func legacyAppData(at url: URL) throws -> LegacyAppData? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let legacy = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let data = try LegacyAppData(legacy.mainContext)
        logger.info("Moving \(data.count) app records to their own store")
        return data
    }
}

/// Plain copies of app models, so they outlive the container they were read from.
private struct LegacyAppData {
    var cards: [(kind: String, position: Int, variant: String)]
    var goals: [(metric: String, value: Double, effectiveFrom: Date, reason: String)]
    var journal: [(dayKey: String, day: Date, tag: String, amount: Double?, updatedAt: Date)]

    var count: Int { cards.count + goals.count + journal.count }

    init(_ context: ModelContext) throws {
        cards = try context.fetch(FetchDescriptor<HomeCard>()).map { ($0.kindRawValue, $0.position, $0.variantRawValue) }
        goals = try context.fetch(FetchDescriptor<GoalChange>())
            .map { ($0.metricRawValue, $0.value, $0.effectiveFrom, $0.reasonRawValue) }
        journal = try context.fetch(FetchDescriptor<JournalEntry>())
            .map { ($0.dayKey, $0.day, $0.tagRawValue, $0.amount, $0.updatedAt) }
    }

    func insert(into context: ModelContext) {
        for card in cards {
            context.insert(HomeCard(kindRawValue: card.kind, position: card.position, variantRawValue: card.variant))
        }
        for goal in goals {
            context.insert(GoalChange(metricRawValue: goal.metric, value: goal.value, effectiveFrom: goal.effectiveFrom,
                                      reasonRawValue: goal.reason))
        }
        for entry in journal {
            let model = JournalEntry(dayKey: entry.dayKey, day: entry.day, tagRawValue: entry.tag, amount: entry.amount)
            model.updatedAt = entry.updatedAt
            context.insert(model)
        }
    }
}
