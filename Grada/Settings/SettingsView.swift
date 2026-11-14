import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Nil follows the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("colorBlindPalette") private var colorBlind = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section {
                    Toggle("Color-blind palette", isOn: $colorBlind)
                } footer: {
                    Text("Calendar days use blue, orange and dark instead of green, yellow and red.")
                }
                ProfileSection()
                Section {
                    Button("Open Health app") {
                        if let url = URL(string: "x-apple-health://") { openURL(url) }
                    }
                } header: {
                    Text("Data source")
                } footer: {
                    Text("Grada reads from Apple Health. To include Garmin, Oura or other devices, turn on Apple Health sync in their apps. Manage what Grada can read in Health › Sharing › Apps.")
                }
#if DEBUG && targetEnvironment(simulator)
                SimulatorDataSection()
#endif
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// Read-only: these values come from Apple Health and are changed there.
private struct ProfileSection: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var profile: HealthProfile?

    var body: some View {
        Section {
            LabeledContent("Age", value: profile.map { $0.age.map { "\($0)" } ?? "Not available" } ?? "…")
            LabeledContent("Max heart rate") {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(profile?.maxHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "–")
                    if let source = profile?.maxHeartRateSource {
                        Text(source == .age ? "220 − age" : "Highest recorded").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Resting heart rate") {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(profile?.restingHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "–")
                    if profile?.restingHeartRate != nil {
                        Text("7-day average").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Sleep need", value: SnapshotBuilder.hoursMinutes(SleepNeed.baseline))
        } header: {
            Text("Profile")
        } footer: {
            if profile != nil, profile?.age == nil {
                Text("Grada can't read your birth date. Add it in Health › your picture › Health Details, then allow Grada to read Date of Birth in Health › Sharing › Apps › Grada.")
            } else {
                Text("Used for Resources, Health age and Sleep need. Read from Apple Health; change them there.")
            }
        }
        // Re-read when coming back from the Health app, where the user may have just changed them.
        .task(id: scenePhase) {
            if scenePhase == .active { profile = await model.loadProfile() }
        }
    }
}

#Preview {
    SettingsView()
        .environment(HomeModel(source: SampleDataSource()))
}

#if DEBUG && targetEnvironment(simulator)
/// Fills the simulator's Apple Health with sample data. Not in device or release builds.
private struct SimulatorDataSection: View {
    @Environment(HomeModel.self) private var model
    @State private var status: String?
    @State private var isWorking = false
    private let seeder = SimulatorHealthSeeder()

    var body: some View {
        Section {
            Button("Add 90 days of sample data") { run { try await seed(days: 90) } }
            Button("Add 2 years of sample data") { run { try await seed(days: 730) } }
            Button("Add 3 years of sample data") { run { try await seed(days: 1_095) } }
            Button("Remove sample data", role: .destructive) {
                run {
                    status = "Removing…"
                    try await seeder.removeSampleData()
                    await reimport()
                }
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Simulator test data")
        } footer: {
            Text("Writes to the simulator's Apple Health, then imports it again. Only in simulator test builds. Tapping Add twice adds the data twice.")
        }
        .disabled(isWorking)
    }

    private func seed(days: Int) async throws {
        let clock = ContinuousClock()
        let seeding = try await clock.measure {
            try await seeder.seed(days: days) { status = "Adding sample data… \(Int($0 * 100))%" }
        }
        await reimport(after: "Added in \(Self.seconds(seeding)).")
    }

    /// Times the full history import, the same work a new user's first launch does.
    private func reimport(after previousStep: String? = nil) async {
        status = "Importing…"
        let importing = await ContinuousClock().measure {
            await model.importer?.reimportHistory()
        }
        status = ["Done.", previousStep, "Imported in \(Self.seconds(importing))."]
            .compactMap { $0 }.joined(separator: " ")
    }

    private static func seconds(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return "\(seconds.formatted(.number.precision(.fractionLength(1)))) s"
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            do { try await work() } catch { status = error.localizedDescription }
            isWorking = false
        }
    }
}
#endif
