import Foundation

/// How much sleep the user needs, and the debt from nights short of it. The need is the user's sleep goal, or
/// the AASM/SRS adult minimum of 7 hours (Watson et al. 2015, for ages 18–60), which the NSF also sets from 65
/// (Hirshkowitz et al. 2015). No published method adds debt or training on
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
/// more, at most 20 minutes awake after falling asleep (30 from 65), and at most one awakening longer than 5 minutes (two from 65).
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
        /// Awake stretches longer than `longAwakening`; nil from stage totals, which don't count them.
        let longAwakenings: Int?

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
    static let longAwakening: TimeInterval = 5 * 60

    /// NSF: up to 20 minutes awake is still good sleep for adults, and 30 from 65.
    static func maximumWakeAfterOnset(age: Int?) -> TimeInterval {
        (age ?? 0) >= 65 ? 30 * 60 : 20 * 60
    }

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

    /// Continuity from a night's stage totals, for sources with no stage timeline, such as Garmin's API (#100):
    /// its awake total is the time awake after onset. Nil without stages, as for periods.
    static func quality(_ night: SleepNight) -> Quality? {
        let asleep = [SleepStage.deep, .core, .rem].reduce(0) { $0 + (night.stages[$1] ?? 0) }
        guard asleep > 0 else { return nil }
        return Quality(asleep: asleep, wakeAfterOnset: night.stages[.awake] ?? 0, longAwakenings: nil)
    }

    /// Nil until the night has stage detail and the week has a Sleep Regularity Index. Without a count of
    /// awakenings, that check is left out rather than counted as met.
    static func score(quality: Quality?, need: TimeInterval, regularity: Double?, age: Int?) -> Result? {
        guard let quality, let regularity else { return nil }
        var checks: [(met: Bool, miss: String)] = [
            (quality.asleep >= need, String(localized: "Short sleep")),
            (quality.efficiency >= minimumEfficiency, String(localized: "Low sleep efficiency")),
            (quality.wakeAfterOnset <= maximumWakeAfterOnset(age: age), String(localized: "Long time awake")),
        ]
        if let awakenings = quality.longAwakenings {
            checks.append((awakenings <= maximumLongAwakenings(age: age), String(localized: "Woke up often")))
        }
        checks.append((SleepConsistency.rating(regularity) != .poor, String(localized: "Irregular schedule")))
        let missed = checks.filter { !$0.met }
        let reason = switch missed.count {
        case 0: String(localized: "All indicators met")
        case 1: missed[0].miss
        default: String(localized: "\(missed[0].miss) · \(missed.count - 1) more")
        }
        let met = checks.count - missed.count
        return Result(score: Int((100 * Double(met) / Double(checks.count)).rounded()),
                      rating: DayRatings.healthStatus(outOfRange: missed.count), reason: reason)
    }
}
