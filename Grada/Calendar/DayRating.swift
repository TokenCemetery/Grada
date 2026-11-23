import SwiftUI

nonisolated extension DayRating {
    var title: String {
        switch self {
        case .good: String(localized: "Good")
        case .fair: String(localized: "Fair")
        case .poor: String(localized: "Poor")
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

    /// Text and the workout dot drawn on top of `fill`.
    func foreground(colorBlind: Bool) -> Color {
        switch (self, colorBlind) {
        case (.good, false), (.fair, false), (.fair, true): .black
        case (.poor, false), (.good, true): .white
        case (.poor, true): Color(.systemBackground)
        }
    }
}

/// What the calendar shows: how days are drawn and which cards a day's sheet holds.
nonisolated enum CalendarMetric: String, CaseIterable, Identifiable {
    /// Vitals against their normal range.
    case health
    /// The recovery score, which already covers sleep.
    case recovery
    /// Steps against the day's Steps goal (#192).
    case activity
    /// Logged periods and cycle days from Apple Health, with sleeping wrist temperature (#137). Only with Female as
    /// the profile's sex.
    case cycle

    var id: String { rawValue }

    /// Also reads the metrics and types the calendar had before, so a saved choice lands on its new type.
    init?(rawValue: String) {
        switch rawValue {
        case "health", "healthStatus", "hrv", "restingHeartRate": self = .health
        case "recovery", "sleep": self = .recovery
        case "activity", "training", "steps": self = .activity
        case "cycle": self = .cycle
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .health: String(localized: "Health")
        case .recovery: String(localized: "Recovery")
        case .activity: String(localized: "Activity")
        case .cycle: String(localized: "Cycle", comment: "Calendar type: the menstrual cycle")
        }
    }

    /// Health, Recovery and Activity colour days red, yellow or green; Cycle draws period days.
    var isRated: Bool { self != .cycle }

    /// The day sheet's cards, in order. Activity adds the day's workouts on top; Cycle shows only the day's flow and cycle day.
    var kinds: [CardKind] {
        switch self {
        case .health: [.healthStatus, .hrvStatus, .heartRate, .oxygenSaturation, .respiratoryRate, .wristTemperature]
        case .recovery: [.recovery, .resources, .sleepStages, .sleepNeed, .sleepConsistency]
        case .activity: [.steps, .activeEnergy, .intensityMinutes, .distance, .weeklyTraining, .vo2Max]
        case .cycle: []
        }
    }
}

/// The rules behind the calendar colours. All thresholds are starting points to tune with real data.
nonisolated enum DayRatings {
    /// Used only without a goal for the day. Sleep otherwise follows each night's Sleep need.
    static let stepsGoal = 10_000.0
    static let sleepGoal = SleepNeed.baseline

    /// Goal metrics: green from 100% of the goal, yellow from 70%, red below.
    static func goal(_ value: Double, goal: Double) -> DayRating {
        let share = value / goal
        if share >= 1 { return .good }
        return share >= 0.7 ? .fair : .poor
    }

    /// Activity days: steps against the Steps goal in effect that day, or `stepsGoal` without one. Days without steps
    /// get no rating, and neither does `today` until its goal is reached, so a day under way doesn't read as poor.
    static func rateSteps(_ series: [DayValue], goals: GoalHistory, today: Date) -> [Date: DayRating] {
        var ratings: [Date: DayRating] = [:]
        for entry in series {
            guard let steps = entry.value else { continue }
            let rating = goal(steps, goal: goals.value(.steps, on: entry.day) ?? stepsGoal)
            if entry.day < today || rating == .good { ratings[entry.day] = rating }
        }
        return ratings
    }

    /// Range metrics: green inside the normal range or past it on the healthy side. Yellow when off by
    /// less than half the range's half-width ("slightly"), red beyond that ("well").
    static func range(_ value: Double, normal: ClosedRange<Double>, higherIsBetter: Bool) -> DayRating {
        let miss = higherIsBetter ? normal.lowerBound - value : value - normal.upperBound
        if miss <= 0 { return .good }
        return miss < slightMiss(normal) ? .fair : .poor
    }

    /// Health status vitals, where either direction counts: green inside the normal range, yellow when
    /// slightly outside it, red when well outside.
    static func vital(_ value: Double, normal: ClosedRange<Double>) -> DayRating {
        let miss = max(normal.lowerBound - value, value - normal.upperBound)
        if miss <= 0 { return .good }
        return miss < slightMiss(normal) ? .fair : .poor
    }

    /// How far past the normal range still counts as "slightly" off: half the range's half-width.
    static func slightMiss(_ normal: ClosedRange<Double>) -> Double {
        (normal.upperBound - normal.lowerBound) / 4
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
