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

    /// Days in the moving average: a week for daily points, 4 weeks for weekly ones (#200).
    var movingAverageDays: Int { isWeekly ? 28 : 7 }

    /// The periods `kind`'s detail offers. Resources replays 5-minute heart rate, too slow beyond a month (#198).
    static func available(for kind: CardKind) -> [TrendPeriod] {
        kind == .resources ? [.week, .month] : allCases
    }
}

/// One point on the trend chart: a day, or a week starting at `date` for long periods.
struct TrendPoint: Identifiable {
    let date: Date
    let value: Double?
    /// Hours per stage, for sleep.
    var stages: [SleepStage: Double] = [:]
    /// The card's color for this day, or for a week the average of its days.
    var rating: DayRating?
    /// The moving average ending here, on charts that draw one (#200): over `TrendPeriod.movingAverageDays`, as an
    /// average week on weekly totals.
    var movingAverage: Double?
    /// Today's total, or this week's, while the day is under way: drawn lighter and left out of the stats (#200).
    var isPartial = false
    /// The goal in effect on this day, drawn as a stepped line (Intensity Minutes' weekly goal, #201).
    var goal: Double?

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
    /// Average/Low/High are over the plotted points themselves, not daily values, even on weekly periods.
    var statsArePerPoint = false

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

    /// False for cards that never chart a trend: Recovery Time's hours left change through the day (#205).
    static func hasTrend(_ kind: CardKind) -> Bool { kind != .recoveryTime }

    /// `source` should already end on the shown day (see `PastDaySource.asOf`). Nil when the card has no trend.
    func trend(for kind: CardKind, period: TrendPeriod) async throws -> Trend? {
        let days = period.days
        // Days before the period, so the moving average starts full on the first one.
        let withLead = days + period.movingAverageDays - 1
        switch kind {
        case .steps, .activeEnergy, .exerciseMinutes, .distance, .floors:
            let metric = kind.quantityMetric!
            var series = try await source.daily(metric, days: withLead)
            var unit = metric.unit
            if metric == .distance, !usesMetric {
                series = series.map { DayValue(day: $0.day, value: $0.value.map { $0 * 0.621_371 }) }
                unit = String(localized: "mi", comment: "Unit: miles")
            }
            return make(series, period, style: .bars, unit: unit, format: .number(decimals: metric.decimals), movingAverage: true,
                        dailyTotal: true)
        case .intensityMinutes:
            return try await intensityMinutes(period)
        case .dayIntensity:
            let active = (try await cardBuilder.dayIntensityDays(withLead) ?? []).map { day in
                DayValue(day: day.day, value: day.seconds.map { $0.filter { $0.key != .veryLight }.values.reduce(0, +) / 3600 })
            }
            return make(active, period, style: .bars, unit: "", format: .hours, title: String(localized: "Light or harder"),
                        movingAverage: true, dailyTotal: true)
        case .standHours:
            return make(try await source.standHours(days: withLead), period, style: .bars, unit: String(localized: "h", comment: "Unit: hours"), format: .number(decimals: 0),
                        movingAverage: true, dailyTotal: true)
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
        case .mobility:
            // The card's 7-day average, so the last point is the card's speed (#201).
            let series = try await source.daily(.walkingSpeed, days: days + Self.cardWeek - 1)
            return rollingWeek(series.map { DayValue(day: $0.day, value: $0.value.map { Mobility.speed($0, usesMetric: usesMetric) }) },
                               period, total: false, unit: Mobility.speedUnit(usesMetric: usesMetric), format: .number(decimals: 1),
                               title: String(localized: "Walking Speed, 7-day average"))
        case .bloodPressure:
            return make(try await source.daily(.bloodPressureSystolic, days: withLead), period, style: .line, unit: BloodPressure.unit,
                        format: .number(decimals: 0), title: String(localized: "Systolic", comment: "Blood pressure chart: the upper number"),
                        movingAverage: true)
        case .heartRateRecovery:
            return make(try await source.heartRateRecovery(days: withLead), period, style: .line,
                        unit: QuantityMetric.restingHeartRate.unit, format: .number(decimals: 0), movingAverage: true)
        case .sleepDuration, .sleepStages:
            return try await sleep(period)
        case .sleepNeed:
            return try await sleepNeed(period)
        case .sleepConsistency:
            return try await sleepConsistency(period)
        case .sleepScore:
            let nights = try await cardBuilder.sleepScoreDays(days)
            let scores = nights.map { DayValue(day: $0.day, value: $0.result.map { Double($0.score) }) }
            return make(scores, period, style: .bars, unit: "", format: .number(decimals: 0), ratings: nights.map { $0.result?.rating })
        case .weeklyTraining:
            // The card's 7-day total, so the last point is the card's value (#201).
            let minutes = minutesPerDay(try await source.workouts(days: days + Self.cardWeek - 1), days: days + Self.cardWeek - 1)
            return rollingWeek(minutes.map { DayValue(day: $0.day, value: $0.value.map { $0 / 60 }) }, period, total: true,
                               unit: "", format: .hours, title: String(localized: "7-day total"))
        case .lastWorkout, .last30Days:
            let workouts = try await source.workouts(days: withLead)
            let minutes = minutesPerDay(workouts, days: withLead)
            return make(minutes, period, style: .bars, unit: "", format: .hours, title: String(localized: "Workout time"),
                        weeklyTotals: true, movingAverage: true, dailyTotal: true, transform: { $0 / 60 })
        case .healthStatus:
            return try await healthStatus(period)
        case .strain:
            return try await strain(period)
        case .recovery:
            let recovery = try await cardBuilder.recoveryDays(days)
            let inRange = recovery.map { DayValue(day: $0.day, value: $0.result.map { Self.share($0.inRange, of: $0.measured) }) }
            return make(inRange, period, style: .bars, unit: "%", format: .number(decimals: 0), title: String(localized: "Inputs in range"),
                        ratings: recovery.map { $0.result?.rating })
        case .healthAge:
            guard let age = try await source.age() else { return nil }
            let ages = try await cardBuilder.healthAgeInputs(age: age, count: days)
                .map { DayValue(day: $0.day, value: HealthAge.age($0.input)) }
            return make(ages, period, style: .line, unit: String(localized: "yrs", comment: "Unit: years"), format: .number(decimals: 1))
        // Replaying 5-minute heart rate is too slow past a month, and storing a daily value would freeze an
        // estimated formula (#42), so only W and M are offered (#198).
        case .resources:
            guard TrendPeriod.available(for: kind).contains(period),
                  let peaks = try await cardBuilder.resourcesPeaks(days) else { return nil }
            return make(peaks, period, style: .bars, unit: "%", format: .number(decimals: 0), title: String(localized: "Daily peak"),
                        ratings: peaks.map { $0.value.map { Resources.rating(Int($0.rounded())) } })
        // Hours left change through the day; the explanation covers the inputs instead.
        case .recoveryTime:
            return nil
        case .trainingReadiness:
            let readiness = try await cardBuilder.readinessDays(days)
            let inRange = readiness.map { DayValue(day: $0.day, value: $0.result.map { Self.share($0.inRange, of: $0.measured) }) }
            return make(inRange, period, style: .bars, unit: "%", format: .number(decimals: 0), title: String(localized: "Inputs in range"),
                        ratings: readiness.map { $0.result?.rating })
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
        // The card's history: the 30 days before its value, which is yesterday's until today's arrives (#208).
        let window = Array(series.suffix(baselineDays + 1))
        let latestIndex = window.indices.suffix(2).last { window[$0].value != nil } ?? window.count - 1
        let history = window[..<latestIndex].compactMap(\.value)
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
        let withLead = period.days + period.movingAverageDays - 1
        guard let nights = try await cardBuilder.sleepDebt(withLead) else { return nil }
        let debt = zip(lastDays(withLead), nights).map { DayValue(day: $0, value: $1.debt / 3600) }
        // A balance carried night to night, so a line like the other levels (#199).
        return make(debt, period, style: .line, unit: "", format: .hours, title: String(localized: "Sleep debt"), movingAverage: true)
    }

    private func sleepConsistency(_ period: TrendPeriod) async throws -> Trend {
        let indexes = try await cardBuilder.sleepRegularity(period.days + period.movingAverageDays - 1).map { DayValue(day: $0.day, value: $0.index) }
        return make(indexes, period, style: .line, unit: "", format: .number(decimals: 0), title: String(localized: "Sleep Regularity Index"),
                    movingAverage: true)
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

    /// The rolling 7-day total the card shows, for each day, against the weekly goal in effect that day (#201).
    private func intensityMinutes(_ period: TrendPeriod) async throws -> Trend {
        let minutes = try await cardBuilder.intensityDays(period.days + Self.cardWeek - 1)
        var trend = rollingWeek(minutes, period, total: true, unit: String(localized: "min", comment: "Unit: minutes"),
                                format: .number(decimals: 0), title: String(localized: "7-day total"))
        let lastDay = minutes.last?.day ?? calendar.startOfDay(for: .now)
        for index in trend.points.indices {
            // A weekly point is dated its week's start but holds the total at the week's end, so take that day's goal.
            let date = trend.points[index].date
            let day = period.isWeekly ? min(calendar.date(byAdding: .day, value: 6, to: date)!, lastDay) : date
            trend.points[index].goal = goals.value(.intensityMinutes, on: day) ?? IntensityMinutes.weeklyTarget
        }
        return trend
    }

    /// Cards that sum or average the last 7 days, today included.
    private static let cardWeek = 7

    /// Each day's 7-day total (or mean) ending that day, as the cards that cover the last 7 days show it. `daily`
    /// starts 6 days before the period. Weekly periods take each week's last day, and the latest day for this week.
    private func rollingWeek(_ daily: [DayValue], _ period: TrendPeriod, total: Bool, unit: String,
                             format: Trend.ValueFormat, title: String) -> Trend {
        let window = Self.cardWeek
        var rolled: [DayValue] = []
        guard daily.count >= window else { return make([], period, style: .line, unit: unit, format: format, title: title) }
        for end in (window - 1)..<daily.count {
            let week = daily[(end - window + 1)...end].compactMap(\.value)
            rolled.append(DayValue(day: daily[end].day, value: week.isEmpty ? nil : total ? week.reduce(0, +) : Baseline.average(week)))
        }
        if period.isWeekly {
            let last = rolled.last?.day
            rolled = rolled.filter { day in
                let weekEnd = calendar.dateInterval(of: .weekOfYear, for: day.day)!.end.addingTimeInterval(-1)
                return calendar.isDate(day.day, inSameDayAs: weekEnd) || day.day == last
            }
        }
        var trend = make(rolled, period, style: .line, unit: unit, format: format, title: title)
        trend.statsArePerPoint = true
        return trend
    }

    /// Percent of `measured` inputs that were in range.
    static func share(_ inRange: Int, of measured: Int) -> Double {
        Double(inRange) / Double(measured) * 100
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
            return (DayValue(day: days[index], value: measured > 0 ? Self.share(inRange, of: measured) : nil),
                    measured > 0 ? DayRatings.healthStatus(outOfRange: measured - inRange) : nil)
        }
        // The share, like the card's bars, and the calendar's colors (#202).
        return make(counts.map(\.0), period, style: .bars, unit: "%", format: .number(decimals: 0), title: String(localized: "Vitals in range"),
                    ratings: counts.map(\.1))
    }

    /// Charts a detail screen shows below its trend, each only with data: body fat, BMI and lean body mass for
    /// Weight (#132), training monotony and strain (#133) and effort against heart rate load (#134) for Strain,
    /// diastolic for Blood Pressure (#135), Walking Steadiness, step length and asymmetry for Mobility (#136).
    func extraTrends(for kind: CardKind, period: TrendPeriod) async throws -> [Trend] {
        if kind == .strain { return try await monotonyAndStrain(period) + effortAndHeartRateLoad(period) }
        if kind == .mobility { return try await mobilityTrends(period) }
        if kind == .bloodPressure {
            let diastolic = try await source.daily(.bloodPressureDiastolic, days: period.days + period.movingAverageDays - 1)
            guard diastolic.contains(where: { $0.value != nil }) else { return [] }
            return [make(diastolic, period, style: .line, unit: BloodPressure.unit, format: .number(decimals: 0),
                         title: String(localized: "Diastolic", comment: "Blood pressure chart: the lower number"), movingAverage: true)]
        }
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

    /// Walking Steadiness titled with Apple's class of the latest value, step length and asymmetry; each only with data.
    private func mobilityTrends(_ period: TrendPeriod) async throws -> [Trend] {
        var trends: [Trend] = []
        let steadiness = try await source.daily(.walkingSteadiness, days: period.days)
        if let latest = steadiness.last(where: { $0.value != nil })?.value {
            let title = Mobility.Steadiness(percent: latest).map {
                String(localized: "Walking Steadiness · \($0.title)", comment: "Chart title with Apple's class of the latest value, e.g. Walking Steadiness · OK")
            } ?? String(localized: "Walking Steadiness")
            trends.append(make(steadiness, period, style: .line, unit: "%", format: .number(decimals: 0), title: title))
        }
        for metric in [QuantityMetric.walkingStepLength, .walkingAsymmetry] {
            let series = try await source.daily(metric, days: period.days)
            guard series.contains(where: { $0.value != nil }) else { continue }
            trends.append(make(series, period, style: .line, unit: metric.unit, format: .number(decimals: metric.decimals),
                               title: DataKind(metric).title))
        }
        return trends
    }

    /// Each day's 7-day monotony, titled High when the shown day's week is above Foster's warning, and training strain.
    /// Today's week ends yesterday, so today has no point of its own.
    private func monotonyAndStrain(_ period: TrendPeriod) async throws -> [Trend] {
        guard var days = try await cardBuilder.strainDays(period.days),
              days.contains(where: { $0.week != nil })
        else { return [] }
        let shownWeek = days.last?.week
        if let last = days.last, calendar.isDateInToday(last.day) { days[days.count - 1].week = nil }
        let title = shownWeek?.isMonotonous == true
            ? String(localized: "Training Monotony · High", comment: "Chart title when the latest week's monotony is above 2")
            : String(localized: "Training Monotony")
        var monotony = make(days.map { DayValue(day: $0.day, value: $0.week?.monotony) }, period, style: .line, unit: "",
                            format: .number(decimals: 1), title: title)
        monotony.normalRange = 0...Strain.highMonotony
        let strain = make(days.map { DayValue(day: $0.day, value: $0.week?.strain) }, period, style: .line, unit: "",
                          format: .number(decimals: 0), title: String(localized: "Training Strain"))
        return [monotony, strain]
    }

    /// Session-RPE load (effort × minutes) and Edwards' TRIMP of the same workouts, so the two compare like for like:
    /// those the user rated (Apple's estimate comes partly from heart rate, so it can't be compared with it) and that
    /// have heart rate. Only with `SessionRPE.minimumRatedWorkouts` of them in the period.
    private func effortAndHeartRateLoad(_ period: TrendPeriod) async throws -> [Trend] {
        let efforts = try await source.workoutEfforts(days: period.days).filter { !$0.value.isEstimate }
        let rated = try await source.workouts(days: period.days).filter { efforts[$0.id] != nil }
        guard rated.count >= SessionRPE.minimumRatedWorkouts,
              let maxHeartRate = Resources.maxHeartRate(age: try await source.age(),
                                                        highestRecorded: try await source.highestHeartRate(days: 365))
        else { return [] }
        let days = lastDays(period.days)
        let heartRate = try await source.heartRate(in: DateInterval(start: days[0], end: max(cardBuilder.now, days[0])))
        let heartRateByDay = Dictionary(grouping: heartRate) { calendar.startOfDay(for: $0.date) }
        var effortLoad: [Date: Double] = [:], heartRateLoad: [Date: Double] = [:]
        var compared = 0
        for workout in rated {
            let day = calendar.startOfDay(for: workout.start)
            let end = workout.start.addingTimeInterval(workout.duration)
            // A workout past midnight takes readings from the next day too.
            let nextDay = calendar.isDate(end, inSameDayAs: day) ? [] : heartRateByDay[calendar.startOfDay(for: end)] ?? []
            let during = ((heartRateByDay[day] ?? []) + nextDay).filter { $0.date >= workout.start && $0.date < end }
            guard !during.isEmpty else { continue }
            compared += 1
            effortLoad[day, default: 0] += SessionRPE.load(effort: efforts[workout.id]!.score, duration: workout.duration)
            heartRateLoad[day, default: 0] += Strain.load(heartRate: during, end: end, maxHeartRate: maxHeartRate)
        }
        guard compared >= SessionRPE.minimumRatedWorkouts else { return [] }
        return [
            make(days.map { DayValue(day: $0, value: effortLoad[$0] ?? 0) }, period, style: .bars, unit: "",
                 format: .number(decimals: 0), title: String(localized: "Effort Load of Rated Workouts"), weeklyTotals: true),
            make(days.map { DayValue(day: $0, value: heartRateLoad[$0] ?? 0) }, period, style: .bars, unit: "TRIMP",
                 format: .number(decimals: 0), title: String(localized: "Heart Rate Load of Rated Workouts"), weeklyTotals: true),
        ]
    }

    // MARK: - Helpers

    /// Daily points, or weekly averages (totals with `weeklyTotals`) for long periods. With `movingAverage`, `series`
    /// starts `movingAverageDays - 1` days before the period, so the average is full from the first point.
    /// `dailyTotal` marks series whose today is still adding up, like steps: while today is under way it is left out
    /// of the stats and the moving average, as the card's 7-day average leaves it out (#39).
    private func make(_ series: [DayValue], _ period: TrendPeriod, style: Trend.Style, unit: String,
                      format: Trend.ValueFormat, title: String? = nil, weeklyTotals: Bool = false, movingAverage: Bool = false,
                      dailyTotal: Bool = false, ratings: [DayRating?]? = nil, transform: (Double) -> Double = { $0 }) -> Trend {
        let all = series
        let series = movingAverage ? Array(all.suffix(period.days)) : all
        let underway = dailyTotal && series.last.map { calendar.isDateInToday($0.day) } == true
        var daily = series.indices.map { index in
            TrendPoint(date: series[index].day, value: series[index].value.map(transform), rating: ratings?[index])
        }
        if underway { daily[daily.count - 1].isPartial = true }
        let values = daily.filter { !$0.isPartial }.compactMap(\.value)
        var points = daily
        if period.isWeekly {
            var buckets = weeks(daily)
            // The period's start cuts its oldest week short, and a total of a few days would chart as a false dip.
            // The current week stays: it's the week so far.
            if weeklyTotals, let first = buckets.first, first.points.count < 7, buckets.count > 1 { buckets.removeFirst() }
            points = buckets.map { week in
                // A weekly total keeps today as the week so far; a weekly average leaves it out.
                let weekValues = (weeklyTotals ? week.points : week.points.filter { !$0.isPartial }).compactMap(\.value)
                let value = weeklyTotals ? weekValues.reduce(0, +) : Baseline.average(weekValues)
                var point = TrendPoint(date: week.start, value: weekValues.isEmpty ? nil : value,
                                       rating: Self.averageRating(week.points.compactMap(\.rating)))
                point.isPartial = weeklyTotals && week.points.contains { $0.isPartial }
                return point
            }
        }
        if movingAverage {
            addMovingAverage(to: &points, from: all, period, weeklyTotals: weeklyTotals, skipLast: underway, transform: transform)
        }
        return Trend(title: title, style: style, unit: unit, format: format, points: points,
                     average: Baseline.average(values), low: values.min(), high: values.max())
    }

    /// The average of the days with a value in the `movingAverageDays` up to each point; for a week, up to its last
    /// day. With `skipLast`, a window ending on today ends on yesterday. Weekly totals get an average week (7 × the daily average) so the line runs through the bars.
    private func addMovingAverage(to points: inout [TrendPoint], from series: [DayValue], _ period: TrendPeriod,
                                  weeklyTotals: Bool, skipLast: Bool, transform: (Double) -> Double) {
        guard let last = series.last?.day else { return }
        let values = series.map { $0.value.map(transform) }
        let index = Dictionary(series.indices.map { (series[$0].day, $0) }, uniquingKeysWith: { first, _ in first })
        let scale = period.isWeekly && weeklyTotals ? 7.0 : 1
        for i in points.indices {
            let end = period.isWeekly ? min(calendar.date(byAdding: .day, value: 6, to: points[i].date)!, last) : points[i].date
            guard var endIndex = index[end] else { continue }
            // Today's unfinished total would pull the line down, so its window ends yesterday instead.
            if skipLast, endIndex == values.count - 1 { endIndex -= 1 }
            guard endIndex >= 0 else { continue }
            let window = values[max(0, endIndex - period.movingAverageDays + 1)...endIndex].compactMap { $0 }
            points[i].movingAverage = Baseline.average(window).map { $0 * scale }
        }
    }

    /// Good counts 2, fair 1 and poor 0; the rounded mean picks the week's color.
    static func averageRating(_ ratings: [DayRating]) -> DayRating? {
        guard !ratings.isEmpty else { return nil }
        let scores = ratings.map { rating -> Double in
            switch rating {
            case .good: 2
            case .fair: 1
            case .poor: 0
            }
        }
        switch (scores.reduce(0, +) / Double(scores.count)).rounded() {
        case 2: return .good
        case 1: return .fair
        default: return .poor
        }
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
