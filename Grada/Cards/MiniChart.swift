import Charts
import SwiftUI

/// The 7-day chart at the bottom of a card. Today is the last value.
struct MiniChart: View {
    let chart: CardSnapshot.Chart
    let color: Color

    static let plotHeight: CGFloat = 34

    var body: some View {
        switch chart {
        case .none:
            EmptyView()
        case .bars(let values):
            TrackBars(values: values, color: color)
        case .line(let values, let normalRange):
            VStack(spacing: 2) {
                AreaLine(values: values, normalRange: normalRange, color: color)
                    .frame(height: Self.plotHeight)
                WeekdayLabels()
            }
        }
    }
}

/// Bars filled from the bottom of a full-height track, so empty days still read as days.
private struct TrackBars: View {
    let values: [Double?]
    let color: Color

    var body: some View {
        // Headroom above the best day keeps the track visible when days are similar, e.g. sleep.
        let highest = max((values.compactMap { $0 }.max() ?? 0) * 1.2, .leastNonzeroMagnitude)
        let labels = WeekdayLabels.symbols(count: values.count)
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                let isToday = index == values.count - 1
                VStack(spacing: 2) {
                    GeometryReader { proxy in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(.systemFill))
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(color)
                                .frame(height: proxy.size.height * min(max((value ?? 0) / highest, 0), 1))
                        }
                        .frame(width: min(proxy.size.width * 0.55, 14))
                        .frame(maxWidth: .infinity)
                    }
                    .frame(height: MiniChart.plotHeight)
                    WeekdayLabels.label(labels[index], isToday: isToday)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 7 days")
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
