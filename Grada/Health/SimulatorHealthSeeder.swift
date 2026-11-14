#if DEBUG && targetEnvironment(simulator)
import Foundation
import HealthKit

/// Writes realistic sample data into the simulator's Apple Health, so the real import path can be tested.
///
/// Compiled only into Debug simulator builds: the app can never write to Apple Health on a device or in
/// release. The write-permission text (`NSHealthUpdateUsageDescription`) exists only in that build too.
/// Exercise minutes, stand hours and wrist temperature can only be written by Apple, so they stay empty.
final class SimulatorHealthSeeder {
    private let store = HKHealthStore()
    private let calendar = Calendar.current

    private static let quantityTypes: [HKQuantityTypeIdentifier] = [
        .stepCount, .activeEnergyBurned, .distanceWalkingRunning, .flightsClimbed,
        .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation, .respiratoryRate,
        .vo2Max, .heartRate,
    ]
    private static var writeTypes: Set<HKSampleType> {
        Set(quantityTypes.map { HKQuantityType($0) } + [HKCategoryType(.sleepAnalysis), HKObjectType.workoutType()])
    }

    /// Adds `days` days of data ending today. `progress` gets 0...1.
    func seed(days: Int, progress: (Double) -> Void) async throws {
        try await store.requestAuthorization(toShare: Self.writeTypes, read: Set(HealthKitReader.readTypes))
        let today = calendar.startOfDay(for: .now)
        var pending: [HKObject] = []

        for offset in (0..<days).reversed() {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            var random = SeededRandom(seed: UInt64(day.timeIntervalSince1970))
            pending += dailySamples(day: day, random: &random)
            pending += sleepSamples(wakeDay: day, random: &random)
            try await addWorkout(day: day, index: offset, random: &random)

            if pending.count > 500 || offset == 0 {
                try await store.save(pending)
                pending = []
                progress(Double(days - offset) / Double(days))
            }
        }
    }

    /// Deletes only what this app wrote; data from other sources is untouched.
    func removeSampleData() async throws {
        let ownData = HKQuery.predicateForObjects(from: HKSource.default())
        for type in Self.writeTypes {
            _ = try await store.deleteObjects(of: type, predicate: ownData)
        }
    }

    private func dailySamples(day: Date, random: inout SeededRandom) -> [HKObject] {
        // A weekly rhythm plus noise, so trends and normal ranges have something to show.
        let weekday = Double(calendar.component(.weekday, from: day))
        let fitness = 1 + 0.1 * sin(weekday)
        var samples: [HKObject] = []

        func quantity(_ id: HKQuantityTypeIdentifier, _ value: Double, _ unit: HKUnit, from startHour: Int, to endHour: Int) {
            let start = calendar.date(byAdding: .hour, value: startHour, to: day)!
            let end = min(calendar.date(byAdding: .hour, value: endHour, to: day)!, .now)
            guard end > start else { return }
            // Scale daily totals for a day still in progress.
            let share = end.timeIntervalSince(start) / Double((endHour - startHour) * 3600)
            let isTotal = HKQuantityType(id).aggregationStyle == .cumulative
            samples.append(HKQuantitySample(
                type: HKQuantityType(id),
                quantity: HKQuantity(unit: unit, doubleValue: isTotal ? value * share : value),
                start: start, end: end
            ))
        }

        let steps = (9_000 + 2_500 * random.nextSigned()) * fitness
        quantity(.stepCount, steps, .count(), from: 8, to: 21)
        quantity(.distanceWalkingRunning, steps * 0.75, .meter(), from: 8, to: 21)
        quantity(.activeEnergyBurned, (520 + 120 * random.nextSigned()) * fitness, .kilocalorie(), from: 8, to: 21)
        quantity(.flightsClimbed, (9 + 4 * random.nextSigned()).rounded(), .count(), from: 8, to: 21)

        let perMinute = HKUnit.count().unitDivided(by: .minute())
        quantity(.restingHeartRate, 54 + 2 * random.nextSigned(), perMinute, from: 6, to: 7)
        quantity(.heartRateVariabilitySDNN, 62 + 7 * random.nextSigned(), .secondUnit(with: .milli), from: 3, to: 4)
        quantity(.oxygenSaturation, (97 + 0.8 * random.nextSigned()) / 100, .percent(), from: 4, to: 5)
        quantity(.respiratoryRate, 14.5 + 0.6 * random.nextSigned(), perMinute, from: 4, to: 5)
        if calendar.component(.day, from: day) % 5 == 0 {
            quantity(.vo2Max, 47 + 0.4 * random.nextSigned(), HKUnit(from: "ml/kg*min"), from: 18, to: 19)
        }
        return samples
    }

    /// One night ending on `wakeDay`, cycling through sleep stages like a real night.
    private func sleepSamples(wakeDay: Date, random: inout SeededRandom) -> [HKObject] {
        var time = calendar.date(byAdding: .minute, value: -60 + Int(30 * random.nextSigned()), to: wakeDay)!
        let wake = time.addingTimeInterval((7.4 + 0.6 * random.nextSigned()) * 3600)
        guard wake <= .now else { return [] }

        let cycle: [(HKCategoryValueSleepAnalysis, Double)] = [
            (.asleepCore, 25), (.asleepDeep, 20), (.asleepCore, 20), (.asleepREM, 20), (.awake, 4),
        ]
        var samples: [HKObject] = []
        var index = 0
        while time < wake {
            let (stage, minutes) = cycle[index % cycle.count]
            let end = min(time.addingTimeInterval(minutes * 60 * (1 + 0.2 * random.nextSigned())), wake)
            samples.append(HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: stage.rawValue, start: time, end: end))
            // Heart rate as a watch records it overnight: lower in deep sleep, so sleeping heart rate has data.
            samples.append(HKQuantitySample(
                type: HKQuantityType(.heartRate),
                quantity: HKQuantity(unit: .count().unitDivided(by: .minute()),
                                     doubleValue: (stage == .asleepDeep ? 48 : 53) + 2 * random.nextSigned()),
                start: time, end: time.addingTimeInterval(60)
            ))
            time = end
            index += 1
        }
        return samples
    }

    /// Workouts on most days, with heart rate and energy so the workout card has stats.
    private func addWorkout(day: Date, index: Int, random: inout SeededRandom) async throws {
        let pattern: [(HKWorkoutActivityType, Double)?] = [
            (.running, 45), nil, (.traditionalStrengthTraining, 50), nil, (.cycling, 75), (.running, 32), nil,
        ]
        guard let (activity, minutes) = pattern[index % pattern.count] else { return }
        let start = calendar.date(byAdding: .hour, value: 7, to: day)!
        let end = start.addingTimeInterval(minutes * 60)
        guard end <= .now else { return }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: start)

        var samples: [HKSample] = [HKQuantitySample(
            type: HKQuantityType(.activeEnergyBurned),
            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: minutes * 9),
            start: start, end: end
        )]
        var time = start
        while time < end {
            let next = min(time.addingTimeInterval(300), end)
            samples.append(HKQuantitySample(
                type: HKQuantityType(.heartRate),
                quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 140 + 10 * random.nextSigned()),
                start: time, end: next
            ))
            time = next
        }
        try await builder.addSamples(samples)
        try await builder.endCollection(at: end)
        _ = try await builder.finishWorkout()
    }
}
#endif
