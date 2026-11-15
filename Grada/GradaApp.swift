import os
import SwiftData
import SwiftUI

@main
struct GradaApp: App {
    private let modelContainer: ModelContainer
    @State private var homeModel: HomeModel
    @State private var calendarModel: CalendarModel
    private let healthSource: HealthDataSource

    init() {
        let container = Self.makeModelContainer()
        modelContainer = container
        let (home, calendar, source) = Self.makeModels(context: container.mainContext)
        _homeModel = State(initialValue: home)
        _calendarModel = State(initialValue: calendar)
        healthSource = source
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(homeModel)
                .environment(calendarModel)
                .environment(\.healthSource, healthSource)
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
        let schema = Schema([HomeCard.self, DaySummary.self, WorkoutRecord.self, GoalChange.self])
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

    private static func makeModels(context: ModelContext) -> (HomeModel, CalendarModel, HealthDataSource) {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SampleData") {
            let source = SampleDataSource()
            return (HomeModel(source: source), CalendarModel(source: source), source)
        }
#endif
        let reader = HealthKitReader()
        let importer = HealthImporter(reader: reader, context: context)
        // Started here, not from a view: iOS may relaunch the app in the background with no UI.
        Task { await importer.startBackgroundUpdates() }
        let source = StoredHealthData(context: context, reader: reader)
        return (HomeModel(source: source, importer: importer), CalendarModel(source: source, importer: importer), source)
    }
}

struct RootView: View {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("calendarMetric") private var calendarMetric: CalendarMetric = .healthStatus
    @Environment(HomeModel.self) private var homeModel
    @Query private var goalChanges: [GoalChange]
    @State private var tab = Tab.home
    /// Goal setup waits until the Apple Health permission screen is answered.
    @State private var isAuthorized = false

    private enum Tab { case home, calendar, settings }

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)
            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .environment(\.openCalendar, OpenCalendarAction { metric in
            if let metric { calendarMetric = metric }
            tab = .calendar
        })
        .preferredColorScheme(appearance.colorScheme)
        .sheet(isPresented: Binding(get: { isAuthorized && goalChanges.isEmpty }, set: { _ in })) {
            GoalSetupView()
        }
        .task {
            await homeModel.importer?.authorize()
            isAuthorized = true
            await homeModel.importer?.importHistoryIfNeeded()
        }
    }
}
