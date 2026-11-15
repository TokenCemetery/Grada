import Charts
import SwiftData
import SwiftUI

/// One metric in depth: the card for the shown day, its trend, a breakdown, what it means, and related metrics.
struct MetricDetailView: View {
    let route: MetricRoute
    @Environment(\.healthSource) private var baseSource
    @Query private var goalChanges: [GoalChange]
    @Environment(\.openCalendar) private var openCalendar
    @State private var period: TrendPeriod = .month
    @State private var snapshot: CardSnapshot?
    @State private var trend: Trend?
    @State private var trendLoaded = false
    @State private var breakdown: Breakdown?

    private var kind: CardKind { route.kind }
    private var calendar: Calendar { .current }
    private var day: Date { calendar.startOfDay(for: route.day ?? .now) }
    private var source: HealthDataSource { PastDaySource.asOf(day, base: baseSource, calendar: calendar) }
    private var color: Color { kind.category.color }

    private var related: (title: String, kinds: [CardKind]) {
        let available = { (kind: CardKind) in kind == .healthStatus || CardKind.gallery.contains(kind) }
        return kind.basedOn.isEmpty
            ? ("Affects", kind.affects.filter(available))
            : ("Based on", kind.basedOn.filter(available))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CardView(kind: kind, snapshot: snapshot)
                trendSection
                if let breakdown {
                    DetailSection(title: breakdown.title) { BreakdownView(breakdown: breakdown, color: color) }
                }
                DetailSection(title: "What it means") {
                    Text(kind.explanation).font(.subheadline).foregroundStyle(.secondary)
                }
                if !related.kinds.isEmpty {
                    DetailSection(title: related.title) {
                        VStack(spacing: 0) {
                            ForEach(related.kinds) { other in
                                NavigationLink(value: MetricRoute(kind: other, day: route.day)) {
                                    HStack {
                                        Image(systemName: other.symbol).foregroundStyle(other.category.color).frame(width: 24)
                                        Text(other.title).foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if other != related.kinds.last { Divider() }
                            }
                        }
                    }
                }
                Button { openCalendar(kind.calendarMetric) } label: {
                    HStack {
                        Text("See in calendar").font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "calendar").foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(route.day.map { "\(kind.title), \($0.formatted(.dateTime.day().month(.abbreviated)))" } ?? kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: kind.symbol).foregroundStyle(color)
            }
        }
        .task {
            var builder = SnapshotBuilder.forDay(day, source: baseSource, calendar: calendar)
            builder.goals = GoalHistory(goalChanges)
            snapshot = try? await builder.snapshot(for: kind)
        }
        .task(id: period) {
            trend = try? await TrendBuilder(source: source, calendar: calendar).trend(for: kind, period: period)
            trendLoaded = true
            breakdown = try? await Breakdown.load(for: kind, day: day, period: period, source: source, calendar: calendar)
        }
    }

    @ViewBuilder
    private var trendSection: some View {
        DetailSection(title: trend?.title ?? "Trend") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Period", selection: $period) {
                    ForEach(TrendPeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if let trend {
                    TrendChart(trend: trend, period: period, color: color, highlighted: route.day.map { _ in day })
                        .frame(height: 200)
                    TrendStats(trend: trend, period: period)
                } else if trendLoaded {
                    Text("A trend for this card is coming in a later version.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
    }
}

/// A titled block in the same card style as Home.
struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Trend

private struct TrendChart: View {
    let trend: Trend
    let period: TrendPeriod
    let color: Color
    /// The day picked in the calendar, marked on the chart.
    let highlighted: Date?
    @State private var selection: Date?

    private var calendar: Calendar { .current }
    private var unit: Calendar.Component { period.isWeekly ? .weekOfYear : .day }

    private var selectedPoint: TrendPoint? {
        guard let selection else { return nil }
        return trend.points.filter { $0.value != nil }
            .min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    private var highlightedDate: Date? {
        guard let highlighted else { return nil }
        return period.isWeekly ? calendar.dateInterval(of: .weekOfYear, for: highlighted)?.start : highlighted
    }

    var body: some View {
        Chart {
            if let range = trend.normalRange {
                ForEach(trend.points) { point in
                    AreaMark(x: .value("Day", point.date, unit: unit),
                             yStart: .value("Low", range.lowerBound), yEnd: .value("High", range.upperBound),
                             series: .value("Series", "Normal range"))
                        .foregroundStyle(color.opacity(0.12))
                }
            }
            ForEach(trend.points) { point in
                if let value = point.value {
                    switch trend.style {
                    case .bars:
                        BarMark(x: .value("Day", point.date, unit: unit), y: .value("Value", value))
                            .foregroundStyle(color.opacity(isEmphasized(point) ? 1 : 0.6))
                    case .line:
                        LineMark(x: .value("Day", point.date, unit: unit), y: .value("Value", value),
                                 series: .value("Series", "Value"))
                            .foregroundStyle(color)
                            .interpolationMethod(.monotone)
                        if period != .year {
                            PointMark(x: .value("Day", point.date, unit: unit), y: .value("Value", value))
                                .foregroundStyle(color)
                                .symbolSize(isEmphasized(point) ? 60 : 16)
                        }
                    case .sleep:
                        ForEach([SleepStage.deep, .core, .rem], id: \.self) { stage in
                            BarMark(x: .value("Day", point.date, unit: unit), y: .value("Hours", point.stages[stage] ?? 0))
                                .foregroundStyle(stage.color(base: color))
                        }
                    }
                }
            }
            if let highlightedDate {
                RuleMark(x: .value("Shown day", highlightedDate, unit: unit))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let point = selectedPoint, let value = point.value {
                RuleMark(x: .value("Selected", point.date, unit: unit))
                    .foregroundStyle(.primary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 0) {
                            Text("\(trend.formatted(value)) \(trend.unit)").font(.caption.weight(.semibold))
                            Text(label(point.date)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .chartXSelection(value: $selection)
        .chartYScale(domain: .automatic(includesZero: trend.style != .line))
    }

    private func isEmphasized(_ point: TrendPoint) -> Bool {
        guard let highlightedDate else { return point.id == trend.points.last?.id }
        return point.date == highlightedDate
    }

    private func label(_ date: Date) -> String {
        period.isWeekly
            ? "Week of \(date.formatted(.dateTime.day().month(.abbreviated)))"
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

private struct TrendStats: View {
    let trend: Trend
    let period: TrendPeriod

    var body: some View {
        HStack {
            stat(period.isWeekly ? "Daily avg" : "Average", trend.average)
            stat("Low", trend.low)
            stat("High", trend.high)
        }
    }

    private func stat(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.map { "\(trend.formatted($0)) \(trend.unit)" } ?? "–")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Breakdown

enum Breakdown {
    case hourly([TimedValue], unit: String, decimals: Int)
    case heartRate([TimedValue])
    case sleep(SleepNight, bedtime: Date?, wakeTime: Date?, debt: TimeInterval)
    case workouts([WorkoutSummary])

    var title: String {
        switch self {
        case .hourly: "By hour"
        case .heartRate: "Through the day"
        case .sleep: "Last night"
        case .workouts: "Workouts"
        }
    }

    /// Nil when the card has no breakdown, or nothing to show for the day.
    static func load(for kind: CardKind, day: Date, period: TrendPeriod, source: HealthDataSource,
                     calendar: Calendar) async throws -> Breakdown? {
        switch kind.family {
        case .total:
            guard let metric = kind.quantityMetric else { return nil }
            var hours = try await source.hourly(metric, on: day)
            var unit = metric.unit
            if metric == .distance, Locale.current.measurementSystem == .us {
                hours = hours.map { TimedValue(date: $0.date, value: $0.value * 0.621_371) }
                unit = "mi"
            }
            return hours.isEmpty ? nil : .hourly(hours, unit: unit, decimals: metric.decimals)
        case .vital:
            guard kind == .heartRate else { return nil }
            let interval = DateInterval(start: day, end: min(.now, calendar.date(byAdding: .day, value: 1, to: day)!))
            let values = try await source.heartRate(in: interval)
            return values.isEmpty ? nil : .heartRate(values)
        case .sleep:
            let days = 21
            let nights = try await source.sleepNights(days: days)
            guard let night = nights.last(where: { $0.wakeDay == day }), night.asleep > 0 else { return nil }
            let byDay = Dictionary(nights.map { ($0.wakeDay, $0.asleep) }, uniquingKeysWith: { first, _ in first })
            let dayStarts = (0..<days).reversed().map { calendar.date(byAdding: .day, value: -$0, to: day)! }
            let debt = SleepNeed.debt(asleep: dayStarts.map { byDay[$0].flatMap { $0 > 0 ? $0 : nil } }).last ?? 0
            let vitals = try await source.overnight(days: 1).last
            return .sleep(night, bedtime: vitals?.bedtime, wakeTime: vitals?.wakeTime, debt: debt)
        case .training:
            guard kind == .lastWorkout || kind == .weeklyTraining else { return nil }
            let workouts = try await source.workouts(days: period.days)
            return workouts.isEmpty ? nil : .workouts(workouts)
        // TODO(#41, v4, Scores): show how much each input raised or lowered Recovery and Resources.
        // Health status and Health age already list theirs on the card.
        case .score:
            return nil
        }
    }
}

private struct BreakdownView: View {
    let breakdown: Breakdown
    let color: Color

    var body: some View {
        switch breakdown {
        case .hourly(let hours, let unit, let decimals):
            Chart(hours, id: \.date) { hour in
                BarMark(x: .value("Hour", hour.date, unit: .hour), y: .value(unit, hour.value))
                    .foregroundStyle(color)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { AxisValueLabel(format: .dateTime.hour()) } }
            .frame(height: 140)
            let peak = hours.max { $0.value < $1.value }!
            Text("Busiest hour \(peak.date.formatted(.dateTime.hour())): \(peak.value.formatted(.number.precision(.fractionLength(decimals)))) \(unit)")
                .font(.caption).foregroundStyle(.secondary)
        case .heartRate(let values):
            Chart(values, id: \.date) { value in
                LineMark(x: .value("Time", value.date), y: .value("bpm", value.value))
                    .foregroundStyle(color)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { AxisValueLabel(format: .dateTime.hour()) } }
            .frame(height: 160)
        case .sleep(let night, let bedtime, let wakeTime, let debt):
            VStack(spacing: 6) {
                ForEach([SleepStage.deep, .core, .rem, .awake], id: \.self) { stage in
                    if let seconds = night.stages[stage], seconds > 0 {
                        row(stage.title, SnapshotBuilder.hoursMinutes(seconds), dot: stage.color(base: color))
                    }
                }
                if night.unspecified > 0 { row("Asleep, no stages", SnapshotBuilder.hoursMinutes(night.unspecified)) }
                Divider()
                if let bedtime { row("Bedtime", bedtime.formatted(date: .omitted, time: .shortened)) }
                if let wakeTime { row("Woke up", wakeTime.formatted(date: .omitted, time: .shortened)) }
                row("Sleep debt", debt >= 5 * 60 ? SnapshotBuilder.hoursMinutes(debt) : "None")
            }
        case .workouts(let workouts):
            VStack(spacing: 0) {
                ForEach(workouts, id: \.id) { workout in
                    NavigationLink(value: WorkoutRoute(workout: workout)) {
                    HStack(spacing: 10) {
                        Image(systemName: workout.symbol).foregroundStyle(color).frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(workout.name).font(.subheadline)
                            Text(workout.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(SnapshotBuilder.hoursMinutes(workout.duration)).font(.subheadline.weight(.semibold))
                            if let kcal = workout.energyKcal {
                                Text("\(Int(kcal.rounded())) kcal").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if workout.id != workouts.last?.id { Divider() }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, dot: Color? = nil) -> some View {
        HStack(spacing: 8) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }
}
