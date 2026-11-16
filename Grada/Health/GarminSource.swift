import Foundation
import HealthKit
import Observation
import os

/// Data read straight from Garmin Connect with the user's own Personal API key, for what Garmin's Apple Health
/// sync leaves out: overnight HRV, resting heart rate, blood oxygen and respiration. Opt-in; works only while a
/// key is saved. Calls go from this iPhone to Garmin, with no server in between.
@Observable
final class GarminSource: HealthSource {
    /// Stored with every value from this source, so it must never change.
    nonisolated static let sourceID = "garminConnect"
    /// Shown in Settings › Data Source and on each metric's "Data from".
    nonisolated static let originName = "Garmin Connect (direct)"
    var id: String { Self.sourceID }
    var name: String { "Garmin Connect" }

    private(set) var isConnected: Bool
    /// Garmin refused the key: it expired or was deleted. Imports stop until the user saves a new one.
    private(set) var needsReconnect: Bool {
        didSet { defaults.set(needsReconnect, forKey: Self.needsReconnectKey) }
    }
    private(set) var lastSync: Date? {
        didSet { defaults.set(lastSync, forKey: Self.lastSyncKey) }
    }
    /// Why the last import from Garmin failed, naming the request; nil once one succeeds.
    private(set) var lastError: String?

    var isAvailable: Bool { isConnected && !needsReconnect }
    /// Garmin publishes no rate limits, and Apple Health changes can trigger imports many times an hour.
    var refreshInterval: TimeInterval { 15 * 60 }

    @ObservationIgnored private let keyStore: any GarminKeyStoring
    @ObservationIgnored private let client: GarminClient
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(subsystem: "Grada", category: "Garmin")
    private static let needsReconnectKey = "garmin.needsReconnect"
    private static let lastSyncKey = "garmin.lastSync"

    /// Days per request, within Garmin's documented maximums: 1 year for daily summaries, 31 days for sleep.
    /// HRV has no documented maximum; it accepted a year when probed (#92).
    nonisolated static let dailyChunk = 365, sleepChunk = 31, hrvChunk = 365, activityPage = 100
    /// How far back `earliestSampleDate` looks for the first day with data.
    nonisolated static let maxHistoryYears = 10

    init(keyStore: any GarminKeyStoring = GarminKeyStore(), transport: GarminClient.Transport? = nil,
         calendar: Calendar = .current, defaults: UserDefaults = .standard) {
        self.keyStore = keyStore
        self.calendar = calendar
        self.defaults = defaults
        client = transport.map { GarminClient(key: { keyStore.key }, transport: $0) } ?? GarminClient(key: { keyStore.key })
        isConnected = keyStore.key != nil
        needsReconnect = defaults.bool(forKey: Self.needsReconnectKey)
        lastSync = defaults.object(forKey: Self.lastSyncKey) as? Date
    }

    /// Saves `key` once Garmin accepts it; a key Garmin refuses isn't kept.
    func connect(key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try keyStore.save(key)
        client.reset()
        do {
            try await client.verify()
        } catch {
            keyStore.delete()
            isConnected = false
            throw error
        }
        isConnected = true
        needsReconnect = false
    }

    /// Removes the key from the Keychain. Data already imported stays.
    func disconnect() {
        keyStore.delete()
        client.reset()
        isConnected = false
        needsReconnect = false
        lastSync = nil
        lastError = nil
    }

    func requestAuthorization() async throws {}

    /// Garmin has no "first day" endpoint: looks back a year at a time until a year has no data.
    func earliestSampleDate() async throws -> Date? {
        var end = calendar.startOfDay(for: .now)
        var earliest: Date?
        for _ in 0..<Self.maxHistoryYears {
            let start = calendar.date(byAdding: .day, value: -(Self.dailyChunk - 1), to: end)!
            let days = try await call("Daily summaries") { try await dailies(from: start, to: end) }
            guard let first = days.filter(\.hasData).compactMap({ GarminData.parseDay($0.calendarDate, calendar: calendar) }).min() else { break }
            earliest = first
            end = calendar.date(byAdding: .day, value: -1, to: start)!
        }
        return earliest
    }

    func batch(for days: DateInterval) async throws -> HealthBatch {
        let first = days.start
        let last = calendar.date(byAdding: .day, value: -1, to: days.end)!
        var dailies: [GarminData.Daily] = [], sleep: [GarminData.Sleep] = [], hrv: [GarminData.HRV] = []
        for (start, end) in chunks(from: first, to: last, days: Self.dailyChunk) {
            dailies += try await call("Daily summaries") { try await self.dailies(from: start, to: end) }
        }
        for (start, end) in chunks(from: first, to: last, days: Self.sleepChunk) {
            sleep += try await call("Sleep") { try await self.sleep(from: start, to: end) }
        }
        for (start, end) in chunks(from: first, to: last, days: Self.hrvChunk) {
            hrv += try await call("HRV") { try await self.hrv(from: start, to: end) }
        }
        let activities = try await call("Activities") { try await self.activities(from: first, to: last) }
        lastSync = .now
        lastError = nil
        return GarminData.batch(days: days, dailies: dailies, sleep: sleep, hrv: hrv, activities: activities, calendar: calendar)
    }

    // Not read live: intraday heart rate, sleep timing and workout screens come from Apple Health.
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] { [] }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { [] }
    func hourly(_ metric: QuantityMetric, in interval: DateInterval) async throws -> [TimedValue] { [] }
    func workoutDetail(_ summary: WorkoutSummary) async throws -> WorkoutDetail { WorkoutDetail() }
    func highestHeartRate(days: Int) async throws -> Double? { nil }
    func age() -> Int? { nil }
    func biologicalSex() -> BiologicalSex? { nil }

    /// Keeps why `request` failed for Settings, and marks the connection as needing a new key when Garmin refuses this one.
    private func call<T>(_ name: String, _ request: () async throws -> T) async throws -> T {
        do {
            return try await request()
        } catch {
            if case GarminClient.Failure.keyRejected = error { needsReconnect = true }
            lastError = "\(name): \(Self.describe(error))"
            logger.error("Garmin \(name, privacy: .public) failed: \(Self.describe(error), privacy: .public)")
            throw error
        }
    }

    /// Decoding errors name the field, so a change in Garmin's JSON can be found from a screenshot.
    nonisolated static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let found), .valueNotFound(_, let found), .keyNotFound(_, let found), .dataCorrupted(let found): context = found
        @unknown default: return error.localizedDescription
        }
        let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        return "unexpected data at \(path.isEmpty ? "top level" : path): \(context.debugDescription)"
    }

    private func dailies(from start: Date, to end: Date) async throws -> [GarminData.Daily] {
        let data = try await client.get("/usersummary-service/v2/dailysummaries", ["startDate": key(start), "endDate": key(end)])
        return try data.map { try JSONDecoder().decode(GarminData.DailySummaries.self, from: $0).data } ?? []
    }

    private func sleep(from start: Date, to end: Date) async throws -> [GarminData.Sleep] {
        let data = try await client.get("/sleep-service/sleep/dailySleepSummariesByDate", ["startDate": key(start), "endDate": key(end)])
        return try data.map { try JSONDecoder().decode([GarminData.Sleep].self, from: $0) } ?? []
    }

    private func hrv(from start: Date, to end: Date) async throws -> [GarminData.HRV] {
        let data = try await client.get("/hrv-service/hrv/daily/\(key(start))/\(key(end))")
        return try data.map { try JSONDecoder().decode(GarminData.HRVSummaries.self, from: $0).hrvSummaries } ?? []
    }

    /// All activities that started between the two days, a page at a time.
    private func activities(from start: Date, to end: Date) async throws -> [GarminData.Activity] {
        var activities: [GarminData.Activity] = []
        while true {
            let data = try await client.get("/activitylist-service/activities/search/activities", [
                "startDate": key(start), "endDate": key(end),
                "start": "\(activities.count)", "limit": "\(Self.activityPage)",
            ])
            let page = try data.map { try JSONDecoder().decode([GarminData.Activity].self, from: $0) } ?? []
            activities += page
            if page.count < Self.activityPage { return activities }
        }
    }

    /// Consecutive ranges of at most `days` days covering `first` through `last`, both inclusive.
    private func chunks(from first: Date, to last: Date, days: Int) -> [(Date, Date)] {
        var chunks: [(Date, Date)] = []
        var start = first
        while start <= last {
            let end = min(last, calendar.date(byAdding: .day, value: days - 1, to: start)!)
            chunks.append((start, end))
            start = calendar.date(byAdding: .day, value: 1, to: end)!
        }
        return chunks
    }

    private func key(_ day: Date) -> String { DayKey.make(day, calendar: calendar) }
}

/// Garmin's JSON and how it maps onto Grada's data. Field names from Garmin's Personal API spec, checked
/// against real responses in #92. Every field is optional: days without data come back with most fields missing.
nonisolated enum GarminData {
    struct DailySummaries: Decodable { var data: [Daily] }

    struct Daily: Decodable {
        var calendarDate: String?
        var movement: Movement?
        var calories: Calories?
        var heartRate: HeartRate?
        var intensityMinutes: IntensityMinutes?
        var respiration: Average?
        var pulseOx: Average?

        struct Movement: Decodable { var steps: Steps? }
        struct Steps: Decodable { var value: Double?; var distanceInMeters: Double? }
        struct Calories: Decodable { var burnedActive: Double? }
        struct HeartRate: Decodable { var restingValue: Double? }
        struct IntensityMinutes: Decodable { var moderate: Double?; var vigorous: Double? }
        struct Average: Decodable { var avgValue: Double? }

        /// Garmin returns an entry for every day asked for, even days the watch wasn't worn.
        var hasData: Bool { (movement?.steps?.value ?? 0) > 0 || heartRate?.restingValue != nil }
    }

    struct Sleep: Decodable {
        var calendarDate: String?
        /// Milliseconds since 1970.
        var sleepStartTimestampGMT: Double?
        var sleepEndTimestampGMT: Double?
        var sleepTimeSeconds: Double?
        var deepSleepSeconds: Double?
        var lightSleepSeconds: Double?
        var remSleepSeconds: Double?
        var awakeSleepSeconds: Double?
        var averageSpO2Value: Double?
        var averageRespirationValue: Double?
    }

    struct HRVSummaries: Decodable { var hrvSummaries: [HRV] }

    /// `calendarDate` is the morning the night ended.
    struct HRV: Decodable {
        var calendarDate: String?
        /// RMSSD, ms: not comparable with Apple Health's SDNN.
        var lastNightAvg: Double?
    }

    struct Activity: Decodable {
        var activityId: Int64?
        /// "yyyy-MM-dd HH:mm:ss" in UTC.
        var startTimeGMT: String?
        /// Seconds.
        var duration: Double?
        var calories: Double?
        var averageHR: Double?
        var activityType: ActivityType?

        struct ActivityType: Decodable { var typeKey: String? }
    }

    static func parseDay(_ calendarDate: String?, calendar: Calendar) -> Date? {
        guard let calendarDate else { return nil }
        let parts = calendarDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func batch(days: DateInterval, dailies: [Daily], sleep: [Sleep], hrv: [HRV], activities: [Activity],
                      calendar: Calendar) -> HealthBatch {
        var batch = HealthBatch(days: days)
        let origin = [GarminSource.originName]
        func add(_ metric: QuantityMetric, _ value: Double?, on day: Date) {
            guard let value else { return }
            batch.daily[metric, default: []].append(DayValue(day: day, value: value))
            batch.origins[DataKind(metric), default: [:]][day] = origin
        }

        // Blood oxygen and respiration: the overnight averages, else the day's.
        var overnightSpO2: [Date: Double] = [:], overnightRespiration: [Date: Double] = [:]
        var vitals: [Date: OvernightVitals] = [:]
        for night in sleep {
            let start = night.sleepStartTimestampGMT.map { Date(timeIntervalSince1970: $0 / 1000) }
            let end = night.sleepEndTimestampGMT.map { Date(timeIntervalSince1970: $0 / 1000) }
            guard let day = end.map({ SleepNight.wakeDay(forEnd: $0, calendar: calendar) }) ?? parseDay(night.calendarDate, calendar: calendar),
                  days.holds(day) else { continue }
            var stages: [SleepStage: TimeInterval] = [:]
            stages[.deep] = night.deepSleepSeconds
            stages[.core] = night.lightSleepSeconds
            stages[.rem] = night.remSleepSeconds
            stages[.awake] = night.awakeSleepSeconds
            let staged = [SleepStage.deep, .core, .rem].contains { (stages[$0] ?? 0) > 0 }
            let unspecified = staged ? 0 : night.sleepTimeSeconds ?? 0
            guard staged || unspecified > 0 else { continue }
            batch.sleepNights.append(SleepNight(wakeDay: day, stages: stages, unspecified: unspecified))
            batch.origins[.sleep, default: [:]][day] = origin
            vitals[day] = OvernightVitals(wakeDay: day, bedtime: start, wakeTime: end)
            overnightSpO2[day] = night.averageSpO2Value
            overnightRespiration[day] = night.averageRespirationValue
        }

        for night in hrv {
            guard let value = night.lastNightAvg, let day = parseDay(night.calendarDate, calendar: calendar), days.holds(day) else { continue }
            vitals[day, default: OvernightVitals(wakeDay: day)].hrv = value
            batch.origins[.overnightHRV, default: [:]][day] = origin
        }
        batch.overnight = vitals.values.sorted { $0.wakeDay < $1.wakeDay }

        for summary in dailies {
            guard let day = parseDay(summary.calendarDate, calendar: calendar), days.holds(day) else { continue }
            add(.steps, summary.movement?.steps?.value, on: day)
            add(.distance, summary.movement?.steps?.distanceInMeters.map { $0 / 1000 }, on: day)
            add(.activeEnergy, summary.calories?.burnedActive, on: day)
            add(.restingHeartRate, summary.heartRate?.restingValue, on: day)
            let intensity = summary.intensityMinutes
            add(.exerciseMinutes, intensity?.moderate == nil && intensity?.vigorous == nil ? nil
                : (intensity?.moderate ?? 0) + (intensity?.vigorous ?? 0), on: day)
            add(.oxygenSaturation, overnightSpO2.removeValue(forKey: day) ?? summary.pulseOx?.avgValue, on: day)
            add(.respiratoryRate, overnightRespiration.removeValue(forKey: day) ?? summary.respiration?.avgValue, on: day)
        }
        // Nights whose day had no daily summary.
        for (day, value) in overnightSpO2 { add(.oxygenSaturation, value, on: day) }
        for (day, value) in overnightRespiration { add(.respiratoryRate, value, on: day) }

        batch.workouts = activities.compactMap { workout($0) }.filter { days.holds($0.start) }
        return batch
    }

    private static let gmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func workout(_ activity: Activity) -> WorkoutSummary? {
        guard let id = activity.activityId, let start = activity.startTimeGMT.flatMap({ gmt.date(from: $0) }), let duration = activity.duration, duration > 0 else { return nil }
        let info = WorkoutNames.info(for: activityType(activity.activityType?.typeKey))
        return WorkoutSummary(id: "garmin-\(id)", start: start, duration: duration, name: info.name,
                              symbol: info.symbol, energyKcal: activity.calories, averageHeartRate: activity.averageHR,
                              source: GarminSource.sourceID, origin: GarminSource.originName)
    }

    /// Garmin's activity type keys Grada names; others become a generic workout.
    static func activityType(_ key: String?) -> HKWorkoutActivityType {
        guard let key else { return .other }
        if key.contains("running") { return .running }
        if key.contains("cycling") || key.contains("biking") || key.contains("ride") { return .cycling }
        if key.contains("swimming") { return .swimming }
        if key.contains("rowing") { return .rowing }
        if key.contains("cross_country") || key.contains("backcountry") { return .crossCountrySkiing }
        if key.contains("skiing") || key.contains("snowboarding") { return .downhillSkiing }
        return switch key {
        case "walking", "casual_walking", "speed_walking": .walking
        case "hiking": .hiking
        case "elliptical": .elliptical
        case "strength_training": .traditionalStrengthTraining
        case "yoga": .yoga
        case "hiit": .highIntensityIntervalTraining
        default: .other
        }
    }
}

private extension DateInterval {
    /// Start inclusive, end exclusive, as `HealthBatch.days` is.
    nonisolated func holds(_ date: Date) -> Bool { date >= start && date < end }
}
