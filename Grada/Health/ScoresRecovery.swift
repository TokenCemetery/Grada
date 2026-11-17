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

    /// The smallest worthwhile change: 0.5 SD of the baseline. On ln(HRV) one SD is about the coefficient of
    /// variation, so this is the 0.5 × CV that Le Meur et al. 2013 used and Buchheit 2014 reviews; no study has
    /// validated a particular fraction. Recovery only flags the direction that signals fatigue.
    static let smallestWorthwhileChangeInSD = 0.5
    /// AASM/SRS consensus: adults up to 60 need at least 7 hours (Watson et al. 2015), and the NSF's 7–8 hours
    /// from 65 keeps the same minimum for older adults (Hirshkowitz et al. 2015, Sleep Health 1:40).
    static let minimumSleep = SleepNeed.baseline
    /// HRV is compared on a log scale, as in HRV research, because its spread grows with its size.
    /// 0.05 in log terms is about ±3 ms at 60 ms, the same floor as the HRV normal range.
    static let minimumLogHRVSD = 0.05

    /// One input against its threshold, for the detail screen.
    struct Check: Equatable {
        enum Kind { case hrv, restingHeartRate, sleep, breathing }

        let kind: Kind
        let value: Double
        /// The threshold: the lowest healthy value when `higherIsBetter`, otherwise the highest.
        let limit: Double
        let higherIsBetter: Bool
        /// How it's described when off, e.g. "HRV below normal".
        let reason: String

        var isOff: Bool { higherIsBetter ? value < limit : value > limit }

        var name: String {
            switch kind {
            case .hrv: "HRV"
            case .restingHeartRate: "Resting HR"
            case .sleep: "Sleep"
            case .breathing: "Breathing"
            }
        }
    }

    /// Each measured input against its threshold, in the order they're named. Nil while HRV and resting heart
    /// rate are both missing or still calibrating.
    static func checks(_ input: Input) -> [Check]? {
        var checks: [Check] = []
        // A z-score of −0.5 on the log scale, back in ms.
        if let hrv = input.hrv, hrv > 0,
           let spread = Baseline.spread(history: input.hrvHistory.filter { $0 > 0 }.map(log), minimumSD: minimumLogHRVSD) {
            checks.append(Check(kind: .hrv, value: hrv, limit: exp(spread.mean - smallestWorthwhileChangeInSD * spread.sd),
                                higherIsBetter: true, reason: "HRV below normal"))
        }
        if let rhr = input.restingHeartRate,
           let spread = Baseline.spread(history: input.restingHeartRateHistory,
                                        minimumSD: QuantityMetric.restingHeartRate.minimumHalfWidth / 2) {
            checks.append(Check(kind: .restingHeartRate, value: rhr, limit: spread.mean + smallestWorthwhileChangeInSD * spread.sd,
                                higherIsBetter: false, reason: "Resting HR high"))
        }
        guard !checks.isEmpty else { return nil }
        if let asleep = input.asleep {
            checks.append(Check(kind: .sleep, value: asleep, limit: minimumSleep, higherIsBetter: true, reason: "Short sleep"))
        }
        // Breathing uses the same ±2 SD normal range as the Respiratory Rate card; only a rise counts.
        if let rate = input.respiratoryRate,
           let normal = Baseline.normalRange(history: input.respiratoryRateHistory,
                                             minimumHalfWidth: QuantityMetric.respiratoryRate.minimumHalfWidth) {
            checks.append(Check(kind: .breathing, value: rate, limit: normal.upperBound, higherIsBetter: false,
                                reason: "Breathing rate up"))
        }
        return checks
    }

    /// Nil while HRV and resting heart rate are both missing or still calibrating.
    static func status(_ input: Input) -> Result? {
        guard let checks = checks(input) else { return nil }
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
    var sex: BiologicalSex?
    var maxHeartRate: Double?
    var maxHeartRateSource: MaxHeartRateSource?
    /// 7-day average, the same one Resources uses.
    var restingHeartRate: Double?

    static func load(from source: HealthDataSource) async throws -> HealthProfile {
        let age = try await source.age()
        let highest = age == nil ? try await source.highestHeartRate(days: 365) : nil
        return HealthProfile(
            age: age,
            sex: try await source.biologicalSex(),
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

    /// What charged or drained the level during a step.
    enum Cause: CaseIterable {
        case sleep, rest, awake, raisedHeartRate, workout

        var title: String {
            switch self {
            case .sleep: "Sleep"
            case .rest: "Calm rest"
            case .awake: "Being awake"
            case .raisedHeartRate: "Raised heart rate"
            case .workout: "Workouts"
            }
        }
    }

    /// One 5-minute step: the level at its start, and what changed it by the next step.
    struct Step: Equatable {
        let date: Date
        let level: Double
        let cause: Cause
        /// The change actually applied, after the level is held within 0–100.
        let change: Double
    }

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
        steps(interval: interval, heartRate: heartRate, sleep: sleep, workouts: workouts, restingHeartRate: restingHeartRate,
              maxHeartRate: maxHeartRate, startLevel: startLevel).map { TimedValue(date: $0.date, value: $0.level) }
    }

    /// How much each cause moved the level from `start` to the last step of `steps`. The amounts add up
    /// to the change between the two levels.
    static func contributions(_ steps: [Step], from start: Date) -> [Cause: Double] {
        var amounts: [Cause: Double] = [:]
        for step in steps.dropLast() where step.date >= start {
            amounts[step.cause, default: 0] += step.change
        }
        return amounts
    }

    /// The simulation behind `timeline`, step by step.
    static func steps(
        interval: DateInterval,
        heartRate: [TimedValue],
        sleep: [SleepPeriod],
        workouts: [DateInterval],
        restingHeartRate: Double,
        maxHeartRate: Double,
        startLevel: Double = 50
    ) -> [Step] {
        let reserve = max(maxHeartRate - restingHeartRate, 1)
        var level = startLevel
        var result: [Step] = []
        var heartRateIndex = 0
        var lastHeartRate: TimedValue?
        var time = interval.start

        while time <= interval.end {
            while heartRateIndex < heartRate.count, heartRate[heartRateIndex].date < time + step {
                lastHeartRate = heartRate[heartRateIndex]
                heartRateIndex += 1
            }
            let hr = lastHeartRate.flatMap { time.timeIntervalSince($0.date) <= heartRateCarry ? $0.value : nil }
            let middle = time + step / 2
            let sleepStage = sleep.first { $0.start <= middle && middle < $0.end }.map(\.stage)

            let change: Double
            let cause: Cause
            if let stage = sleepStage {
                var charge = sleepCharge(stage)
                if let hr { charge *= hr <= restingHeartRate ? 1.2 : (hr > restingHeartRate + 10 ? 0.5 : 1) }
                (change, cause) = (charge, .sleep)
            } else if workouts.contains(where: { $0.contains(middle) }) {
                // Without heart rate, assume moderate effort.
                let intensity = hr.map { min(max(($0 - restingHeartRate) / reserve, 0), 1) } ?? 0.5
                (change, cause) = (-(calmDrain + 3 * pow(intensity, 1.5)), .workout)
            } else if let hr, (hr - restingHeartRate) / reserve > stressThreshold {
                (change, cause) = (-1.5 * min((hr - restingHeartRate) / reserve, 1), .raisedHeartRate)
            } else if let hr, hr <= restingHeartRate + restMargin {
                (change, cause) = (restCharge, .rest)
            } else {
                (change, cause) = (-calmDrain, .awake)
            }
            let next = min(max(level + change, 0), 100)
            result.append(Step(date: time, level: level, cause: cause, change: next - level))
            level = next
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
    /// The HRV-guided training method: the 7-day rolling average of ln(HRV) (Plews et al. 2012, Eur J Appl Physiol
    /// 112:3729) against the baseline mean ± a fraction of its spread. On the log scale one SD is about the
    /// coefficient of variation, so this is Le Meur et al. 2013's 0.5 × CV (Med Sci Sports Exerc 45:2061), and Low,
    /// a full SD below, is Plews et al.'s 1 × CV. Buchheit 2014 (Front Physiol 5:73) reviews both and notes no
    /// fraction has been validated.
    private static let smallestWorthwhileChangeInSD = 0.5
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
