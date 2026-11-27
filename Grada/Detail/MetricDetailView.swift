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
    @State private var trendFailed = false
    @State private var extraTrends: [Trend] = []
    @State private var breakdown: Breakdown?
    @State private var origins: [(kind: DataKind, origins: [DataOrigin])] = []

    private var kind: CardKind { route.kind }
    private var calendar: Calendar { .current }
    private var day: Date { calendar.startOfDay(for: route.day ?? .now) }
    private var source: HealthDataSource { PastDaySource.asOf(day, base: baseSource, calendar: calendar) }
    private var color: Color { kind.category.color }

    private var related: (title: String, kinds: [CardKind]) { kind.related }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CardView(kind: kind, snapshot: snapshot)
                if let recommendation = snapshot?.recommendation {
                    DetailSection(title: String(localized: "Recommendation")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recommendation.text).font(.subheadline.weight(.semibold))
                            Text(recommendation.reason).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if TrendBuilder.hasTrend(kind) {
                    // Above every section it drives: the trends below and the breakdown all follow the period.
                    Picker("Period", selection: $period) {
                        ForEach(TrendPeriod.available(for: kind)) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    trendSection
                }
                ForEach(Array(extraTrends.enumerated()), id: \.offset) { _, extra in
                    DetailSection(title: extra.title ?? String(localized: "Trend")) {
                        VStack(alignment: .leading, spacing: 12) {
                            TrendChart(trend: extra, period: period, color: color, highlighted: route.day.map { _ in day })
                                .frame(height: 160)
                            TrendStats(trend: extra, period: period)
                        }
                    }
                }
                if let breakdown {
                    DetailSection(title: breakdown.title) { BreakdownView(breakdown: breakdown, color: color) }
                }
                DetailSection(title: String(localized: "What it means")) {
                    Text(kind.explanation).font(.subheadline).foregroundStyle(.secondary)
                }
                if !origins.isEmpty {
                    DetailSection(title: String(localized: "Data from")) { OriginsView(origins: origins) }
                }
                if !kind.sources.isEmpty || kind.estimateNote != nil {
                    DetailSection(title: String(localized: "Sources")) { SourcesView(sources: kind.sources, estimateNote: kind.estimateNote) }
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
                Text(MedicalNotice.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(route.day.map { String(localized: "\(kind.title), \($0.formatted(.dateTime.day().month(.abbreviated)))") } ?? kind.title)
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
            let all = (try? await baseSource.origins()) ?? [:]
            origins = kind.dataKinds.compactMap { kind in all[kind].map { (kind, $0) } }
        }
        .task(id: period) {
            var trendBuilder = TrendBuilder(source: source, calendar: calendar)
            trendBuilder.goals = GoalHistory(goalChanges)
            do {
                trend = try await trendBuilder.trend(for: kind, period: period)
                trendFailed = false
            } catch is CancellationError {
                return
            } catch {
                trend = nil
                trendFailed = true
            }
            extraTrends = (try? await trendBuilder.extraTrends(for: kind, period: period)) ?? []
            trendLoaded = true
            breakdown = try? await Breakdown.load(for: kind, day: day, period: period, source: source, calendar: calendar,
                                                  goals: GoalHistory(goalChanges))
        }
    }

    @ViewBuilder
    private var trendSection: some View {
        DetailSection(title: trend?.title ?? String(localized: "Trend")) {
            VStack(alignment: .leading, spacing: 12) {
                if let trend {
                    TrendChart(trend: trend, period: period, color: color, highlighted: route.day.map { _ in day })
                        .frame(height: 200)
                    TrendStats(trend: trend, period: period)
                } else if trendLoaded {
                    // Nil means calibrating or no data yet; the card above says what it needs (#205).
                    Text(trendFailed ? "Couldn't load the trend." : "Not enough data for a trend yet.")
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

/// The studies behind a calculated metric, each opening its paper, then what Grada estimated itself.
struct SourcesView: View {
    let sources: [MetricSource]
    let estimateNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sources, id: \.self) { source in
                VStack(alignment: .leading, spacing: 2) {
                    if let url = source.url {
                        Link(destination: url) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(source.citation).multilineTextAlignment(.leading)
                                Image(systemName: "arrow.up.right").font(.caption2)
                            }
                        }
                        .font(.subheadline)
                    } else {
                        Text(source.citation).font(.subheadline)
                    }
                    Text(source.supports).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let note = estimateNote {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Grada's estimate", systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.orange)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The apps and devices whose data the card used, per kind of data, each with the last day it sent data.
struct OriginsView: View {
    let origins: [(kind: DataKind, origins: [DataOrigin])]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(origins, id: \.kind) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    if origins.count > 1 {
                        Text(entry.kind.title).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(entry.origins, id: \.name) { origin in
                        HStack {
                            Text(origin.name)
                            Spacer()
                            Text(Self.lastDay(origin.lastDay)).foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }

    /// "Today", "Yesterday" or the date; Grada stores data per day, so there's no time to show.
    static func lastDay(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Trend

private struct TrendChart: View {
    let trend: Trend
    let period: TrendPeriod
    let color: Color
    /// The day picked in the calendar, marked on the chart.
    let highlighted: Date?
    @AppStorage(SettingsKey.colorBlindPalette) private var colorBlind = false
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
            ForEach(Array(trend.zones.enumerated()), id: \.offset) { _, zone in
                RectangleMark(yStart: .value("Low", zone.range.lowerBound), yEnd: .value("High", zone.range.upperBound))
                    .foregroundStyle(zone.rating.fill(colorBlind: colorBlind).opacity(0.15))
                    .accessibilityHidden(true)
            }
            if let range = trend.normalRange {
                ForEach(trend.points) { point in
                    AreaMark(x: .value("Day", point.date, unit: unit),
                             yStart: .value("Low", range.lowerBound), yEnd: .value("High", range.upperBound),
                             series: .value("Series", "Normal range"))
                        .foregroundStyle(color.opacity(0.12))
                        .accessibilityHidden(true)
                }
            }
            ForEach(trend.points) { point in
                if let value = point.value {
                    switch trend.style {
                    case .bars:
                        BarMark(x: .value("Day", point.date, unit: unit), y: .value("Value", value))
                            // Rated bars stay at full color so they match the card's bars.
                            .foregroundStyle(point.rating?.fill(colorBlind: colorBlind) ?? color.opacity(opacity(point)))
                            .accessibilityLabel(pointLabel(point))
                            .accessibilityValue(pointValue(point, value))
                    case .line:
                        LineMark(x: .value("Day", point.date, unit: unit), y: .value("Value", value),
                                 series: .value("Series", "Value"))
                            .foregroundStyle(color)
                            .interpolationMethod(.monotone)
                            .accessibilityLabel(pointLabel(point))
                            .accessibilityValue(pointValue(point, value))
                        if period != .year {
                            PointMark(x: .value("Day", point.date, unit: unit), y: .value("Value", value))
                                .foregroundStyle(color)
                                .symbolSize(isEmphasized(point) ? 60 : 16)
                                .accessibilityHidden(true)
                        }
                    case .sleep:
                        ForEach([SleepStage.deep, .core, .rem], id: \.self) { stage in
                            BarMark(x: .value("Day", point.date, unit: unit), y: .value("Hours", point.stages[stage] ?? 0))
                                .foregroundStyle(stage.color)
                                .accessibilityLabel(pointLabel(point) + ", " + stage.title)
                                .accessibilityValue(SnapshotBuilder.hoursMinutes((point.stages[stage] ?? 0) * 3600))
                        }
                    }
                }
            }
            ForEach(trend.points) { point in
                if let goal = point.goal {
                    LineMark(x: .value("Day", point.date, unit: unit), y: .value("Goal", goal), series: .value("Series", "Goal"))
                        .foregroundStyle(DayRating.good.fill(colorBlind: colorBlind))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .interpolationMethod(.stepEnd)
                        .accessibilityHidden(true)
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            if point.id == trend.points.first?.id {
                                Text("Goal").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                }
            }
            ForEach(trend.points) { point in
                if let average = point.movingAverage {
                    LineMark(x: .value("Day", point.date, unit: unit), y: .value("Average", average),
                             series: .value("Series", "Moving average"))
                        .foregroundStyle(.gray)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .interpolationMethod(.monotone)
                        .accessibilityHidden(true)
                        .annotation(position: .top, alignment: .trailing, spacing: 4) {
                            if point.id == trend.points.last(where: { $0.movingAverage != nil })?.id {
                                Text(period.isWeekly ? String(localized: "4-week avg") : String(localized: "7-day avg"))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                }
            }
            if let highlightedDate {
                RuleMark(x: .value("Shown day", highlightedDate, unit: unit))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
            }
            if let point = selectedPoint, let value = point.value {
                RuleMark(x: .value("Selected", point.date, unit: unit))
                    .foregroundStyle(.primary.opacity(0.4))
                    .accessibilityHidden(true)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 0) {
                            Text("\(trend.formatted(value)) \(trend.unit)").font(.caption.weight(.semibold))
                            Text(pointLabel(point))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .chartXSelection(value: $selection)
        .chartYScale(domain: .automatic(includesZero: trend.style != .line))
    }

    /// The point's day or week, with "so far" while it is still adding up.
    private func pointLabel(_ point: TrendPoint) -> String {
        point.isPartial
            ? String(localized: "\(label(point.date)) · so far", comment: "Trend chart label for today's or this week's unfinished total, e.g. Tue 25 Nov · so far")
            : label(point.date)
    }

    /// What VoiceOver reads for a point: its value with unit, and its rating, which the bar shows only by color (#207).
    private func pointValue(_ point: TrendPoint, _ value: Double) -> String {
        let text = "\(trend.formatted(value)) \(trend.unit)".trimmingCharacters(in: .whitespaces)
        return point.rating.map { "\(text), \($0.title)" } ?? text
    }

    /// Today's unfinished total is drawn faint, so it doesn't read as a low day.
    private func opacity(_ point: TrendPoint) -> Double {
        if point.isPartial { return 0.3 }
        return isEmphasized(point) ? 1 : 0.6
    }

    private func isEmphasized(_ point: TrendPoint) -> Bool {
        guard let highlightedDate else { return point.id == trend.points.last?.id }
        return point.date == highlightedDate
    }

    private func label(_ date: Date) -> String {
        period.isWeekly
            ? String(localized: "Week of \(date.formatted(.dateTime.day().month(.abbreviated)))")
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

private struct TrendStats: View {
    let trend: Trend
    let period: TrendPeriod

    var body: some View {
        HStack {
            stat(period.isWeekly && !trend.statsArePerPoint ? "Daily avg" : "Average", trend.average)
            stat("Low", trend.low)
            stat("High", trend.high)
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: Double?) -> some View {
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
    /// `title` names the night as the card does: last night, the night before on a past day, or yesterday's (#206).
    case sleep(SleepNight, title: String, bedtime: Date?, wakeTime: Date?, debt: TimeInterval)
    case workouts([WorkoutSummary])
    /// Each Recovery input against its threshold.
    case recovery([Recovery.Check])
    /// Resources at midnight and now (the end of a past day, labelled by `nowLabel`), and what moved it in between.
    case resources(midnight: Double, now: Double, amounts: [Resources.Cause: Double], nowLabel: String)
    /// The period's daily cuff readings, newest first, each in its ACC/AHA category's color (#135).
    case bloodPressure([(day: Date, systolic: Double, diastolic: Double)])

    var title: String {
        switch self {
        case .hourly: String(localized: "By hour")
        case .heartRate: String(localized: "Through the day")
        case .sleep(_, let title, _, _, _): title
        case .workouts: String(localized: "Workouts")
        case .recovery: String(localized: "Inputs")
        case .resources: String(localized: "Since midnight")
        case .bloodPressure: String(localized: "Readings")
        }
    }

    /// Nil when the card has no breakdown, or nothing to show for the day.
    static func load(for kind: CardKind, day: Date, period: TrendPeriod, source: HealthDataSource,
                     calendar: Calendar, goals: GoalHistory = GoalHistory()) async throws -> Breakdown? {
        switch kind.family {
        case .total:
            guard let metric = kind.quantityMetric else { return nil }
            var hours = try await source.hourly(metric, on: day)
            var unit = metric.unit
            if metric == .distance, Locale.current.measurementSystem == .us {
                hours = hours.map { TimedValue(date: $0.date, value: $0.value * 0.621_371) }
                unit = String(localized: "mi", comment: "Unit: miles")
            }
            return hours.isEmpty ? nil : .hourly(hours, unit: unit, decimals: metric.decimals)
        case .vital where kind == .bloodPressure:
            let readings = BloodPressure.readings(systolic: try await source.daily(.bloodPressureSystolic, days: period.days),
                                                  diastolic: try await source.daily(.bloodPressureDiastolic, days: period.days))
            return readings.isEmpty ? nil : .bloodPressure(readings.reversed())
        case .vital:
            guard kind == .heartRate else { return nil }
            let interval = DateInterval(start: day, end: min(.now, calendar.date(byAdding: .day, value: 1, to: day)!))
            let values = try await source.heartRate(in: interval)
            return values.isEmpty ? nil : .heartRate(values)
        case .sleep:
            var builder = SnapshotBuilder.forDay(day, source: source, calendar: calendar)
            builder.goals = goals
            // The card's night: the shown day's, or yesterday's until it arrives.
            let nights = try await source.sleepNights(days: 2)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: day)!
            let shown: (night: SleepNight, title: String, index: Int)
            if let night = nights.last(where: { $0.wakeDay == day && $0.asleep > 0 }) {
                shown = (night, builder.lastNightLabel, 1)
            } else if let night = nights.last(where: { $0.wakeDay == yesterday && $0.asleep > 0 }) {
                shown = (night, builder.yesterdayLabel, 0)
            } else {
                return nil
            }
            let debts = try await builder.sleepDebt(2)
            let debt = debts.flatMap { $0.indices.contains(shown.index) ? $0[shown.index].debt : nil } ?? 0
            let vitals = try await source.overnight(days: 2).last { $0.wakeDay == shown.night.wakeDay }
            return .sleep(shown.night, title: shown.title, bedtime: vitals?.bedtime, wakeTime: vitals?.wakeTime, debt: debt)
        case .training:
            guard kind == .lastWorkout || kind == .weeklyTraining else { return nil }
            let workouts = try await source.workouts(days: period.days)
            return workouts.isEmpty ? nil : .workouts(workouts)
        case .score:
            let builder = SnapshotBuilder.forDay(day, source: source, calendar: calendar)
            switch kind {
            case .recovery:
                // The same night the card shows: today's, or yesterday's until today's arrives.
                let days = try await builder.recoveryDays(2)
                let checks = (days.last?.hasData == true ? days.last : days.first)?.checks ?? []
                return checks.isEmpty ? nil : .recovery(checks)
            case .resources:
                return try await builder.resourcesContributions().map {
                    .resources(midnight: $0.midnight, now: $0.now, amounts: $0.amounts, nowLabel: builder.nowLabel)
                }
            default:
                return nil
            }
        }
    }
}

private struct BreakdownView: View {
    let breakdown: Breakdown
    let color: Color
    @AppStorage(SettingsKey.colorBlindPalette) private var colorBlind = false

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
        case .sleep(let night, _, let bedtime, let wakeTime, let debt):
            VStack(spacing: 6) {
                ForEach([SleepStage.deep, .core, .rem, .awake], id: \.self) { stage in
                    if let seconds = night.stages[stage], seconds > 0 {
                        row(stage.title, SnapshotBuilder.hoursMinutes(seconds), dot: stage.color)
                    }
                }
                if night.unspecified > 0 { row(String(localized: "Asleep, no stages"), SnapshotBuilder.hoursMinutes(night.unspecified)) }
                Divider()
                if let bedtime { row(String(localized: "Bedtime"), bedtime.formatted(date: .omitted, time: .shortened)) }
                if let wakeTime { row(String(localized: "Woke up"), wakeTime.formatted(date: .omitted, time: .shortened)) }
                row(String(localized: "Sleep debt"), debt >= 5 * 60 ? SnapshotBuilder.hoursMinutes(debt) : String(localized: "None"))
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
        case .recovery(let checks):
            VStack(spacing: 6) {
                ForEach(checks, id: \.name) { check in
                    let rating: DayRating = check.isOff ? .poor : .good
                    HStack(spacing: 8) {
                        Circle().fill(rating.fill(colorBlind: colorBlind)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.name).font(.subheadline)
                            Text("\(check.isOff ? check.reason : String(localized: "Within threshold")) · \(check.higherIsBetter ? "≥" : "≤") \(Self.recoveryValue(check.limit, check, decimals: Self.decimals(check)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Self.recoveryValue(check.value, check, decimals: Self.decimals(check))).font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(rating.text(colorBlind: colorBlind))
                    }
                }
            }
        case .bloodPressure(let readings):
            VStack(spacing: 6) {
                ForEach(readings, id: \.day) { reading in
                    let category = BloodPressure.Category(systolic: reading.systolic, diastolic: reading.diastolic)
                    HStack(spacing: 8) {
                        Circle().fill(category.rating.fill(colorBlind: colorBlind)).frame(width: 8, height: 8)
                        Text(reading.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text(category.title).font(.caption).foregroundStyle(.secondary)
                        Text("\(BloodPressure.reading(systolic: reading.systolic, diastolic: reading.diastolic)) \(BloodPressure.unit)")
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(category.rating.text(colorBlind: colorBlind))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        case .resources(let midnight, let now, let amounts, let nowLabel):
            VStack(spacing: 6) {
                row(String(localized: "At midnight"), "\(Int(midnight.rounded()))%")
                Divider()
                ForEach(Resources.Cause.allCases, id: \.self) { cause in
                    if let amount = amounts[cause], abs(amount) >= 0.5 {
                        HStack {
                            Text(cause.title).font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Text(amount.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always())))
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(amount > 0 ? DayRating.good.text(colorBlind: colorBlind) : .orange)
                        }
                    }
                }
                Divider()
                row(nowLabel, "\(Int(now.rounded()))%")
            }
        }
    }

    /// A Recovery input or its threshold in the input's own unit.
    private static func recoveryValue(_ value: Double, _ check: Recovery.Check, decimals: Int) -> String {
        let number = value.formatted(.number.precision(.fractionLength(decimals)))
        switch check.kind {
        case .sleep: return SnapshotBuilder.hoursMinutes(value)
        case .breathing: return "\(number) \(QuantityMetric.respiratoryRate.unit)"
        case .hrv: return "\(number) \(QuantityMetric.hrv.unit)"
        case .restingHeartRate: return "\(number) \(QuantityMetric.restingHeartRate.unit)"
        }
    }

    /// Whole numbers, or one decimal more when the value and its threshold would otherwise read the same,
    /// so an input flagged off never looks equal to its limit.
    private static func decimals(_ check: Recovery.Check) -> Int {
        let base = check.kind == .breathing ? 1 : 0
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(base))
        return check.value.formatted(style) == check.limit.formatted(style) ? base + 1 : base
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
