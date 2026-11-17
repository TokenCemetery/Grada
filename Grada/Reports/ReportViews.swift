import SwiftUI

/// Journal's reports: side by side where there's room (iPad), stacked otherwise. A `List` can't place
/// sections side by side, so each report draws its own grouped card inside one clear row.
struct ReportColumns: View {
    /// Nil while loading.
    let morning: DailyReport?
    let evening: DailyReport?
    let day: Date
    let open: (MetricRoute) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            // Both cards stretch to the taller one, so the columns end together.
            HStack(alignment: .top, spacing: 20) {
                ReportCard(kind: .morning, report: morning, day: day, open: open)
                ReportCard(kind: .evening, report: evening, day: day, open: open)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 24) {
                ReportCard(kind: .morning, report: morning, day: day, open: open)
                ReportCard(kind: .evening, report: evening, day: day, open: open)
            }
        }
    }
}

/// A report: one row per card, each opening its detail screen.
struct ReportCard: View {
    let kind: DailyReport.Kind
    /// Nil while loading.
    let report: DailyReport?
    let day: Date
    /// Opens a row's detail screen. Buttons, not navigation links: in a List row, every link's tap goes to the last.
    let open: (MetricRoute) -> Void
    @AppStorage(SettingsKey.colorBlindPalette) private var colorBlind = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReportHeader(title: kind.title)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let report {
            if report.hasData {
                let rows = kind.kinds.compactMap { card in
                    report.snapshots[card].flatMap { $0.value == nil ? nil : (card, $0) }
                }
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { Divider().padding(.leading, 56) }
                    row(rows[index].0, rows[index].1)
                }
            } else {
                // Only the morning report waits for data.
                Text(isToday ? "Waiting for last night's sleep from Apple Health." : "No sleep recorded that night.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(16)
        }
    }

    /// One line each for the title, value and comparison, so rows are the same height in both columns.
    private func row(_ kind: CardKind, _ snapshot: CardSnapshot) -> some View {
        Button { open(MetricRoute(kind: kind, day: isToday ? nil : day)) } label: {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(kind.title).lineLimit(1).minimumScaleFactor(0.8)
                } icon: {
                    Image(systemName: kind.symbol).foregroundStyle(kind.category.color)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(snapshot.value ?? "").font(.body.weight(.semibold)).foregroundStyle(valueColor(snapshot))
                    Text(snapshot.comparison ?? " ").font(.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        // Several buttons share one List row; a non-default style keeps each its own tap target.
        .buttonStyle(.plain)
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

/// Both reports' recommendations: two per row where there's room (iPad), one list otherwise.
struct RecommendationsView: View {
    let recommendations: [Recommendation]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReportHeader(title: "Recommendations")
            if sizeClass == .regular {
                Grid(horizontalSpacing: 20, verticalSpacing: 12) {
                    ForEach(Array(stride(from: 0, to: recommendations.count, by: 2)), id: \.self) { start in
                        GridRow {
                            tile(recommendations[start])
                            if start + 1 < recommendations.count {
                                tile(recommendations[start + 1])
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recommendations.indices, id: \.self) { index in
                        if index > 0 { Divider().padding(.leading, 56) }
                        RecommendationRow(recommendation: recommendations[index])
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private func tile(_ recommendation: Recommendation) -> some View {
        RecommendationRow(recommendation: recommendation)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct RecommendationRow: View {
    let recommendation: Recommendation

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(recommendation.text).font(.subheadline.weight(.semibold))
                Text(recommendation.reason).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: recommendation.symbol).foregroundStyle(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// A section title above a report card, like a grouped List's header.
private struct ReportHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
            .padding(.leading, 20)
            .accessibilityAddTraits(.isHeader)
    }
}
