import Foundation

enum TrendPeriod: String, CaseIterable, Identifiable {
    case week, month, threeMonths, sixMonths, year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: String(localized: "W", comment: "Trend period button: one week")
        case .month: String(localized: "M", comment: "Trend period button: one month")
        case .threeMonths: String(localized: "3M", comment: "Trend period button: three months")
        case .sixMonths: String(localized: "6M", comment: "Trend period button: six months")
        case .year: String(localized: "Y", comment: "Trend period button: one year")
        }
    }

    var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .threeMonths: 91
        case .sixMonths: 182
        case .year: 365
        }
    }

    /// Daily points get too dense to read beyond 3 months, so these show one point per week.
    var isWeekly: Bool { self == .sixMonths || self == .year }
}

/// One point on the trend chart: a day, or a week starting at `date` for long periods.
struct TrendPoint: Identifiable {
    let date: Date
    let value: Double?
    /// Hours per stage, for sleep.
    var stages: [SleepStage: Double] = [:]

    var id: Date { date }
}

struct Trend {
    enum Style { case bars, line, sleep }
    enum ValueFormat { case number(decimals: Int), hours }

    /// What is plotted, when it differs from the card, e.g. "Resting heart rate" on the Heart rate card.
    var title: String?
    var style: Style
    var unit: String
    var format: ValueFormat
    var points: [TrendPoint]
    var normalRange: ClosedRange<Double>?
    /// Stats over the daily values, also for weekly charts.
    var average: Double?
    var low: Double?
    var high: Double?

    func formatted(_ value: Double) -> String {
        switch format {
        case .number(let decimals): value.formatted(.number.precision(.fractionLength(decimals)))
        case .hours: SnapshotBuilder.hoursMinutes(value * 3600)
        }
    }
}

/// Builds the trend chart series for a card, ending on the shown day.
struct TrendBuilder {
    let source: HealthDataSource
    var calendar: Calendar = .current
    var usesMetric: Bool = Locale.current.measurementSystem != .us
    /// The user's goals, for series that depend on them, e.g. sleep debt.
    var goals = GoalHistory()

    /// History used for personal normal ranges, as on the cards.
    private let baselineDays = 30

    /// `source` should already end on the shown day (see `PastDaySource.asOf`). Nil when the card has no trend.
    func trend(for kind: CardKind, period: TrendPeriod) async throws -> Trend? {
        let days = period.days
        switch kind {
        case .steps, .activeEnergy, .exerciseMinutes, .distance, .floors:
            let metric = kind.quantityMetric!
            var series = try await source.daily(metric, days: days)
            var unit = metric.unit
            if metric == .distance, !usesMetric {
                series = series.map { DayValue(day: $0.day, value: $0.value.map { $0 * 0.621_371 }) }
                unit = String(localized: "mi", comment: "Unit: miles")
            }
            return make(series, period, style: .bars, unit: unit, format: .number(decimals: metric.decimals))
        case .intensityMinutes:
            return make(try await cardBuilder.intensityDays(days), period, style: .bars, unit: String(localized: "min", comment: "Unit: minutes"),
                        format: .number(decimals: 0), weeklyTotals: true)
        case .dayIntensity:
            let active = (try await cardBuilder.dayIntensityDays(days) ?? []).map { day in
                DayValue(day: day.day, value: day.seconds.map { $0.filter { $0.key != .veryLight }.values.reduce(0, +) / 3600 })
            }
            return make(active, period, style: .bars, unit: String(localized: "h", comment: "Unit: hours"), format: .number(decimals: 1), title: String(localized: "Light or harder"))
        case .standHours:
            return make(try await source.standHours(days: days), period, style: .bars, unit: String(localized: "h", comment: "Unit: hours"), format: .number(decimals: 0))
        case .restingHeartRate, .hrv, .oxygenSaturation, .respiratoryRate, .wristTemperature, .heartRate:
            return try await vital(kind.quantityMetric!, period,
                                   title: kind == .heartRate ? String(localized: "Resting heart rate") : nil)
        case .hrvStatus:
            return try await hrvStatus(period)
        case .vo2Max, .racePredictor:
            let series = try await source.daily(.vo2Max, days: days)
            return make(series, period, style: .line, unit: QuantityMetric.vo2Max.unit, format: .number(decimals: 1),
                        title: kind == .racePredictor ? String(localized: "VO₂ Max") : nil)
        case .weight:
            let series = try await source.daily(.bodyMass, days: days)
            return make(series.map { DayValue(day: $0.day, value: $0.value.map { BodyMass.display($0, usesMetric: usesMetric) }) },
                        period, style: .line, unit: BodyMass.unit(usesMetric: usesMetric), format: .number(decimals: 1))
        case .heartRateRecovery:
            return make(try await source.heartRateRecovery(days: days), period, style: .line,
                        unit: QuantityMetric.restingHeartRate.unit, format: .number(decimals: 0))
        case .sleepDuration, .sleepStages:
            return try await sleep(period)
        case .sleepNeed:
            return try await sleepNeed(period)
        case .sleepConsistency:
            return try await sleepConsistency(period)
        case .sleepScore:
            let scores = try await cardBuilder.sleepScoreDays(days).map { DayValue(day: $0.day, value: $0.result.map { Double($0.score) }) }
            return make(scores, period, style: .bars, unit: "", format: .number(decimals: 0))
        case .lastWorkout, .weeklyTraining, .last30Days:
            let workouts = try await source.workouts(days: days)
            let minutes = minutesPerDay(workouts, days: days)
            return make(minutes, period, style: .bars, unit: "", format: .hours, title: String(localized: "Workout time"),
                        weeklyTotals: true, transform: { $0 / 60 })
        case .healthStatus:
            return try await healthStatus(period)
        case .strain:
            return try await strain(period)
        case .recovery:
            let inRange = try await cardBuilder.recoveryDays(days)
                .map { DayValue(day: $0.day, value: $0.result.map { Double($0.inRange) }) }
            return make(inRange, period, style: .bars, unit: "", format: .number(decimals: 0), title: String(localized: "Inputs in range"))
        case .healthAge:
            guard let age = try await source.age() else { return nil }
            let ages = try await cardBuilder.healthAgeInputs(age: age, count: days)
                .map { DayValue(day: $0.day, value: HealthAge.age($0.input)) }
            return make(ages, period, style: .line, unit: String(localized: "yrs", comment: "Unit: years"), format: .number(decimals: 1))
        // Rebuilding each day needs a year of 5-minute heart rate, too slow for a chart, and storing a daily value
        // would freeze an estimated formula (#42). The detail screen shows today's breakdown instead.
        case .resources:
            return nil
        // Hours left change through the day; the explanation covers the inputs instead.
        case .recoveryTime:
            return nil
        case .trainingReadiness:
            let inRange = try await cardBuilder.readinessDays(days)
                .map { DayValue(day: $0.day, value: $0.result.map { Double($0.inRange) }) }
            return make(inRange, period, style: .bars, unit: "", format: .number(decimals: 0), title: String(localized: "Inputs in range"))
        case .loadFocus:
            guard let days = try await cardBuilder.loadFocusDays(days) else { return nil }
            var trend = make(days.map { DayValue(day: $0.day, value: LoadFocus.shares($0.seconds).map { $0[0] * 100 }) },
                             period, style: .line, unit: "%", format: .number(decimals: 0), title: String(localized: "Low intensity, 4 weeks"))
            trend.normalRange = LoadFocus.lowTarget * 100...100
            return trend
        }
    }

    // MARK: - Series

    /// Line with the personal normal range from the 30 days before the shown day.
    private func vital(_ metric: QuantityMetric, _ period: TrendPeriod, title: String?) async throws -> Trend {
        var series = try await source.daily(metric, days: max(period.days, baselineDays + 1))
        var unit = metric.unit
        if metric == .wristTemperature, !usesMetric {
            series = series.map { DayValue(day: $0.day, value: $0.value.map { $0 * 1.8 + 32 }) }
            unit = "°F"
        }
        let history = series.dropLast().suffix(baselineDays).compactMap(\.value)
        let range = Baseline.normalRange(history: history, minimumHalfWidth: metric.minimumHalfWidth * (unit == "°F" ? 1.8 : 1))
        var trend = make(Array(series.suffix(period.days)), period, style: .line, unit: unit,
                         format: .number(decimals: metric.decimals), title: title)
        trend.normalRange = range
        return trend
    }

    private func sleep(_ period: TrendPeriod) async throws -> Trend {
        let nights = try await source.sleepNights(days: period.days)
        let byDay = Dictionary(nights.map { ($0.wakeDay, $0) }, uniquingKeysWith: { first, _ in first })
        let days = lastDays(period.days)
        let daily: [TrendPoint] = days.map { day in
            guard let night = byDay[day], night.asleep > 0 else { return TrendPoint(date: day, value: nil) }
            var stages = night.stages.mapValues { $0 / 3600 }
            stages[.awake] = nil
            // Asleep time without stage detail is drawn as core sleep.
            if night.unspecified > 0 { stages[.core, default: 0] += night.unspecified / 3600 }
            return TrendPoint(date: day, value: night.asleep / 3600, stages: stages)
        }
        let values = daily.compactMap(\.value)
        var points = daily
        if period.isWeekly {
            points = weeks(daily).map { week in
                let measured = week.points.filter { $0.value != nil }
                guard !measured.isEmpty else { return TrendPoint(date: week.start, value: nil) }
                var stages: [SleepStage: Double] = [:]
                for point in measured {
                    for (stage, hours) in point.stages { stages[stage, default: 0] += hours / Double(measured.count) }
                }
                return TrendPoint(date: week.start, value: Baseline.average(measured.compactMap(\.value)), stages: stages)
            }
        }
        return Trend(style: .sleep, unit: "", format: .hours, points: points,
                     average: Baseline.average(values), low: values.min(), high: values.max())
    }

    /// Sleep debt after each night, as the Sleep Need card counts it.
    private func sleepNeed(_ period: TrendPeriod) async throws -> Trend? {
        guard let nights = try await cardBuilder.sleepDebt(period.days) else { return nil }
        let debt = zip(lastDays(period.days), nights).map { DayValue(day: $0, value: $1.debt / 3600) }
        return make(debt, period, style: .bars, unit: "", format: .hours, title: String(localized: "Sleep debt"))
    }

    private func sleepConsistency(_ period: TrendPeriod) async throws -> Trend {
        let indexes = try await cardBuilder.sleepRegularity(period.days).map { DayValue(day: $0.day, value: $0.index) }
        return make(indexes, period, style: .line, unit: "", format: .number(decimals: 0), title: String(localized: "Sleep Regularity Index"))
    }

    /// The 7-night average for each day, with the shown day's baseline as the normal range.
    private func hrvStatus(_ period: TrendPeriod) async throws -> Trend {
        let lead = HRVStatus.baselineNights + HRVStatus.window - 1
        let overnight = try await source.overnight(days: period.days + lead)
        let nights = overnight.map(\.hrv)
        let averages = (lead..<nights.count).map { end in
            DayValue(day: overnight[end].wakeDay, value: HRVStatus.status(nights: nights, endingAt: end)?.average)
        }
        var trend = make(averages, period, style: .line, unit: QuantityMetric.hrv.unit, format: .number(decimals: 0),
                         title: String(localized: "7-night average HRV"))
        trend.normalRange = HRVStatus.status(nights: nights, endingAt: nights.count - 1)?.baseline
        return trend
    }

    /// The 7-day average load each day, with the shown day's sweet spot (0.8–1.3 × its 28-day average) as the range.
    private func strain(_ period: TrendPeriod) async throws -> Trend? {
        guard let days = try await cardBuilder.strainDays(period.days) else { return nil }
        var trend = make(days.map { DayValue(day: $0.day, value: $0.ratio?.acute) }, period, style: .line, unit: "TRIMP",
                         format: .number(decimals: 0), title: String(localized: "7-day load against 28-day"))
        trend.normalRange = days.last?.ratio.map {
            Strain.sweetSpot.lowerBound * $0.chronic...Strain.sweetSpot.upperBound * $0.chronic
        }
        return trend
    }

    /// Vitals in range each night, out of those measured with a finished baseline.
    private func healthStatus(_ period: TrendPeriod) async throws -> Trend {
        var series: [QuantityMetric: [DayValue]] = [:]
        for (vital, _) in SnapshotBuilder.vitals {
            series[vital] = try await SnapshotBuilder.vitalSeries(vital, days: period.days + baselineDays, source: source)
        }
        let days = series.values.first!.map(\.day)
        let counts = days.indices.dropFirst(baselineDays).map { index in
            var measured = 0, inRange = 0
            for (metric, values) in series {
                guard let value = values[index].value else { continue }
                let history = values[(index - baselineDays)..<index].compactMap(\.value)
                guard let range = Baseline.normalRange(history: history, minimumHalfWidth: metric.minimumHalfWidth) else { continue }
                measured += 1
                if range.contains(value) { inRange += 1 }
            }
            return DayValue(day: days[index], value: measured > 0 ? Double(inRange) : nil)
        }
        return make(counts, period, style: .bars, unit: "", format: .number(decimals: 0), title: String(localized: "Vitals in range"))
    }

    /// Charts a detail screen shows below its trend, each only with data: body fat, BMI and lean body mass for
    /// Weight (#132).
    func extraTrends(for kind: CardKind, period: TrendPeriod) async throws -> [Trend] {
        guard kind == .weight else { return [] }
        let days = period.days
        var trends: [Trend] = []
        let fat = try await source.daily(.bodyFat, days: days)
        if fat.contains(where: { $0.value != nil }) {
            trends.append(make(fat, period, style: .line, unit: "%", format: .number(decimals: 1),
                               title: String(localized: "Body Fat Percentage")))
        }
        if let height = try await source.latest(.height) {
            let bmi = try await source.daily(.bodyMass, days: days)
                .map { DayValue(day: $0.day, value: $0.value.map { BodyMass.bmi(kilograms: $0, centimeters: height) }) }
            if bmi.contains(where: { $0.value != nil }) {
                let latest = bmi.last { $0.value != nil }!.value!
                var trend = make(bmi, period, style: .line, unit: "", format: .number(decimals: 1),
                                 title: String(localized: "Body Mass Index · \(BodyMass.BMIClass(latest).title)",
                                               comment: "BMI chart title with the WHO class of the latest value, e.g. Body Mass Index · Normal"))
                trend.normalRange = BodyMass.normalBMI
                trends.append(trend)
            }
        }
        let lean = try await source.daily(.leanBodyMass, days: days)
        if lean.contains(where: { $0.value != nil }) {
            trends.append(make(lean.map { DayValue(day: $0.day, value: $0.value.map { BodyMass.display($0, usesMetric: usesMetric) }) },
                               period, style: .line, unit: BodyMass.unit(usesMetric: usesMetric), format: .number(decimals: 1),
                               title: String(localized: "Lean Body Mass")))
        }
        return trends
    }

    // MARK: - Helpers

    /// Daily points, or weekly averages (totals with `weeklyTotals`) for long periods.
    private func make(_ series: [DayValue], _ period: TrendPeriod, style: Trend.Style, unit: String,
                      format: Trend.ValueFormat, title: String? = nil, weeklyTotals: Bool = false,
                      transform: (Double) -> Double = { $0 }) -> Trend {
        let daily = series.map { TrendPoint(date: $0.day, value: $0.value.map(transform)) }
        let values = daily.compactMap(\.value)
        var points = daily
        if period.isWeekly {
            points = weeks(daily).map { week in
                let weekValues = week.points.compactMap(\.value)
                let value = weeklyTotals ? weekValues.reduce(0, +) : Baseline.average(weekValues)
                return TrendPoint(date: week.start, value: weekValues.isEmpty ? nil : value)
            }
        }
        return Trend(title: title, style: style, unit: unit, format: format, points: points,
                     average: Baseline.average(values), low: values.min(), high: values.max())
    }

    private func weeks(_ points: [TrendPoint]) -> [(start: Date, points: [TrendPoint])] {
        let grouped = Dictionary(grouping: points) { calendar.dateInterval(of: .weekOfYear, for: $0.date)!.start }
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }

    /// Workout minutes per day, oldest first, ending on the shown day.
    private func minutesPerDay(_ workouts: [WorkoutSummary], days: Int) -> [DayValue] {
        let dayStarts = lastDays(days)
        var minutes = [Date: Double]()
        for workout in workouts {
            minutes[calendar.startOfDay(for: workout.start), default: 0] += workout.duration / 60
        }
        return dayStarts.map { DayValue(day: $0, value: minutes[$0] ?? 0) }
    }

    /// The last `count` days ending on the shown day. The source's day series always end there,
    /// so read the end from one of them.
    private func lastDays(_ count: Int) -> [Date] {
        let end = shownDay
        return (0..<count).reversed().map { calendar.date(byAdding: .day, value: -$0, to: end)! }
    }

    /// For series the cards already calculate, ending on the shown day.
    private var cardBuilder: SnapshotBuilder {
        var builder = SnapshotBuilder(source: source)
        builder.calendar = calendar
        builder.goals = goals
        if !calendar.isDateInToday(shownDay) {
            builder.now = calendar.date(byAdding: .day, value: 1, to: shownDay)!.addingTimeInterval(-1)
        }
        return builder
    }

    private var shownDay: Date {
        (source as? PastDaySource).map { calendar.date(byAdding: .day, value: -1, to: $0.dayEnd)! }
            ?? calendar.startOfDay(for: .now)
    }
}
