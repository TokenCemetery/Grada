import SwiftUI
import UniformTypeIdentifiers

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System", comment: "Appearance option that follows the device setting")
        case .light: String(localized: "Light", comment: "Appearance option: light mode")
        case .dark: String(localized: "Dark", comment: "Appearance option: dark mode")
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

/// App Review 1.4.1 asks health apps to remind people to see a doctor before making medical decisions (#107).
enum MedicalNotice {
    static let text = String(localized: "Grada isn't a medical device and doesn't diagnose, treat or prevent any condition. Talk to a doctor before making medical decisions.")
}

/// Every group is a row that opens its own screen, like iOS Settings.
struct SettingsView: View {
    /// The same URL as the privacy policy in App Store Connect (#108).
    static let privacyPolicy = URL(string: "https://github.com/TokenCemetery/Grada/blob/main/PRIVACY.md")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { ProfileView() } label: { SettingsRow("Profile", icon: "person.fill", color: .blue) }
                    NavigationLink { GoalsView() } label: { SettingsRow("Goals", icon: "target", color: .green) }
                    NavigationLink { ThemeView() } label: { SettingsRow("Theme", icon: "paintpalette.fill", color: .indigo) }
                    NavigationLink { AccessibilityView() } label: { SettingsRow("Accessibility", icon: "accessibility", color: .cyan) }
                    NavigationLink { DataSourceView() } label: { SettingsRow("Data Source", icon: "heart.fill", color: .pink) }
                    NavigationLink { ImportView() } label: { SettingsRow("Import", icon: "square.and.arrow.down.fill", color: .orange) }
#if DEBUG && targetEnvironment(simulator)
                    NavigationLink { SimulatorDataView() } label: { SettingsRow("Simulator Data", icon: "hammer.fill", color: .gray) }
#endif
                }
                Section {
                    Link(destination: Self.privacyPolicy) { SettingsRow("Privacy Policy", icon: "hand.raised.fill", color: .blue) }
                        .foregroundStyle(.primary)
                } footer: {
                    VStack(spacing: 16) {
                        Text(MedicalNotice.text)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// White symbol on a colored tile, like the iOS Settings app.
private struct SettingsRow: View {
    let title: LocalizedStringKey
    let icon: String
    let color: Color

    init(_ title: LocalizedStringKey, icon: String, color: Color) {
        self.title = title
        self.icon = icon
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct ThemeView: View {
    @AppStorage(SettingsKey.appearance) private var appearance: Appearance = .system

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .navigationTitle("Theme")
    }
}

private struct AccessibilityView: View {
    @AppStorage(SettingsKey.colorBlindPalette) private var colorBlind = false

    var body: some View {
        Form {
            Section {
                Toggle("Color-Blind Palette", isOn: $colorBlind)
            } footer: {
                Text("Ratings on cards, widgets and Calendar days use blue, orange and dark instead of green, yellow and red.")
            }
        }
        .navigationTitle("Accessibility")
        .onChange(of: colorBlind) { WidgetPublisher.setColorBlind(colorBlind) }
    }
}

/// Each kind of data Grada reads, and the apps and devices it came from, like Health's Data Sources & Access.
private struct DataSourceView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.healthSource) private var source
    @State private var origins: [DataKind: [DataOrigin]]?

    var body: some View {
        Form {
            Section {
                Button("Open Health App") {
                    if let url = URL(string: "x-apple-health://") { openURL(url) }
                }
            } footer: {
                Text("Grada reads from Apple Health. To include Garmin, Oura or other devices, turn on Apple Health sync in their apps, import their FIT files, or connect Garmin directly, all in Settings › Import. Manage what Grada can read in Health › Sharing › Apps.")
            }
            if let origins {
                ForEach(DataKind.allCases) { kind in
                    Section(kind.title) {
                        if let list = origins[kind] {
                            ForEach(list, id: \.name) { origin in
                                LabeledContent(origin.name, value: OriginsView.lastDay(origin.lastDay))
                            }
                        } else {
                            Text("No data yet").foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Text("Mindful Minutes")
                    Text("Time in Daylight")
                    Text("Alcoholic Beverages")
                    Text("Caffeine")
                } header: {
                    Text("Journal Suggestions")
                } footer: {
                    Text("Read from Apple Health when Journal shows a day, to suggest tags. Grada doesn't store them.")
                }
                Section {
                    Text("Menstrual Flow")
                    Text("Basal Body Temperature")
                    Text("Ovulation Test Result")
                    Text("Cervical Mucus Quality")
                } header: {
                    Text("Cycle")
                } footer: {
                    Text("Read from Apple Health when Calendar or Journal shows a day, and only with Female as your sex in Profile or Apple Health. Grada doesn't store them.")
                }
                Section {} footer: {
                    Text("When several apps record the same readings, Grada uses the one that recorded the most days in the last month, and one app per night for sleep. Apple Health combines totals such as steps by the order set in the Health app's Data Sources & Access.")
                }
            }
        }
        .navigationTitle("Data Source")
        .task { origins = (try? await source.origins()) ?? [:] }
    }
}

/// Ways to bring in data that doesn't reach Apple Health, one row per kind of file.
private struct ImportView: View {
    var body: some View {
        Form {
            NavigationLink { ImportFilesView() } label: { SettingsRow("FIT Files", icon: "applewatch", color: .blue) }
            NavigationLink { GarminConnectView() } label: { SettingsRow("Garmin Connect", icon: "arrow.triangle.2.circlepath", color: .teal) }
        }
        .navigationTitle("Import")
    }
}

/// Imports FIT files from watches whose Apple Health sync leaves data out, such as Garmin's overnight HRV.
private struct ImportFilesView: View {
    @Environment(HomeModel.self) private var model
    @State private var isPicking = false
    @State private var isImporting = false
    @State private var result: FITImport?
    @State private var error: String?

    /// Folders let the user pick an unzipped Garmin export as a whole.
    private static let types: [UTType] = [UTType(filenameExtension: "fit") ?? .data, .folder]

    var body: some View {
        Form {
            Section {
                Button("Choose Files or Folder") { isPicking = true }
                    .disabled(isImporting || model.importer == nil)
                if isImporting {
                    LabeledContent("Reading files…") { ProgressView() }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            } header: {
                Text("Garmin, COROS, Polar and Suunto devices record workouts in FIT files. Import them to bring in data their Apple Health sync leaves out. Files are read on this iPhone and never uploaded, and importing the same files again changes nothing.")
                    .textCase(nil)
            }
            if let result {
                Section {
                    LabeledContent("Workouts", value: "\(result.workouts.count)")
                    LabeledContent("Nights of Sleep", value: "\(result.sleepNights.count)")
                    LabeledContent("Nights with HRV", value: "\(result.overnight.filter { $0.hrv != nil }.count)")
                    LabeledContent("Days with Resting Heart Rate", value: "\(result.restingHeartRate.count)")
                } header: {
                    Text("Last Import")
                } footer: {
                    Text(result.filesRead == 1 ? String(localized: "Read 1 file.") : String(localized: "Read \(result.filesRead) files."))
                }
                if !result.failures.isEmpty {
                    Section("Couldn't Read") {
                        ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                            VStack(alignment: .leading) {
                                Text(failure.file)
                                Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                ForEach(Self.guides, id: \.service) { guide in
                    DisclosureGroup(guide.service) {
                        ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                            Label { Text(step) } icon: { Text("\(index + 1).").monospacedDigit() }
                        }
                    }
                }
            } header: {
                Text("How to Get FIT Files")
            } footer: {
                Text("Exports hold workouts. Sleep, overnight HRV and resting heart rate are read from Garmin watches' own daily FIT files when you have them; Garmin's account export may not include them.")
            }
        }
        .navigationTitle("FIT Files")
        .fileImporter(isPresented: $isPicking, allowedContentTypes: Self.types, allowsMultipleSelection: true) { picked in
            switch picked {
            case .success(let urls) where !urls.isEmpty: importFiles(urls)
            case .success: break
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    /// The services from #85 that export FIT files. Steps from their support pages; Garmin's from third-party guides.
    /// Steps are Markdown, so links open the export pages.
    private static let guides: [(service: String, steps: [LocalizedStringKey])] = [
        ("Garmin", [
            "On [Garmin Connect](https://connect.garmin.com/app/activities), open an activity, click the gear icon and choose Export Original. Garmin Connect on iPhone can't export files.",
            "For your whole history, request an export in [Account › Data Management › Export Your Data](https://www.garmin.com/account/datamanagement/exportdata/). Garmin emails a link, which can take several days.",
            "Unzip the download in the Files app. In a full export, the FIT files are in zip files inside DI_CONNECT › DI-Connect-Uploaded-Files; unzip those too.",
            "Choose the .fit files, or the unzipped folder.",
        ]),
        ("COROS", [
            "For one activity: in the COROS app, open it under Activities, tap ⋯, choose Export Data, then .FIT, and save it to Files.",
            "For your whole history: open [Activity List on COROS Training Hub](https://t.coros.com/admin/views/activities), choose Export Data and pick .FIT. COROS emails the files.",
            "Unzip them in the Files app if they arrive zipped, then choose them here.",
        ]),
        ("Polar", [
            "Open your [Polar Flow diary](https://flow.polar.com/diary) and click a training session.",
            "Open the Export menu and choose FIT file. Sessions export one at a time.",
            "Save the file to Files, then choose it here.",
        ]),
        ("Suunto", [
            "In the Suunto app, open a workout and tap ⋯.",
            "Export it as a FIT file and save it to Files. Workouts export one at a time.",
            "Choose the file here.",
        ]),
    ]

    private func importFiles(_ urls: [URL]) {
        guard let importer = model.importer else { return }
        isImporting = true
        error = nil
        Task {
            do { result = try await importer.importFiles(urls) } catch { self.error = error.localizedDescription }
            isImporting = false
        }
    }
}

/// Values from Apple Health, which are changed there. Birth date and sex it doesn't provide can be entered
/// and saved here instead (#99).
private struct ProfileView: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var profile: HealthProfile?
    /// Which values Apple Health provides; nil until checked.
    @State private var provided: (age: Bool, sex: Bool)?
    @AppStorage(EnteredProfile.birthDateKey) private var savedBirthDate: Double = 0
    @AppStorage(EnteredProfile.sexKey) private var savedSex = ""
    @State private var birthDate = Date.now
    @State private var sex = ""
    /// Whether the user picked a birth date: with none saved, the picker starts at a placeholder that mustn't be
    /// saved as theirs (#169).
    @State private var pickedBirthDate = false
    /// Set once the entries are filled in, so coming back to the app doesn't reset unsaved ones.
    @State private var entriesLoaded = false

    var body: some View {
        Form {
            profileSection
            if let provided, !provided.age || !provided.sex {
                entrySection(provided)
            }
            Section {
                NavigationLink("Sleep Schedule") { SleepScheduleView() }
            } footer: {
                Text("Your bedtime and wake-up, and the morning and evening report notifications.")
            }
        }
        .navigationTitle("Profile")
        // Re-read when coming back from the Health app, where the user may have just changed them.
        .task(id: scenePhase) {
            if scenePhase == .active { await load() }
        }
    }

    private func load() async {
        profile = await model.loadProfile()
        provided = model.sourcesProvideProfile()
        guard !entriesLoaded else { return }
        entriesLoaded = true
        birthDate = savedBirthDate != 0 ? Date(timeIntervalSince1970: savedBirthDate)
            : Calendar.current.date(byAdding: .year, value: -30, to: .now)!
        sex = savedSex
    }

    /// Only the values Apple Health doesn't provide; nothing is kept until Save.
    private func entrySection(_ provided: (age: Bool, sex: Bool)) -> some View {
        let birthDateChanged = !provided.age
            && (savedBirthDate == 0 ? pickedBirthDate : birthDate.timeIntervalSince1970 != savedBirthDate)
        let sexChanged = !provided.sex && sex != savedSex
        return Section {
            if !provided.age {
                DatePicker("Birth Date", selection: Binding { birthDate } set: { birthDate = $0; pickedBirthDate = true },
                           in: ...Date.now, displayedComponents: .date)
            }
            if !provided.sex {
                Picker("Sex", selection: $sex) {
                    Text("Not Set").tag("")
                    Text("Female").tag(BiologicalSex.female.rawValue)
                    Text("Male").tag(BiologicalSex.male.rawValue)
                }
            }
            Button("Save") {
                if birthDateChanged { savedBirthDate = birthDate.timeIntervalSince1970 }
                if sexChanged { savedSex = sex }
                Task { profile = await model.loadProfile() }
            }
            .disabled(!birthDateChanged && !sexChanged)
        } header: {
            Text("Not in Apple Health")
        } footer: {
            Text("Grada can't read these from Apple Health, for example when your data comes from Garmin or FIT files. What you save is used instead and kept on this device.")
        }
    }

    private var profileSection: some View {
        Section {
            LabeledContent("Age", value: profile.map { $0.age.map { "\($0)" } ?? String(localized: "Not available") } ?? "…")
            LabeledContent("Sex", value: profile.map { $0.sex.map { $0 == .female ? String(localized: "Female") : String(localized: "Male") } ?? String(localized: "Not available") } ?? "…")
            LabeledContent("Max Heart Rate") {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(profile?.maxHeartRate.map { String(localized: "\(Int($0.rounded())) bpm") } ?? "–")
                    if let source = profile?.maxHeartRateSource {
                        Text(source == .age ? String(localized: "208 − 0.7 × age") : String(localized: "Highest recorded")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Resting Heart Rate") {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(profile?.restingHeartRate.map { String(localized: "\(Int($0.rounded())) bpm") } ?? "–")
                    if profile?.restingHeartRate != nil {
                        Text("7-day average").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Sleep Need", value: SnapshotBuilder.hoursMinutes(SleepNeed.baseline))
        } footer: {
            if let provided, !provided.age || !provided.sex {
                Text("Used for Resources, Health age and Sleep need. Read from Apple Health where it's allowed: add your birth date and sex in Health › your picture › Health Details, then allow Grada to read them in Health › Sharing › Apps › Grada, or save them below.")
            } else {
                Text("Used for Resources, Health age and Sleep need. Read from Apple Health; change them there.")
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(HomeModel(source: SampleDataSource()))
}

#if DEBUG && targetEnvironment(simulator)
/// Fills the simulator's Apple Health with sample data. Not in device or release builds.
private struct SimulatorDataView: View {
    @Environment(HomeModel.self) private var model
    @State private var status: String?
    @State private var isWorking = false
    private let seeder = SimulatorHealthSeeder()

    var body: some View {
        Form {
            Section {
                Button("Add 90 Days of Sample Data") { run { try await seed(days: 90) } }
                Button("Add 2 Years of Sample Data") { run { try await seed(days: 730) } }
                Button("Add 3 Years of Sample Data") { run { try await seed(days: 1_095) } }
                Button("Remove Sample Data", role: .destructive) {
                    run {
                        status = "Removing…"
                        try await seeder.removeSampleData()
                        await reimport()
                    }
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Writes to the simulator's Apple Health, then imports it again. Only in simulator test builds. Tapping Add twice adds the data twice.")
            }
            .disabled(isWorking)
        }
        .navigationTitle("Simulator Data")
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
