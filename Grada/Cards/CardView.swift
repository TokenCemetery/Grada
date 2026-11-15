import SwiftUI

/// One home card: title, period, big value, one comparison line, and a 7-day chart or a detail block.
struct CardView: View {
    let kind: CardKind
    let snapshot: CardSnapshot?
    @AppStorage("colorBlindPalette") private var colorBlind = false

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
            } else if case .workout(let workout)? = snapshot?.detail, let snapshot {
                // The sport leads the title row, like Suunto's Latest activity; the stats run underneath.
                HStack(alignment: .top, spacing: 10) {
                    WorkoutSport(workout: workout)
                    // The sport name takes the title's place; the icon and stats already say it's a workout.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Text(snapshot.period).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(kind.title): \(workout.name), \(snapshot.period)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: kind.symbol).foregroundStyle(color)
                }
                CardDetailView(detail: snapshot.detail, color: color)
                    .padding(.top, 10)
            } else {
                header
                periodAndContent(snapshot)
            }
        }
        .padding(12)
        // maxHeight lets a card stretch to the tallest card in its grid row.
        .frame(maxWidth: .infinity, minHeight: kind.size == .square ? Self.squareHeight : nil, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        HStack {
            Text(kind.title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
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
            MiniChart(chart: snapshot.chart, color: chartColor(snapshot))
            CardDetailView(detail: snapshot.detail, color: color)
        case .wide, .big:
            if case .days = snapshot.detail {
                // The workout count is already the period line; the calendar takes the space.
                EmptyView()
            } else if snapshot.chart.isBars {
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
                .foregroundStyle(valueColor(snapshot))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            ValueText(value: snapshot.value ?? "", unit: snapshot.unit, numberFont: numberFont)
                .foregroundStyle(valueColor(snapshot))
        }
    }

    private func comparisonText(_ comparison: String, _ tone: CardSnapshot.Tone) -> some View {
        Text(comparison)
            .font(.caption)
            .foregroundStyle(tone == .warning && !kind.isScore ? Color.orange : .secondary)
    }

    /// A rating colors the value red, yellow or green; otherwise only scored cards color it by tone.
    private func valueColor(_ snapshot: CardSnapshot) -> Color {
        if let rating = snapshot.rating { return rating.text(colorBlind: colorBlind) }
        guard kind.isScore else { return .primary }
        switch snapshot.tone {
        case .good: return .green
        case .warning: return .orange
        case .neutral: return .primary
        }
    }

    /// A rated day line takes the rating's color, so the line reads like the value above it.
    private func chartColor(_ snapshot: CardSnapshot) -> Color {
        if case .intraday = snapshot.chart, let rating = snapshot.rating { return rating.text(colorBlind: colorBlind) }
        return color
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

/// Extra content below the value or chart.
private struct CardDetailView: View {
    let detail: CardSnapshot.Detail
    let color: Color
    @AppStorage("colorBlindPalette") private var colorBlind = false

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
            WorkoutStats(workout: workout, color: color)
        case .days(let days):
            DaysGrid(days: days)
        case .rows(let rows):
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.label).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(row.value).fontWeight(.semibold).monospacedDigit()
                            .foregroundStyle(row.rating?.text(colorBlind: colorBlind) ?? .primary)
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
            }
        case .stats(let stats):
            // Equal columns, so a long label shrinks inside its share instead of crowding its neighbours.
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(stat.value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Text(stat.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A vital's tile, filled green, yellow or red by its rating, like the calendar's days. Vitals still
/// calibrating or without data stay grey.
private struct VitalChip: View {
    let vital: VitalStatus
    @AppStorage("colorBlindPalette") private var colorBlind = false

    var body: some View {
        Text(vital.name)
            .font(.caption.weight(vital.rating == nil ? .regular : .semibold))
            .foregroundStyle(vital.rating?.foreground(colorBlind: colorBlind) ?? .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(vital.rating?.fill(colorBlind: colorBlind) ?? Color(.tertiarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(vital.name): \(stateLabel)")
    }

    private var stateLabel: String {
        switch (vital.state, vital.rating) {
        case (.calibrating, _): "calibrating"
        case (.noData, _): "no data"
        case (_, .fair): "slightly out of range"
        case (_, .poor): "well out of range"
        case (.outOfRange, _): "out of range"
        default: "in range"
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

/// The workout's sport icon in its color, like Suunto's Latest activity; it leads the card's title row.
private struct WorkoutSport: View {
    let workout: WorkoutSummary

    var body: some View {
        let sportColor = WorkoutColors.color(symbol: workout.symbol)
        Image(systemName: workout.symbol)
            .font(.body)
            .foregroundStyle(sportColor)
            .frame(width: 36, height: 36)
            .background(sportColor.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Labelled stats in equal columns, like Suunto's Latest activity. A stat Apple Health doesn't have
/// shows a dash, so the columns don't shift between workouts.
private struct WorkoutStats: View {
    let workout: WorkoutSummary
    let color: Color

    var body: some View {
        let whole = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))
        HStack(alignment: .top, spacing: 8) {
            stat("Duration", SnapshotBuilder.hoursMinutes(workout.duration))
            stat("Calories", workout.energyKcal.map { "\($0.formatted(whole)) kcal" })
            stat("Avg Heart Rate", workout.averageHeartRate.map { "\($0.formatted(whole)) bpm" })
        }
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(value ?? "–").font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The last 30 days as a calendar: weekday columns, one dot per day split into a slice per sport by
/// minutes, bigger dots for longer days, today ringed. A legend names the sports, most days first.
private struct DaysGrid: View {
    let days: [WorkoutDay]
    @State private var width: CGFloat = 0

    /// Day columns no wider than on the largest iPhone keep the base size; wider ones, as on iPad,
    /// scale the whole grid up so the dots don't sit far apart.
    private var scale: CGFloat { max(1, width / 7 / 56) }

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let first = calendar.date(byAdding: .day, value: -(days.count - 1), to: today)!
        let leadingBlanks = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let cells: [WorkoutDay?] = Array(repeating: nil, count: leadingBlanks) + days.map { $0 }
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
            LazyVGrid(columns: columns, spacing: 6 * scale) {
                ForEach(Array(cells.enumerated()), id: \.offset) { index, day in
                    ZStack {
                        if let day {
                            SportPie(day: day, diameter: diameter(day.minutes) * scale)
                        }
                        if index == cells.count - 1 {
                            Circle().strokeBorder(Color.primary.opacity(0.6), lineWidth: 1.5).frame(width: 30 * scale, height: 30 * scale)
                        }
                    }
                    .frame(height: 30 * scale)
                }
            }
            HStack(spacing: 12) {
                ForEach(WorkoutDay.topSports(days, limit: 4), id: \.name) { sport in
                    HStack(spacing: 4) {
                        Circle().fill(WorkoutColors.color(symbol: sport.symbol)).frame(width: 8, height: 8)
                        Text(sport.name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(days.filter { $0.minutes > 0 }.count) active days in the last 30 days")
    }

    private func diameter(_ minutes: Double) -> CGFloat {
        minutes <= 0 ? 6 : min(12 + CGFloat(minutes) / 6, 26)
    }
}

/// A day's dot: one slice per sport, sized by its minutes, longest first from 12 o'clock. A rest day is a
/// small grey dot.
struct SportPie: View {
    let day: WorkoutDay
    let diameter: CGFloat

    var body: some View {
        let total = max(day.minutes, .leastNonzeroMagnitude)
        let starts = day.sports.indices.map { index in day.sports[..<index].reduce(0) { $0 + $1.minutes } / total }
        ZStack {
            if day.sports.isEmpty {
                Circle().fill(Color(.tertiarySystemFill))
            }
            ForEach(day.sports.indices, id: \.self) { index in
                // A stroke half the diameter wide, on a circle half the size, fills the pie slice.
                Circle()
                    .trim(from: starts[index], to: starts[index] + day.sports[index].minutes / total)
                    .stroke(WorkoutColors.color(symbol: day.sports[index].symbol), lineWidth: diameter / 2)
                    .frame(width: diameter / 2, height: diameter / 2)
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// One color per sport, keyed by the workout symbol Apple Health workouts are stored with.
enum WorkoutColors {
    static func color(symbol: String?) -> Color {
        switch symbol {
        case "figure.run": .orange
        case "figure.walk": .yellow
        case "figure.hiking": .brown
        case "figure.outdoor.cycle": .purple
        case "figure.pool.swim": .blue
        case "figure.strengthtraining.traditional": .red
        case "figure.highintensity.intervaltraining": .pink
        case "figure.yoga": .mint
        case "figure.rower": .cyan
        case "figure.elliptical": .indigo
        case "figure.skiing.downhill": .teal
        default: .gray
        }
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
                PreviewCard(kind: .hrvStatus, builder: builder)
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
