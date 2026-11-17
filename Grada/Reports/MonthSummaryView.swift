import SwiftUI

/// The month holding `day`: each metric's average and how it changed from the month before.
struct MonthSummaryView: View {
    let day: Date
    @Environment(\.healthSource) private var healthSource
    @Environment(HomeModel.self) private var homeModel
    @State private var summary: MonthSummary?

    private let calendar = Calendar.current
    private var month: Date { calendar.dateInterval(of: .month, for: day)!.start }
    private var previousName: String {
        calendar.date(byAdding: .month, value: -1, to: month)!.formatted(.dateTime.month(.wide))
    }
    private var isCurrent: Bool { calendar.isDate(month, equalTo: .now, toGranularity: .month) }

    var body: some View {
        List {
            Section {
                if let summary {
                    ForEach(summary.rows, id: \.metric) { row($0) }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                Text(subtitle).textCase(nil)
            } footer: {
                Text("A change shows only when it's bigger than a fifth of how much your days vary. A month needs 14 days with data (VO₂ max: 2 readings).")
            }
        }
        .navigationTitle(month.formatted(.dateTime.month(.wide).year()))
        .task(id: homeModel.importer?.revision ?? 0) {
            summary = try? await MonthSummary.load(month: month, source: healthSource, calendar: calendar)
        }
    }

    private var subtitle: String {
        guard isCurrent else { return "Compared with \(previousName)" }
        let days = calendar.component(.day, from: .now)
        return "So far · \(days) \(days == 1 ? "day" : "days") · compared with \(previousName)"
    }

    private func row(_ row: MonthSummary.Row) -> some View {
        let card = row.metric.card
        return HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                    Text(per(row)).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: card.symbol).foregroundStyle(card.category.color)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.average.map { value($0, row.metric) } ?? "—").font(.body.weight(.semibold))
                Text(change(row)).font(.caption).foregroundStyle(changeColor(row))
            }
            .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// What the average is per.
    private func per(_ row: MonthSummary.Row) -> String {
        switch row.metric {
        case .steps: "a day"
        case .exercise: "a week · goal 150 min"
        case .restingHeartRate: "average"
        case .hrv: "overnight average"
        case .sleep: "a night"
        case .vo2Max: "average of \(row.days) \(row.days == 1 ? "reading" : "readings")"
        }
    }

    private func change(_ row: MonthSummary.Row) -> String {
        if row.average == nil {
            return "\(row.days) of \(row.metric.minimumDays) \(row.metric == .vo2Max ? "readings" : "days") needed"
        }
        guard let previous = row.previous else { return "Not enough data in \(previousName)" }
        switch row.change {
        case .unknown: return ""
        case .steady: return "About the same"
        case .changed(let difference):
            let arrow = difference > 0 ? "↑" : "↓"
            return "\(arrow) \(value(abs(difference), row.metric, unit: false, fine: true)) from \(value(previous, row.metric, unit: false))"
        }
    }

    private func changeColor(_ row: MonthSummary.Row) -> Color {
        guard case .changed(let difference) = row.change, let higherIsBetter = row.metric.higherIsBetter else { return .secondary }
        return (difference > 0) == higherIsBetter ? .green : .orange
    }

    /// `fine` adds a decimal to a difference that would round to zero, since it's a real change (e.g. 0.4 bpm).
    private func value(_ value: Double, _ metric: MonthSummary.Metric, unit: Bool = true, fine: Bool = false) -> String {
        let number = { (decimals: Int) in
            let scale = pow(10, Double(decimals))
            let decimals = fine && (value * scale).rounded() == 0 ? decimals + 1 : decimals
            return value.formatted(.number.precision(.fractionLength(decimals)))
        }
        return switch metric {
        case .steps: number(0)
        case .exercise: number(0) + (unit ? " min" : "")
        case .restingHeartRate: number(0) + (unit ? " bpm" : "")
        case .hrv: number(0) + (unit ? " ms" : "")
        case .sleep: SnapshotBuilder.hoursMinutes(value)
        case .vo2Max: number(1)
        }
    }
}

#Preview {
    NavigationStack {
        MonthSummaryView(day: .now)
    }
    .environment(HomeModel(source: SampleDataSource()))
    .environment(\.healthSource, SampleDataSource())
}
