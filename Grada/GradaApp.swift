import os
import SwiftData
import SwiftUI
import UserNotifications

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
        // Set before launch finishes, so a tap that launched the app still reaches it.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
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

    /// See `ModelStores`. If the stores on disk can't be opened, the app still launches with an in-memory store
    /// rather than crashing on every launch (#124).
    private static func makeModelContainer() -> ModelContainer {
        do {
            if !isTestHost { return try ModelStores.makeContainer() }
        } catch {
            Logger(subsystem: "Grada", category: "Storage").fault("Stores unavailable, using memory: \(error.localizedDescription)")
        }
        do {
            return try ModelStores.makeInMemoryContainer()
        } catch {
            preconditionFailure("SwiftData can't create an in-memory store: \(error)")
        }
    }

    /// Unit tests run inside the app. Skipping iCloud and HealthKit setup there keeps CI from
    /// stalling on the main actor for minutes before the tests can start.
    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func makeModels(context: ModelContext) -> (HomeModel, CalendarModel, HealthDataSource) {
#if DEBUG
        if isTestHost || ProcessInfo.processInfo.arguments.contains("-SampleData") {
            let source = SampleDataSource()
            return (HomeModel(source: source), CalendarModel(source: source), source)
        }
#endif
        let reader = HealthKitReader()
        // Apple Health first: Garmin direct fills what its Apple Health sync leaves out, such as overnight HRV.
        let importer = HealthImporter(sources: [reader, GarminSource(), FITFileSource()], context: context)
        // Started here, not from a view: iOS may relaunch the app in the background with no UI.
        Task { await importer.startBackgroundUpdates() }
        let source = StoredHealthData(context: context, sources: importer.sources)
        let notifier = ReportNotifier(source: source, context: context)
        importer.onRecentImport = { await notifier.update() }
        return (HomeModel(source: source, importer: importer), CalendarModel(source: source, importer: importer), source)
    }
}

struct RootView: View {
    @AppStorage(SettingsKey.appearance) private var appearance: Appearance = .system
    @AppStorage(SettingsKey.calendarMetric) private var calendarMetric: CalendarMetric = .health
    @Environment(HomeModel.self) private var homeModel
    @Query private var goalChanges: [GoalChange]
    @State private var tab = Tab.home
    /// Goal setup waits until the Apple Health permission screen is answered.
    @State private var isAuthorized = false

    private enum Tab { case home, calendar, journal, settings }

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)
            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)
            JournalView()
                .tabItem { Label("Journal", systemImage: "book") }
                .tag(Tab.journal)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // Initial too: a tap that launched the app can arrive before this view first draws.
        .onChange(of: NotificationRouter.shared.journalRequests, initial: true) { _, requests in
            if requests > 0 { tab = .journal }
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
