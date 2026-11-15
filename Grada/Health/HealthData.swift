import Foundation

/// One calendar day's value; `value` is nil when Apple Health has nothing for that day.
nonisolated struct DayValue: Equatable {
    let day: Date
    let value: Double?
}

/// Quantity metrics read from Apple Health, in the units the app displays.
nonisolated enum QuantityMetric: CaseIterable {
    case restingHeartRate, hrv, oxygenSaturation, respiratoryRate, wristTemperature
    case steps, activeEnergy, exerciseMinutes, distance, floors, vo2Max

    /// Summed per day (steps) vs averaged per day (heart rate).
    var isCumulative: Bool {
        switch self {
        case .steps, .activeEnergy, .exerciseMinutes, .distance, .floors: true
        default: false
        }
    }
}

nonisolated enum SleepStage: CaseIterable {
    case awake, rem, core, deep
}

/// Sleep that ended on `wakeDay`. Durations in seconds.
nonisolated struct SleepNight: Equatable {
    let wakeDay: Date
    var stages: [SleepStage: TimeInterval]
    /// Asleep time not split into stages (e.g. from apps without stage tracking).
    var unspecified: TimeInterval

    var asleep: TimeInterval {
        unspecified + (stages[.core] ?? 0) + (stages[.deep] ?? 0) + (stages[.rem] ?? 0)
    }

    /// The day a stretch of sleep ending at `end` counts toward. Sleep ending after 18:00 belongs to the
    /// next morning, so a night that starts before midnight stays in one piece.
    static func wakeDay(forEnd end: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: end.addingTimeInterval(6 * 3600))
    }
}

nonisolated struct WorkoutSummary: Hashable {
    /// The Apple Health sample UUID, stable across devices.
    let id: String
    let start: Date
    let duration: TimeInterval
    let name: String
    let symbol: String
    let energyKcal: Double?
    let averageHeartRate: Double?
}

/// What a workout's own screen needs beyond its summary, read live from Apple Health on this device.
nonisolated struct WorkoutDetail: Equatable {
    /// Heart rate readings during the workout, oldest first.
    var heartRate: [TimedValue] = []
    var maxHeartRate: Double?
    /// Total distance in meters, as Apple Health sums it.
    var distance: Double?
    /// Distance covered so far, in meters, at the end of each distance sample, oldest first.
    var distanceTrack: [TimedValue] = []
    /// Meters climbed.
    var elevationGain: Double?
    /// The GPS route, if the workout recorded one.
    var route: [RoutePoint] = []
}

nonisolated struct RoutePoint: Equatable {
    let latitude: Double
    let longitude: Double
}

/// A value at a point in time, e.g. the average heart rate of a 5-minute interval starting at `date`.
nonisolated struct TimedValue: Equatable {
    let date: Date
    let value: Double
}

/// A stretch of sleep in one stage. `stage` is nil for asleep time without stage detail.
nonisolated struct SleepPeriod: Equatable {
    let start: Date
    let end: Date
    let stage: SleepStage?
}

/// Vitals measured while asleep, for the night that ended on `wakeDay`. Daytime readings are
/// left out: they move with stress, caffeine and activity, which makes them noisy for recovery.
nonisolated struct OvernightVitals: Equatable {
    let wakeDay: Date
    /// Average HRV (SDNN, ms) of readings taken while asleep.
    var hrv: Double?
    /// Lowest 5-minute average heart rate while asleep.
    var heartRate: Double?
    /// When the night's sleep started and ended, for sleep consistency.
    var bedtime: Date?
    var wakeTime: Date?

    /// Groups readings by the night they fall in. All arrays must be sorted by time; awake periods are skipped.
    static func make(hrv: [TimedValue], heartRate: [TimedValue], sleep: [SleepPeriod], calendar: Calendar) -> [OvernightVitals] {
        let asleep = sleep.filter { $0.stage != .awake }
        let nights = Dictionary(grouping: asleep) { SleepNight.wakeDay(forEnd: $0.end, calendar: calendar) }
        let hrvByNight = byNight(hrv, asleep, calendar)
        let heartRateByNight = byNight(heartRate, asleep, calendar)
        return nights.keys.sorted().map { day in
            OvernightVitals(
                wakeDay: day,
                hrv: Baseline.average(hrvByNight[day] ?? []),
                heartRate: heartRateByNight[day]?.min(),
                bedtime: nights[day]?.map(\.start).min(),
                wakeTime: nights[day]?.map(\.end).max()
            )
        }
    }

    /// One pass over both sorted lists, since a year of 5-minute heart rate is ~100k values.
    private static func byNight(_ values: [TimedValue], _ periods: [SleepPeriod], _ calendar: Calendar) -> [Date: [Double]] {
        var result: [Date: [Double]] = [:]
        var index = 0
        for value in values {
            while index < periods.count, periods[index].end <= value.date { index += 1 }
            guard index < periods.count, periods[index].start <= value.date else { continue }
            result[SleepNight.wakeDay(forEnd: periods[index].end, calendar: calendar), default: []].append(value.value)
        }
        return result
    }
}

/// Biological sex as Apple Health records it; zone tables like VO₂ max fitness depend on it.
nonisolated enum BiologicalSex { case female, male }

/// Where cards get their data: the imported store in the app, sample data in previews and demo mode.
protocol HealthDataSource {
    /// Average heart rate per 5 minutes in `interval`, oldest first; intervals without data are left out.
    func heartRate(in interval: DateInterval) async throws -> [TimedValue]
    /// Sleep stages that overlap `interval`, oldest first, from one source per night.
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod]
    /// The user's age from Apple Health, if they entered a birth date.
    func age() async throws -> Int?
    /// The user's biological sex from Apple Health, if they entered it as female or male.
    func biologicalSex() async throws -> BiologicalSex?
    /// Highest heart rate recorded in the last `days` days.
    func highestHeartRate(days: Int) async throws -> Double?
    /// One value per day for the `days` days ending today, oldest first.
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue]
    func standHours(days: Int) async throws -> [DayValue]
    /// One entry per day for the `days` days ending today, oldest first; values are nil without overnight data.
    func overnight(days: Int) async throws -> [OvernightVitals]
    /// Nights whose wake-up day falls in the last `days` days, oldest first.
    func sleepNights(days: Int) async throws -> [SleepNight]
    /// Workouts that started in the last `days` days, newest first.
    func workouts(days: Int) async throws -> [WorkoutSummary]
    /// The oldest day with data, where the calendar starts. Nil if unknown.
    func earliestDay() async throws -> Date?
    /// Hourly totals of a cumulative metric on `day`, oldest first; hours without data are left out.
    func hourly(_ metric: QuantityMetric, on day: Date) async throws -> [TimedValue]
    /// Heart rate, distance and route of one workout.
    func workoutDetail(_ workout: WorkoutSummary) async throws -> WorkoutDetail
}

extension HealthDataSource {
    func earliestDay() async throws -> Date? { nil }
    func hourly(_ metric: QuantityMetric, on day: Date) async throws -> [TimedValue] { [] }

    /// Without workout samples, the 5-minute heart rate during the workout.
    func workoutDetail(_ workout: WorkoutSummary) async throws -> WorkoutDetail {
        let heartRate = try await heartRate(in: DateInterval(start: workout.start, duration: workout.duration))
        return WorkoutDetail(heartRate: heartRate, maxHeartRate: heartRate.map(\.value).max())
    }
}
