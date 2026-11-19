import Foundation
import CoreLocation
import HealthKit
import os

/// Reads raw data from Apple Health for a date range. Garmin, Oura and others arrive here
/// through their own Apple Health sync.
final class HealthKitReader: HealthSource {
    let store = HKHealthStore()
    private let calendar = Calendar.current
    private let logger = Logger(subsystem: "Grada", category: "HealthKitReader")

    nonisolated static let sourceID = "appleHealth"
    var id: String { Self.sourceID }
    var name: String { "Apple Health" }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    var isAvailable: Bool { Self.isAvailable }

    /// Every type the app reads.
    static let readTypes: [HKSampleType] =
        QuantityMetric.allCases.map { HKQuantityType($0.identifier) } + [
            HKQuantityType(.heartRate),
            HKCategoryType(.sleepAnalysis),
            HKCategoryType(.appleStandHour),
            HKObjectType.workoutType(),
            // Workout screens: ride and swim distance for splits, and the GPS route.
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
            HKSeriesType.workoutRoute(),
            // Journal suggestions: Meditation and Outdoor time.
            HKCategoryType(.mindfulSession),
            HKQuantityType(.timeInDaylight),
        ]

    func requestAuthorization() async throws {
        let characteristics = [HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex)]
        try await store.requestAuthorization(toShare: [], read: Set(Self.readTypes as [HKObjectType] + characteristics))
    }

    /// Calls `onChange` whenever Apple Health gets new data for any read type, even while the app is
    /// in the background or not running (iOS relaunches it). `onChange` must call its completion
    /// handler when done, or iOS backs off delivery.
    func observeChanges(_ onChange: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws {
        // Heart rate is sampled every few minutes; its changes come with the daily metrics anyway. Workout
        // screen data (ride and swim distance, routes) is read live and arrives with its workout.
        // Mindful sessions and daylight are read live for the Journal and aren't imported either.
        let unobserved: Set<HKSampleType> = [HKQuantityType(.heartRate), HKQuantityType(.distanceCycling),
                                             HKQuantityType(.distanceSwimming), HKSeriesType.workoutRoute(),
                                             HKCategoryType(.mindfulSession), HKQuantityType(.timeInDaylight)]
        for type in Self.readTypes where !unobserved.contains(type) {
            store.execute(HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                // HealthKit's completion handler may be called from any thread, but isn't annotated Sendable.
                nonisolated(unsafe) let completion = completion
                onChange { completion() }
            })
            // One type failing mustn't leave the rest without background delivery (#120).
            do {
                try await store.enableBackgroundDelivery(for: type, frequency: .immediate)
            } catch {
                logger.error("Background delivery for \(type.identifier) unavailable: \(error.localizedDescription)")
            }
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

    func batch(for days: DateInterval) async throws -> HealthBatch {
        var batch = HealthBatch(days: days)
        for metric in QuantityMetric.allCases {
            (batch.daily[metric], batch.origins[DataKind(metric)]) = try await daily(metric, in: days)
        }
        (batch.standHours, batch.origins[.standHours]) = try await standHours(in: days)
        (batch.sleepNights, batch.origins[.sleep]) = try await sleepNights(in: days)
        (batch.overnight, batch.origins[.overnightHRV]) = try await overnightVitals(in: days)
        batch.workouts = try await workouts(in: days)
        return batch
    }

    /// The name Apple Health shows for a source, plus the device when it says more, e.g.
    /// "Garmin Connect · Forerunner 265". Apple's own sources are already named after the device.
    nonisolated static func originName(_ source: HKSource, device: HKDevice?) -> String {
        guard let device = device?.name, !device.isEmpty, !source.name.localizedCaseInsensitiveContains(device) else {
            return source.name
        }
        return "\(source.name) · \(device)"
    }

    /// One value per day in `days` (start of day ..< start of day), oldest first, and the apps it came
    /// from. Totals are merged by Apple Health, which drops overlaps between apps by the source priority
    /// set in the Health app. Readings such as HRV come from one app per metric; see `SourceMerge.rankByCoverage`.
    func daily(_ metric: QuantityMetric, in days: DateInterval) async throws -> ([DayValue], [Date: [String]]) {
        guard metric.isCumulative else { return try await readings(metric, in: days) }
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(metric.identifier),
                predicate: HKQuery.predicateForSamples(withStart: days.start, end: days.end)
            ),
            options: [.cumulativeSum, .separateBySource],
            anchorDate: days.start,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: store)
        var values: [DayValue] = []
        var origins: [Date: [String]] = [:]
        collection.enumerateStatistics(from: days.start, to: days.end) { statistics, _ in
            values.append(DayValue(day: statistics.startDate, value: statistics.sumQuantity().map(metric.convert)))
            let names = (statistics.sources ?? []).filter { (statistics.sumQuantity(for: $0).map(metric.convert) ?? 0) > 0 }
                .map { Self.originName($0, device: nil) }
            if !names.isEmpty { origins[statistics.startDate] = names.sorted() }
        }
        return (values, origins)
    }

    /// Daily averages of a reading, from the app with the most days of it lately; other apps fill only
    /// the days it missed. Averaging apps together would blend devices that measure differently.
    private func readings(_ metric: QuantityMetric, in days: DateInterval) async throws -> ([DayValue], [Date: [String]]) {
        let start = min(days.start, calendar.date(byAdding: .day, value: -SourceMerge.coverageDays, to: days.end)!)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(metric.identifier),
                predicate: HKQuery.predicateForSamples(withStart: start, end: days.end)
            ),
            options: [.discreteAverage, .separateBySource],
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: store)
        var bySource: [String: [DayValue]] = [:]
        var names: [String: String] = [:]
        collection.enumerateStatistics(from: start, to: days.end) { statistics, _ in
            for source in statistics.sources ?? [] {
                if let average = statistics.averageQuantity(for: source) {
                    bySource[source.bundleIdentifier, default: []].append(DayValue(day: statistics.startDate, value: metric.convert(average)))
                    names[source.bundleIdentifier] = Self.originName(source, device: nil)
                }
            }
        }
        let order = SourceMerge.rankByCoverage(bySource, endingBefore: days.end, calendar: calendar)
        let dayStarts = dayStarts(in: days)
        let daysBySource = bySource.mapValues { Set($0.map(\.day)) }
        let origins = dayStarts.reduce(into: [Date: [String]]()) { origins, day in
            if let id = order.first(where: { daysBySource[$0]!.contains(day) }) { origins[day] = [names[id]!] }
        }
        return (SourceMerge.firstAvailable(bySource, order: order, days: dayStarts), origins)
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

    /// Hours with at least a minute of standing, per day, and the devices that recorded them. All nil
    /// when no stand data exists at all.
    func standHours(in days: DateInterval) async throws -> ([DayValue], [Date: [String]]) {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(
                type: HKCategoryType(.appleStandHour),
                predicate: HKQuery.predicateForSamples(withStart: days.start, end: days.end)
            )],
            sortDescriptors: []
        )
        let samples = try await descriptor.result(for: store)
        let dayStarts = self.dayStarts(in: days)
        guard !samples.isEmpty else { return (dayStarts.map { DayValue(day: $0, value: nil) }, [:]) }
        let byDay = Dictionary(grouping: samples) { calendar.startOfDay(for: $0.startDate) }
        let counts = byDay.mapValues { samples in
            Double(samples.filter { $0.value == HKCategoryValueAppleStandHour.stood.rawValue }.count)
        }
        let origins = byDay.mapValues { samples in
            Set(samples.map { Self.originName($0.sourceRevision.source, device: $0.device) }).sorted()
        }
        return (dayStarts.map { DayValue(day: $0, value: counts[$0] ?? 0) }, origins)
    }

    /// Nights whose wake-up day falls in `days`, oldest first, and the app each came from. Sleep counts
    /// toward the day you wake up.
    func sleepNights(in days: DateInterval) async throws -> ([SleepNight], [Date: [String]]) {
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
        var nights: [SleepNight] = []
        var origins: [Date: [String]] = [:]
        for day in byDay.keys.filter({ $0 >= days.start && $0 < days.end }).sorted() {
            let best = SleepNight.mainSleep(Self.bestSource(byDay[day]!), start: \.startDate, end: \.endDate)
            guard let first = best.first else { continue }
            nights.append(Self.night(wakeDay: day, sourceSamples: best))
            origins[day] = [Self.originName(first.sourceRevision.source, device: first.device)]
        }
        return (nights, origins)
    }

    /// Average heart rate per 5 minutes, oldest first; intervals without data are left out.
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] {
        try await heartRate(in: interval, from: nil)
    }

    /// `from` limits the readings to one app; nil uses every app.
    private func heartRate(in interval: DateInterval, from source: HKSource?) async throws -> [TimedValue] {
        var predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        if let source {
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, HKQuery.predicateForObjects(from: source)])
        }
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.heartRate), predicate: predicate),
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

    /// HRV and lowest heart rate while asleep, for each wake-up day in `days`, and the app they came from.
    /// Both come from the app with the most days of HRV lately, as `readings` picks, so each night's values
    /// come from one device.
    func overnightVitals(in days: DateInterval) async throws -> ([OvernightVitals], [Date: [String]]) {
        // Start the afternoon before the first day so that night is complete.
        let window = DateInterval(start: calendar.date(byAdding: .hour, value: -12, to: days.start)!, end: days.end)
        let sleep = try await sleepPeriods(in: window)
        guard !sleep.isEmpty else { return ([], [:]) }
        let coverageStart = min(window.start, calendar.date(byAdding: .day, value: -SourceMerge.coverageDays, to: days.end)!)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(
                type: HKQuantityType(.heartRateVariabilitySDNN),
                predicate: HKQuery.predicateForSamples(withStart: coverageStart, end: window.end)
            )],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        let daysBySource = Dictionary(grouping: samples) { $0.sourceRevision.source.bundleIdentifier }.mapValues { samples in
            Set(samples.map { calendar.startOfDay(for: $0.startDate) }).map { DayValue(day: $0, value: 1) }
        }
        let mainID = SourceMerge.rankByCoverage(daysBySource, endingBefore: days.end, calendar: calendar).first
        let main = samples.first { $0.sourceRevision.source.bundleIdentifier == mainID }?.sourceRevision.source
        let hrv = samples.filter { $0.sourceRevision.source == main && $0.startDate >= window.start }.map {
            TimedValue(date: $0.startDate, value: $0.quantity.doubleValue(for: .secondUnit(with: .milli)))
        }
        var heartRate = try await self.heartRate(in: window, from: main)
        // Without HRV from any app, heart rate from every app is used, so no one app can be named.
        let mainName = main.map { main in
            Self.originName(main, device: samples.first { $0.sourceRevision.source == main }?.device)
        }
        if heartRate.isEmpty { heartRate = try await self.heartRate(in: window) }
        let nights = OvernightVitals.make(hrv: hrv, heartRate: heartRate, sleep: sleep, calendar: calendar)
            .filter { $0.wakeDay >= days.start && $0.wakeDay < days.end }
        var origins: [Date: [String]] = [:]
        if let mainName {
            for night in nights where night.hrv != nil || night.heartRate != nil { origins[night.wakeDay] = [mainName] }
        }
        return (nights, origins)
    }

    func time(in activity: TimedActivity, during interval: DateInterval) async throws -> TimeInterval? {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        switch activity {
        case .mindfulness:
            let sessions = try await HKSampleQueryDescriptor(
                predicates: [.categorySample(type: HKCategoryType(.mindfulSession), predicate: predicate)], sortDescriptors: []
            ).result(for: store)
            guard !sessions.isEmpty else { return nil }
            // Clipped to the interval; overlapping sessions from two apps would count twice, which is rare enough.
            return sessions.reduce(0) { $0 + min($1.endDate, interval.end).timeIntervalSince(max($1.startDate, interval.start)) }
        case .daylight:
            let statistics = try await HKStatisticsQueryDescriptor(
                predicate: .quantitySample(type: HKQuantityType(.timeInDaylight), predicate: predicate), options: .cumulativeSum
            ).result(for: store)
            return statistics?.sumQuantity().map { $0.doubleValue(for: .minute()) * 60 }
        }
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

    /// Workouts that started in `days`, newest first. A workout several apps wrote is kept once.
    func workouts(in days: DateInterval) async throws -> [WorkoutSummary] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: days.start, end: days.end))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let workouts = try await descriptor.result(for: store).map { workout in
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
                    .averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())),
                origin: Self.originName(workout.sourceRevision.source, device: workout.device)
            )
        }
        return SourceMerge.uniqueWorkouts(workouts)
    }

    func workoutDetail(_ summary: WorkoutSummary) async throws -> WorkoutDetail {
        guard let uuid = UUID(uuidString: summary.id),
              let workout = try await HKSampleQueryDescriptor(
                  predicates: [.workout(HKQuery.predicateForObject(with: uuid))], sortDescriptors: []
              ).result(for: store).first
        else { return WorkoutDetail() }

        let during = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate)
        let heartRate = try await HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: during)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        ).result(for: store).map { TimedValue(date: $0.startDate, value: $0.quantity.doubleValue(for: Self.bpm)) }

        let distanceTypes: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
        let distanceType = distanceTypes.map { HKQuantityType($0) }.first { workout.statistics(for: $0)?.sumQuantity() != nil }
        let distance = distanceType.flatMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
        var track: [TimedValue] = []
        if let distanceType, let distance {
            track = try await distanceTrack(distanceType, workout: workout, during: during, total: distance)
        }

        var route: [RoutePoint] = []
        let routes = try await HKSampleQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        ).result(for: store)
        for workoutRoute in routes {
            for try await location in HKWorkoutRouteQueryDescriptor(workoutRoute).results(for: store) {
                route.append(RoutePoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
            }
        }

        return WorkoutDetail(
            heartRate: heartRate,
            maxHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?.maximumQuantity()?.doubleValue(for: Self.bpm)
                ?? heartRate.map(\.value).max(),
            distance: distance,
            distanceTrack: track,
            elevationGain: (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()),
            route: route
        )
    }

    /// Distance so far through the workout. Prefers the samples recorded with the workout; when a phone
    /// and a watch both counted, the track is scaled to the workout's own total so splits aren't doubled.
    private func distanceTrack(_ type: HKQuantityType, workout: HKWorkout, during: NSPredicate,
                               total: Double) async throws -> [TimedValue] {
        func samples(_ predicate: NSPredicate) async throws -> [HKQuantitySample] {
            try await HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: type, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            ).result(for: store)
        }
        var found = try await samples(HKQuery.predicateForObjects(from: workout))
        if found.isEmpty { found = try await samples(during) }
        var sum = 0.0
        let track = found.map { sample in
            sum += sample.quantity.doubleValue(for: .meter())
            return TimedValue(date: sample.endDate, value: sum)
        }
        guard sum > 0 else { return [] }
        return track.map { TimedValue(date: $0.date, value: $0.value * total / sum) }
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
    /// one night's samples from the source with sleep stages, then the one with the most sleep.
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

nonisolated enum WorkoutNames {
    static func info(for type: HKWorkoutActivityType) -> (name: String, symbol: String) {
        switch type {
        case .running: (String(localized: "Run", comment: "Workout type name"), "figure.run")
        case .walking: (String(localized: "Walk", comment: "Workout type name"), "figure.walk")
        case .hiking: (String(localized: "Hike", comment: "Workout type name"), "figure.hiking")
        case .cycling: (String(localized: "Ride", comment: "Workout type name"), "figure.outdoor.cycle")
        case .swimming: (String(localized: "Swim", comment: "Workout type name"), "figure.pool.swim")
        case .traditionalStrengthTraining, .functionalStrengthTraining: (String(localized: "Strength", comment: "Workout type name"), "figure.strengthtraining.traditional")
        case .highIntensityIntervalTraining: (String(localized: "HIIT", comment: "Workout type name"), "figure.highintensity.intervaltraining")
        case .yoga: (String(localized: "Yoga", comment: "Workout type name"), "figure.yoga")
        case .rowing: (String(localized: "Row", comment: "Workout type name"), "figure.rower")
        case .elliptical: (String(localized: "Elliptical", comment: "Workout type name"), "figure.elliptical")
        case .crossCountrySkiing, .downhillSkiing: (String(localized: "Ski", comment: "Workout type name"), "figure.skiing.downhill")
        default: (String(localized: "Workout", comment: "Workout type name"), "figure.mixed.cardio")
        }
    }
}
