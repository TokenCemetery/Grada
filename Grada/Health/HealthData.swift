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
    /// From smart scales or entered by hand (#132): kilograms, percent, kilograms, centimeters.
    case bodyMass, bodyFat, leanBodyMass, height
    /// Cuff readings (#135), millimetres of mercury, averaged per day.
    case bloodPressureSystolic, bloodPressureDiastolic
    /// iPhone's mobility metrics (#136), averaged per day: m/s, centimeters, percent, percent.
    case walkingSpeed, walkingStepLength, walkingAsymmetry, walkingSteadiness

    /// The other number of a blood pressure reading, which must come from the same app and day.
    var bloodPressurePartner: QuantityMetric? {
        switch self {
        case .bloodPressureSystolic: .bloodPressureDiastolic
        case .bloodPressureDiastolic: .bloodPressureSystolic
        default: nil
        }
    }

    /// Body measurements keep the day's last reading, as a scale shows it, rather than averaging weighings.
    var usesLatestReading: Bool {
        switch self {
        case .bodyMass, .bodyFat, .leanBodyMass, .height: true
        default: false
        }
    }

    /// Summed per day (steps) vs averaged per day (heart rate).
    var isCumulative: Bool {
        switch self {
        case .steps, .activeEnergy, .exerciseMinutes, .distance, .floors: true
        default: false
        }
    }
}

/// Time Apple Health records for an activity, read live for journal suggestions.
nonisolated enum TimedActivity {
    /// Mindful sessions, such as Mindfulness or a meditation app.
    case mindfulness
    /// Time in daylight, measured by Apple Watch.
    case daylight
}

/// What Apple Health records someone drank on a day, read live for journal suggestions (#130).
nonisolated enum Intake {
    /// Alcoholic drinks, as logged in a drink-tracking or nutrition app.
    case alcoholicDrinks
    /// Caffeine in milligrams.
    case caffeine
}

nonisolated enum SleepStage: String, CaseIterable, Codable {
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

    /// Sleep at least this far from the rest of the day's sleep is a separate sleep, such as a nap. Within a
    /// night, watches record waking as awake samples, so a gap this long means the night had ended.
    static let separateSleepGap: TimeInterval = 2 * 3600

    /// The night's main sleep out of everything that counts toward one `wakeDay`: the longest stretch of
    /// samples with no gap of `separateSleepGap`. Naps and evening dozes would otherwise add to the night's
    /// totals and move its bed and wake times (#101).
    static func mainSleep<T>(_ items: [T], start: (T) -> Date, end: (T) -> Date) -> [T] {
        separateSleeps(items, start: start, end: end).max { $0.span.duration < $1.span.duration }?.items ?? []
    }

    /// `items` split into stretches with no gap of `separateSleepGap`, earliest first.
    static func separateSleeps<T>(_ items: [T], start: (T) -> Date, end: (T) -> Date) -> [(items: [T], span: DateInterval)] {
        let sorted = items.sorted { start($0) < start($1) }
        var stretches: [(items: [T], start: Date, end: Date)] = []
        for item in sorted {
            if let last = stretches.last, start(item).timeIntervalSince(last.end) < separateSleepGap {
                stretches[stretches.count - 1].items.append(item)
                stretches[stretches.count - 1].end = max(last.end, end(item))
            } else {
                stretches.append(([item], start(item), end(item)))
            }
        }
        return stretches.map { ($0.items, DateInterval(start: $0.start, end: max($0.start, $0.end))) }
    }
}

nonisolated struct WorkoutSummary: Hashable {
    /// The workout's ID in its source, e.g. the Apple Health sample UUID; stable across devices.
    let id: String
    let start: Date
    let duration: TimeInterval
    let name: String
    let symbol: String
    let energyKcal: Double?
    let averageHeartRate: Double?
    /// The `HealthSource.id` the workout came from.
    var source: String = HealthKitReader.sourceID
    /// The app or device inside the source that recorded it, e.g. "Garmin Connect · Forerunner 265".
    var origin: String?
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
    /// How far heart rate fell in the minute after the workout, in bpm (#131).
    var heartRateRecovery: Double?
    /// How hard the workout was, 1–10, from Apple Health on iOS 18 and later (#134).
    var effort: WorkoutEffort?
}

/// A workout's effort rating on Apple's 1–10 scale: the user's own, or else Apple's estimate (#134).
nonisolated struct WorkoutEffort: Equatable {
    let score: Double
    let isEstimate: Bool
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
nonisolated struct SleepPeriod: Equatable, Codable {
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
        let nights = Dictionary(grouping: sleep.filter { $0.stage != .awake }) { SleepNight.wakeDay(forEnd: $0.end, calendar: calendar) }
            .mapValues { SleepNight.mainSleep($0, start: \.start, end: \.end) }
        let asleep = nights.values.flatMap { $0 }.sorted { $0.start < $1.start }
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

/// The kinds of imported data Grada keeps origins for, in the order Settings › Data Source lists them.
/// Raw values are stored with each day, so they must never change.
nonisolated enum DataKind: String, CaseIterable, Identifiable {
    case restingHeartRate, hrv, overnightHRV, oxygenSaturation, respiratoryRate, wristTemperature, vo2Max
    case bodyMass, bodyFat, leanBodyMass, height
    case bloodPressureSystolic, bloodPressureDiastolic
    case walkingSpeed, walkingStepLength, walkingAsymmetry, walkingSteadiness
    case sleep
    case steps, activeEnergy, exerciseMinutes, distance, floors, standHours
    case workouts

    var id: String { rawValue }

    init(_ metric: QuantityMetric) {
        self = switch metric {
        case .restingHeartRate: .restingHeartRate
        case .hrv: .hrv
        case .oxygenSaturation: .oxygenSaturation
        case .respiratoryRate: .respiratoryRate
        case .wristTemperature: .wristTemperature
        case .steps: .steps
        case .activeEnergy: .activeEnergy
        case .exerciseMinutes: .exerciseMinutes
        case .distance: .distance
        case .floors: .floors
        case .vo2Max: .vo2Max
        case .bodyMass: .bodyMass
        case .bodyFat: .bodyFat
        case .leanBodyMass: .leanBodyMass
        case .height: .height
        case .bloodPressureSystolic: .bloodPressureSystolic
        case .bloodPressureDiastolic: .bloodPressureDiastolic
        case .walkingSpeed: .walkingSpeed
        case .walkingStepLength: .walkingStepLength
        case .walkingAsymmetry: .walkingAsymmetry
        case .walkingSteadiness: .walkingSteadiness
        }
    }

    var title: String {
        switch self {
        case .restingHeartRate: String(localized: "Resting Heart Rate")
        case .hrv: String(localized: "Heart Rate Variability")
        case .overnightHRV: String(localized: "HRV and Heart Rate While Asleep")
        case .oxygenSaturation: String(localized: "Blood Oxygen")
        case .respiratoryRate: String(localized: "Respiratory Rate")
        case .wristTemperature: String(localized: "Wrist Temperature")
        case .vo2Max: String(localized: "VO₂ Max")
        case .bodyMass: String(localized: "Weight")
        case .bodyFat: String(localized: "Body Fat Percentage")
        case .leanBodyMass: String(localized: "Lean Body Mass")
        case .height: String(localized: "Height")
        case .bloodPressureSystolic: String(localized: "Systolic Blood Pressure")
        case .bloodPressureDiastolic: String(localized: "Diastolic Blood Pressure")
        case .walkingSpeed: String(localized: "Walking Speed")
        case .walkingStepLength: String(localized: "Walking Step Length")
        case .walkingAsymmetry: String(localized: "Walking Asymmetry")
        case .walkingSteadiness: String(localized: "Walking Steadiness")
        case .sleep: String(localized: "Sleep")
        case .steps: String(localized: "Steps")
        case .activeEnergy: String(localized: "Active Energy")
        case .exerciseMinutes: String(localized: "Exercise Minutes")
        case .distance: String(localized: "Walking and Running Distance")
        case .floors: String(localized: "Floors Climbed")
        case .standHours: String(localized: "Stand Hours")
        case .workouts: String(localized: "Workouts")
        }
    }
}

/// An app or device whose data Grada used, and the last day it did.
nonisolated struct DataOrigin: Hashable {
    let name: String
    let lastDay: Date
}

/// Biological sex as Apple Health records it; zone tables like VO₂ max fitness depend on it.
nonisolated enum BiologicalSex: String { case female, male }

/// Birth date and sex entered in Settings › Profile, for when Apple Health can't provide them (#99).
/// Kept in this device's settings.
nonisolated enum EnteredProfile {
    /// Seconds since 1970; 0 when not entered.
    static let birthDateKey = "profile.birthDate"
    /// A `BiologicalSex` raw value; empty when not entered.
    static let sexKey = "profile.sex"

    static func age(defaults: UserDefaults = .standard, calendar: Calendar = .current) -> Int? {
        let seconds = defaults.double(forKey: birthDateKey)
        guard seconds != 0 else { return nil }
        return calendar.dateComponents([.year], from: Date(timeIntervalSince1970: seconds), to: .now).year
    }

    static func sex(defaults: UserDefaults = .standard) -> BiologicalSex? {
        defaults.string(forKey: sexKey).flatMap(BiologicalSex.init(rawValue:))
    }
}

/// Where cards get their data: the imported store in the app, sample data in previews and demo mode.
/// Nonisolated so stores and builders can read and score off the main actor; each reader runs on its caller's executor.
nonisolated protocol HealthDataSource {
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
    /// The apps and devices whose data Grada used, per kind of data, most recently used first.
    func origins() async throws -> [DataKind: [DataOrigin]]
    /// Whether a source provides the user's age and sex, so what's entered in Settings › Profile isn't used (#121).
    @MainActor func providesProfile() -> (age: Bool, sex: Bool)
    /// A copy that reads the last `days` days once, for callers that ask for long ranges many times in a row.
    @concurrent func withDaysLoaded(_ days: Int) async throws -> HealthDataSource
    /// Seconds of `activity` on `day`; nil without any record of it.
    func time(in activity: TimedActivity, on day: Date) async throws -> TimeInterval?
    /// The day's total of `intake`: drinks, or milligrams of caffeine; nil without any record of it.
    func intake(_ intake: Intake, on day: Date) async throws -> Double?
    /// Heart rate recovery after each of the last `days` days' last workout with one, oldest first (#131).
    func heartRateRecovery(days: Int) async throws -> [DayValue]
    /// Effort ratings by workout ID, for the last `days` days' workouts that have one (#134).
    func workoutEfforts(days: Int) async throws -> [String: WorkoutEffort]
    /// Days with menstrual flow logged in the last `days` days, oldest first (#137).
    func menstrualFlow(days: Int) async throws -> [FlowDay]
    /// Basal body temperatures, ovulation tests and cervical mucus logged in the last `days` days, oldest first (#138).
    func cycleSigns(days: Int) async throws -> [CycleSign]
    /// The most recent value of `metric` ever stored, e.g. height, which is rarely measured.
    func latest(_ metric: QuantityMetric) async throws -> Double?
}

nonisolated extension HealthDataSource {
    func earliestDay() async throws -> Date? { nil }
    func hourly(_ metric: QuantityMetric, on day: Date) async throws -> [TimedValue] { [] }
    func origins() async throws -> [DataKind: [DataOrigin]] { [:] }
    @concurrent func withDaysLoaded(_ days: Int) async throws -> HealthDataSource { self }
    @MainActor func providesProfile() -> (age: Bool, sex: Bool) { (false, false) }
    func time(in activity: TimedActivity, on day: Date) async throws -> TimeInterval? { nil }
    func intake(_ intake: Intake, on day: Date) async throws -> Double? { nil }
    func heartRateRecovery(days: Int) async throws -> [DayValue] { [] }
    func workoutEfforts(days: Int) async throws -> [String: WorkoutEffort] { [:] }
    func menstrualFlow(days: Int) async throws -> [FlowDay] { [] }
    func cycleSigns(days: Int) async throws -> [CycleSign] { [] }
    func latest(_ metric: QuantityMetric) async throws -> Double? {
        try await daily(metric, days: 3650).last { $0.value != nil }?.value
    }

    /// Without workout samples, the 5-minute heart rate during the workout.
    func workoutDetail(_ workout: WorkoutSummary) async throws -> WorkoutDetail {
        let heartRate = try await heartRate(in: DateInterval(start: workout.start, duration: workout.duration))
        return WorkoutDetail(heartRate: heartRate, maxHeartRate: heartRate.map(\.value).max())
    }
}
