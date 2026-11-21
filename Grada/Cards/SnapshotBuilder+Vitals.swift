import Foundation

nonisolated extension SnapshotBuilder {
    // MARK: - Vitals

    /// The vitals behind Health status; the calendar rates days with the same set.
    static let vitals: [(QuantityMetric, String)] = [
        (.hrv, String(localized: "HRV")), (.restingHeartRate, String(localized: "RHR", comment: "Abbreviation for resting heart rate")),
        (.respiratoryRate, String(localized: "Resp", comment: "Abbreviation for respiratory rate")),
        (.oxygenSaturation, String(localized: "SpO₂")), (.wristTemperature, String(localized: "Temp", comment: "Abbreviation for temperature")),
    ]

    /// One value per day for a vital, oldest first. HRV is the night's, as Recovery and HRV status use: one series
    /// per night, from readings taken asleep, and the only HRV that Garmin and FIT files provide.
    static func vitalSeries(_ metric: QuantityMetric, days: Int, source: HealthDataSource) async throws -> [DayValue] {
        guard metric == .hrv else { return try await source.daily(metric, days: days) }
        return try await source.overnight(days: days).map { DayValue(day: $0.wakeDay, value: $0.hrv) }
    }

    /// Vitals from the night that ended today. Until it has (e.g. just after midnight),
    /// the previous night is shown instead, labelled "Yesterday".
    func healthStatus() async throws -> CardSnapshot {
        var allSeries: [(QuantityMetric, String, [DayValue])] = []
        for (metric, name) in Self.vitals {
            allSeries.append((metric, name, try await Self.vitalSeries(metric, days: baselineDays + 1, source: source)))
        }
        let todayIndex = baselineDays
        let hasToday = allSeries.contains { $0.2.last?.value != nil }
        let nightIndex = hasToday ? todayIndex : todayIndex - 1
        let period = hasToday ? lastNightLabel : yesterdayLabel

        var statuses: [VitalStatus] = []
        for (metric, name, series) in allSeries {
            let state: VitalStatus.State
            var rating: DayRating?
            if let value = series[nightIndex].value {
                let history = series[..<nightIndex].compactMap(\.value)
                if let range = Baseline.normalRange(history: history, minimumHalfWidth: metric.minimumHalfWidth) {
                    state = range.contains(value) ? .inRange : .outOfRange
                    rating = DayRatings.vital(value, normal: range)
                } else {
                    state = .calibrating
                }
            } else {
                state = .noData
            }
            statuses.append(VitalStatus(name: name, state: state, rating: rating))
        }

        let measured = statuses.filter { $0.state != .noData }
        guard !measured.isEmpty else { return .noData(period: lastNightLabel) }
        let outOfRange = statuses.filter { $0.state == .outOfRange }.count
        let inRange = statuses.filter { $0.state == .inRange }.count

        var snapshot = CardSnapshot(period: period, value: nil, detail: .vitals(statuses))
        if outOfRange > 0 {
            snapshot.value = outOfRange == 1 ? String(localized: "1 vital out of range")
                : String(localized: "\(outOfRange) vitals out of range")
            snapshot.tone = .warning
        } else if inRange == 0 {
            snapshot.value = String(localized: "Calibrating")
            snapshot.comparison = String(localized: "Needs \(Baseline.minimumDays) nights of data")
        } else {
            snapshot.value = String(localized: "All in range")
            snapshot.tone = .good
        }
        if snapshot.comparison == nil {
            snapshot.comparison = String(localized: "\(inRange) of \(measured.count) vitals normal")
        }
        return snapshot
    }

    /// Discrete vitals: latest value from today or yesterday, compared with the personal normal range.
    /// Current marks it on the range; 7 days draws the line through the range.
    func vital(_ metric: QuantityMetric, _ variant: CardVariant) async throws -> CardSnapshot {
        let series = try await source.daily(metric, days: baselineDays + 1)
        guard let latestIndex = series.indices.suffix(2).last(where: { series[$0].value != nil }),
              let latest = series[latestIndex].value
        else { return .noData(period: todayLabel) }

        let history = series[..<latestIndex].compactMap(\.value)
        let range = Baseline.normalRange(history: history, minimumHalfWidth: metric.minimumHalfWidth)
        let comparison = range.map {
            String(localized: "Normal \(format($0.lowerBound, metric.decimals))–\(format($0.upperBound, metric.decimals))")
        } ?? String(localized: "Calibrating")
        // Low blood oxygen or HRV is the worry; for the others, a high reading is.
        let higherIsBetter = metric == .oxygenSaturation || metric == .hrv
        let isTodays = isToday && latestIndex == series.count - 1

        return CardSnapshot(
            period: dayLabel(series[latestIndex].day),
            value: format(latest, metric.decimals),
            unit: metric.unit,
            comparison: comparison,
            tone: range.map { $0.contains(latest) ? .neutral : .warning } ?? .neutral,
            rating: range.map { DayRatings.range(latest, normal: $0, higherIsBetter: higherIsBetter) },
            chart: variant == .week
                ? .line(series.suffix(7).map(\.value), normalRange: range)
                : range.map { .range(value: latest, normalRange: $0, higherIsBetter: higherIsBetter, decimals: 0) } ?? .none,
            recommendation: metric == .restingHeartRate && isTodays
                ? range.flatMap { Recommendations.restingHeartRate(latest, normal: $0) } : nil
        )
    }

    /// The 7 nights ending last night; until last night is recorded, the 7 ending yesterday.
    /// Current shows the 7-night average on a gauge: yellow above the baseline ("Unbalanced"), yellow then red
    /// below it ("Low" from twice the half-width under the mean). 7 days draws the line through the baseline.
    func hrvStatus(_ variant: CardVariant) async throws -> CardSnapshot {
        let period = String(localized: "Last \(HRVStatus.window) nights")
        let chartDays = 7
        let nights = try await source.overnight(days: HRVStatus.baselineNights + HRVStatus.window + chartDays - 1).map(\.hrv)
        guard nights.suffix(HRVStatus.window + 1).contains(where: { $0 != nil }) else { return .noData(period: period) }

        let last = nights.count - 1
        let end = nights[last] == nil ? last - 1 : last
        guard let shown = HRVStatus.status(nights: nights, endingAt: end) else {
            return CardSnapshot(period: period, value: String(localized: "Calibrating"),
                                comparison: String(localized: "Needs \(HRVStatus.minimumBaselineNights + HRVStatus.window) nights of data"))
        }
        let baseline = "\(format(shown.baseline.lowerBound, 0))–\(format(shown.baseline.upperBound, 0))"
        let halfWidth = (shown.baseline.upperBound - shown.baseline.lowerBound) / 2
        return CardSnapshot(
            period: period,
            value: format(shown.average, 0),
            unit: QuantityMetric.hrv.unit,
            comparison: String(localized: "\(shown.state.word) · baseline \(baseline)"),
            tone: shown.state.tone,
            rating: shown.state.rating,
            chart: variant == .week
                ? .line((end - chartDays + 1...end).map { HRVStatus.status(nights: nights, endingAt: $0)?.average },
                        normalRange: shown.baseline)
                : .range(value: shown.average, normalRange: shown.baseline, below: halfWidth, above: .infinity),
            // Not from the night before when last night's HRV hasn't arrived, as for resting heart rate.
            recommendation: isToday && end == last ? Recommendations.hrv(shown.state) : nil
        )
    }

    /// Last night's wrist temperature against the personal normal range, colored by how far it rose.
    /// Current shows it on a gauge; 7 days draws the last 7 nights through the range.
    func wristTemperature(_ variant: CardVariant) async throws -> CardSnapshot {
        let series = try await source.daily(.wristTemperature, days: baselineDays + 1)
        guard let latestIndex = series.indices.suffix(2).last(where: { series[$0].value != nil }),
              let latest = series[latestIndex].value
        else { return .noData(period: lastNightLabel) }

        let toDisplay: (Double) -> Double = { usesMetric ? $0 : $0 * 1.8 + 32 }
        let unit = usesMetric ? "°C" : "°F"
        let history = series[..<latestIndex].compactMap(\.value)
        let period = latestIndex == series.count - 1 ? lastNightLabel : dayLabel(series[latestIndex].day)

        let week = series.suffix(7).map { $0.value.map(toDisplay) }
        guard history.count >= Baseline.minimumDays, let mean = Baseline.average(history) else {
            return CardSnapshot(period: period, value: format(toDisplay(latest), 1), unit: unit, comparison: String(localized: "Calibrating"),
                                chart: variant == .week ? .line(week, normalRange: nil) : .none)
        }
        let range = Baseline.normalRange(history: history, minimumHalfWidth: QuantityMetric.wristTemperature.minimumHalfWidth)
        let shownRange = range.map { toDisplay($0.lowerBound)...toDisplay($0.upperBound) }
        let deviation = (latest - mean) * (usesMetric ? 1 : 1.8)
        let chart: CardSnapshot.Chart = if variant == .week {
            .line(week, normalRange: shownRange)
        } else {
            // A rise can mean illness or a cycle phase; a cooler night is no concern.
            shownRange.map { .range(value: toDisplay(latest), normalRange: $0, higherIsBetter: false, decimals: 1) } ?? .none
        }
        return CardSnapshot(
            period: period,
            value: format(toDisplay(latest), 1),
            unit: unit,
            comparison: String(localized: "\(format(deviation, 1, signed: true))° vs baseline"),
            rating: range.map { DayRatings.range(latest, normal: $0, higherIsBetter: false) },
            chart: chart
        )
    }

    func vo2Max() async throws -> CardSnapshot {
        let readings = try await source.daily(.vo2Max, days: 90).filter { $0.value != nil }
        guard let latest = readings.last, let value = latest.value else { return .noData(period: String(localized: "Latest")) }
        guard let age = try await source.age(), let sex = try await source.biologicalSex() else {
            let points = readings.suffix(7).map(\.value)
            return CardSnapshot(
                period: dayLabel(latest.day),
                value: format(value, 1),
                unit: QuantityMetric.vo2Max.unit,
                comparison: String(localized: "Add your age and sex in Apple Health"),
                chart: .line(Array(repeating: nil, count: 7 - points.count) + points, normalRange: nil)
            )
        }
        let bounds = VO2MaxZones.bounds(age: age, sex: sex)
        let zone = VO2MaxZones.zone(value, bounds: bounds)
        return CardSnapshot(
            period: dayLabel(latest.day),
            value: format(value, 1),
            unit: QuantityMetric.vo2Max.unit,
            comparison: zone.word,
            rating: zone.rating,
            chart: .zones(value: value, bounds: bounds)
        )
    }
}

nonisolated extension SnapshotBuilder {
    /// The latest workout's one-minute heart rate recovery in the last `HeartRateRecovery.cardDays` days, marked when
    /// it's at or below Cole's cut-off (#131).
    func heartRateRecovery() async throws -> CardSnapshot {
        let readings = try await source.heartRateRecovery(days: HeartRateRecovery.cardDays).filter { $0.value != nil }
        guard let latest = readings.last, let value = latest.value else { return .noData(period: String(localized: "Latest")) }
        let points = readings.suffix(7).map(\.value)
        let slow = value <= HeartRateRecovery.slowCutOff
        return CardSnapshot(
            period: dayLabel(latest.day),
            value: format(value, 0),
            unit: QuantityMetric.restingHeartRate.unit,
            comparison: slow ? String(localized: "Slow: \(Int(HeartRateRecovery.slowCutOff)) bpm or less")
                : String(localized: "Above \(Int(HeartRateRecovery.slowCutOff)) bpm"),
            tone: slow ? .warning : .neutral,
            rating: HeartRateRecovery.rating(value),
            chart: .line(Array(repeating: nil, count: 7 - points.count) + points, normalRange: nil)
        )
    }
}

nonisolated extension QuantityMetric {
    var unit: String {
        switch self {
        case .restingHeartRate: String(localized: "bpm", comment: "Unit: beats per minute")
        case .hrv: String(localized: "ms", comment: "Unit: milliseconds")
        case .oxygenSaturation: "%"
        case .respiratoryRate: String(localized: "br/min", comment: "Unit: breaths per minute")
        case .wristTemperature: "°C"
        case .steps, .floors: ""
        case .activeEnergy: String(localized: "kcal", comment: "Unit: kilocalories")
        case .exerciseMinutes: String(localized: "min", comment: "Unit: minutes")
        case .distance: String(localized: "km", comment: "Unit: kilometers")
        case .vo2Max: "ml/kg·min"
        }
    }

    var decimals: Int {
        switch self {
        case .respiratoryRate, .wristTemperature, .distance, .vo2Max: 1
        default: 0
        }
    }

    /// Smallest half-width of the normal range, so normal day-to-day noise isn't flagged.
    var minimumHalfWidth: Double {
        switch self {
        case .restingHeartRate: 3
        case .hrv: 6
        case .oxygenSaturation: 1.5
        case .respiratoryRate: 1
        case .wristTemperature: 0.4
        default: 0
        }
    }
}
