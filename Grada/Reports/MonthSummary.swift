import Foundation

/// A month's averages for a few key metrics, each compared with the month before.
///
/// A change counts only when it's bigger than 0.2 × the spread of the user's own daily values: Hopkins et al.
/// 2009 (Med Sci Sports Exerc 41:3) set 0.2 between-subject SDs as the smallest worthwhile change; applying it
/// to one person's day-to-day SD is Grada's estimate.
nonisolated struct MonthSummary: Equatable {
    enum Metric: CaseIterable {
        case steps, exercise, restingHeartRate, hrv, sleep, vo2Max

        /// The card whose title, symbol and color it borrows.
        var card: CardKind {
            switch self {
            case .steps: .steps
            case .exercise: .exerciseMinutes
            case .restingHeartRate: .restingHeartRate
            case .hrv: .hrv
            case .sleep: .sleepDuration
            case .vo2Max: .vo2Max
            }
        }

        /// Whether a rise is good news; nil when neither way is (more sleep isn't better past the need).
        var higherIsBetter: Bool? {
            switch self {
            case .steps, .exercise, .hrv, .vo2Max: true
            case .restingHeartRate: false
            case .sleep: nil
            }
        }

        /// Days with data a month needs. Step studies ask for 3–5 valid days a week (Hart et al. 2011); no study
        /// sets a monthly minimum, so 14 is Grada's estimate. Watches estimate VO₂ max only after some outdoor
        /// walks and runs, so it needs just 2 readings.
        var minimumDays: Int { self == .vo2Max ? 2 : 14 }
    }

    enum Change: Equatable {
        /// One of the months has too few days with data.
        case unknown
        /// Within the smallest change that matters.
        case steady
        /// The difference from the month before, in the metric's units.
        case changed(Double)
    }

    struct Row: Equatable {
        let metric: Metric
        /// Nil with fewer than `metric.minimumDays` days of data.
        let average: Double?
        let previous: Double?
        /// Days with data this month.
        let days: Int
        let change: Change
    }

    /// The first day of the month.
    let month: Date
    let rows: [Row]

    /// A month's row from its daily values and the month before's. Exercise is per week, the rest per day.
    static func row(_ metric: Metric, current: [Double], previous: [Double]) -> Row {
        let scale = metric == .exercise ? 7.0 : 1.0
        let average = current.count >= metric.minimumDays ? Baseline.average(current).map { $0 * scale } : nil
        let before = previous.count >= metric.minimumDays ? Baseline.average(previous).map { $0 * scale } : nil
        guard let average, let before, let spread = standardDeviation(current + previous) else {
            return Row(metric: metric, average: average, previous: before, days: current.count, change: .unknown)
        }
        let difference = average - before
        let change: Change = abs(difference) > 0.2 * spread * scale ? .changed(difference) : .steady
        return Row(metric: metric, average: average, previous: before, days: current.count, change: change)
    }

    /// The summary of the month holding `day`, up to today (steps and exercise up to yesterday), compared with the
    /// whole month before.
    static func load(month day: Date, source: HealthDataSource, calendar: Calendar, now: Date = .now) async throws -> MonthSummary {
        let month = calendar.dateInterval(of: .month, for: day)!
        let previous = calendar.dateInterval(of: .month, for: month.start.addingTimeInterval(-1))!
        let today = calendar.startOfDay(for: now)
        let days = (calendar.dateComponents([.day], from: previous.start, to: today).day ?? 0) + 1
        guard days > 0 else { return MonthSummary(month: month.start, rows: []) }

        let daily = { (metric: QuantityMetric) in try await source.daily(metric, days: days).compactMap { day in day.value.map { (day.day, $0) } } }
        // Today's steps and exercise are still adding up, so averaging them in would pull the month down.
        let finished = { (metric: QuantityMetric) in try await daily(metric).filter { $0.0 < today } }
        let series: [Metric: [(Date, Double)]] = [
            .steps: try await finished(.steps),
            .exercise: try await finished(.exerciseMinutes),
            .restingHeartRate: try await daily(.restingHeartRate),
            .hrv: try await source.overnight(days: days).compactMap { night in night.hrv.map { (night.wakeDay, $0) } },
            .sleep: try await source.sleepNights(days: days).filter { $0.asleep > 0 }.map { ($0.wakeDay, $0.asleep) },
            .vo2Max: try await daily(.vo2Max),
        ]
        let rows = Metric.allCases.map { metric in
            let values = series[metric] ?? []
            // Not `DateInterval.contains`: it includes the end, which is the next month's first day.
            let inMonth = { (start: Date) in values.filter { calendar.isDate($0.0, equalTo: start, toGranularity: .month) }.map(\.1) }
            return row(metric, current: inMonth(month.start), previous: inMonth(previous.start))
        }
        return MonthSummary(month: month.start, rows: rows)
    }

    /// Sample standard deviation; nil with fewer than two values.
    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count >= 2, let mean = Baseline.average(values) else { return nil }
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1)).squareRoot()
    }
}
