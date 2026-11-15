import Foundation

/// Made-up but realistic data for SwiftUI previews and the simulator, which has no Health data.
/// Enable in the app with the `-SampleData` launch argument.
struct SampleDataSource: HealthDataSource {
    var calendar: Calendar = .current

    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] {
        var random = SeededRandom(seed: UInt64(metric.hashSeed))
        let (base, spread): (Double, Double) = switch metric {
        case .restingHeartRate: (54, 2)
        case .hrv: (62, 7)
        case .oxygenSaturation: (97, 0.8)
        case .respiratoryRate: (14.5, 0.6)
        case .wristTemperature: (35.6, 0.15)
        case .steps: (9_000, 2_500)
        case .activeEnergy: (520, 120)
        case .exerciseMinutes: (38, 15)
        case .distance: (6.5, 2)
        case .floors: (9, 4)
        case .vo2Max: (47, 0.4)
        }
        return lastDays(days).enumerated().map { index, day in
            // VO₂ max is only measured every few days.
            if metric == .vo2Max, index % 5 != 0 { return DayValue(day: day, value: nil) }
            var value = base + spread * random.nextSigned()
            // Today is still in progress for daily totals.
            if metric.isCumulative, index == days - 1 { value *= 0.7 }
            return DayValue(day: day, value: max(0, value))
        }
    }

    /// Overnight HRV runs a little above the daily average, sleeping heart rate a little below resting.
    /// Bed around 23:00 and up around 07:00, give or take 20 minutes.
    func overnight(days: Int) async throws -> [OvernightVitals] {
        let hrv = try await daily(.hrv, days: days)
        let resting = try await daily(.restingHeartRate, days: days)
        var random = SeededRandom(seed: 13)
        return zip(hrv, resting).map { hrv, resting in
            OvernightVitals(
                wakeDay: hrv.day,
                hrv: hrv.value.map { $0 + 3 },
                heartRate: resting.value.map { $0 - 4 },
                bedtime: hrv.day.addingTimeInterval(-3600 + 1200 * random.nextSigned()),
                wakeTime: hrv.day.addingTimeInterval(7 * 3600 + 1200 * random.nextSigned())
            )
        }
    }

    func standHours(days: Int) async throws -> [DayValue] {
        var random = SeededRandom(seed: 7)
        return lastDays(days).map { DayValue(day: $0, value: (10 + 3 * random.nextSigned()).rounded()) }
    }

    func sleepNights(days: Int) async throws -> [SleepNight] {
        var random = SeededRandom(seed: 11)
        return lastDays(days).map { day in
            let total = (7.4 + 0.6 * random.nextSigned()) * 3600
            return SleepNight(
                wakeDay: day,
                stages: [.deep: total * 0.17, .rem: total * 0.23, .core: total * 0.6, .awake: 1_400],
                unspecified: 0
            )
        }
    }

    func workouts(days: Int) async throws -> [WorkoutSummary] {
        let pattern: [(String, String, Double)?] = [
            ("Run", "figure.run", 45), nil, ("Strength", "figure.strengthtraining.traditional", 50), nil,
            ("Ride", "figure.outdoor.cycle", 75), ("Run", "figure.run", 32), nil,
        ]
        return lastDays(days).enumerated().reversed().compactMap { index, day in
            guard let (name, symbol, minutes) = pattern[index % pattern.count] else { return nil }
            return WorkoutSummary(
                id: "sample-\(index)",
                start: calendar.date(byAdding: .hour, value: 7, to: day)!,
                duration: minutes * 60,
                name: name,
                symbol: symbol,
                energyKcal: minutes * 9,
                averageHeartRate: 138
            )
        }
    }

    /// About 50 bpm asleep, 70 awake, and workout effort during the sample workouts.
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] {
        let asleep = try await sleepPeriods(in: interval)
        let workouts = try await workouts(days: 8)
        var random = SeededRandom(seed: 3)
        var values: [TimedValue] = []
        var time = interval.start
        while time < min(interval.end, .now) {
            let base: Double
            if workouts.contains(where: { time >= $0.start && time < $0.start.addingTimeInterval($0.duration) }) {
                base = 140
            } else if asleep.contains(where: { time >= $0.start && time < $0.end && $0.stage != .awake }) {
                base = 51
            } else {
                base = 72
            }
            values.append(TimedValue(date: time, value: base + 5 * random.nextSigned()))
            time.addTimeInterval(300)
        }
        return values
    }

    /// 23:00 to 07:00 every night, in 90-minute cycles of core, deep, REM and a short wake.
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] {
        let cycle: [(SleepStage, TimeInterval)] = [(.core, 45 * 60), (.deep, 20 * 60), (.rem, 20 * 60), (.awake, 5 * 60)]
        var periods: [SleepPeriod] = []
        for day in lastDays(8) {
            var time = calendar.date(byAdding: .hour, value: -1, to: day)!
            let wake = calendar.date(byAdding: .hour, value: 7, to: day)!
            var index = 0
            while time < wake {
                let (stage, length) = cycle[index % cycle.count]
                let end = min(time.addingTimeInterval(length), wake)
                if end <= .now, end > interval.start, time < interval.end {
                    periods.append(SleepPeriod(start: time, end: end, stage: stage))
                }
                time = end
                index += 1
            }
        }
        return periods
    }

    func age() async throws -> Int? { 35 }
    func biologicalSex() async throws -> BiologicalSex? { .male }

    func highestHeartRate(days: Int) async throws -> Double? { 184 }

    /// Spreads the day's total over waking hours, busiest around lunch and early evening.
    func hourly(_ metric: QuantityMetric, on day: Date) async throws -> [TimedValue] {
        let start = calendar.startOfDay(for: day)
        let daysAgo = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: .now)).day ?? 0
        guard let total = try await daily(metric, days: daysAgo + 1).first?.value else { return [] }
        let weights: [Double] = [0, 0, 0, 0, 0, 0, 0.5, 1, 1.5, 1, 1, 1, 2, 1.5, 1, 1, 1, 1.5, 2, 1.5, 1, 0.5, 0.2, 0]
        let lastHour = calendar.isDateInToday(day) ? calendar.component(.hour, from: .now) : 23
        let share = weights[0...lastHour].reduce(0, +)
        return (0...lastHour).compactMap { hour in
            guard weights[hour] > 0 else { return nil }
            return TimedValue(date: calendar.date(byAdding: .hour, value: hour, to: start)!, value: total * weights[hour] / share)
        }
    }

    /// Half a year of history for the calendar.
    func earliestDay() async throws -> Date? {
        lastDays(182).first
    }

    private func lastDays(_ count: Int) -> [Date] {
        let today = calendar.startOfDay(for: .now)
        return (0..<count).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today)! }
    }
}

/// Deterministic generator so previews look the same every time.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    /// A value in -1...1.
    mutating func nextSigned() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
}

private extension QuantityMetric {
    var hashSeed: Int { QuantityMetric.allCases.firstIndex(of: self)! + 1 }
}
