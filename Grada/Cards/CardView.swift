import SwiftUI

/// One home card: title, period, big value, one comparison line, and a 7-day chart or a detail block.
struct CardView: View {
    let kind: CardKind
    let snapshot: CardSnapshot?

    static let squareHeight: CGFloat = 176

    private var color: Color { kind.category.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if kind.valueBesideTitle, let snapshot, snapshot.value != nil {
                // A big value shares the title row, between the text and the icon, so it adds no height.
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).font(.subheadline.weight(.semibold))
                        Text(snapshot.period).font(.caption).foregroundStyle(.secondary)
                        if let comparison = snapshot.comparison {
                            comparisonText(comparison, snapshot.tone).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    valueText(snapshot, numberFont: .system(.largeTitle, weight: .bold))
                        .fixedSize()
                    Image(systemName: kind.symbol).foregroundStyle(color)
                }
                CardDetailView(detail: snapshot.detail, color: color)
                    .padding(.top, 8)
            } else {
                header
                periodAndContent(snapshot)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: kind.size == .square ? Self.squareHeight : nil, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        HStack {
            Text(kind.title).font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            Image(systemName: kind.symbol).foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func periodAndContent(_ snapshot: CardSnapshot?) -> some View {
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

    @ViewBuilder
    private func content(_ snapshot: CardSnapshot) -> some View {
        switch kind.size {
        case .square:
            valueBlock(snapshot)
            Spacer(minLength: 8)
            MiniChart(chart: snapshot.chart, color: color)
        case .wide:
            if snapshot.chart.isBars {
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
            valueText(snapshot)
            if let comparison = snapshot.comparison {
                comparisonText(comparison, snapshot.tone).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func valueText(_ snapshot: CardSnapshot, numberFont: Font = ValueText.numberFont) -> some View {
        if kind == .healthStatus || !(snapshot.value ?? "").contains(where: \.isNumber) {
            Text(snapshot.value ?? "")
                .font(.title2.weight(.bold))
                .foregroundStyle(valueColor(snapshot.tone))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            ValueText(value: snapshot.value ?? "", unit: snapshot.unit, numberFont: numberFont)
                .foregroundStyle(valueColor(snapshot.tone))
        }
    }

    private func comparisonText(_ comparison: String, _ tone: CardSnapshot.Tone) -> some View {
        Text(comparison)
            .font(.caption)
            .foregroundStyle(tone == .warning && !kind.isScore ? Color.orange : .secondary)
    }

    /// Only scored cards color their value; plain metrics stay neutral.
    private func valueColor(_ tone: CardSnapshot.Tone) -> Color {
        guard kind.isScore else { return .primary }
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

/// Big bold numbers with small bold units, like "7 h 50 min" or "52 bpm".
private struct ValueText: View {
    let value: String
    let unit: String
    var numberFont: Font = Self.numberFont

    static let numberFont = Font.system(.title, weight: .bold)
    private static let unitFont = Font.subheadline.weight(.semibold)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(Self.runs(value).enumerated()), id: \.offset) { _, run in
                Text(run.text).font(run.isNumber ? numberFont : Self.unitFont)
            }
            if !unit.isEmpty {
                Text("\u{2009}" + unit).font(Self.unitFont)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }

    /// Splits "7h 50m" into number and letter runs, with a thin space before each letter run.
    static func runs(_ value: String) -> [(text: String, isNumber: Bool)] {
        var runs: [(text: String, isNumber: Bool)] = []
        for character in value {
            let isNumber = character.isNumber || "+-−–.,:\u{00A0}\u{202F}".contains(character)
            if let last = runs.last, last.isNumber == isNumber {
                runs[runs.count - 1].text.append(character)
            } else {
                runs.append((text: (isNumber || runs.isEmpty ? "" : "\u{2009}") + String(character), isNumber: isNumber))
            }
        }
        return runs
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
        case .stats(let stats):
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(stat.value).font(.headline).monospacedDigit()
                        Text(stat.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
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

    var body: some View {
        let total = max(SleepStage.chartOrder.reduce(0) { $0 + (stages[$1] ?? 0) }, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(SleepStage.chartOrder, id: \.self) { stage in
                        let share = (stages[stage] ?? 0) / total
                        if share > 0 {
                            stage.color(base: color).background(Color.white)
                                .frame(width: max(proxy.size.width * share - 2, 2))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 8)
            HStack(spacing: 8) {
                ForEach(SleepStage.chartOrder, id: \.self) { stage in
                    HStack(spacing: 4) {
                        Circle().fill(stage.color(base: color)).background(Circle().fill(.white)).frame(width: 7, height: 7)
                        Text("\(stage.title) \(SnapshotBuilder.hoursMinutes(stages[stage] ?? 0))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
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

/// The last 30 days as a calendar: weekday columns, one dot per day, bigger dots for longer
/// workouts, today ringed.
private struct DaysGrid: View {
    let minutes: [Double]
    let color: Color

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let first = calendar.date(byAdding: .day, value: -(minutes.count - 1), to: today)!
        let leadingBlanks = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let cells: [Double?] = Array(repeating: nil, count: leadingBlanks) + minutes.map { $0 }
        let letters = calendar.veryShortStandaloneWeekdaySymbols
        let header = (0..<7).map { letters[(calendar.firstWeekday - 1 + $0) % 7] }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

        VStack(spacing: 4) {
            // The header is a separate grid: sharing one ForEach id space with the days would drop days.
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(header.enumerated()), id: \.offset) { _, letter in
                    Text(letter).font(.caption2).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { index, value in
                    ZStack {
                        if let value {
                            Circle()
                                .fill(value > 0 ? color : Color(.tertiarySystemFill))
                                .frame(width: diameter(value), height: diameter(value))
                        }
                        if index == cells.count - 1 {
                            Circle().strokeBorder(Color.primary.opacity(0.6), lineWidth: 1.5).frame(width: 24, height: 24)
                        }
                    }
                    .frame(height: 24)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(minutes.filter { $0 > 0 }.count) active days in the last 30 days")
    }

    private func diameter(_ minutes: Double) -> CGFloat {
        minutes <= 0 ? 6 : min(10 + CGFloat(minutes) / 8, 20)
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
