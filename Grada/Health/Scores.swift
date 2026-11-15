import Foundation

/// Morning recovery: each overnight input is checked against a published threshold, and the status counts
/// how many crossed it, like Health Status. No study has validated a formula that weighs these inputs into one
/// number (WHOOP's isn't published), so none is made up here.
nonisolated enum Recovery {
    struct Input {
        /// Overnight HRV (ms).
        var hrv: Double?
        /// Earlier nights, used as the baseline.
        var hrvHistory: [Double]
        /// Lowest heart rate while asleep.
        var restingHeartRate: Double?
        var restingHeartRateHistory: [Double]
        var asleep: TimeInterval?
        /// Sleeping respiratory rate; a rise above normal is an early sign of illness or fatigue.
        var respiratoryRate: Double? = nil
        var respiratoryRateHistory: [Double] = []
    }

    struct Result: Equatable {
        /// Good with no input off, Fair with one, Poor with two or more.
        let rating: DayRating
        /// Inputs measured with enough history to judge, and how many of them were within their threshold.
        let measured: Int
        let inRange: Int
        /// The first input that's off, e.g. "HRV below normal", or "Close to your normal".
        let reason: String
    }

    /// The smallest worthwhile change: 0.5 SD of the baseline (Hopkins 2000), as used for HRV-guided training
    /// (Plews et al. 2013, Buchheit 2014). Recovery only flags the direction that signals fatigue.
    static let smallestWorthwhileChangeInSD = 0.5
    /// AASM/SRS consensus: adults need at least 7 hours (Watson et al. 2015).
    static let minimumSleep = SleepNeed.baseline
    /// HRV is compared on a log scale, as in HRV research, because its spread grows with its size.
    /// 0.05 in log terms is about ±3 ms at 60 ms, the same floor as the HRV normal range.
    static let minimumLogHRVSD = 0.05

    /// Nil while HRV and resting heart rate are both missing or still calibrating.
    static func status(_ input: Input) -> Result? {
        // Each checked input, in the order they're named: whether it's off and how it's described.
        var checks: [(isOff: Bool, reason: String)] = []
        if let hrv = input.hrv, hrv > 0,
           let z = Baseline.zScore(log(hrv), history: input.hrvHistory.filter { $0 > 0 }.map(log), minimumSD: minimumLogHRVSD) {
            checks.append((z < -smallestWorthwhileChangeInSD, "HRV below normal"))
        }
        if let rhr = input.restingHeartRate,
           let z = Baseline.zScore(rhr, history: input.restingHeartRateHistory,
                                   minimumSD: QuantityMetric.restingHeartRate.minimumHalfWidth / 2) {
            checks.append((z > smallestWorthwhileChangeInSD, "Resting HR high"))
        }
        guard !checks.isEmpty else { return nil }
        if let asleep = input.asleep {
            checks.append((asleep < minimumSleep, "Short sleep"))
        }
        // Breathing uses the same ±2 SD normal range as the Respiratory Rate card; only a rise counts.
        if let rate = input.respiratoryRate,
           let normal = Baseline.normalRange(history: input.respiratoryRateHistory,
                                             minimumHalfWidth: QuantityMetric.respiratoryRate.minimumHalfWidth) {
            checks.append((rate > normal.upperBound, "Breathing rate up"))
        }

        let off = checks.filter(\.isOff)
        let reason = switch off.count {
        case 0: "Close to your normal"
        case 1: off[0].reason
        default: "\(off[0].reason) · \(off.count - 1) more off"
        }
        return Result(rating: DayRatings.healthStatus(outOfRange: off.count),
                      measured: checks.count, inRange: checks.count - off.count, reason: reason)
    }
}

/// The personal values scores are built on, as Settings shows them.
nonisolated struct HealthProfile: Equatable {
    enum MaxHeartRateSource: Equatable { case age, highestRecorded }

    var age: Int?
    var maxHeartRate: Double?
    var maxHeartRateSource: MaxHeartRateSource?
    /// 7-day average, the same one Resources uses.
    var restingHeartRate: Double?

    static func load(from source: HealthDataSource) async throws -> HealthProfile {
        let age = try await source.age()
        let highest = age == nil ? try await source.highestHeartRate(days: 365) : nil
        return HealthProfile(
            age: age,
            maxHeartRate: Resources.maxHeartRate(age: age, highestRecorded: highest),
            maxHeartRateSource: age != nil ? .age : (highest != nil ? .highestRecorded : nil),
            restingHeartRate: Baseline.average(try await source.daily(.restingHeartRate, days: 8).compactMap(\.value))
        )
    }
}

/// Estimated energy through the day, 0–100, from heart rate: sleep and rest charge it,
/// raised heart rate and workouts drain it. Garmin and Suunto use beat-to-beat HRV for this,
/// which iOS doesn't record all day, so this is an estimate.
nonisolated enum Resources {
    static let step: TimeInterval = 5 * 60

    /// Charge per 5 minutes asleep, by stage. Nil is asleep without stage detail.
    private static func sleepCharge(_ stage: SleepStage?) -> Double {
        switch stage {
        case .deep: 0.9
        case .core, nil: 0.6
        case .rem: 0.45
        case .awake: 0
        }
    }

    /// Drain per 5 minutes awake: the normal cost of being up and about.
    private static let calmDrain = 0.2
    /// Charge per 5 minutes of calm daytime rest, like Garmin. Rest is heart rate within
    /// `restMargin` bpm of resting: close enough that ordinary sitting doesn't count.
    private static let restCharge = 0.15
    private static let restMargin = 3.0
    /// Above this share of heart rate reserve, while not in a workout, counts as stress or activity.
    private static let stressThreshold = 0.15
    /// Heart rate is carried forward over gaps up to this long (watches sample every few minutes).
    private static let heartRateCarry: TimeInterval = 15 * 60

    /// The level at the start of every 5-minute step from `interval.start` to `interval.end`,
    /// starting at `startLevel`. Start a few days back so the starting guess no longer matters.
    static func timeline(
        interval: DateInterval,
        heartRate: [TimedValue],
        sleep: [SleepPeriod],
        workouts: [DateInterval],
        restingHeartRate: Double,
        maxHeartRate: Double,
        startLevel: Double = 50
    ) -> [TimedValue] {
        let reserve = max(maxHeartRate - restingHeartRate, 1)
        var level = startLevel
        var result: [TimedValue] = []
        var heartRateIndex = 0
        var lastHeartRate: TimedValue?
        var time = interval.start

        while time <= interval.end {
            result.append(TimedValue(date: time, value: level))
            while heartRateIndex < heartRate.count, heartRate[heartRateIndex].date < time + step {
                lastHeartRate = heartRate[heartRateIndex]
                heartRateIndex += 1
            }
            let hr = lastHeartRate.flatMap { time.timeIntervalSince($0.date) <= heartRateCarry ? $0.value : nil }
            let middle = time + step / 2
            let sleepStage = sleep.first { $0.start <= middle && middle < $0.end }.map(\.stage)

            let change: Double
            if let stage = sleepStage {
                var charge = sleepCharge(stage)
                if let hr { charge *= hr <= restingHeartRate ? 1.2 : (hr > restingHeartRate + 10 ? 0.5 : 1) }
                change = charge
            } else if workouts.contains(where: { $0.contains(middle) }) {
                // Without heart rate, assume moderate effort.
                let intensity = hr.map { min(max(($0 - restingHeartRate) / reserve, 0), 1) } ?? 0.5
                change = -(calmDrain + 3 * pow(intensity, 1.5))
            } else if let hr, (hr - restingHeartRate) / reserve > stressThreshold {
                change = -1.5 * min((hr - restingHeartRate) / reserve, 1)
            } else if let hr, hr <= restingHeartRate + restMargin {
                change = restCharge
            } else {
                change = -calmDrain
            }
            level = min(max(level + change, 0), 100)
            time += step
        }
        return result
    }

    /// WHOOP's recovery bands (green from 67, yellow from 34), with no published basis; see #69.
    static func rating(_ level: Int) -> DayRating {
        switch level {
        case 67...: .good
        case 34...: .fair
        default: .poor
        }
    }

    /// 208 − 0.7 × age (Tanaka, Monahan & Seals 2001, a meta-analysis of 351 studies; 220 − age has no
    /// study behind it and underestimates older adults), or the highest heart rate on record without an age.
    static func maxHeartRate(age: Int?, highestRecorded: Double?) -> Double? {
        if let age { return 208 - 0.7 * Double(age) }
        return highestRecorded
    }
}

/// Weekly moderate and vigorous minutes against the WHO target, like Garmin Intensity Minutes.
nonisolated enum IntensityMinutes {
    /// WHO: at least 150 minutes of moderate activity a week, or 75 vigorous.
    static let weeklyTarget = 150.0
    /// ACSM bands as a share of heart rate reserve: moderate 40–59%, vigorous from 60%.
    private static let moderateReserve = 0.4
    private static let vigorousReserve = 0.6

    /// Moderate plus vigorous minutes, vigorous counted double, from 5-minute average heart rate.
    static func total(heartRate: [TimedValue], restingHeartRate: Double, maxHeartRate: Double) -> Double {
        let reserve = maxHeartRate - restingHeartRate
        guard reserve > 0 else { return 0 }
        let minutesPerValue = Resources.step / 60
        return heartRate.reduce(0) { total, value in
            let share = (value.value - restingHeartRate) / reserve
            if share >= vigorousReserve { return total + 2 * minutesPerValue }
            if share >= moderateReserve { return total + minutesPerValue }
            return total
        }
    }
}

/// Waking time outside workouts split into the ACSM intensity bands by share of heart rate reserve
/// (Garber et al. 2011, Med Sci Sports Exerc 43:1334, Table 1). Workouts are left to Intensity Minutes.
nonisolated enum DayIntensity {
    enum Band: Int, CaseIterable {
        /// Below 30% of heart rate reserve.
        case veryLight
        /// 30–39%.
        case light
        /// 40–59%.
        case moderate
        /// 60% and up: ACSM's vigorous (60–89%) and near-maximal (90%+) together.
        case vigorous

        var title: String {
            switch self {
            case .veryLight: "Very light"
            case .light: "Light"
            case .moderate: "Moderate"
            case .vigorous: "Vigorous"
            }
        }
    }

    /// Lower bounds of light, moderate and vigorous as a share of heart rate reserve.
    static let lowerBounds = [0.3, 0.4, 0.6]

    static func band(_ heartRate: Double, restingHeartRate: Double, maxHeartRate: Double) -> Band {
        let share = (heartRate - restingHeartRate) / max(maxHeartRate - restingHeartRate, 1)
        return Band(rawValue: lowerBounds.filter { share >= $0 }.count)!
    }

    /// Seconds in each band from 5-minute average heart rates, skipping readings taken asleep and any that
    /// touch a workout, so workout time is never counted here as well as in Intensity Minutes.
    static func time(heartRate: [TimedValue], sleep: [SleepPeriod], workouts: [DateInterval],
                     restingHeartRate: Double, maxHeartRate: Double) -> [Band: TimeInterval] {
        var seconds: [Band: TimeInterval] = [:]
        for reading in heartRate {
            let end = reading.date + Resources.step
            let middle = reading.date + Resources.step / 2
            let asleep = sleep.contains { $0.stage != .awake && $0.start <= middle && middle < $0.end }
            let inWorkout = workouts.contains { $0.start < end && reading.date < $0.end }
            guard !asleep, !inWorkout else { continue }
            seconds[band(reading.value, restingHeartRate: restingHeartRate, maxHeartRate: maxHeartRate), default: 0] += Resources.step
        }
        return seconds
    }
}

/// How much sleep the user needs, and the debt from nights short of it. The need is the user's sleep goal, or
/// the AASM/SRS adult minimum of 7 hours (Watson et al. 2015). No published method adds debt or training on
/// top of it, so nothing is added.
nonisolated enum SleepNeed {
    static let baseline: TimeInterval = 7 * 3600
    /// Van Dongen et al. 2003 saw deficits keep building over 14 nights of short sleep.
    static let debtNights = 14

    /// How far each night fell short of its need, oldest first; nights without data count nothing.
    static func shortfalls(asleep: [TimeInterval?], need: [TimeInterval]) -> [TimeInterval] {
        zip(asleep, need).map { night, need in night.map { max(need - $0, 0) } ?? 0 }
    }

    /// Debt after each night, oldest first: the shortfalls of the last `debtNights` nights. A long night doesn't
    /// cancel earlier ones: no paper gives a payback rate, and Kitamura et al. 2016 found an hour of debt took
    /// four days of extended sleep to recover.
    static func debt(shortfalls: [TimeInterval]) -> [TimeInterval] {
        shortfalls.indices.map { shortfalls[max($0 - debtNights + 1, 0)...$0].reduce(0, +) }
    }
}

/// The Sleep Regularity Index (Phillips et al. 2017, Sci Rep 7:3216): the chance of being in the same state,
/// asleep or awake, at two moments 24 hours apart, scaled so identical days score 100 and random ones 0 (it can
/// fall below 0). Only pairs where both moments have data count. In UK Biobank, more regular sleepers had 20–48%
/// lower all-cause mortality than the least regular fifth (Windred et al. 2024, Sleep 47:zsad253).
nonisolated enum SleepConsistency {
    /// One week, as Windred et al. scored it; Phillips et al. also used whole weeks.
    static let days = 7
    /// Days with a sleep record needed in the week. Grada's own data-sufficiency rule; the papers don't give one.
    static let minimumDays = 5
    /// UK Biobank (Windred et al. 2024): median 81.0, interquartile range 73.8–86.3.
    static let populationMedian = 81.0
    static let populationLowerQuartile = 73.8

    private static let minutesPerDay = 24 * 60

    /// The index over `days` 24-hour blocks from `start`, from minute-by-minute sleep state. A block without any
    /// sleep record is missing (the watch was off), as is every minute from `until` on. Nil with too few days.
    static func index(sleep: [SleepPeriod], start: Date, days: Int = days, until: Date = .distantFuture) -> Double? {
        let total = days * minutesPerDay
        var asleep = [Bool](repeating: false, count: total)
        var measured = [Bool](repeating: false, count: days)
        for period in sleep where period.stage != .awake {
            let first = max(Int((period.start.timeIntervalSince(start) / 60).rounded(.down)), 0)
            let last = min(Int((period.end.timeIntervalSince(start) / 60).rounded(.up)), total)
            guard first < last else { continue }
            for minute in first..<last { asleep[minute] = true }
            for block in (first / minutesPerDay)...((last - 1) / minutesPerDay) { measured[block] = true }
        }
        guard measured.filter({ $0 }).count >= minimumDays else { return nil }

        let available = min(total, max(Int(until.timeIntervalSince(start) / 60), 0))
        var same = 0, pairs = 0
        for minute in 0..<max(available - minutesPerDay, 0) {
            let block = minute / minutesPerDay
            guard measured[block], measured[block + 1] else { continue }
            pairs += 1
            if asleep[minute] == asleep[minute + minutesPerDay] { same += 1 }
        }
        guard pairs > 0 else { return nil }
        return 200 * Double(same) / Double(pairs) - 100
    }

    /// Against UK Biobank adults: Good from the median, Fair from the lower quartile, Poor below it.
    static func rating(_ index: Double) -> DayRating {
        if index >= populationMedian { return .good }
        return index >= populationLowerQuartile ? .fair : .poor
    }
}

/// A 0–100 sleep score: the share of good-sleep indicators a night meets. The quality indicators and their cut-offs
/// are the National Sleep Foundation's consensus (Ohayon et al. 2017, Sleep Health 3:6): sleep efficiency of 85% or
/// more, at most 20 minutes awake after falling asleep, and at most one awakening longer than 5 minutes (two from 65).
/// Duration is checked against the night's Sleep Need, and timing against the Sleep Regularity Index. The panel found
/// no consensus on sleep stages as a quality marker, so the stage mix isn't scored; sleep latency isn't either, as
/// Apple Health doesn't reliably record time in bed before sleep. No study weighs the indicators, so each counts
/// the same and the rating counts misses, like Recovery.
nonisolated enum SleepScore {
    /// One night's continuity, from its first to its last minute asleep.
    struct Quality: Equatable {
        let asleep: TimeInterval
        /// Time awake between falling asleep and the final wake-up (WASO), gaps in the record included.
        let wakeAfterOnset: TimeInterval
        /// Awake stretches longer than `longAwakening`.
        let longAwakenings: Int

        /// Asleep time over the time from falling asleep to waking up. Without sleep latency this runs a
        /// little above the efficiency a sleep lab measures from lights out.
        var efficiency: Double { asleep / max(asleep + wakeAfterOnset, 1) }
    }

    struct Result: Equatable {
        let score: Int
        let rating: DayRating
        /// The first indicator missed, e.g. "Short sleep", or "All indicators met".
        let reason: String
    }

    static let minimumEfficiency = 0.85
    static let maximumWakeAfterOnset: TimeInterval = 20 * 60
    static let longAwakening: TimeInterval = 5 * 60

    /// NSF: one awakening is still good sleep for adults, and two for older adults.
    static func maximumLongAwakenings(age: Int?) -> Int {
        (age ?? 0) >= 65 ? 2 : 1
    }

    /// Continuity of one night from its periods. Nil without stage detail: sources that record only "asleep"
    /// don't record waking either, so the night would look unbroken.
    static func quality(_ periods: [SleepPeriod]) -> Quality? {
        let asleep = periods.filter { $0.stage != .awake && $0.stage != nil }.sorted { $0.start < $1.start }
        guard !asleep.isEmpty else { return nil }
        // Merge overlapping stretches so a gap between them is time awake or off the wrist.
        var merged: [(start: Date, end: Date)] = []
        for period in asleep {
            if let last = merged.last, period.start <= last.end {
                merged[merged.count - 1].end = max(last.end, period.end)
            } else {
                merged.append((period.start, period.end))
            }
        }
        let gaps = zip(merged, merged.dropFirst()).map { $1.start.timeIntervalSince($0.end) }
        return Quality(asleep: merged.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) },
                       wakeAfterOnset: gaps.reduce(0, +),
                       longAwakenings: gaps.filter { $0 > longAwakening }.count)
    }

    /// Nil until the night has stage detail and the week has a Sleep Regularity Index.
    static func score(quality: Quality?, need: TimeInterval, regularity: Double?, age: Int?) -> Result? {
        guard let quality, let regularity else { return nil }
        let checks: [(met: Bool, miss: String)] = [
            (quality.asleep >= need, "Short sleep"),
            (quality.efficiency >= minimumEfficiency, "Low sleep efficiency"),
            (quality.wakeAfterOnset <= maximumWakeAfterOnset, "Long time awake"),
            (quality.longAwakenings <= maximumLongAwakenings(age: age), "Woke up often"),
            (SleepConsistency.rating(regularity) != .poor, "Irregular schedule"),
        ]
        let missed = checks.filter { !$0.met }
        let reason = switch missed.count {
        case 0: "All indicators met"
        case 1: missed[0].miss
        default: "\(missed[0].miss) · \(missed.count - 1) more"
        }
        let met = checks.count - missed.count
        return Result(score: Int((100 * Double(met) / Double(checks.count)).rounded()),
                      rating: DayRatings.healthStatus(outOfRange: missed.count), reason: reason)
    }
}

/// Like Garmin HRV Status: the average overnight HRV of the last 7 nights against a personal baseline
/// from the nights before them.
nonisolated enum HRVStatus {
    enum State: Equatable {
        case balanced, unbalanced, low

        var word: String {
            switch self {
            case .balanced: "Balanced"
            case .unbalanced: "Unbalanced"
            case .low: "Low"
            }
        }

        var tone: CardSnapshot.Tone { self == .balanced ? .good : .warning }

        var rating: DayRating {
            switch self {
            case .balanced: .good
            case .unbalanced: .fair
            case .low: .poor
            }
        }
    }

    struct Result: Equatable {
        let average: Double
        let baseline: ClosedRange<Double>
        let state: State
    }

    static let window = 7
    /// Nights before the window that the baseline is built from.
    static let baselineNights = 60
    /// Garmin also needs about 3 weeks: 14 baseline nights plus a 7-night window.
    static let minimumBaselineNights = 14
    static let minimumWindowNights = 3
    /// The HRV-guided training method (Plews et al. 2012/2013, Buchheit 2014): the 7-night average of ln(HRV)
    /// against the baseline mean ± the smallest worthwhile change, 0.5 SD of ln(HRV) (Hopkins 2000).
    private static let smallestWorthwhileChangeInSD = 0.5
    /// Low is a full SD below the baseline mean: twice the smallest worthwhile change.
    private static let lowInSD = 1.0

    /// Status for the window ending at `end`, from overnight HRV per night (nil without a reading),
    /// oldest first. Nil while calibrating. `average` and `baseline` are in ms, back from the log scale.
    static func status(nights: [Double?], endingAt end: Int) -> Result? {
        let windowStart = end - window + 1
        guard windowStart >= 0, end < nights.count else { return nil }
        let recent = nights[windowStart...end].compactMap { $0 }.filter { $0 > 0 }.map(log)
        let history = nights[max(windowStart - baselineNights, 0)..<windowStart].compactMap { $0 }.filter { $0 > 0 }.map(log)
        guard recent.count >= minimumWindowNights, history.count >= minimumBaselineNights,
              let average = Baseline.average(recent), let mean = Baseline.average(history)
        else { return nil }

        let variance = history.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(history.count - 1)
        // Keeps a very steady history from flagging tiny changes; the same floor Recovery uses.
        let sd = max(variance.squareRoot(), Recovery.minimumLogHRVSD)
        let change = smallestWorthwhileChangeInSD * sd
        let state: State = if abs(average - mean) <= change {
            .balanced
        } else if average < mean - lowInSD * sd {
            .low
        } else {
            .unbalanced
        }
        return Result(average: exp(average), baseline: exp(mean - change)...exp(mean + change), state: state)
    }
}

/// Health age: the user's age plus, for each input, the years of aging that carry the same all-cause mortality
/// risk. Each input's risk ratio comes from a meta-analysis or pooled cohort, against a published reference for
/// the user's age and sex, and turns into years through the Gompertz law: adult mortality doubles about every
/// 8 years (Finch et al. 1990), so years = 8 × log₂(risk ratio). The studies adjusted for different things and the
/// inputs overlap (fit people also walk more), so the sum somewhat overstates the total.
nonisolated enum HealthAge {
    struct Input {
        var age: Int
        /// Needed for the VO₂ max and resting heart rate norms; without it those two are left out.
        var sex: BiologicalSex? = nil
        var sleepHours: Double?
        var dailySteps: Double?
        var restingHeartRate: Double?
        var vo2Max: Double?
        /// Apple exercise minutes: moderate effort or more.
        var exerciseMinutesPerWeek: Double?
    }

    struct Impact: Equatable {
        let name: String
        /// Positive adds years, negative takes them away.
        let years: Double
    }

    /// Fewer inputs than this and the age would rest on too little.
    static let minimumInputs = 3
    /// Gompertz mortality doubling time for adults (Finch et al. 1990).
    static let mortalityDoublingYears = 8.0

    /// Years of aging with the same change in mortality risk.
    static func years(riskRatio: Double) -> Double {
        mortalityDoublingYears * log2(riskRatio)
    }

    static func impacts(_ input: Input) -> [Impact] {
        var impacts: [Impact] = []
        if let vo2 = input.vo2Max, let sex = input.sex {
            // Kodama et al. 2009 (JAMA 301:2024): RR 0.87 per 1 MET (3.5 ml/kg·min) higher fitness.
            let mets = (vo2 - expectedVO2Max(age: input.age, sex: sex)) / 3.5
            impacts.append(Impact(name: "VO₂ Max", years: mets * years(riskRatio: 0.87)))
        }
        if let rhr = input.restingHeartRate, let sex = input.sex {
            // Zhang et al. 2016 (CMAJ 188:E53): RR 1.09 per 10 bpm higher.
            let tens = (rhr - expectedRestingHeartRate(age: input.age, sex: sex)) / 10
            impacts.append(Impact(name: "Resting HR", years: tens * years(riskRatio: 1.09)))
        }
        if let steps = input.dailySteps {
            let reference = input.age < 60 ? 7_803.0 : 5_649.0
            impacts.append(Impact(name: "Steps", years: years(riskRatio: stepsRisk(steps) / stepsRisk(reference))))
        }
        if let hours = input.sleepHours {
            impacts.append(Impact(name: "Sleep", years: years(riskRatio: sleepRisk(hours))))
        }
        if let minutes = input.exerciseMinutesPerWeek {
            impacts.append(Impact(name: "Exercise", years: years(riskRatio: exerciseRisk(minutes))))
        }
        return impacts
    }

    static func age(_ input: Input) -> Double? {
        let impacts = impacts(input)
        guard impacts.count >= minimumInputs else { return nil }
        return Double(input.age) + impacts.reduce(0) { $0 + $1.years }
    }

    /// Median measured VO₂ max (ml/kg·min) for the age and sex: the 50th percentiles of the FRIEND registry's
    /// treadmill tests (Kaminsky et al. 2015, Mayo Clin Proc 90:1515, Table 3). Under 20 uses the 20s,
    /// 80 and over the 70s.
    static func expectedVO2Max(age: Int, sex: BiologicalSex) -> Double {
        VO2MaxZones.bounds(age: age, sex: sex)[1]
    }

    /// Median resting pulse for the age and sex in NHANES 1999–2008 (Ostchega et al. 2011, NHSR 41, Table 1):
    /// ages 20–39, 40–59, 60–79 and 80+. That pulse was taken seated after 4 minutes' rest; Apple's resting heart
    /// rate is usually a little lower, which errs toward a younger health age.
    static func expectedRestingHeartRate(age: Int, sex: BiologicalSex) -> Double {
        let row = min(max(age / 20 - 1, 0), 3)
        return sex == .male ? [69.0, 68, 67, 68][row] : [74.0, 71, 70, 71][row]
    }

    /// Mortality risk against the lowest quartile, from Paluch et al. 2022 (Lancet Public Health 7:e219): quartile
    /// medians of 3553, 5801, 7842 and 10 901 steps had HRs of 1, 0.60, 0.55 and 0.47. Between medians the
    /// log-risk is interpolated; beyond them it stays flat. References are the pooled medians for under-60s
    /// (7803) and 60 and over (5649).
    static func stepsRisk(_ steps: Double) -> Double {
        let points: [(steps: Double, risk: Double)] = [(3_553, 1), (5_801, 0.60), (7_842, 0.55), (10_901, 0.47)]
        guard steps > points[0].steps else { return points[0].risk }
        guard let upper = points.firstIndex(where: { $0.steps >= steps }) else { return points[points.count - 1].risk }
        let (low, high) = (points[upper - 1], points[upper])
        let share = (steps - low.steps) / (high.steps - low.steps)
        return exp(log(low.risk) + share * (log(high.risk) - log(low.risk)))
    }

    /// Cappuccio et al. 2010 (Sleep 33:585): RR 1.12 for short and 1.30 for long sleep against the studies'
    /// reference, mostly 7 or 7–8 hours.
    static func sleepRisk(_ hours: Double) -> Double {
        if hours < 7 { return 1.12 }
        return hours > 8 ? 1.30 : 1
    }

    /// Arem et al. 2015 (JAMA Intern Med 175:959), as multiples of the 150-minute guideline against none:
    /// below it HR 0.80, 1–2× 0.69, 2–3× 0.63, 3–5× 0.61 (5–10× is taken as the same; not confirmed), 10× and up
    /// 0.69. Returned against the guideline
    /// (1–2×), so meeting it adds nothing. Exercise minutes stand in for the study's moderate-intensity minutes.
    static func exerciseRisk(_ minutesPerWeek: Double) -> Double {
        let multiple = minutesPerWeek / 150
        let risk = switch multiple {
        case ..<0.001: 1.0
        case ..<1: 0.80
        case ..<2: 0.69
        case ..<3: 0.63
        case ..<10: 0.61
        default: 0.69
        }
        return risk / 0.69
    }
}

/// VO₂ max fitness zones by age and sex, from the FRIEND registry's measured treadmill VO₂ max (Kaminsky et al.
/// 2015, Mayo Clin Proc 90:1515, Table 3): Poor below the 25th percentile, Fair from it, Good from the 50th,
/// Excellent from the 75th and Superior from the 90th.
nonisolated enum VO2MaxZones {
    enum Zone: Int, CaseIterable {
        case poor, fair, good, excellent, superior

        var word: String {
            switch self {
            case .poor: "Poor"
            case .fair: "Fair"
            case .good: "Good"
            case .excellent: "Excellent"
            case .superior: "Superior"
            }
        }

        var rating: DayRating {
            switch self {
            case .poor: .poor
            case .fair: .fair
            case .good, .excellent, .superior: .good
            }
        }
    }

    /// Lower bounds of Fair, Good, Excellent and Superior in ml/kg·min: the 25th, 50th, 75th and 90th percentiles.
    /// FRIEND covers ages 20–79, so younger adults use the 20s and older ones the 70s.
    static func bounds(age: Int, sex: BiologicalSex) -> [Double] {
        let row = min(max(age / 10 - 2, 0), 5)
        return sex == .male ? men[row] : women[row]
    }

    static func zone(_ value: Double, bounds: [Double]) -> Zone {
        Zone(rawValue: bounds.filter { value >= $0 }.count) ?? .superior
    }

    private static let men: [[Double]] = [
        [40.1, 48.0, 55.2, 61.8], [35.9, 42.4, 49.2, 56.5], [31.9, 37.8, 45.0, 52.1],
        [27.1, 32.6, 39.7, 45.6], [23.7, 28.2, 34.5, 40.3], [20.4, 24.4, 30.4, 36.6],
    ]
    private static let women: [[Double]] = [
        [30.5, 37.6, 44.7, 51.3], [25.3, 30.2, 36.1, 41.4], [22.1, 26.7, 32.4, 38.4],
        [19.9, 23.4, 27.6, 32.0], [17.2, 20.0, 23.8, 27.0], [15.6, 18.3, 20.8, 23.1],
    ]
}

/// Race times from VO₂ max with Jack Daniels' running formula, as Garmin's race predictor does
/// from its own VO₂ max. Assumes training for the distance; real results vary with it.
nonisolated enum RacePredictor {
    static let distances: [(name: String, meters: Double)] = [
        ("5K", 5_000), ("10K", 10_000), ("Half", 21_097.5), ("Marathon", 42_195),
    ]

    /// Direction of the race times from a VO₂ max change. Watches estimate VO₂ max to about ±0.5, so
    /// smaller changes count as steady.
    static func trend(from earlier: Double, to latest: Double) -> String {
        let change = latest - earlier
        if change >= 0.5 { return "Improving" }
        if change <= -0.5 { return "Declining" }
        return "Steady"
    }

    /// Seconds to run `meters` at the given VO₂ max.
    static func time(meters: Double, vo2Max: Double) -> TimeInterval {
        // Oxygen cost of running at v m/min, and the share of VO₂ max sustainable for t minutes.
        func cost(_ velocity: Double) -> Double { -4.60 + 0.182258 * velocity + 0.000104 * velocity * velocity }
        func sustainable(_ minutes: Double) -> Double {
            0.8 + 0.1894393 * exp(-0.012778 * minutes) + 0.2989558 * exp(-0.1932605 * minutes)
        }
        // Faster times cost more than can be sustained; binary search for where they meet.
        var low = 1.0, high = 1_000.0
        for _ in 0..<60 {
            let minutes = (low + high) / 2
            if cost(meters / minutes) > vo2Max * sustainable(minutes) { low = minutes } else { high = minutes }
        }
        return high * 60
    }
}

/// Five heart rate zones as a share of max heart rate, as Garmin and Whoop use them.
nonisolated enum HeartRateZones {
    /// Lower bounds of zones 1–5.
    static let lowerBounds = [0.5, 0.6, 0.7, 0.8, 0.9]
    /// A reading counts until the next one, but not across a gap longer than this (watch off the wrist).
    static let maxGap: TimeInterval = 5 * 60

    /// Zone 1–5, or nil below zone 1.
    static func zone(_ heartRate: Double, maxHeartRate: Double) -> Int? {
        let share = heartRate / maxHeartRate
        return lowerBounds.lastIndex { share >= $0 }.map { $0 + 1 }
    }

    /// Seconds in zones 1–5. `heartRate` is oldest first; the last reading lasts until `end`.
    static func time(_ heartRate: [TimedValue], end: Date, maxHeartRate: Double) -> [TimeInterval] {
        var seconds = Array(repeating: 0.0, count: lowerBounds.count)
        for (index, reading) in heartRate.enumerated() {
            let next = index + 1 < heartRate.count ? heartRate[index + 1].date : end
            guard let zone = zone(reading.value, maxHeartRate: maxHeartRate) else { continue }
            seconds[zone - 1] += min(max(next.timeIntervalSince(reading.date), 0), maxGap)
        }
        return seconds
    }
}

/// A workout's training load as Edwards' TRIMP (Edwards 1993): minutes in each `HeartRateZones` zone weighted
/// 1–5 and summed. There's no published scale for what a score means for fitness, so it's shown as the number,
/// for comparing workouts with each other.
nonisolated enum TrainingLoad {
    /// Each zone's weighted minutes, zones 1–5.
    static func edwardsTRIMPByZone(timeInZones: [TimeInterval]) -> [Double] {
        timeInZones.enumerated().map { Double($0.offset + 1) * $0.element / 60 }
    }

    static func edwardsTRIMP(timeInZones: [TimeInterval]) -> Double {
        edwardsTRIMPByZone(timeInZones: timeInZones).reduce(0, +)
    }
}

/// Time and heart rate for each kilometer of a workout.
nonisolated enum Splits {
    struct Split: Equatable {
        /// Meters in this split: the full length, or less for the last one.
        let meters: Double
        let duration: TimeInterval
        let averageHeartRate: Double?
    }

    /// A last stretch shorter than this share of a split is dropped.
    private static let minimumLastShare = 0.1

    /// `track` is the distance covered so far, oldest first. Each split ends where the track crosses the
    /// next whole length, interpolated between readings.
    static func make(track: [TimedValue], heartRate: [TimedValue], start: Date, length: Double = 1000) -> [Split] {
        var splits: [Split] = []
        var previous = TimedValue(date: start, value: 0)
        var splitStart = start
        var mark = length
        func split(meters: Double, until end: Date) {
            let readings = heartRate.filter { $0.date >= splitStart && $0.date < end }.map(\.value)
            splits.append(Split(meters: meters, duration: end.timeIntervalSince(splitStart),
                                averageHeartRate: readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)))
            splitStart = end
        }
        for point in track where point.value > previous.value {
            while point.value >= mark {
                let share = (mark - previous.value) / (point.value - previous.value)
                split(meters: length, until: previous.date.addingTimeInterval(share * point.date.timeIntervalSince(previous.date)))
                mark += length
            }
            previous = point
        }
        let rest = previous.value - (mark - length)
        if rest >= length * minimumLastShare {
            split(meters: rest, until: previous.date)
        }
        return splits
    }
}
