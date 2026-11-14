import SwiftData
import SwiftUI

@main
struct DailyHealthApp: App {
    @State private var homeModel = HomeModel(source: Self.makeDataSource())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(homeModel)
        }
        .modelContainer(for: HomeCard.self)
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
