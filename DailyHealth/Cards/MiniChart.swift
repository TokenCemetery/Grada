import Charts
import SwiftUI

/// The 7-day chart at the bottom of a card. Today is the last, highlighted value.
struct MiniChart: View {
    let chart: CardSnapshot.Chart
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            plot.frame(height: 34)
            WeekdayLabels()
        }
    }

    @ViewBuilder
    private var plot: some View {
        switch chart {
        case .none:
            EmptyView()
        case .bars(let values):
            Chart(Array(values.enumerated()), id: \.offset) { index, value in
                // A category axis, so each day gets an equal slot for `.ratio` widths.
                BarMark(x: .value("Day", String(index)), y: .value("Value", value ?? 0), width: .ratio(0.6))
                    .foregroundStyle(index == values.count - 1 ? color : color.opacity(0.3))
                    .cornerRadius(2)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        case .line(let values, let normalRange):
            let points = values.enumerated().compactMap { index, value in value.map { (index, $0) } }
            Chart {
                if let normalRange {
                    RectangleMark(
                        xStart: .value("Start", -0.5), xEnd: .value("End", Double(values.count) - 0.5),
                        yStart: .value("Low", normalRange.lowerBound), yEnd: .value("High", normalRange.upperBound)
                    )
                    .foregroundStyle(color.opacity(0.12))
                }
                ForEach(points, id: \.0) { index, value in
                    LineMark(x: .value("Day", Double(index)), y: .value("Value", value))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
                if let last = points.last, last.0 == values.count - 1 {
                    PointMark(x: .value("Day", Double(last.0)), y: .value("Value", last.1))
                        .foregroundStyle(color)
                        .symbolSize(24)
                }
            }
            .chartXScale(domain: -0.5...Double(values.count) - 0.5)
            .chartYScale(domain: Self.domain(points.map(\.1), normalRange))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
    }

    private static func domain(_ values: [Double], _ range: ClosedRange<Double>?) -> ClosedRange<Double> {
        let all = values + (range.map { [$0.lowerBound, $0.upperBound] } ?? [])
        guard let low = all.min(), let high = all.max() else { return 0...1 }
        let padding = max((high - low) * 0.15, 0.5)
        return (low - padding)...(high + padding)
    }
}

/// Single-letter weekdays for the last 7 days, today last and bold.
struct WeekdayLabels: View {
    private let days: [String] = {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let today = calendar.startOfDay(for: .now)
        return (0..<7).reversed().map {
            let day = calendar.date(byAdding: .day, value: -$0, to: today)!
            return symbols[calendar.component(.weekday, from: day) - 1]
        }
    }()

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                Text(day)
                    .font(.caption2.weight(index == days.count - 1 ? .bold : .regular))
                    .foregroundStyle(index == days.count - 1 ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
