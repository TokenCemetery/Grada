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
    private static let minimumLogHRVSD = 0.05

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

    /// 220 − age, or the highest heart rate on record when the age isn't known.
    static func maxHeartRate(age: Int?, highestRecorded: Double?) -> Double? {
        if let age { return Double(220 - age) }
        return highestRecorded
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

/// Health age and pace of aging, inspired by WHOOP Healthspan. WHOOP's model isn't public, so this is
/// a transparent heuristic: each habit or fitness marker adds or removes years from the user's real age,
/// using rough sizes from published associations with mortality and fitness norms.
nonisolated enum HealthAge {
    struct Input {
        var age: Int
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
        if let vo2 = input.vo2Max {
            // Typical VO₂ max falls about 0.35 per year from ~45 at 25.
            let expected = 45 - 0.35 * Double(max(input.age - 25, 0))
            impacts.append(Impact(name: "VO₂ max", years: clamp((expected - vo2) * 0.4, -5, 5)))
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
nonisolated enum RacePredictor {
    static let distances: [(name: String, meters: Double)] = [
        ("5K", 5_000), ("10K", 10_000), ("Half", 21_097.5), ("Marathon", 42_195),
    ]

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
