import Foundation
import SwiftData

/// One day of imported Apple Health data. Defaults on every property and no unique
/// constraints keep it ready for CloudKit sync; `dayKey` is the identity used to merge duplicates.
@Model
final class DaySummary {
    /// "yyyy-MM-dd" in the calendar the day was imported with.
    var dayKey: String = ""
    var day: Date = Date.distantPast
    var updatedAt: Date = Date.distantPast

    var restingHeartRate: Double?
    var hrv: Double?
    var oxygenSaturation: Double?
    var respiratoryRate: Double?
    var wristTemperature: Double?
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

    init(day: Date, dayKey: String) {
        self.day = day
        self.dayKey = dayKey
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

/// A workout imported from Apple Health; `healthID` is the Health sample UUID.
@Model
final class WorkoutRecord {
    var healthID: String = ""
    var start: Date = Date.distantPast
    var duration: TimeInterval = 0
    var name: String = ""
    var symbol: String = ""
    var energyKcal: Double?
    var averageHeartRate: Double?

    init(_ workout: WorkoutSummary) {
        healthID = workout.id
        start = workout.start
        duration = workout.duration
        name = workout.name
        symbol = workout.symbol
        energyKcal = workout.energyKcal
        averageHeartRate = workout.averageHeartRate
    }

    var summary: WorkoutSummary {
        WorkoutSummary(id: healthID, start: start, duration: duration, name: name, symbol: symbol,
                       energyKcal: energyKcal, averageHeartRate: averageHeartRate)
    }
}

enum DayKey {
    static func make(_ day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

/// Card data read from the imported store, so cards load instantly and work offline.
struct StoredHealthData: HealthDataSource {
    let context: ModelContext
    var calendar: Calendar = .current

    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] {
        let summaries = try summaries(days: days)
        return lastDays(days).map { DayValue(day: $0, value: summaries[DayKey.make($0, calendar: calendar)]?.value(for: metric)) }
    }

    func standHours(days: Int) async throws -> [DayValue] {
        let summaries = try summaries(days: days)
        return lastDays(days).map { DayValue(day: $0, value: summaries[DayKey.make($0, calendar: calendar)]?.standHours) }
    }

    func sleepNights(days: Int) async throws -> [SleepNight] {
        let summaries = try summaries(days: days)
        return lastDays(days).compactMap { summaries[DayKey.make($0, calendar: calendar)]?.sleepNight }
    }

    func workouts(days: Int) async throws -> [WorkoutSummary] {
        let start = lastDays(days).first!
        let descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.start >= start },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        var seen = Set<String>()
        return try context.fetch(descriptor).filter { seen.insert($0.healthID).inserted }.map(\.summary)
    }

    /// Summaries by day key; the first wins if iCloud delivered duplicates.
    private func summaries(days: Int) throws -> [String: DaySummary] {
        let start = lastDays(days).first!
        let descriptor = FetchDescriptor<DaySummary>(predicate: #Predicate { $0.day >= start })
        return Dictionary(try context.fetch(descriptor).map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func lastDays(_ count: Int) -> [Date] {
        let today = calendar.startOfDay(for: .now)
        return (0..<count).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today)! }
    }
}
