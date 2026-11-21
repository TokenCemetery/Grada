import SwiftUI

/// What the Cycle calendar shows and what it rests on (#138).
struct CycleInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DetailSection(title: String(localized: "What it means")) {
                        Text("Period days come from apps that log to Apple Health. With \(Cycle.minimumCycles) complete cycles logged, the calendar shows when your next period is likely, as a range that widens the more your cycles vary. Ovulation is marked only from evidence: a positive LH test, after which ovulation is likely within 1–2 days, or a sustained rise in basal body or sleeping wrist temperature by the three-over-six rule. Cervical mucus is shown but never marks ovulation on its own. Grada doesn't predict a fertile window, and isn't for birth control or planning a pregnancy.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    DetailSection(title: String(localized: "Sources")) {
                        SourcesView(sources: MetricSource.cycle, estimateNote: Self.estimateNote)
                    }
                }
                .padding()
                .readableWidth()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Cycle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    static var estimateNote: String {
        String(localized: "The range is your mean cycle length ± 1 standard deviation over your last \(Cycle.predictionCycles) complete cycles, from \(Cycle.minimumCycles) cycles; both are Grada's choices. A cycle over \(Cycle.maximumCycleDay) days counts as a missed log. A temperature rise needs nine nights in a row with the third high night at least \(Cycle.riseMargin.formatted()) °C above the six before, and ovulation is marked on the last night before it. The rule was set for basal thermometer readings; applying it to sleeping wrist temperature is Grada's choice.")
    }
}
