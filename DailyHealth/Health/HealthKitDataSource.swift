import Foundation
import HealthKit

/// Reads raw data from Apple Health. Garmin, Oura and others arrive here through their own Apple Health sync.
final class HealthKitDataSource: HealthDataSource {
    private let store = HKHealthStore()
    private let calendar = Calendar.current

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        var types: Set<HKObjectType> = Set(QuantityMetric.allCases.map { HKQuantityType($0.identifier) })
        types.insert(HKQuantityType(.heartRate))
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKCategoryType(.appleStandHour))
        types.insert(HKObjectType.workoutType())
        try await store.requestAuthorization(toShare: [], read: types)
    }

    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] {
        let start = startOfDay(daysAgo: days - 1)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(metric.identifier),
                predicate: HKQuery.predicateForSamples(withStart: start, end: end)
            ),
            options: metric.isCumulative ? .cumulativeSum : .discreteAverage,
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: store)
        var values: [DayValue] = []
        collection.enumerateStatistics(from: start, to: end) { statistics, _ in
            let quantity = metric.isCumulative ? statistics.sumQuantity() : statistics.averageQuantity()
            values.append(DayValue(day: statistics.startDate, value: quantity.map(metric.convert)))
        }
        return values
    }

    func standHours(days: Int) async throws -> [DayValue] {
        let start = startOfDay(daysAgo: days - 1)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(
                type: HKCategoryType(.appleStandHour),
                predicate: HKQuery.predicateForSamples(withStart: start, end: nil)
            )],
            sortDescriptors: []
        )
        let samples = try await descriptor.result(for: store)
        guard !samples.isEmpty else { return lastDays(days).map { DayValue(day: $0, value: nil) } }
        let stood = samples.filter { $0.value == HKCategoryValueAppleStandHour.stood.rawValue }
        let counts = Dictionary(grouping: stood) { calendar.startOfDay(for: $0.startDate) }.mapValues { Double($0.count) }
        return lastDays(days).map { DayValue(day: $0, value: counts[$0] ?? 0) }
    }

    func sleepNights(days: Int) async throws -> [SleepNight] {
        // Start the evening before the first day so that night is complete.
        let start = calendar.date(byAdding: .hour, value: -12, to: startOfDay(daysAgo: days - 1))!
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(
                type: HKCategoryType(.sleepAnalysis),
                predicate: HKQuery.predicateForSamples(withStart: start, end: nil)
            )],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        let firstDay = startOfDay(daysAgo: days - 1)

        // Sleep counts toward the day you wake up.
        let byDay = Dictionary(grouping: samples) { calendar.startOfDay(for: $0.endDate) }
        return byDay.keys.filter { $0 >= firstDay }.sorted().compactMap { day in
            Self.night(wakeDay: day, samples: byDay[day]!)
        }
    }

    func workouts(days: Int) async throws -> [WorkoutSummary] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: startOfDay(daysAgo: days - 1), end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return try await descriptor.result(for: store).map { workout in
            let info = WorkoutNames.info(for: workout.workoutActivityType)
            return WorkoutSummary(
                start: workout.startDate,
                duration: workout.duration,
                name: info.name,
                symbol: info.symbol,
                energyKcal: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                    .sumQuantity()?.doubleValue(for: .kilocalorie()),
                averageHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?
                    .averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
            )
        }
    }

    /// Several apps and watches can record the same night. Using one source avoids double counting:
    /// the one with sleep stages, then the one with the most sleep.
    private static func night(wakeDay: Date, samples: [HKCategorySample]) -> SleepNight? {
        let nights = Dictionary(grouping: samples) { $0.sourceRevision.source.bundleIdentifier }
            .values.map { night(wakeDay: wakeDay, sourceSamples: $0) }
        return nights.max { lhs, rhs in
            let lhsHasStages = !lhs.stages.isEmpty, rhsHasStages = !rhs.stages.isEmpty
            return lhsHasStages == rhsHasStages ? lhs.asleep < rhs.asleep : rhsHasStages
        }
    }

    private static func night(wakeDay: Date, sourceSamples: [HKCategorySample]) -> SleepNight {
        var night = SleepNight(wakeDay: wakeDay, stages: [:], unspecified: 0)
        for sample in sourceSamples {
            let duration = sample.endDate.timeIntervalSince(sample.startDate)
            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .asleepCore: night.stages[.core, default: 0] += duration
            case .asleepDeep: night.stages[.deep, default: 0] += duration
            case .asleepREM: night.stages[.rem, default: 0] += duration
            case .awake: night.stages[.awake, default: 0] += duration
            case .asleepUnspecified: night.unspecified += duration
            default: break // inBed overlaps the asleep samples
            }
        }
        return night
    }

    private func startOfDay(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now))!
    }

    private func lastDays(_ count: Int) -> [Date] {
        (0..<count).reversed().map { startOfDay(daysAgo: $0) }
    }
}

extension QuantityMetric {
    var identifier: HKQuantityTypeIdentifier {
        switch self {
        case .restingHeartRate: .restingHeartRate
        case .hrv: .heartRateVariabilitySDNN
        case .oxygenSaturation: .oxygenSaturation
        case .respiratoryRate: .respiratoryRate
        case .wristTemperature: .appleSleepingWristTemperature
        case .steps: .stepCount
        case .activeEnergy: .activeEnergyBurned
        case .exerciseMinutes: .appleExerciseTime
        case .distance: .distanceWalkingRunning
        case .floors: .flightsClimbed
        case .vo2Max: .vo2Max
        }
    }

    func convert(_ quantity: HKQuantity) -> Double {
        switch self {
        case .restingHeartRate, .respiratoryRate: quantity.doubleValue(for: .count().unitDivided(by: .minute()))
        case .hrv: quantity.doubleValue(for: .secondUnit(with: .milli))
        case .oxygenSaturation: quantity.doubleValue(for: .percent()) * 100
        case .wristTemperature: quantity.doubleValue(for: .degreeCelsius())
        case .steps, .floors: quantity.doubleValue(for: .count())
        case .activeEnergy: quantity.doubleValue(for: .kilocalorie())
        case .exerciseMinutes: quantity.doubleValue(for: .minute())
        case .distance: quantity.doubleValue(for: .meterUnit(with: .kilo))
        case .vo2Max: quantity.doubleValue(for: HKUnit(from: "ml/kg*min"))
        }
    }
}

private enum WorkoutNames {
    static func info(for type: HKWorkoutActivityType) -> (name: String, symbol: String) {
        switch type {
        case .running: ("Run", "figure.run")
        case .walking: ("Walk", "figure.walk")
        case .hiking: ("Hike", "figure.hiking")
        case .cycling: ("Ride", "figure.outdoor.cycle")
        case .swimming: ("Swim", "figure.pool.swim")
        case .traditionalStrengthTraining, .functionalStrengthTraining: ("Strength", "figure.strengthtraining.traditional")
        case .highIntensityIntervalTraining: ("HIIT", "figure.highintensity.intervaltraining")
        case .yoga: ("Yoga", "figure.yoga")
        case .rowing: ("Row", "figure.rower")
        case .elliptical: ("Elliptical", "figure.elliptical")
        case .crossCountrySkiing, .downhillSkiing: ("Ski", "figure.skiing.downhill")
        default: ("Workout", "figure.mixed.cardio")
        }
    }
}
