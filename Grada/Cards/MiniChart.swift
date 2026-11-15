import Charts
import SwiftUI

/// The 7-day chart at the bottom of a card. Today is the last value.
struct MiniChart: View {
    let chart: CardSnapshot.Chart
    let color: Color
    @AppStorage("colorBlindPalette") private var colorBlind = false

    static let plotHeight: CGFloat = 34

    var body: some View {
        switch chart {
        case .none:
            EmptyView()
        case .bars(let values, let target, let ratings):
            TrackBars(days: values.indices.map { index in
                [(values[index] ?? 0, ratings?[index]?.fill(colorBlind: colorBlind) ?? color)]
            }, target: target)
        case .sleep(let nights, let target):
            TrackBars(days: nights.map { night in
                SleepStage.chartOrder.map { stage in ((night?.hours(in: stage) ?? 0), stage.color(base: color)) }
            }, target: target)
        case .line(let values, let normalRange):
            VStack(spacing: 2) {
                AreaLine(values: values, normalRange: normalRange, color: color)
                    .frame(height: Self.plotHeight)
                WeekdayLabels()
            }
        case .progress(let value, let goal, let isAverage):
            GoalBar(share: goal > 0 ? value / goal : 0, isAverage: isAverage, color: color)
        case .range(let value, let normalRange):
            RangeBar(value: value, normalRange: normalRange, color: color)
        case .zones(let value, let bounds):
            ZoneBar(value: value, bounds: bounds, colorBlind: colorBlind)
        case .intraday(let points, let domain):
            VStack(spacing: 2) {
                DayLine(points: points, domain: domain, color: color)
                    .frame(height: Self.plotHeight)
                HStack {
                    Text("0:00")
                    Spacer()
                    Text("24:00")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Today so far on a midnight-to-midnight axis, with a soft fill below the line.
private struct DayLine: View {
    let points: [(hour: Double, value: Double)]
    let domain: ClosedRange<Double>?
    let color: Color

    var body: some View {
        let values = points.map(\.value)
        let yDomain = domain ?? ((values.min() ?? 0) - 5)...((values.max() ?? 1) + 5)
        let fill = LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Hour", point.hour), yStart: .value("Base", yDomain.lowerBound), yEnd: .value("Value", point.value))
                    .foregroundStyle(fill)
                LineMark(x: .value("Hour", point.hour), y: .value("Value", point.value), series: .value("Part", "Today"))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            // The rest of the day as a dotted line from the latest value, like Suunto.
            if let last = points.last, last.hour < 24 {
                ForEach([last.hour, 24], id: \.self) { hour in
                    LineMark(x: .value("Hour", hour), y: .value("Value", last.value), series: .value("Part", "Rest"))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today")
    }
}

/// Progress toward a goal on a full-width track, with ticks every 10% and 0% and 100% marks below.
private struct GoalBar: View {
    let share: Double
    /// Measured against the 7-day average rather than a goal.
    let isAverage: Bool
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Spacer(minLength: 0)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemFill))
                    Capsule().fill(color).frame(width: proxy.size.width * min(max(share, 0), 1))
                }
            }
            .frame(height: 8)
            HStack(alignment: .top, spacing: 0) {
                ForEach(0...10, id: \.self) { tick in
                    Rectangle().frame(width: 1, height: tick % 5 == 0 ? 5 : 3)
                    if tick < 10 { Spacer(minLength: 0) }
                }
            }
            .foregroundStyle(.tertiary)
            HStack {
                Text("0%")
                Spacer()
                Text(isAverage ? "7-day avg" : "100%")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(height: MiniChart.plotHeight + 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int((share * 100).rounded()))% of \(isAverage ? "7-day average" : "goal")")
    }
}

/// A value as a marker on a track split into fitness zones: Poor red, Fair yellow, Good to Superior
/// in deepening greens. The zone edges are labelled underneath, like Suunto's VO₂max card.
private struct ZoneBar: View {
    let value: Double
    /// Lower bounds of zones 2–5.
    let bounds: [Double]
    let colorBlind: Bool

    var body: some View {
        let domain = Self.domain(value, bounds)
        let edges = [domain.lowerBound] + bounds + [domain.upperBound]
        let good = DayRating.good.fill(colorBlind: colorBlind)
        let colors = [DayRating.poor.fill(colorBlind: colorBlind), DayRating.fair.fill(colorBlind: colorBlind),
                      good.opacity(0.55), good.opacity(0.78), good]
        VStack(spacing: 2) {
            Spacer(minLength: 0)
            GeometryReader { proxy in
                let width = proxy.size.width
                let x = { (v: Double) in width * (v - domain.lowerBound) / (domain.upperBound - domain.lowerBound) }
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(colors.indices, id: \.self) { index in
                            colors[index].frame(width: max(x(edges[index + 1]) - x(edges[index]) - 2, 0), height: 8)
                        }
                    }
                    .clipShape(Capsule())
                    Capsule().fill(Color.primary)
                        .frame(width: 4, height: 18)
                        .offset(x: min(max(x(value) - 2, 0), width - 4))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
            GeometryReader { proxy in
                let width = proxy.size.width
                ForEach(bounds, id: \.self) { bound in
                    Text(bound.formatted(.number.precision(.fractionLength(0))))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: width * (bound - domain.lowerBound) / (domain.upperBound - domain.lowerBound), y: 6)
                }
            }
            .frame(height: 12)
        }
        .frame(height: MiniChart.plotHeight + 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VO2MaxZones.zone(value, bounds: bounds).word)
    }

    /// Poor and Superior get a third of the inner zones' span each, widened to fit a value beyond them.
    private static func domain(_ value: Double, _ bounds: [Double]) -> ClosedRange<Double> {
        let outer = ((bounds.last ?? 1) - (bounds.first ?? 0)) / 3
        return min(value - 1, (bounds.first ?? 0) - outer)...max(value + 1, (bounds.last ?? 1) + outer)
    }
}

/// Today's value as a marker on a track, with the personal normal range shaded.
private struct RangeBar: View {
    let value: Double
    let normalRange: ClosedRange<Double>
    let color: Color

    var body: some View {
        let domain = Self.domain(value, normalRange)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            GeometryReader { proxy in
                let width = proxy.size.width
                let x = { (v: Double) in width * (v - domain.lowerBound) / (domain.upperBound - domain.lowerBound) }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemFill)).frame(height: 8)
                    Rectangle().fill(color.opacity(0.35))
                        .frame(width: x(normalRange.upperBound) - x(normalRange.lowerBound), height: 8)
                        .offset(x: x(normalRange.lowerBound))
                    Capsule().fill(Color.primary)
                        .frame(width: 4, height: 18)
                        .offset(x: min(max(x(value) - 2, 0), width - 4))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
        }
        .frame(height: MiniChart.plotHeight + 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(normalRange.contains(value) ? "In your normal range"
            : value > normalRange.upperBound ? "Above your normal range" : "Below your normal range")
    }

    /// The normal range fills the middle half of the track, widened to fit a value outside it.
    private static func domain(_ value: Double, _ range: ClosedRange<Double>) -> ClosedRange<Double> {
        let margin = max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude) / 2
        return min(value - margin / 4, range.lowerBound - margin)...max(value + margin / 4, range.upperBound + margin)
    }
}

/// Bars filled from the bottom of a full-height track, so empty days still read as days.
/// Each day can stack several segments, listed bottom to top.
private struct TrackBars: View {
    let days: [[(value: Double, color: Color)]]
    /// A full bar means the target was reached; days above it are cut off at the top of the track.
    var target: Double?

    var body: some View {
        let totals = days.map { $0.reduce(0) { $0 + max($1.value, 0) } }
        // Headroom above the best day keeps the track visible when days are similar, e.g. sleep.
        let highest = max(target ?? (totals.max() ?? 0) * 1.2, .leastNonzeroMagnitude)
        let labels = WeekdayLabels.symbols(count: days.count)
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, segments in
                VStack(spacing: 2) {
                    GeometryReader { proxy in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(.systemFill))
                            VStack(spacing: 0) {
                                ForEach(Array(segments.enumerated().reversed()), id: \.offset) { _, segment in
                                    // White underneath makes translucent shades lighter in dark mode too.
                                    segment.color.background(Color.white)
                                        .frame(height: proxy.size.height * max(segment.value, 0) / highest)
                                }
                            }
                            .frame(height: proxy.size.height, alignment: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                        .frame(width: min(proxy.size.width * 0.55, 14))
                        .frame(maxWidth: .infinity)
                    }
                    .frame(height: MiniChart.plotHeight)
                    WeekdayLabels.label(labels[index], isToday: index == days.count - 1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 7 days")
    }
}

extension SleepStage {
    /// Bottom to top in sleep bars, left to right in the stage legend.
    static let chartOrder: [SleepStage] = [.deep, .core, .rem, .awake]

    var title: String {
        switch self {
        case .deep: "Deep"
        case .core: "Core"
        case .rem: "REM"
        case .awake: "Awake"
        }
    }

    /// Asleep stages are shades of the sleep color; awake stands out, as in Suunto.
    func color(base: Color) -> Color {
        switch self {
        case .deep: base
        case .core: base.opacity(0.65)
        case .rem: base.opacity(0.4)
        case .awake: .orange
        }
    }
}

extension SleepNight {
    /// Hours in a stage. Sleep without stage detail is drawn as core.
    func hours(in stage: SleepStage) -> Double {
        ((stages[stage] ?? 0) + (stage == .core ? unspecified : 0)) / 3600
    }
}

/// A line with a soft fill below it; dotted lines mark the personal normal range.
private struct AreaLine: View {
    let values: [Double?]
    let normalRange: ClosedRange<Double>?
    let color: Color

    var body: some View {
        let points = values.enumerated().compactMap { index, value in value.map { (Double(index), $0) } }
        let domain = Self.domain(points.map(\.1), normalRange)
        let fill = LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
        Chart {
            ForEach(points, id: \.0) { day, value in
                AreaMark(x: .value("Day", day), yStart: .value("Base", domain.lowerBound), yEnd: .value("Value", value))
                    .foregroundStyle(fill)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", day), y: .value("Value", value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if let normalRange {
                ForEach([normalRange.lowerBound, normalRange.upperBound], id: \.self) { bound in
                    RuleMark(y: .value("Normal", bound))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
            if let last = points.last, Int(last.0) == values.count - 1 {
                PointMark(x: .value("Day", last.0), y: .value("Value", last.1))
                    .foregroundStyle(color)
                    .symbolSize(30)
            }
        }
        .chartXScale(domain: -0.5...Double(values.count) - 0.5)
        .chartYScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    /// Leaves room above and below so the line doesn't hug the card edges.
    private static func domain(_ values: [Double], _ range: ClosedRange<Double>?) -> ClosedRange<Double> {
        let all = values + (range.map { [$0.lowerBound, $0.upperBound] } ?? [])
        guard let low = all.min(), let high = all.max() else { return 0...1 }
        let padding = max((high - low) * 0.25, 0.5)
        return (low - padding)...(high + padding)
    }
}

/// Single-letter weekdays for the last 7 days, today last and bold.
struct WeekdayLabels: View {
    var body: some View {
        let symbols = Self.symbols(count: 7)
        HStack(spacing: 0) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                Self.label(symbol, isToday: index == symbols.count - 1)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    static func label(_ symbol: String, isToday: Bool) -> some View {
        Text(symbol)
            .font(.caption2.weight(isToday ? .bold : .regular))
            .foregroundStyle(isToday ? .primary : .secondary)
    }

    /// Weekday letters for the last `count` days, oldest first.
    static func symbols(count: Int) -> [String] {
        let calendar = Calendar.current
        let letters = calendar.veryShortStandaloneWeekdaySymbols
        let today = calendar.startOfDay(for: .now)
        return (0..<count).reversed().map {
            let day = calendar.date(byAdding: .day, value: -$0, to: today)!
            return letters[calendar.component(.weekday, from: day) - 1]
        }
    }
}
