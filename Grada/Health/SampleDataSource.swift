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
