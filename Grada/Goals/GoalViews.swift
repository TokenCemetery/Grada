import SwiftData
import SwiftUI

/// Shown once in onboarding: picks the starting goals. Saving them closes the sheet.
struct GoalSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.healthSource) private var healthSource
    @Environment(HomeModel.self) private var homeModel
    /// The last 7 days per metric; nil until loaded or with less than a week of history.
    @State private var lastWeek: [GoalMetric: [Double?]]?

    private var store: GoalStore { GoalStore(context: modelContext, source: healthSource) }

    var body: some View {
        List {
            if let lastWeek {
                option(title: String(localized: "From your last 7 days"), summary: String(localized: "Your recent activity"),
                       goals: Goals.fromLastWeek(lastWeek, fallback: .balanced), reason: .lastWeek)
            }
            ForEach(GoalPreset.allCases) { preset in
                option(title: preset.title, summary: preset.summary, goals: preset.goals, reason: .preset)
            }
            Section {
            } footer: {
                Text("Goals adjust every Monday from your progress, and sleep follows your Sleep need. Change them any time in Settings › Goals.")
            }
        }
        .navigationTitle("Choose your goals")
        // History imports in the background, so check again as data arrives.
        .task(id: homeModel.importer?.revision) { lastWeek = try? await store.lastWeek() }
    }

    private func option(title: String, summary: String, goals: [GoalMetric: Double], reason: GoalEntry.Reason) -> some View {
        Section {
            Button {
                store.start(with: goals, reason: reason)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    Text(GoalMetric.allCases.compactMap { metric in goals[metric].map { "\(metric.title) \(metric.formatted($0))" } }
                        .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Settings › Goals: each goal, its latest change, edit, and re-pick a preset.
struct GoalsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.healthSource) private var healthSource
    @Query private var goalChanges: [GoalChange]
    @State private var editing: GoalMetric?
    @State private var pendingPreset: GoalPreset?

    private var history: GoalHistory { GoalHistory(goalChanges) }
    private var today: Date { Calendar.current.startOfDay(for: .now) }

    var body: some View {
        List {
            Section {
                ForEach(GoalMetric.allCases) { metric in
                    Button { editing = metric } label: { row(metric) }
                        .buttonStyle(.plain)
                }
            } footer: {
                Text("Goals adjust every Monday: up 5% after a week you met them, down 5% after a week you missed them. A goal you change holds for a week, then adjusts from your value.")
            }
            Section {
                Menu("Reset to a Preset") {
                    ForEach(GoalPreset.allCases) { preset in
                        Button("\(preset.title): \(preset.summary)") { pendingPreset = preset }
                    }
                }
            } footer: {
                Text("Replaces every goal with the preset's values, starting today.")
            }
        }
        .navigationTitle("Goals")
        .sheet(item: $editing) { metric in
            GoalEditor(metric: metric, current: history.value(metric, on: today) ?? defaultValue(metric)) { value in
                GoalStore(context: modelContext, source: healthSource).edit(metric, to: value)
            }
            .presentationDetents([.height(260)])
        }
        .confirmationDialog("Reset every goal to \(pendingPreset?.title ?? "")?", isPresented: Binding(
            get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }
        ), titleVisibility: .visible) {
            Button("Reset Goals") {
                if let pendingPreset {
                    GoalStore(context: modelContext, source: healthSource).start(with: pendingPreset.goals, reason: .preset)
                }
            }
        }
    }

    private func row(_ metric: GoalMetric) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title)
                Text(changeText(metric)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(history.value(metric, on: today).map(metric.formatted) ?? (metric == .sleep ? String(localized: "Sleep need") : "–"))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func changeText(_ metric: GoalMetric) -> String {
        if metric == .sleep, history.value(.sleep, on: today) == nil { return String(localized: "Follows your Sleep need") }
        guard let (entry, previous) = history.latestChange(metric) else { return String(localized: "Not set") }
        let date = entry.effectiveFrom.formatted(.dateTime.day().month(.abbreviated))
        switch entry.reason {
        case .preset: return String(localized: "Set from a preset on \(date)")
        case .lastWeek: return String(localized: "Set from your last 7 days on \(date)")
        case .edit: return String(localized: "Changed by you on \(date)")
        case .automatic:
            guard let previous else { return String(localized: "Adjusted on \(date)") }
            let from = metric.formatted(previous)
            let to = metric.formatted(entry.value)
            return entry.value > previous
                ? String(localized: "Raised from \(from) to \(to) on \(date)")
                : String(localized: "Lowered from \(from) to \(to) on \(date)")
        }
    }

    private func defaultValue(_ metric: GoalMetric) -> Double {
        GoalPreset.balanced.goals[metric] ?? SleepNeed.baseline
    }
}

private struct GoalEditor: View {
    let metric: GoalMetric
    @State var value: Double
    let save: (Double) -> Void
    @Environment(\.dismiss) private var dismiss

    init(metric: GoalMetric, current: Double, save: @escaping (Double) -> Void) {
        self.metric = metric
        _value = State(initialValue: current)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(metric.formatted(value)).font(.largeTitle.weight(.bold)).monospacedDigit()
                Stepper(metric.title, value: $value, in: metric.limits, step: metric.step).labelsHidden()
                Text("Holds for a week, then adjusts from your value.").font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle(metric.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(value)
                        dismiss()
                    }
                }
            }
        }
    }
}
