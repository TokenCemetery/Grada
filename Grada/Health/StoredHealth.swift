import Foundation
import SwiftData

/// One day of data imported from one source. Defaults on every property and no unique constraints
/// keep it ready for CloudKit sync; `dayKey` and `source` together are the identity used to merge duplicates.
@Model
final class DaySummary {
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
        }
    }
}

/// An imported workout; `healthID` is its ID in its source, e.g. the Apple Health sample UUID.
@Model
final class WorkoutRecord {
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

enum DayKey {
    static func make(_ day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

/// Card data read from the imported store, so cards load instantly and work offline. Each source's
/// rows are merged in the order of `sources`: per day and metric, the first source with a value wins.
/// Intraday data (5-minute heart rate, sleep timing) isn't stored; it's read live from the sources.
struct StoredHealthData: HealthDataSource {
    let context: ModelContext
    /// In order of preference. Stored data from sources not listed here comes after them.
    var sources: [any HealthSource] = []
    var calendar: Calendar = .current
    /// Rows from `loadedSince` on, set by `withDaysLoaded(_:)`; nil to fetch on each read. Fetching costs
    /// about the same per row whatever is read, so a calendar of years of days fetched once per metric was slow.
    var loadedRows: [String: [DaySummary]]?
    var loadedSince: Date = .distantFuture

    func withDaysLoaded(_ days: Int) throws -> HealthDataSource {
        var copy = self
        copy.loadedSince = lastDays(days).first!
        copy.loadedRows = try rows(since: copy.loadedSince)
        return copy
    }

    func heartRate(in interval: DateInterval) async throws -> [TimedValue] {
        for source in sources {
            let values = try await source.heartRate(in: interval)
            if !values.isEmpty { return values }
        }
        return []
    }

    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] {
        for source in sources {
            let periods = try await source.sleepPeriods(in: interval)
            if !periods.isEmpty { return periods }
        }
        return []
    }

    func workoutDetail(_ workout: WorkoutSummary) async throws -> WorkoutDetail {
        try await sources.first { $0.id == workout.source }?.workoutDetail(workout) ?? WorkoutDetail()
    }

    func age() async throws -> Int? {
        sources.lazy.compactMap { $0.age() }.first
    }

    func biologicalSex() async throws -> BiologicalSex? {
        sources.lazy.compactMap { $0.biologicalSex() }.first
    }

    func highestHeartRate(days: Int) async throws -> Double? {
        for source in sources {
            if let highest = try await source.highestHeartRate(days: days) { return highest }
        }
        return nil
    }

    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] {
        try merged(days: days) { $0.value(for: metric) }
    }

    func standHours(days: Int) async throws -> [DayValue] {
        try merged(days: days) { $0.standHours }
    }

    /// Each night's vitals come together from one source, so HRV and bed time aren't from different devices.
    func overnight(days: Int) async throws -> [OvernightVitals] {
        let rows = try rows(days: days)
        return lastDays(days).map { day in
            let summary = first(in: rows, on: day) {
                $0.overnightHRV != nil || $0.sleepingHeartRate != nil || $0.bedtime != nil || $0.wakeTime != nil
            }
            return OvernightVitals(wakeDay: day, hrv: summary?.overnightHRV, heartRate: summary?.sleepingHeartRate,
                                   bedtime: summary?.bedtime, wakeTime: summary?.wakeTime)
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
        let workouts = try context.fetch(descriptor).filter { seen.insert([$0.source, $0.healthID]).inserted }.map(\.summary)
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
        return try context.fetch(descriptor).first?.day
    }

    /// For each day, the value from the first source in order that has one.
    private func merged(days: Int, _ value: (DaySummary) -> Double?) throws -> [DayValue] {
        let rows = try rows(days: days)
        return lastDays(days).map { day in
            DayValue(day: day, value: first(in: rows, on: day) { value($0) != nil }.flatMap(value))
        }
    }

    /// The first row on `day`, in source order, that `matches`.
    private func first(in rows: [String: [DaySummary]], on day: Date, where matches: (DaySummary) -> Bool) -> DaySummary? {
        rows[DayKey.make(day, calendar: calendar)]?.first(where: matches)
    }

    /// Rows by day key, each day's sorted by source preference. If iCloud delivered a source's day twice, the first wins.
    private func rows(days: Int) throws -> [String: [DaySummary]] {
        let start = lastDays(days).first!
        // Extra days in `loadedRows` are harmless: callers look rows up by day.
        if let loadedRows, start >= loadedSince { return loadedRows }
        return try rows(since: start)
    }

    private func rows(since start: Date) throws -> [String: [DaySummary]] {
        let fetched = try context.fetch(FetchDescriptor<DaySummary>(predicate: #Predicate { $0.day >= start }))
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
