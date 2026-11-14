import os
import SwiftData
import SwiftUI

@main
struct DailyHealthApp: App {
    @State private var homeModel = HomeModel(source: Self.makeDataSource())
    private let modelContainer = Self.makeModelContainer()

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
    /// `iCloud.com.GitHub.TokenCemetery.DailyHealth`, and Background Modes › Remote notifications.
    ///
    /// Falls back to a local-only store so the app still works if iCloud can't be set up.
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([HomeCard.self])
        do {
            let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            Logger(subsystem: "DailyHealth", category: "Storage")
                .error("iCloud store unavailable, using local store: \(error.localizedDescription)")
            do {
                let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
                return try ModelContainer(for: schema, configurations: configuration)
            } catch {
                fatalError("Could not create the local store: \(error)")
            }
        }
    }

    private static func makeDataSource() -> HealthDataSource {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SampleData") { return SampleDataSource() }
#endif
        return HealthKitDataSource()
    }
}

struct RootView: View {
    @AppStorage("appearance") private var appearance: Appearance = .system

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
    }
}
