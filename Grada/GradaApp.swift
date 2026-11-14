import os
import SwiftData
import SwiftUI

@main
struct GradaApp: App {
    private let modelContainer: ModelContainer
    @State private var homeModel: HomeModel

    init() {
        let container = Self.makeModelContainer()
        modelContainer = container
        _homeModel = State(initialValue: Self.makeHomeModel(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(homeModel)
        }
        .modelContainer(modelContainer)
    }

    /// App data lives in the user's private iCloud database and syncs across their devices.
    ///
    /// `.automatic` syncs with the iCloud container from the app's entitlements and stays local-only
    /// without one. iCloud is off for now: personal (free) teams can't sign the iCloud capability.
    /// To turn it on with a paid team, add in Signing & Capabilities: iCloud › CloudKit with container
    /// `iCloud.com.GitHub.TokenCemetery.Grada`, and Background Modes › Remote notifications.
    ///
    /// Falls back to a local-only store so the app still works if iCloud can't be set up.
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([HomeCard.self, DaySummary.self, WorkoutRecord.self])
        do {
            let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            Logger(subsystem: "Grada", category: "Storage")
                .error("iCloud store unavailable, using local store: \(error.localizedDescription)")
            do {
                let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
                return try ModelContainer(for: schema, configurations: configuration)
            } catch {
                fatalError("Could not create the local store: \(error)")
            }
        }
    }

    private static func makeHomeModel(context: ModelContext) -> HomeModel {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SampleData") { return HomeModel(source: SampleDataSource()) }
#endif
        let importer = HealthImporter(reader: HealthKitReader(), context: context)
        // Started here, not from a view: iOS may relaunch the app in the background with no UI.
        Task { await importer.startBackgroundUpdates() }
        return HomeModel(source: StoredHealthData(context: context), importer: importer)
    }
}

struct RootView: View {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Environment(HomeModel.self) private var homeModel

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .preferredColorScheme(appearance.colorScheme)
        .task { await homeModel.importer?.importHistoryIfNeeded() }
    }
}
