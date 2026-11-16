import SwiftUI

/// Connects Garmin Connect with the user's own Personal API key, for data Garmin's Apple Health sync leaves out.
struct GarminConnectView: View {
    @Environment(HomeModel.self) private var model
    @State private var key = ""
    @State private var progress: String?
    @State private var error: String?

    private var garmin: GarminSource? { model.importer?.sources.lazy.compactMap { $0 as? GarminSource }.first }

    var body: some View {
        Form {
            if let garmin {
                if garmin.isConnected { status(garmin) }
                if !garmin.isConnected || garmin.needsReconnect {
                    keyEntry(garmin)
                    guide
                }
            } else {
                Text("Not available with sample data.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Garmin Connect")
    }

    private func status(_ garmin: GarminSource) -> some View {
        Section {
            LabeledContent("Status", value: garmin.needsReconnect ? "Key Expired or Deleted" : "Connected")
            LabeledContent("Last Sync", value: garmin.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "Not Yet")
            if let progress {
                LabeledContent(progress) { ProgressView() }
            }
            if let lastError = garmin.lastError, !garmin.needsReconnect {
                VStack(alignment: .leading) {
                    Text("Last Sync Failed")
                    Text(lastError).font(.caption).foregroundStyle(.red)
                }
            }
            if !garmin.needsReconnect {
                Button("Sync Now") { sync(garmin) }
                    .disabled(progress != nil)
            }
            Button("Disconnect", role: .destructive) {
                garmin.disconnect()
                model.importer?.sourceDisconnected(garmin)
            }
            .disabled(progress != nil)
        } footer: {
            Text(garmin.needsReconnect
                 ? "Garmin no longer accepts the saved key. Create a new one and paste it below. Data already imported stays."
                 : "Grada checks Garmin for new data at most every 15 minutes, when the app refreshes. Disconnecting deletes the key from this iPhone; data already imported stays.")
        }
    }

    private func keyEntry(_ garmin: GarminSource) -> some View {
        Section {
            SecureField("Personal API Key", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(garmin.needsReconnect ? "Save New Key" : "Connect") { connect(garmin) }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || progress != nil)
            if let progress, !garmin.isConnected {
                LabeledContent(progress) { ProgressView() }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Garmin's Apple Health sync leaves out overnight HRV, resting heart rate, blood oxygen and respiration. With your own Garmin key, Grada reads them, with sleep, steps and workouts, straight from Garmin Connect. Apple Health data comes first; Garmin fills in what it lacks.")
                .textCase(nil)
        } footer: {
            Text("The key stays in this iPhone's Keychain and is sent only to Garmin. Garmin's terms let you use your key in apps you use for yourself, and forbid sharing it with anyone.")
        }
    }

    private var guide: some View {
        Section("How to Get a Key") {
            Label { Text("Open [Personal API Key](https://connect.garmin.com/app/settings/personalApiToken) on Garmin Connect and sign in.") }
                icon: { Text("1.").monospacedDigit() }
            Label { Text("Select Create Key, read and accept Garmin's terms, and choose how long the key lasts. When it expires, Grada asks for a new one.") }
                icon: { Text("2.").monospacedDigit() }
            Label { Text("Copy the key and paste it above. Garmin shows it only once.") }
                icon: { Text("3.").monospacedDigit() }
        }
    }

    /// Imports whatever history is still missing, then the latest days, ignoring the 15-minute wait.
    private func sync(_ garmin: GarminSource) {
        progress = "Importing from Garmin…"
        Task {
            await model.importer?.sourceConnected(garmin)
            progress = nil
        }
    }

    private func connect(_ garmin: GarminSource) {
        error = nil
        progress = "Checking the key…"
        Task {
            do {
                try await garmin.connect(key: key)
                key = ""
                progress = "Importing from Garmin…"
                await model.importer?.sourceConnected(garmin)
            } catch {
                self.error = error.localizedDescription
            }
            progress = nil
        }
    }
}

#Preview {
    NavigationStack { GarminConnectView() }
        .environment(HomeModel(source: SampleDataSource()))
}
