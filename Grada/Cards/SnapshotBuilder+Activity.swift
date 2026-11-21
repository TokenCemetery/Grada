import Foundation

nonisolated extension SnapshotBuilder {
    // MARK: - Activity

    func cumulative(_ metric: QuantityMetric, goal: GoalMetric? = nil, _ variant: CardVariant) async throws -> CardSnapshot {
        var series = try await source.daily(metric, days: 8)
        if metric == .distance, !usesMetric {
            series = series.map { DayValue(day: $0.day, value: $0.value.map { $0 * 0.621_371 }) }
        }
        let goalValue = goal.flatMap { goals.value($0, on: calendar.startOfDay(for: now)) }
        var snapshot = totals(series, decimals: metric.decimals, unit: metric == .distance && !usesMetric ? String(localized: "mi", comment: "Unit: miles") : metric.unit,
                              goal: goalValue, variant: variant)
        if metric == .steps, isToday, let goalValue, snapshot.value != nil {
            snapshot.recommendation = Recommendations.steps(today: series.last?.value ?? 0, goal: goalValue)
        }
        return snapshot
    }

    /// The last 7 days' total against the weekly goal, or the WHO target without one.
    func intensityMinutes() async throws -> CardSnapshot {
        let period = String(localized: "Last 7 days")
        let days = try await intensityDays(7)
        guard days.contains(where: { $0.value != nil }) else { return .noData(period: period) }

        let total = days.compactMap(\.value).reduce(0, +)
        let target = goals.value(.intensityMinutes, on: calendar.startOfDay(for: now)) ?? IntensityMinutes.weeklyTarget
        return CardSnapshot(
            period: period,
            value: format(total, 0),
            unit: String(localized: "min", comment: "Unit: minutes"),
            comparison: Self.goalComparison(total, goal: target, decimals: 0),
            tone: total >= target ? .good : .neutral,
            chart: .progress(value: total, goal: target)
        )
    }

    /// Today's waking time at light effort or harder, with the last 7 days split by ACSM band.
    func dayIntensity() async throws -> CardSnapshot {
        guard let days = try await dayIntensityDays(7) else {
            return CardSnapshot(period: todayLabel, value: String(localized: "Calibrating"),
                                comparison: String(localized: "Needs resting and max heart rate"))
        }
        guard let today = days.last?.seconds else { return .noData(period: todayLabel) }
        let active = today.filter { $0.key != .veryLight }.values.reduce(0, +)
        return CardSnapshot(
            period: todayLabel,
            value: Self.hoursMinutes(active),
            comparison: String(localized: "\(Self.hoursMinutes(today[.veryLight] ?? 0)) very light"),
            chart: .intensity(days.map(\.seconds))
        )
    }

    /// Seconds per ACSM band for each of the last `count` days, oldest first; nil on days without heart rate.
    /// Nil altogether until resting and max heart rate are known.
    func dayIntensityDays(_ count: Int) async throws -> [(day: Date, seconds: [DayIntensity.Band: TimeInterval]?)]? {
        let days = lastDays(count)
        let restingHeartRate = Baseline.average(try await source.daily(.restingHeartRate, days: baselineDays).compactMap(\.value))
        let maxHeartRate = Resources.maxHeartRate(age: try await source.age(),
                                                  highestRecorded: try await source.highestHeartRate(days: 365))
        guard let restingHeartRate, let maxHeartRate, maxHeartRate > restingHeartRate + 20 else { return nil }

        let interval = DateInterval(start: days[0], end: max(now, days[count - 1]))
        let byDay = Dictionary(grouping: try await source.heartRate(in: interval)) { calendar.startOfDay(for: $0.date) }
        let sleep = try await source.sleepPeriods(in: interval)
        let workouts = try await source.workouts(days: count).map { DateInterval(start: $0.start, duration: $0.duration) }
        return days.map { day in
            (day, byDay[day].map { DayIntensity.time(heartRate: $0, sleep: sleep, workouts: workouts,
                                                      restingHeartRate: restingHeartRate, maxHeartRate: maxHeartRate) })
        }
    }

    /// Intensity minutes for each of the last `count` days, oldest first: from heart rate where the day has
    /// any, otherwise Apple's exercise minutes. Nil on days with neither.
    func intensityDays(_ count: Int) async throws -> [DayValue] {
        let days = lastDays(count)
        let heartRate = try await source.heartRate(in: DateInterval(start: days[0], end: max(now, days[count - 1])))
        let byDay = Dictionary(grouping: heartRate) { calendar.startOfDay(for: $0.date) }
        let exercise = try await source.daily(.exerciseMinutes, days: count)
        let restingHeartRate = Baseline.average(try await source.daily(.restingHeartRate, days: baselineDays).compactMap(\.value))
        let maxHeartRate = Resources.maxHeartRate(age: try await source.age(),
                                                  highestRecorded: try await source.highestHeartRate(days: 365))

        // A highest heart rate barely above resting (little history and no age) would count easy walking as
        // vigorous; the same guard as Day Intensity's, falling back to Apple's exercise minutes (#172).
        let usable = restingHeartRate.flatMap { resting in maxHeartRate.map { $0 > resting + 20 } } ?? false
        return days.indices.map { index in
            if usable, let values = byDay[days[index]], let restingHeartRate, let maxHeartRate {
                return DayValue(day: days[index], value: IntensityMinutes.total(
                    heartRate: values, restingHeartRate: restingHeartRate, maxHeartRate: maxHeartRate))
            }
            return DayValue(day: days[index], value: exercise[index].value)
        }
    }

    /// Today's total against the goal, or without a goal, compared with the 7 days before it.
    /// Current shows a progress bar toward the goal or that average; 7 days shows bars filling toward the goal.
    // No arrow against the average: today's total is still building while the average covers full days (#39).
    func totals(_ series: [DayValue], decimals: Int, unit: String, goal: Double? = nil,
                        variant: CardVariant) -> CardSnapshot {
        guard series.contains(where: { $0.value != nil }) else { return .noData(period: todayLabel) }
        let today = series.last?.value ?? 0
        let average = Baseline.average(series.dropLast().compactMap(\.value))
        var snapshot = CardSnapshot(period: todayLabel, value: format(today, decimals), unit: unit)
        if let goal {
            snapshot.comparison = Self.goalComparison(today, goal: goal, decimals: decimals)
            snapshot.tone = today >= goal ? .good : .neutral
        } else {
            snapshot.comparison = average.map { String(localized: "7-day avg \(format($0, decimals))") }
        }
        switch variant {
        case .current:
            if let goal {
                snapshot.chart = .progress(value: today, goal: goal)
            } else if let average {
                snapshot.chart = .progress(value: today, goal: average, isAverage: true)
            }
        case .week:
            snapshot.chart = .bars(series.suffix(7).map { $0.value ?? 0 }, target: goal)
        }
        return snapshot
    }
}
