import SwiftUI

/// How good a day was for one metric; drives the calendar's day colours.
nonisolated enum DayRating: CaseIterable {
    case good, fair, poor

    var title: String {
        switch self {
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Poor"
        }
    }

    func fill(colorBlind: Bool) -> Color {
        switch (self, colorBlind) {
        case (.good, false): .green
        case (.fair, false): .yellow
        case (.poor, false): .red
        case (.good, true): .blue
        case (.fair, true): .orange
        case (.poor, true): .primary
        }
    }

    /// A card value in this rating's color. Yellow text is unreadable on a light card, so fair is orange.
    func text(colorBlind: Bool) -> Color {
        switch (self, colorBlind) {
        case (.good, false): .green
        case (.fair, _): .orange
        case (.poor, false): .red
        case (.good, true): .blue
        case (.poor, true): .primary
        }
    }

    /// Text and the workout dot drawn on top of `fill`.
    func foreground(colorBlind: Bool) -> Color {
        switch (self, colorBlind) {
        case (.good, false), (.fair, false), (.fair, true): .black
        case (.poor, false), (.good, true): .white
        case (.poor, true): Color(.systemBackground)
        }
    }
}

/// Metrics the calendar can colour days by.
nonisolated enum CalendarMetric: String, CaseIterable, Identifiable {
    case healthStatus, sleep, steps, hrv, restingHeartRate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .healthStatus: "Health status"
        case .sleep: "Sleep"
        case .steps: "Steps"
        case .hrv: "HRV"
        case .restingHeartRate: "RHR"
        }
    }
}

/// The rules behind the calendar colours. All thresholds are starting points to tune with real data.
nonisolated enum DayRatings {
    /// Used only before the user has goals. Sleep otherwise follows each night's Sleep need.
    static let stepsGoal = 10_000.0
    static let sleepGoal = SleepNeed.baseline

    /// Goal metrics: green from 100% of the goal, yellow from 70%, red below.
    static func goal(_ value: Double, goal: Double) -> DayRating {
        let share = value / goal
        if share >= 1 { return .good }
        return share >= 0.7 ? .fair : .poor
    }

    /// Range metrics: green inside the normal range or past it on the healthy side. Yellow when off by
    /// less than half the range's half-width ("slightly"), red beyond that ("well").
    static func range(_ value: Double, normal: ClosedRange<Double>, higherIsBetter: Bool) -> DayRating {
        let miss = higherIsBetter ? normal.lowerBound - value : value - normal.upperBound
        if miss <= 0 { return .good }
        let halfWidth = (normal.upperBound - normal.lowerBound) / 2
        return miss < halfWidth / 2 ? .fair : .poor
    }

    /// Green with every measured vital in range, yellow with one out, red with two or more.
    static func healthStatus(outOfRange: Int) -> DayRating {
        switch outOfRange {
        case 0: .good
        case 1: .fair
        default: .poor
        }
    }

    /// Rates each day of `series` (oldest first) against the `baselineDays` before it, like the cards do.
    /// Days without a value, or still calibrating, get no rating.
    static func rateVital(_ series: [DayValue], metric: QuantityMetric, higherIsBetter: Bool,
                          baselineDays: Int) -> [Date: DayRating] {
        var ratings: [Date: DayRating] = [:]
        for (index, entry) in series.enumerated() {
            guard let value = entry.value, let normal = normalRange(series, before: index, metric, baselineDays) else { continue }
            ratings[entry.day] = range(value, normal: normal, higherIsBetter: higherIsBetter)
        }
        return ratings
    }

    /// `series` holds one aligned series per vital (same days, oldest first). A day needs at least one
    /// vital measured against a finished baseline; vitals still calibrating don't count.
    static func rateHealthStatus(_ series: [QuantityMetric: [DayValue]], baselineDays: Int) -> [Date: DayRating] {
        guard let days = series.values.first?.map(\.day) else { return [:] }
        var ratings: [Date: DayRating] = [:]
        for index in days.indices {
            var measured = 0, outOfRange = 0
            for (metric, values) in series {
                guard let value = values[index].value,
                      let normal = normalRange(values, before: index, metric, baselineDays) else { continue }
                measured += 1
                if !normal.contains(value) { outOfRange += 1 }
            }
            if measured > 0 { ratings[days[index]] = healthStatus(outOfRange: outOfRange) }
        }
        return ratings
    }

    private static func normalRange(_ series: [DayValue], before index: Int, _ metric: QuantityMetric,
                                    _ baselineDays: Int) -> ClosedRange<Double>? {
        let history = series[max(0, index - baselineDays)..<index].compactMap(\.value)
        return Baseline.normalRange(history: history, minimumHalfWidth: metric.minimumHalfWidth)
    }
}
