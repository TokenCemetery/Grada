import Foundation
import HealthKit

/// Reads raw data from Apple Health for a date range. Garmin, Oura and others arrive here
/// through their own Apple Health sync.
final class HealthKitReader {
    let store = HKHealthStore()
    private let calendar = Calendar.current

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Every type the app reads.
    static let readTypes: [HKSampleType] =
        QuantityMetric.allCases.map { HKQuantityType($0.identifier) } + [
            HKQuantityType(.heartRate),
            HKCategoryType(.sleepAnalysis),
            HKCategoryType(.appleStandHour),
            HKObjectType.workoutType(),
        ]

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: Set(Self.readTypes))
    }

    /// Date of the oldest data the app can import.
    func earliestSampleDate() async throws -> Date? {
        let dates = [
            try await earliest(.quantitySample(type: HKQuantityType(.stepCount))),
            try await earliest(.quantitySample(type: HKQuantityType(.heartRate))),
            try await earliest(.categorySample(type: HKCategoryType(.sleepAnalysis))),
            try await earliest(.workout()),
        ]
        return dates.compactMap { $0 }.min()
    }

    /// One value per day in `days` (start of day ..< start of day), oldest first.
    func daily(_ metric: QuantityMetric, in days: DateInterval) async throws -> [DayValue] {
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(metric.identifier),
                predicate: HKQuery.predicateForSamples(withStart: days.start, end: days.end)
            ),
            options: metric.isCumulative ? .cumulativeSum : .discreteAverage,
            anchorDate: days.start,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: store)
        var values: [DayValue] = []
        collection.enumerateStatistics(from: days.start, to: days.end) { statistics, _ in
            let quantity = metric.isCumulative ? statistics.sumQuantity() : statistics.averageQuantity()
            values.append(DayValue(day: statistics.startDate, value: quantity.map(metric.convert)))
        }
        return values
    }

    /// Hours with at least a minute of standing, per day. All nil when no stand data exists at all.
    func standHours(in days: DateInterval) async throws -> [DayValue] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(
                type: HKCategoryType(.appleStandHour),
                predicate: HKQuery.predicateForSamples(withStart: days.start, end: days.end)
            )],
            sortDescriptors: []
        )
        let samples = try await descriptor.result(for: store)
        let dayStarts = self.dayStarts(in: days)
        guard !samples.isEmpty else { return dayStarts.map { DayValue(day: $0, value: nil) } }
        let stood = samples.filter { $0.value == HKCategoryValueAppleStandHour.stood.rawValue }
        let counts = Dictionary(grouping: stood) { calendar.startOfDay(for: $0.startDate) }.mapValues { Double($0.count) }
        return dayStarts.map { DayValue(day: $0, value: counts[$0] ?? 0) }
    }

    /// Nights whose wake-up day falls in `days`, oldest first. Sleep counts toward the day you wake up.
    func sleepNights(in days: DateInterval) async throws -> [SleepNight] {
        // Start the evening before the first day so that night is complete.
        let start = calendar.date(byAdding: .hour, value: -12, to: days.start)!
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(
                type: HKCategoryType(.sleepAnalysis),
                predicate: HKQuery.predicateForSamples(withStart: start, end: days.end)
            )],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        let byDay = Dictionary(grouping: samples) { calendar.startOfDay(for: $0.endDate) }
        return byDay.keys.filter { $0 >= days.start && $0 < days.end }.sorted().compactMap { day in
            Self.night(wakeDay: day, samples: byDay[day]!)
        }
    }

    /// Workouts that started in `days`, newest first.
    func workouts(in days: DateInterval) async throws -> [WorkoutSummary] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: days.start, end: days.end))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return try await descriptor.result(for: store).map { workout in
            let info = WorkoutNames.info(for: workout.workoutActivityType)
            return WorkoutSummary(
                id: workout.uuid.uuidString,
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

    private func earliest<Sample: HKSample>(_ predicate: HKSamplePredicate<Sample>) async throws -> Date? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [predicate],
            sortDescriptors: [SortDescriptor(\.startDate)],
            limit: 1
        )
        return try await descriptor.result(for: store).first?.startDate
    }

    private func dayStarts(in days: DateInterval) -> [Date] {
        var result: [Date] = []
        var day = days.start
        while day < days.end {
            result.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
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
