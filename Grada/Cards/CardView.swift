import SwiftUI

/// One home card: title, period, big value, one comparison line, and a 7-day chart or a detail block.
struct CardView: View {
    let kind: CardKind
    let snapshot: CardSnapshot?

    static let squareHeight: CGFloat = 176

    private var color: Color { kind.category.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(kind.title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Image(systemName: kind.symbol).foregroundStyle(color)
            }
            if let snapshot {
                Text(snapshot.period).font(.caption).foregroundStyle(.secondary)
                if snapshot.value != nil {
                    content(snapshot)
                } else {
                    noData
                }
            } else {
                Spacer(minLength: 0)
                ProgressView().frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: kind.size == .square ? Self.squareHeight : nil, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func content(_ snapshot: CardSnapshot) -> some View {
        switch kind.size {
        case .square:
            valueBlock(snapshot)
            Spacer(minLength: 8)
            MiniChart(chart: snapshot.chart, color: color)
        case .wide:
            if case .bars = snapshot.chart {
                HStack(alignment: .bottom, spacing: 16) {
                    valueBlock(snapshot)
                    MiniChart(chart: snapshot.chart, color: color).frame(width: 150)
                }
            } else {
                valueBlock(snapshot)
            }
            CardDetailView(detail: snapshot.detail, color: color)
                .padding(.top, 8)
        }
    }

    private func valueBlock(_ snapshot: CardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(snapshot.value ?? "")
                    .font(.system(kind == .healthStatus ? .title2 : .title, design: .rounded).weight(.semibold))
                    .foregroundStyle(valueColor(snapshot.tone))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if !snapshot.unit.isEmpty {
                    Text(snapshot.unit).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let comparison = snapshot.comparison {
                Text(comparison)
                    .font(.caption)
                    .foregroundStyle(snapshot.tone == .warning && kind != .healthStatus ? Color.orange : .secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Only scored cards color their value; plain metrics stay neutral.
    private func valueColor(_ tone: CardSnapshot.Tone) -> Color {
        guard kind == .healthStatus else { return .primary }
        switch tone {
        case .good: return .green
        case .warning: return .orange
        case .neutral: return .primary
        }
    }

    private var noData: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 8)
            Text("No data yet").font(.headline)
            Text(kind.missingDataHint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Extra content for wide cards.
private struct CardDetailView: View {
    let detail: CardSnapshot.Detail
    let color: Color

    var body: some View {
        switch detail {
        case .none:
            EmptyView()
        case .vitals(let vitals):
            HStack(spacing: 6) {
                ForEach(vitals, id: \.name) { VitalChip(vital: $0) }
            }
        case .sleepStages(let stages):
            SleepStagesBar(stages: stages, color: color)
        case .workout(let workout):
            WorkoutDetail(workout: workout, color: color)
        case .days(let minutes):
            DaysGrid(minutes: minutes, color: color)
        }
    }
}

private struct VitalChip: View {
    let vital: VitalStatus

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.caption2).foregroundStyle(tint)
            Text(vital.name).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(vital.name): \(stateLabel)")
    }

    private var symbol: String {
        switch vital.state {
        case .inRange: "checkmark.circle"
        case .outOfRange: "exclamationmark.circle"
        case .calibrating: "hourglass"
        case .noData: "minus.circle"
        }
    }

    private var tint: Color {
        switch vital.state {
        case .inRange: .green
        case .outOfRange: .orange
        case .calibrating, .noData: .secondary
        }
    }

    private var stateLabel: String {
        switch vital.state {
        case .inRange: "in range"
        case .outOfRange: "out of range"
        case .calibrating: "calibrating"
        case .noData: "no data"
        }
    }
}

private struct SleepStagesBar: View {
    let stages: [SleepStage: TimeInterval]
    let color: Color

    private let order: [(SleepStage, String, Double)] = [
        (.deep, "Deep", 1), (.core, "Core", 0.65), (.rem, "REM", 0.4), (.awake, "Awake", 0.15),
    ]

    var body: some View {
        let total = max(order.reduce(0) { $0 + (stages[$1.0] ?? 0) }, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(order, id: \.1) { stage, _, opacity in
                        let share = (stages[stage] ?? 0) / total
                        if share > 0 {
                            color.opacity(opacity)
                                .frame(width: max(proxy.size.width * share - 2, 2))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 8)
            HStack(spacing: 10) {
                ForEach(order, id: \.1) { stage, name, opacity in
                    HStack(spacing: 4) {
                        Circle().fill(color.opacity(opacity)).frame(width: 7, height: 7)
                        Text("\(name) \(SnapshotBuilder.hoursMinutes(stages[stage] ?? 0))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .opacity(stages.isEmpty ? 0 : 1)
    }
}

private struct WorkoutDetail: View {
    let workout: WorkoutSummary
    let color: Color

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: workout.symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.15), in: Circle())
            if let energy = workout.energyKcal {
                stat(energy.formatted(.number.precision(.fractionLength(0))), "kcal")
            }
            if let heartRate = workout.averageHeartRate {
                stat(heartRate.formatted(.number.precision(.fractionLength(0))), "avg bpm")
            }
            Spacer()
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.headline)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// One dot per day; bigger dots mean longer workouts.
private struct DaysGrid: View {
    let minutes: [Double]
    let color: Color

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 15)
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(minutes.enumerated()), id: \.offset) { _, value in
                Circle()
                    .fill(value > 0 ? color : Color(.tertiarySystemFill))
                    .frame(width: diameter(value), height: diameter(value))
                    .frame(height: 16)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(minutes.filter { $0 > 0 }.count) active days in the last 30 days")
    }

    private func diameter(_ minutes: Double) -> CGFloat {
        minutes <= 0 ? 5 : min(8 + CGFloat(minutes) / 10, 16)
    }
}

#Preview("Cards") {
    let builder = SnapshotBuilder(source: SampleDataSource())
    ScrollView {
        VStack(spacing: 12) {
            ForEach([CardKind.healthStatus, .sleepStages, .lastWorkout, .last30Days]) { kind in
                PreviewCard(kind: kind, builder: builder)
            }
            HStack(spacing: 12) {
                PreviewCard(kind: .restingHeartRate, builder: builder)
                PreviewCard(kind: .steps, builder: builder)
            }
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}

private struct PreviewCard: View {
    let kind: CardKind
    let builder: SnapshotBuilder
    @State private var snapshot: CardSnapshot?

    var body: some View {
        CardView(kind: kind, snapshot: snapshot)
            .task { snapshot = try? await builder.snapshot(for: kind) }
    }
}
