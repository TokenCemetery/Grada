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
        let characteristics = [HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex)]
        try await store.requestAuthorization(toShare: [], read: Set(Self.readTypes as [HKObjectType] + characteristics))
    }

    /// Calls `onChange` whenever Apple Health gets new data for any read type, even while the app is
    /// in the background or not running (iOS relaunches it). `onChange` must call its completion
    /// handler when done, or iOS backs off delivery.
    func observeChanges(_ onChange: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws {
        // Heart rate is sampled every few minutes; its changes come with the daily metrics anyway.
        for type in Self.readTypes where type != HKQuantityType(.heartRate) {
            store.execute(HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                // HealthKit's completion handler may be called from any thread, but isn't annotated Sendable.
                nonisolated(unsafe) let completion = completion
                onChange { completion() }
            })
            try await store.enableBackgroundDelivery(for: type, frequency: .immediate)
        }
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

    /// Hourly totals of a cumulative metric in `interval`, oldest first; hours without data are left out.
    func hourly(_ metric: QuantityMetric, in interval: DateInterval) async throws -> [TimedValue] {
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(metric.identifier),
                predicate: HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
            ),
            options: .cumulativeSum,
            anchorDate: interval.start,
            intervalComponents: DateComponents(hour: 1)
        )
        let collection = try await descriptor.result(for: store)
        var values: [TimedValue] = []
        collection.enumerateStatistics(from: interval.start, to: interval.end) { statistics, _ in
            if let sum = statistics.sumQuantity() {
                values.append(TimedValue(date: statistics.startDate, value: metric.convert(sum)))
            }
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
        // Start the afternoon before the first day so that night is complete.
        let start = calendar.date(byAdding: .hour, value: -12, to: days.start)!
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(
                type: HKCategoryType(.sleepAnalysis),
                predicate: HKQuery.predicateForSamples(withStart: start, end: days.end)
            )],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        let byDay = Dictionary(grouping: samples) { SleepNight.wakeDay(forEnd: $0.endDate, calendar: calendar) }
        return byDay.keys.filter { $0 >= days.start && $0 < days.end }.sorted().compactMap { day in
            Self.night(wakeDay: day, samples: byDay[day]!)
        }
    }

    /// Average heart rate per 5 minutes, oldest first; intervals without data are left out.
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] {
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(.heartRate),
                predicate: HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
            ),
            options: .discreteAverage,
            anchorDate: interval.start,
            intervalComponents: DateComponents(minute: 5)
        )
        let collection = try await descriptor.result(for: store)
        var values: [TimedValue] = []
        collection.enumerateStatistics(from: interval.start, to: interval.end) { statistics, _ in
            if let average = statistics.averageQuantity() {
                values.append(TimedValue(date: statistics.startDate, value: average.doubleValue(for: Self.bpm)))
            }
        }
        return values
    }

    /// HRV and lowest heart rate while asleep, for each wake-up day in `days`.
    func overnightVitals(in days: DateInterval) async throws -> [OvernightVitals] {
        // Start the afternoon before the first day so that night is complete.
        let window = DateInterval(start: calendar.date(byAdding: .hour, value: -12, to: days.start)!, end: days.end)
        let sleep = try await sleepPeriods(in: window)
        guard !sleep.isEmpty else { return [] }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(
                type: HKQuantityType(.heartRateVariabilitySDNN),
                predicate: HKQuery.predicateForSamples(withStart: window.start, end: window.end)
            )],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let hrv = try await descriptor.result(for: store).map {
            TimedValue(date: $0.startDate, value: $0.quantity.doubleValue(for: .secondUnit(with: .milli)))
        }
        return OvernightVitals.make(hrv: hrv, heartRate: try await heartRate(in: window), sleep: sleep, calendar: calendar)
            .filter { $0.wakeDay >= days.start && $0.wakeDay < days.end }
    }

    /// Sleep stages overlapping `interval`, oldest first, from the best source of each night.
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(
                type: HKCategoryType(.sleepAnalysis),
                predicate: HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
            )],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        let byDay = Dictionary(grouping: samples) { SleepNight.wakeDay(forEnd: $0.endDate, calendar: calendar) }
        return byDay.values.flatMap { Self.bestSource($0) }.compactMap { sample in
            let stage: SleepStage?
            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .asleepCore: stage = .core
            case .asleepDeep: stage = .deep
            case .asleepREM: stage = .rem
            case .awake: stage = .awake
            case .asleepUnspecified: stage = nil
            default: return nil // inBed overlaps the asleep samples
            }
            return SleepPeriod(start: sample.startDate, end: sample.endDate, stage: stage)
        }
        .sorted { $0.start < $1.start }
    }

    /// Nil when no birth date is set or reading it isn't allowed. HealthKit reports both as an error
    /// without details (for privacy it doesn't say which), so the error itself carries no information.
    func age() -> Int? {
        guard let components = try? store.dateOfBirthComponents(), components.year != nil,
              let birth = calendar.date(from: components)
        else { return nil }
        return calendar.dateComponents([.year], from: birth, to: .now).year
    }

    /// Nil when not set, set to "Other", or reading it isn't allowed; like the birth date, HealthKit
    /// doesn't say which.
    func biologicalSex() -> BiologicalSex? {
        switch try? store.biologicalSex().biologicalSex {
        case .female: .female
        case .male: .male
        default: nil
        }
    }

    func highestHeartRate(days: Int) async throws -> Double? {
        let start = calendar.date(byAdding: .day, value: -days, to: .now)!
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(.heartRate),
                predicate: HKQuery.predicateForSamples(withStart: start, end: .now)
            ),
            options: .discreteMax
        )
        return try await descriptor.result(for: store)?.maximumQuantity()?.doubleValue(for: Self.bpm)
    }

    private static let bpm = HKUnit.count().unitDivided(by: .minute())

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
        let best = bestSource(samples)
        return best.isEmpty ? nil : night(wakeDay: wakeDay, sourceSamples: best)
    }

    /// One night's samples from the source with sleep stages, then the one with the most sleep.
    private static func bestSource(_ samples: [HKCategorySample]) -> [HKCategorySample] {
        let bySource = Dictionary(grouping: samples) { $0.sourceRevision.source.bundleIdentifier }.values
        let best = bySource.map { ($0, night(wakeDay: .distantPast, sourceSamples: $0)) }.max { lhs, rhs in
            let lhsHasStages = !lhs.1.stages.isEmpty, rhsHasStages = !rhs.1.stages.isEmpty
            return lhsHasStages == rhsHasStages ? lhs.1.asleep < rhs.1.asleep : rhsHasStages
        }
        return best?.0 ?? []
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
