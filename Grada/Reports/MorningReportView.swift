import SwiftUI

/// Journal's reports: side by side where there's room (iPad), stacked otherwise. A `List` can't place
/// sections side by side, so each report draws its own grouped card inside one clear row.
struct ReportColumns: View {
    let morning: MorningReport?
    let day: Date
    let open: (MetricRoute) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            HStack(alignment: .top, spacing: 20) {
                MorningReportCard(report: morning, day: day, open: open).frame(maxWidth: .infinity)
                // The evening report's column (#27).
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        } else {
            MorningReportCard(report: morning, day: day, open: open)
        }
    }
}

/// The morning report: one row per card, each opening its detail screen, then recommendations.
struct MorningReportCard: View {
    /// Nil while loading.
    let report: MorningReport?
    let day: Date
    /// Opens a row's detail screen. Buttons, not navigation links: in a List row, every link's tap goes to the last.
    let open: (MetricRoute) -> Void
    @AppStorage("colorBlindPalette") private var colorBlind = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Morning Report")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let report {
            if report.hasSleep {
                let rows = MorningReport.kinds.compactMap { kind in
                    report.snapshots[kind].flatMap { $0.value == nil ? nil : (kind, $0) }
                }
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { Divider().padding(.leading, 56) }
                    row(rows[index].0, rows[index].1)
                }
                ForEach(report.recommendations.indices, id: \.self) { index in
                    Divider().padding(.leading, 56)
                    recommendation(report.recommendations[index])
                }
            } else {
                Text(isToday ? "Waiting for last night's sleep from Apple Health." : "No sleep recorded that night.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(16)
        }
    }

    private func row(_ kind: CardKind, _ snapshot: CardSnapshot) -> some View {
        Button { open(MetricRoute(kind: kind, day: isToday ? nil : day)) } label: {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(kind.title)
                } icon: {
                    Image(systemName: kind.symbol).foregroundStyle(kind.category.color)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(snapshot.value ?? "").font(.body.weight(.semibold)).foregroundStyle(valueColor(snapshot))
                    if let comparison = snapshot.comparison {
                        Text(comparison).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        // Several buttons share one List row; a non-default style keeps each its own tap target.
        .buttonStyle(.plain)
    }

    private func recommendation(_ recommendation: Recommendation) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(recommendation.text).font(.subheadline.weight(.semibold))
                Text(recommendation.reason).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "lightbulb").foregroundStyle(.yellow)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Like the cards: the rating's color, else the tone's.
    private func valueColor(_ snapshot: CardSnapshot) -> Color {
        if let rating = snapshot.rating { return rating.text(colorBlind: colorBlind) }
        switch snapshot.tone {
        case .good: return .green
        case .warning: return .orange
        case .neutral: return .primary
        }
    }
}
