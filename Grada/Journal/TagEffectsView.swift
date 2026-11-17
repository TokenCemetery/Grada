import SwiftData
import SwiftUI

/// How Alcohol and Caffeine change the night after, from the user's own journal and nights.
struct TagEffectsView: View {
    @Environment(\.healthSource) private var healthSource
    @Environment(HomeModel.self) private var homeModel
    @Query private var entries: [JournalEntry]
    @State private var sections: [TagEffect.Section]?

    var body: some View {
        List {
            if let sections {
                ForEach(sections, id: \.title) { section in
                    Section {
                        if section.rows.allSatisfy({ $0.with == nil }) {
                            Text(waiting(section)).foregroundStyle(.secondary)
                        } else {
                            ForEach(section.rows, id: \.metric) { row($0, tag: section.tag) }
                        }
                    } header: {
                        Label(section.title, systemImage: section.tag.symbol)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Section {
            } footer: {
                Text("Compares the night after days you logged a tag with the night after days you didn't, over the last \(TagEffect.windowDays) days. Nights after Illness or Night shift are left out. A difference shows only when it's clearly bigger than how much your nights vary, and each side needs \(TagEffect.minimumNights) nights.")
            }
        }
        .navigationTitle("Tag Effects")
        .task(id: homeModel.importer?.revision ?? 0) {
            let calendar = Calendar.current
            var logged: [String: [JournalTag: Double]] = [:]
            for entry in entries {
                guard let tag = entry.tag else { continue }
                logged[entry.dayKey, default: [:]][tag] = entry.amount ?? 1
            }
            guard let nights = try? await TagEffect.nights(source: healthSource) else { return }
            sections = TagEffect.sections(logged: logged, nights: nights, calendar: calendar)
        }
    }

    private func row(_ row: TagEffect.Row, tag: JournalTag) -> some View {
        let card = row.metric.card
        return HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.metric.title)
                    Text("\(row.nightsWith) \(row.nightsWith == 1 ? "night" : "nights") with · \(row.nightsWithout) without")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: card.symbol).foregroundStyle(card.category.color)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.with.map { value($0, row.metric) } ?? "—").font(.body.weight(.semibold))
                Text(change(row, tag: tag)).font(.caption).foregroundStyle(changeColor(row))
            }
            .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// For a section with nothing to show yet: what's missing, counting the metric closest to enough.
    private func waiting(_ section: TagEffect.Section) -> String {
        let with = section.rows.map(\.nightsWith).max() ?? 0
        let without = section.rows.map(\.nightsWithout).max() ?? 0
        let needed = TagEffect.minimumNights
        if with < needed {
            return "Log \(section.tag.title) on \(needed) days to see how it changes the night after · \(with) so far"
        }
        if without < needed { return "Needs \(needed) nights without \(section.tag.title) · \(without) so far" }
        return "Needs \(needed) nights of sleep data on each side"
    }

    private func change(_ row: TagEffect.Row, tag: JournalTag) -> String {
        guard let without = row.without else {
            let missing = row.nightsWith < TagEffect.minimumNights ? "with \(tag.title)" : "without it"
            return "Needs \(TagEffect.minimumNights) nights \(missing)"
        }
        switch row.change {
        case .notEnough: return ""
        case .withinVariation: return "Within your usual variation"
        case .changed(let difference):
            let arrow = difference > 0 ? "↑" : "↓"
            return "\(arrow) \(value(abs(difference), row.metric, unit: false)) vs \(value(without, row.metric)) without"
        }
    }

    private func changeColor(_ row: TagEffect.Row) -> Color {
        guard case .changed(let difference) = row.change else { return .secondary }
        return (difference > 0) == row.metric.higherIsBetter ? .green : .orange
    }

    private func value(_ value: Double, _ metric: TagEffect.Metric, unit: Bool = true) -> String {
        if metric.isDuration { return SnapshotBuilder.hoursMinutes(value) }
        let number = value.formatted(.number.precision(.fractionLength(0)))
        guard unit else { return number }
        return number + (metric == .hrv ? " ms" : " bpm")
    }
}

private extension TagEffect.Section {
    var title: String { dose.map { "\(tag.title) · \($0)" } ?? tag.title }
}

#Preview {
    NavigationStack {
        TagEffectsView()
    }
    .environment(HomeModel(source: SampleDataSource()))
    .environment(\.healthSource, SampleDataSource())
    .modelContainer(for: [JournalEntry.self], inMemory: true)
}
