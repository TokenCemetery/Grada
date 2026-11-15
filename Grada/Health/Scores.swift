import Foundation

/// Morning recovery, 0–100, modelled on WHOOP: HRV and heart rate measured while asleep against
/// the user's own baseline, plus sleep against their sleep need and a penalty for raised breathing rate.
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
        /// What the user needed that night; see `SleepNeed`.
        var sleepNeed: TimeInterval = SleepNeed.baseline
        /// Sleeping respiratory rate; a rise above normal is an early sign of illness or fatigue.
        var respiratoryRate: Double? = nil
        var respiratoryRateHistory: [Double] = []
    }

    struct Result: Equatable {
        let score: Int
        /// The input that moved the score most, e.g. "HRV above normal".
        let reason: String
    }

    /// A component score on a normal day; one standard deviation moves it by `pointsPerSD`.
    private static let neutral = 65.0
    private static let pointsPerSD = 20.0
    /// Points lost per hour of sleep below the sleep need.
    private static let pointsPerHourShort = 20.0
    /// Points lost per SD of respiratory rate beyond the first SD above normal, up to `maxBreathingPenalty`.
    private static let pointsPerBreathingSD = 10.0
    private static let maxBreathingPenalty = 30.0
    /// HRV is compared on a log scale, as in HRV research, because its spread grows with its size.
    /// 0.05 in log terms is about ±3 ms at 60 ms, the same floor as the HRV normal range.
    static let minimumLogHRVSD = 0.05

    /// Nil while HRV and resting heart rate are both missing or still calibrating.
    static func score(_ input: Input) -> Result? {
        // `effect` is how far, in standard deviations, the input pushes recovery up (+) or down (−).
        var parts: [(weight: Double, score: Double, effect: Double, high: String?, low: String)] = []
        if let hrv = input.hrv, hrv > 0,
           let z = Baseline.zScore(log(hrv), history: input.hrvHistory.filter { $0 > 0 }.map(log), minimumSD: minimumLogHRVSD) {
            parts.append((0.5, neutral + pointsPerSD * z, z, "HRV above normal", "HRV below normal"))
        }
        if let rhr = input.restingHeartRate,
           let z = Baseline.zScore(rhr, history: input.restingHeartRateHistory,
                                   minimumSD: QuantityMetric.restingHeartRate.minimumHalfWidth / 2) {
            // Lower resting heart rate means better recovery.
            parts.append((0.25, neutral - pointsPerSD * z, -z, "Resting HR low", "Resting HR high"))
        }
        guard !parts.isEmpty else { return nil }
        if let asleep = input.asleep {
            let hoursShort = max(input.sleepNeed - asleep, 0) / 3600
            // An hour short counts like one standard deviation; enough sleep is expected, not a boost.
            parts.append((0.25, 100 - pointsPerHourShort * hoursShort, -hoursShort, nil, "Short sleep"))
        }

        // Missing inputs don't count against the score: weights are shared among what's there.
        let totalWeight = parts.reduce(0) { $0 + $1.weight }
        var score = parts.reduce(0) { $0 + $1.weight * min(max($1.score, 0), 100) } / totalWeight

        // Breathing only ever lowers the score: a normal rate says nothing about recovery.
        if let rate = input.respiratoryRate,
           let z = Baseline.zScore(rate, history: input.respiratoryRateHistory,
                                   minimumSD: QuantityMetric.respiratoryRate.minimumHalfWidth / 2), z >= 1 {
            score = max(score - min((z - 1) * pointsPerBreathingSD, maxBreathingPenalty), 0)
            parts.append((0.25, score, -z, nil, "Breathing rate up"))
        }

        // Only inputs at least one SD from normal are named; a drag explains more than a boost.
        let reason: String
        if let worst = parts.filter({ $0.effect <= -1 }).min(by: { $0.effect * $0.weight < $1.effect * $1.weight }) {
            reason = worst.low
        } else if let best = parts.filter({ $0.effect >= 1 && $0.high != nil })
            .max(by: { $0.effect * $0.weight < $1.effect * $1.weight }), let high = best.high {
            reason = high
        } else {
            reason = "Close to your normal"
        }
        return Result(score: Int(score.rounded()), reason: reason)
    }

    /// Whoop's bands: green from 67, yellow from 34, red below.
    static func rating(_ score: Int) -> DayRating {
        switch score {
        case 67...: .good
        case 34...: .fair
        default: .poor
        }
    }

    static func status(_ score: Int) -> (word: String, tone: CardSnapshot.Tone) {
        switch score {
        case 67...: ("Good", .good)
        case 34...: ("Fair", .neutral)
        default: ("Low", .warning)
        }
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

/// How much sleep the user needs tonight, like WHOOP's Sleep Planner and Garmin's Sleep Coach:
/// a baseline, plus part of the recent sleep debt, plus extra after a training day.
nonisolated enum SleepNeed {
    /// Until Goals (v2) let the user set it.
    static let baseline: TimeInterval = 8 * 3600
    /// Share of the debt to win back in one night, so a big debt is repaid over several nights.
    private static let debtShare = 0.25
    private static let maxDebtExtra: TimeInterval = 90 * 60
    /// Extra sleep per hour of workout, up to `maxTrainingExtra`.
    private static let extraPerTrainingHour: TimeInterval = 15 * 60
    private static let maxTrainingExtra: TimeInterval = 45 * 60
    /// Share of the debt that fades each night, so it reflects recent nights only: always sleeping
    /// 30 minutes short settles at 2 hours of debt instead of growing forever.
    private static let nightlyFade = 0.25

    /// Running debt after each night, oldest first. Short nights add to it and long nights repay it;
    /// nights without data leave it unchanged.
    static func debt(asleep: [TimeInterval?]) -> [TimeInterval] {
        var debt: TimeInterval = 0
        return asleep.map { night in
            if let night { debt = max(debt * (1 - nightlyFade) + baseline - night, 0) }
            return debt
        }
    }

    static func need(debt: TimeInterval, trainingTime: TimeInterval) -> TimeInterval {
        baseline + min(debt * debtShare, maxDebtExtra) + min(trainingTime / 3600 * extraPerTrainingHour, maxTrainingExtra)
    }
}

/// How regular bed and wake times are, like WHOOP's Sleep Consistency: 100 means the same times every night.
nonisolated enum SleepConsistency {
    struct Result: Equatable {
        let score: Int
        /// Standard deviations in minutes.
        let bedtimeSpread: Double
        let wakeSpread: Double
    }

    /// WHOOP compares the last 4 nights.
    static let nights = 4
    /// Points lost per minute of average spread: 15 minutes ≈ 88, 30 ≈ 76, an hour ≈ 52.
    private static let pointsPerMinute = 0.8

    /// Times as minutes after midnight. Bedtimes before noon are taken as after midnight (e.g. 00:30).
    /// Nil with fewer than 3 nights.
    static func score(bedtimes: [Double], wakeTimes: [Double]) -> Result? {
        guard bedtimes.count >= 3, wakeTimes.count >= 3 else { return nil }
        let bedtimeSpread = spread(bedtimes.map { $0 < 12 * 60 ? $0 + 24 * 60 : $0 })
        let wakeSpread = spread(wakeTimes)
        let score = 100 - pointsPerMinute * (bedtimeSpread + wakeSpread) / 2
        return Result(score: Int(min(max(score, 0), 100).rounded()), bedtimeSpread: bedtimeSpread, wakeSpread: wakeSpread)
    }

    private static func spread(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
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

/// Health age and pace of aging, inspired by WHOOP Healthspan. WHOOP's model isn't public, so this is
/// a transparent heuristic: each habit or fitness marker adds or removes years from the user's real age,
/// using rough sizes from published associations with mortality and fitness norms.
nonisolated enum HealthAge {
    struct Input {
        var age: Int
        /// Needed to compare VO₂ max with the right norm; without it VO₂ max is left out.
        var sex: BiologicalSex? = nil
        var sleepHours: Double?
        var sleepConsistency: Double?
        var dailySteps: Double?
        var restingHeartRate: Double?
        var vo2Max: Double?
        /// Apple exercise minutes, roughly WHOOP's heart rate zones 1–3.
        var moderateMinutesPerWeek: Double?
        /// Workout time at 80% of max heart rate or more, roughly zones 4–5.
        var vigorousMinutesPerWeek: Double?
        var strengthMinutesPerWeek: Double?
    }

    struct Impact: Equatable {
        let name: String
        /// Positive adds years, negative takes them away.
        let years: Double
    }

    /// Fewer inputs than this and the age would rest on too little.
    static let minimumInputs = 3

    static func impacts(_ input: Input) -> [Impact] {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), high) }
        var impacts: [Impact] = []
        if let vo2 = input.vo2Max, let sex = input.sex {
            let expected = expectedVO2Max(age: input.age, sex: sex)
            impacts.append(Impact(name: "VO₂ Max", years: clamp((expected - vo2) * 0.4, -5, 5)))
        }
        if let rhr = input.restingHeartRate {
            impacts.append(Impact(name: "Resting HR", years: clamp((rhr - 60) * 0.15, -2, 4)))
        }
        if let steps = input.dailySteps {
            impacts.append(Impact(name: "Steps", years: clamp((8_000 - steps) / 1_000 * 0.4, -2, 3)))
        }
        if let hours = input.sleepHours {
            // 7 to 8.5 hours is the healthy band; each hour outside it adds a year.
            let outside = hours < 7 ? 7 - hours : max(hours - 8.5, 0)
            impacts.append(Impact(name: "Sleep", years: clamp(outside, 0, 3)))
        }
        if let consistency = input.sleepConsistency {
            impacts.append(Impact(name: "Consistency", years: clamp((75 - consistency) * 0.05, -1, 2)))
        }
        if let minutes = input.moderateMinutesPerWeek {
            // 150 minutes a week is the WHO guideline.
            impacts.append(Impact(name: "Exercise", years: clamp((150 - minutes) / 50 * 0.5, -1.5, 2)))
        }
        if let minutes = input.vigorousMinutesPerWeek {
            impacts.append(Impact(name: "Hard training", years: clamp((60 - minutes) / 30 * 0.5, -1.5, 1.5)))
        }
        if let minutes = input.strengthMinutesPerWeek {
            impacts.append(Impact(name: "Strength", years: clamp((60 - minutes) / 30 * 0.5, -1, 1.5)))
        }
        return impacts
    }

    /// Median measured VO₂ max (ml/kg·min) for the age and sex: the 50th percentiles of the FRIEND registry's
    /// treadmill tests (Kaminsky et al. 2015, Mayo Clin Proc 90:1515, Table 3). Under 20 uses the 20s,
    /// 80 and over the 70s.
    static func expectedVO2Max(age: Int, sex: BiologicalSex) -> Double {
        let row = min(max(age / 10 - 2, 0), 5)
        return sex == .male ? medianMen[row] : medianWomen[row]
    }

    private static let medianMen = [48.0, 42.4, 37.8, 32.6, 28.2, 24.4]
    private static let medianWomen = [37.6, 30.2, 26.7, 23.4, 20.0, 18.3]

    static func age(_ input: Input) -> Double? {
        let impacts = impacts(input)
        guard impacts.count >= minimumInputs else { return nil }
        return Double(input.age) + impacts.reduce(0) { $0 + $1.years }
    }

    /// Years aged per calendar year, from the last 30 days against the last 6 months, like WHOOP:
    /// 1× is steady, below 1× slowing, below 0× getting younger. Each year of difference moves it by 0.5.
    static func pace(recent: Double, baseline: Double) -> Double {
        min(max(1 + (recent - baseline) * 0.5, -1), 3)
    }
}

/// Race times from VO₂ max with Jack Daniels' running formula, as Garmin's race predictor does
/// from its own VO₂ max. Assumes training for the distance; real results vary with it.
/// VO₂ max fitness zones by age and sex, from the Cooper Institute norms (the 6-category table reproduced
/// by most fitness references; Very poor is merged into Poor here).
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

    /// Lower bounds of Fair, Good, Excellent and Superior in ml/kg·min. Under 20 uses the 13–19 row.
    static func bounds(age: Int, sex: BiologicalSex) -> [Double] {
        let row = switch age {
        case ..<20: 0
        case 20..<30: 1
        case 30..<40: 2
        case 40..<50: 3
        case 50..<60: 4
        default: 5
        }
        return sex == .male ? men[row] : women[row]
    }

    static func zone(_ value: Double, bounds: [Double]) -> Zone {
        Zone(rawValue: bounds.filter { value >= $0 }.count) ?? .superior
    }

    private static let men: [[Double]] = [
        [38.4, 45.2, 51.0, 56.0], [36.5, 42.5, 46.5, 52.5], [35.5, 41.0, 45.0, 49.5],
        [33.6, 39.0, 43.8, 48.1], [31.0, 35.8, 41.0, 45.4], [26.1, 32.3, 36.5, 44.3],
    ]
    private static let women: [[Double]] = [
        [31.0, 35.0, 39.0, 42.0], [29.0, 33.0, 37.0, 41.1], [27.0, 31.5, 35.7, 40.1],
        [24.5, 29.0, 32.9, 37.0], [22.8, 27.0, 31.5, 35.8], [20.2, 24.5, 30.3, 31.5],
    ]
}

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

/// How much a workout improves aerobic fitness, 0–5, on Garmin's Training Effect scale. Garmin's model
/// (Firstbeat EPOC) isn't public, so this uses zone-weighted minutes (Edwards TRIMP) with a curve that
/// gives a steady 45-minute zone 3 run about 3 and a hard hour in zone 4 about 4.
nonisolated enum TrainingEffect {
    /// TRIMP at which the effect reaches 63% of the scale.
    private static let scale = 150.0

    static func aerobic(timeInZones: [TimeInterval]) -> Double {
        let load = timeInZones.enumerated().reduce(0) { $0 + Double($1.offset + 1) * $1.element / 60 }
        let effect = 5 * (1 - exp(-load / scale))
        return (effect * 10).rounded() / 10
    }

    static func label(_ effect: Double) -> String {
        switch effect {
        case ..<1: "No benefit"
        case ..<2: "Minor benefit"
        case ..<3: "Maintaining"
        case ..<4: "Improving"
        case ..<5: "Highly improving"
        default: "Overreaching"
        }
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
