import Foundation
import SwiftData

/// One day of data imported from one source. Defaults on every property and no unique constraints
/// keep it ready for CloudKit sync; `dayKey` and `source` together are the identity used to merge duplicates.
@Model
nonisolated final class DaySummary {
    /// "yyyy-MM-dd" in the calendar the day was imported with.
    var dayKey: String = ""
    /// The `HealthSource.id` this row came from. The default fills in rows imported before sources existed,
    /// which all came from Apple Health; it must stay a literal for SwiftData's migration.
    var source: String = "appleHealth"
    var day: Date = Date.distantPast
    var updatedAt: Date = Date.distantPast

    var restingHeartRate: Double?
    var hrv: Double?
    var oxygenSaturation: Double?
    var respiratoryRate: Double?
    var wristTemperature: Double?
    /// Measured while asleep in the night that ended on this day.
    var overnightHRV: Double?
    var sleepingHeartRate: Double?
    var bedtime: Date?
    var wakeTime: Date?
    var steps: Double?
    var activeEnergy: Double?
    var exerciseMinutes: Double?
    var distance: Double?
    var floors: Double?
    var vo2Max: Double?
    var bodyMass: Double?
    var bodyFat: Double?
    var leanBodyMass: Double?
    var height: Double?
    var bloodPressureSystolic: Double?
    var bloodPressureDiastolic: Double?
    var walkingSpeed: Double?
    var walkingStepLength: Double?
    var walkingAsymmetry: Double?
    var walkingSteadiness: Double?
    var standHours: Double?

    /// Seconds per sleep stage for the night that ended on this day.
    var sleepCore: Double?
    var sleepDeep: Double?
    var sleepREM: Double?
    var sleepAwake: Double?
    var sleepUnspecified: Double?

    /// Names of the apps and devices inside the source that this day's values came from, keyed by
    /// `DataKind.rawValue`, e.g. ["hrv": ["Oura"], "steps": ["Oleg’s iPhone", "Oleg’s Apple Watch"]].
    var origins: [String: [String]] = [:]

    init(day: Date, dayKey: String, source: String) {
        self.day = day
        self.dayKey = dayKey
        self.source = source
    }

    func value(for metric: QuantityMetric) -> Double? {
        self[keyPath: Self.keyPath(for: metric)]
    }

    func setValue(_ value: Double?, for metric: QuantityMetric) {
        self[keyPath: Self.keyPath(for: metric)] = value
    }

    var sleepNight: SleepNight? {
        guard sleepCore != nil || sleepDeep != nil || sleepREM != nil || sleepUnspecified != nil else { return nil }
        var stages: [SleepStage: TimeInterval] = [:]
        stages[.core] = sleepCore
        stages[.deep] = sleepDeep
        stages[.rem] = sleepREM
        stages[.awake] = sleepAwake
        return SleepNight(wakeDay: day, stages: stages, unspecified: sleepUnspecified ?? 0)
    }

    func setSleep(_ night: SleepNight?) {
        sleepCore = night?.stages[.core]
        sleepDeep = night?.stages[.deep]
        sleepREM = night?.stages[.rem]
        sleepAwake = night?.stages[.awake]
        sleepUnspecified = night.map(\.unspecified)
    }

    private static func keyPath(for metric: QuantityMetric) -> ReferenceWritableKeyPath<DaySummary, Double?> {
        switch metric {
        case .restingHeartRate: \.restingHeartRate
        case .hrv: \.hrv
        case .oxygenSaturation: \.oxygenSaturation
        case .respiratoryRate: \.respiratoryRate
        case .wristTemperature: \.wristTemperature
        case .steps: \.steps
        case .activeEnergy: \.activeEnergy
        case .exerciseMinutes: \.exerciseMinutes
        case .distance: \.distance
        case .floors: \.floors
        case .vo2Max: \.vo2Max
        case .bodyMass: \.bodyMass
        case .bodyFat: \.bodyFat
        case .leanBodyMass: \.leanBodyMass
        case .height: \.height
        case .bloodPressureSystolic: \.bloodPressureSystolic
        case .bloodPressureDiastolic: \.bloodPressureDiastolic
        case .walkingSpeed: \.walkingSpeed
        case .walkingStepLength: \.walkingStepLength
        case .walkingAsymmetry: \.walkingAsymmetry
        case .walkingSteadiness: \.walkingSteadiness
        }
    }
}

/// An imported workout; `healthID` is its ID in its source, e.g. the Apple Health sample UUID.
@Model
nonisolated final class WorkoutRecord {
    var healthID: String = ""
    /// The `HealthSource.id` this workout came from; see `DaySummary.source` for the default.
    var source: String = "appleHealth"
    var start: Date = Date.distantPast
    var duration: TimeInterval = 0
    var name: String = ""
    var symbol: String = ""
    var energyKcal: Double?
    var averageHeartRate: Double?
    /// The app or device inside the source that recorded it.
    var origin: String?

    init(_ workout: WorkoutSummary) {
        healthID = workout.id
        start = workout.start
        duration = workout.duration
        name = workout.name
        symbol = workout.symbol
        energyKcal = workout.energyKcal
        averageHeartRate = workout.averageHeartRate
        source = workout.source
        origin = workout.origin
    }

    var summary: WorkoutSummary {
        WorkoutSummary(id: healthID, start: start, duration: duration, name: name, symbol: symbol,
                       energyKcal: energyKcal, averageHeartRate: averageHeartRate, source: source, origin: origin)
    }
}

nonisolated enum DayKey {
    static func make(_ day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

/// A plain copy of a `DaySummary`, so rows read on a background context can be used anywhere; SwiftData
/// models must stay on the context that fetched them.
nonisolated struct StoredDay {
    let dayKey: String
    let source: String
    let day: Date
    let metrics: [QuantityMetric: Double]
    let standHours: Double?
    let overnightHRV: Double?
    let sleepingHeartRate: Double?
    let bedtime: Date?
    let wakeTime: Date?
    let sleepNight: SleepNight?
    let origins: [String: [String]]

    init(_ summary: DaySummary) {
        dayKey = summary.dayKey
        source = summary.source
        day = summary.day
        metrics = Dictionary(uniqueKeysWithValues: QuantityMetric.allCases.compactMap { metric in
            summary.value(for: metric).map { (metric, $0) }
        })
        standHours = summary.standHours
        overnightHRV = summary.overnightHRV
        sleepingHeartRate = summary.sleepingHeartRate
        bedtime = summary.bedtime
        wakeTime = summary.wakeTime
        sleepNight = summary.sleepNight
        origins = summary.origins
    }

    func value(for metric: QuantityMetric) -> Double? { metrics[metric] }
}

/// Card data read from the imported store, so cards load instantly and work offline. Each source's
/// rows are merged in the order of `sources`: per day and metric, the first source with a value wins.
/// Intraday data (5-minute heart rate, sleep timing) isn't stored here; it's read live from the sources.
/// Reads and merges on whatever executor calls it, never the main actor's by itself: each read opens its own
/// `ModelContext` on `container`, because a context and its models belong to one actor.
nonisolated struct StoredHealthData: HealthDataSource {
    let container: ModelContainer
    /// In order of preference. Stored data from sources not listed here comes after them.
    var sources: [any LiveHealthSource] = []
    var calendar: Calendar = .autoupdatingCurrent
    /// Where `EnteredProfile` is kept.
    var defaults: UserDefaults = .standard
    /// Rows from `loadedSince` on, set by `withDaysLoaded(_:)`; nil to fetch on each read. Fetching costs
    /// about the same per row whatever is read, so a calendar of years of days fetched once per metric was slow.
    var loadedRows: [String: [StoredDay]]?
    var loadedSince: Date = .distantFuture

    @concurrent func withDaysLoaded(_ days: Int) async throws -> HealthDataSource {
        var copy = self
        copy.loadedSince = lastDays(days).first!
        copy.loadedRows = try rows(since: copy.loadedSince)
        return copy
    }

    /// Each day from the first source with heart rate that day, as daily values are; later sources are asked only
    /// for the span of days still empty (#97).
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] {
        var missing: [Date] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            missing.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        var values: [TimedValue] = []
        for source in sources {
            guard let first = missing.first, let last = missing.last else { break }
            let span = DateInterval(start: max(first, interval.start),
                                    end: min(calendar.date(byAdding: .day, value: 1, to: last)!, interval.end))
            let byDay = Dictionary(grouping: try await source.heartRate(in: span)) { calendar.startOfDay(for: $0.date) }
            for day in missing where byDay[day] != nil { values += byDay[day]! }
            missing.removeAll { byDay[$0] != nil }
        }
        return values.sorted { $0.date < $1.date }
    }

    /// From the first source with any record of it that day; read live, since only journal suggestions use it.
    func time(in activity: TimedActivity, on day: Date) async throws -> TimeInterval? {
        let start = calendar.startOfDay(for: day)
        let interval = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        for source in sources {
            if let time = try await source.time(in: activity, during: interval) { return time }
        }
        return nil
    }

    /// From the first source with any record of it that day; read live, since only journal suggestions use it.
    func intake(_ intake: Intake, on day: Date) async throws -> Double? {
        let start = calendar.startOfDay(for: day)
        let interval = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        for source in sources {
            if let amount = try await source.intake(intake, during: interval) { return amount }
        }
        return nil
    }

    /// From the first source with any record of it, read live and never stored: cycle data stays in Apple Health (#137).
    func menstrualFlow(days: Int) async throws -> [FlowDay] {
        let start = lastDays(days).first!
        let interval = DateInterval(start: start, end: calendar.date(byAdding: .day, value: days, to: start)!)
        for source in sources {
            if let flow = try await source.menstrualFlow(during: interval) { return flow }
        }
        return []
    }

    /// Like `menstrualFlow(days:)`: from the first source with any, read live and never stored (#138).
    func cycleSigns(days: Int) async throws -> [CycleSign] {
        let start = lastDays(days).first!
        let interval = DateInterval(start: start, end: calendar.date(byAdding: .day, value: days, to: start)!)
        for source in sources {
            if let signs = try await source.cycleSigns(during: interval) { return signs }
        }
        return []
    }

    /// Each sleep comes whole from the first source that has it, as nights do in `sleepNights(days:)`, so stages from
    /// different devices aren't mixed (#96). A sleep is a stretch of periods with no `SleepNight.separateSleepGap`;
    /// a later source's sleep that overlaps one already taken is the same sleep, so a nap doesn't hide a night.
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] {
        var periods: [SleepPeriod] = []
        var taken: [DateInterval] = []
        for source in sources {
            let sleeps = SleepNight.separateSleeps(try await source.sleepPeriods(in: interval), start: \.start, end: \.end)
                .filter { sleep in !taken.contains { $0.start < sleep.span.end && sleep.span.start < $0.end } }
            periods += sleeps.flatMap(\.items)
            taken += sleeps.map(\.span)
        }
        return periods.sorted { $0.start < $1.start }
    }

    /// Detail from the workout's own source. Sources without workout heart rate (Garmin, FIT files, which have no
    /// source) get it from the heart rate over the workout's time instead (#98).
    func workoutDetail(_ workout: WorkoutSummary) async throws -> WorkoutDetail {
        var detail = try await sources.first { $0.id == workout.source }?.workoutDetail(workout) ?? WorkoutDetail()
        if detail.heartRate.isEmpty {
            detail.heartRate = try await heartRate(in: DateInterval(start: workout.start, duration: workout.duration))
            detail.maxHeartRate = detail.maxHeartRate ?? detail.heartRate.map(\.value).max()
        }
        return detail
    }

    /// From the first source that has it, else as entered in Settings › Profile (#99).
    func age() async throws -> Int? {
        await sourceAge() ?? EnteredProfile.age(defaults: defaults, calendar: calendar)
    }

    func biologicalSex() async throws -> BiologicalSex? {
        await sourceSex() ?? EnteredProfile.sex(defaults: defaults)
    }

    /// Sources are main-actor objects (HealthKit's characteristics are read there), so these hop to it.
    @MainActor private func sourceAge() -> Int? { sources.lazy.compactMap { $0.age() }.first }
    @MainActor private func sourceSex() -> BiologicalSex? { sources.lazy.compactMap { $0.biologicalSex() }.first }

    /// Whether `age()` and `biologicalSex()` come from a source rather than from what was entered (#121).
    @MainActor func providesProfile() -> (age: Bool, sex: Bool) {
        (sources.contains { $0.age() != nil }, sources.contains { $0.biologicalSex() != nil })
    }

    func highestHeartRate(days: Int) async throws -> Double? {
        for source in sources {
            if let highest = try await source.highestHeartRate(days: days) { return highest }
        }
        return nil
    }

    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] {
        // Blood pressure only from a source with both numbers that day, so a pair isn't mixed between sources (#135).
        if let partner = metric.bloodPressurePartner {
            return try merged(days: days) { $0.metrics[partner] == nil ? nil : $0.metrics[metric] }
        }
        return try merged(days: days) { $0.value(for: metric) }
    }

    func standHours(days: Int) async throws -> [DayValue] {
        try merged(days: days) { $0.standHours }
    }

    /// HRV and heart rate each come from the first source that has them, as daily values do: Garmin writes
    /// sleep and heart rate to Apple Health, but its HRV only comes from its files. Bed and wake time come
    /// together from one source, so a night's timing isn't mixed between devices.
    func overnight(days: Int) async throws -> [OvernightVitals] {
        let rows = try rows(days: days)
        return lastDays(days).map { day in
            let timing = first(in: rows, on: day) { $0.bedtime != nil || $0.wakeTime != nil }
            return OvernightVitals(wakeDay: day,
                                   hrv: first(in: rows, on: day) { $0.overnightHRV != nil }?.overnightHRV,
                                   heartRate: first(in: rows, on: day) { $0.sleepingHeartRate != nil }?.sleepingHeartRate,
                                   bedtime: timing?.bedtime, wakeTime: timing?.wakeTime)
        }
    }

    /// Each night comes whole from one source; stages from different devices aren't mixed.
    func sleepNights(days: Int) async throws -> [SleepNight] {
        let rows = try rows(days: days)
        return lastDays(days).compactMap { day in first(in: rows, on: day) { $0.sleepNight != nil }?.sleepNight }
    }

    func workouts(days: Int) async throws -> [WorkoutSummary] {
        try workouts(since: lastDays(days).first!)
    }

    /// The value on the newest day that has one; on that day the first source in order wins, as for daily values.
    /// Fetches only the days that have one.
    func latest(_ metric: QuantityMetric) async throws -> Double? {
        let predicate: Predicate<DaySummary>
        switch metric {
        case .height: predicate = #Predicate { $0.height != nil }
        case .bodyMass: predicate = #Predicate { $0.bodyMass != nil }
        default: return try await daily(metric, days: 3650).last { $0.value != nil }?.value
        }
        let context = ModelContext(container)
        var newest = FetchDescriptor<DaySummary>(predicate: predicate, sortBy: [SortDescriptor(\.day, order: .reverse)])
        newest.fetchLimit = 1
        guard let key = try context.fetch(newest).first?.dayKey else { return nil }
        // By day key, not instant: the same day stored in another time zone starts at a different instant (#118).
        let sameDay = try context.fetch(FetchDescriptor<DaySummary>(predicate: #Predicate { $0.dayKey == key }))
            .filter { $0.value(for: metric) != nil }
        let rank = rank(Set(sameDay.map(\.source)))
        return sameDay.min { rank[$0.source]! < rank[$1.source]! }?.value(for: metric)
    }

    /// Read live from each workout's own source, like the rest of a workout's detail.
    func heartRateRecovery(days: Int) async throws -> [DayValue] {
        let workouts = try await workouts(days: days)
        var values: [String: Double] = [:]
        for (sourceID, ofSource) in Dictionary(grouping: workouts, by: \.source) {
            guard let source = sources.first(where: { $0.id == sourceID }) else { continue }
            values.merge(try await source.heartRateRecovery(after: ofSource)) { first, _ in first }
        }
        return HeartRateRecovery.byDay(values, workouts: workouts, days: lastDays(days), calendar: calendar)
    }

    /// Read live from each workout's own source, like heart rate recovery.
    func workoutEfforts(days: Int) async throws -> [String: WorkoutEffort] {
        var efforts: [String: WorkoutEffort] = [:]
        for (sourceID, ofSource) in Dictionary(grouping: try await workouts(days: days), by: \.source) {
            guard let source = sources.first(where: { $0.id == sourceID }) else { continue }
            efforts.merge(try await source.effort(of: ofSource)) { first, _ in first }
        }
        return efforts
    }

    /// Per kind, the first source in order with origins wins each day, as it does for the values.
    func origins() async throws -> [DataKind: [DataOrigin]] {
        var lastDay: [DataKind: [String: Date]] = [:]
        for dayRows in try rows(since: .distantPast).values {
            for kind in DataKind.allCases {
                guard let row = dayRows.first(where: { !($0.origins[kind.rawValue] ?? []).isEmpty }) else { continue }
                for name in row.origins[kind.rawValue]! {
                    lastDay[kind, default: [:]][name] = max(lastDay[kind]?[name] ?? .distantPast, row.day)
                }
            }
        }
        for workout in try workouts(since: .distantPast) {
            guard let name = workout.origin else { continue }
            let day = calendar.startOfDay(for: workout.start)
            lastDay[.workouts, default: [:]][name] = max(lastDay[.workouts]?[name] ?? .distantPast, day)
        }
        return lastDay.mapValues { days in
            days.map { DataOrigin(name: $0, lastDay: $1) }.sorted { ($0.lastDay, $1.name) > ($1.lastDay, $0.name) }
        }
    }

    private func workouts(since start: Date) throws -> [WorkoutSummary] {
        let descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.start >= start },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        var seen = Set<[String]>()
        let workouts = try ModelContext(container).fetch(descriptor).filter { seen.insert([$0.source, $0.healthID]).inserted }.map(\.summary)
        let rank = rank(Set(workouts.map(\.source)))
        return SourceMerge.uniqueWorkouts(workouts) { lhs, rhs in
            rank[lhs.source]! != rank[rhs.source]! ? rank[lhs.source]! < rank[rhs.source]! : SourceMerge.mostDetail(lhs, rhs)
        }
    }

    func hourly(_ metric: QuantityMetric, on day: Date) async throws -> [TimedValue] {
        let start = calendar.startOfDay(for: day)
        let interval = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        for source in sources {
            let values = try await source.hourly(metric, in: interval)
            if !values.isEmpty { return values }
        }
        return []
    }

    func earliestDay() async throws -> Date? {
        var descriptor = FetchDescriptor<DaySummary>(sortBy: [SortDescriptor(\.day)])
        descriptor.fetchLimit = 1
        return try ModelContext(container).fetch(descriptor).first?.day
    }

    /// For each day, the value from the first source in order that has one.
    private func merged(days: Int, _ value: (StoredDay) -> Double?) throws -> [DayValue] {
        let rows = try rows(days: days)
        return lastDays(days).map { day in
            DayValue(day: day, value: first(in: rows, on: day) { value($0) != nil }.flatMap(value))
        }
    }

    /// The first row on `day`, in source order, that `matches`.
    private func first(in rows: [String: [StoredDay]], on day: Date, where matches: (StoredDay) -> Bool) -> StoredDay? {
        rows[DayKey.make(day, calendar: calendar)]?.first(where: matches)
    }

    /// Rows by day key, each day's sorted by source preference. If iCloud delivered a source's day twice, the first wins.
    private func rows(days: Int) throws -> [String: [StoredDay]] {
        let start = lastDays(days).first!
        // Extra days in `loadedRows` are harmless: callers look rows up by day.
        if let loadedRows, start >= loadedSince { return loadedRows }
        return try rows(since: start)
    }

    private func rows(since start: Date) throws -> [String: [StoredDay]] {
        // A day stored in a time zone further east starts before `start` as an instant (#118).
        let from = calendar.date(byAdding: .day, value: -1, to: start)!
        let fetched = try ModelContext(container).fetch(FetchDescriptor<DaySummary>(predicate: #Predicate { $0.day >= from })).map(StoredDay.init)
        let rank = rank(Set(fetched.map(\.source)))
        var seen = Set<[String]>()
        return Dictionary(grouping: fetched.filter { seen.insert([$0.dayKey, $0.source]).inserted }, by: \.dayKey)
            .mapValues { $0.sorted { rank[$0.source]! < rank[$1.source]! } }
    }

    /// Position of each source: listed sources first, then any others by name.
    private func rank(_ stored: Set<String>) -> [String: Int] {
        let listed = sources.map(\.id)
        let order = listed + stored.subtracting(listed).sorted()
        return Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func lastDays(_ count: Int) -> [Date] {
        let today = calendar.startOfDay(for: .now)
        return (0..<count).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today)! }
    }
}
