import Foundation

/// VO₂ max fitness zones by age and sex, from the FRIEND registry's measured treadmill VO₂ max (Kaminsky et al.
/// 2015, Mayo Clin Proc 90:1515, Table 3): Poor below the 25th percentile, Fair from it, Good from the 50th,
/// Excellent from the 75th and Superior from the 90th.
nonisolated enum VO2MaxZones {
    enum Zone: Int, CaseIterable {
        case poor, fair, good, excellent, superior

        var word: String {
            switch self {
            case .poor: String(localized: "Poor")
            case .fair: String(localized: "Fair")
            case .good: String(localized: "Good")
            case .excellent: String(localized: "Excellent")
            case .superior: String(localized: "Superior")
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
        (String(localized: "5K", comment: "Race distance name"), 5_000), (String(localized: "10K", comment: "Race distance name"), 10_000),
        (String(localized: "Half", comment: "Race distance name, short for half marathon"), 21_097.5), (String(localized: "Marathon", comment: "Race distance name"), 42_195),
    ]

    /// Direction of the race times from a VO₂ max change. Watches estimate VO₂ max to about ±0.5, so
    /// smaller changes count as steady.
    static func trend(from earlier: Double, to latest: Double) -> String {
        let change = latest - earlier
        if change >= 0.5 { return String(localized: "Improving") }
        if change <= -0.5 { return String(localized: "Declining") }
        return String(localized: "Steady")
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

/// Foster et al. 2001 (J Strength Cond Res 15:109): a session's load is how hard it felt on the CR-10 scale times
/// its minutes (session RPE). Against a heart rate method (Edwards' TRIMP) it rose and fell consistently over steady,
/// interval cycling and basketball, though its scores ran higher. Apple's 1–10 workout effort score stands in for
/// the CR-10 rating (#134).
nonisolated enum SessionRPE {
    /// Rated workouts in the shown period needed to compare with heart rate load. Grada's choice.
    static let minimumRatedWorkouts = 3

    static func load(effort: Double, duration: TimeInterval) -> Double {
        effort * duration / 60
    }
}

/// Daily strain and the acute:chronic workload ratio. A day's load is Edwards' TRIMP over all of its heart rate,
/// so workouts and an active day both count. Acute load is the last 7 days' average and chronic the last 28 days'
/// (Hulin et al. 2016, Br J Sports Med 50:231); Gabbett 2016 (Br J Sports Med 50:273) found the lowest injury risk
/// at ratios of 0.8–1.3 and the highest from 1.5. Those studies are of team-sport athletes, and later work questions
/// how well the ratio predicts injury (Impellizzeri et al. 2020, Int J Sports Physiol Perform 15:907), so it's a
/// guide to how fast load is changing, not a risk score.
nonisolated enum Strain {
    struct Ratio: Equatable {
        let acute: Double
        let chronic: Double
        var value: Double { acute / chronic }
    }

    static let acuteDays = 7
    static let chronicDays = 28
    /// Days with heart rate needed in each window. Grada's own data-sufficiency rule; the papers don't give one.
    static let minimumAcuteDays = 4
    static let minimumChronicDays = 21
    /// Gabbett 2016's sweet spot and danger zone.
    static let sweetSpot = 0.8...1.3
    static let dangerRatio = 1.5

    /// Edwards' TRIMP from a day's heart rate, oldest first; the last reading lasts until `end`.
    static func load(heartRate: [TimedValue], end: Date, maxHeartRate: Double) -> Double {
        TrainingLoad.edwardsTRIMP(timeInZones: HeartRateZones.time(heartRate, end: end, maxHeartRate: maxHeartRate))
    }

    /// Acute against chronic load for the day at `end` in `loads` (oldest first, nil without heart rate).
    /// Days without heart rate are left out of the averages. Nil without enough days in either window.
    static func ratio(loads: [Double?], endingAt end: Int) -> Ratio? {
        guard end >= 0, end < loads.count else { return nil }
        let acute = loads[max(end - acuteDays + 1, 0)...end].compactMap { $0 }
        let chronic = loads[max(end - chronicDays + 1, 0)...end].compactMap { $0 }
        guard acute.count >= minimumAcuteDays, chronic.count >= minimumChronicDays,
              let acuteMean = Baseline.average(acute), let chronicMean = Baseline.average(chronic), chronicMean > 0
        else { return nil }
        return Ratio(acute: acuteMean, chronic: chronicMean)
    }

    /// Foster 1998 (Med Sci Sports Exerc 30:1164): a week's monotony is its mean daily load over the standard
    /// deviation, and training strain its total load times monotony. Athletes' illnesses mostly came when strain
    /// passed a threshold of their own; monotony above 2 is the warning later work takes from it (Clemente et al.
    /// 2019, PLOS ONE 14:e0225522). Foster counted rest days as zero load; a day's load here is all of its heart
    /// rate, so rest days count what they had.
    struct Week: Equatable {
        /// The 7 days' total load.
        let load: Double
        let monotony: Double
        var strain: Double { load * monotony }
        var isMonotonous: Bool { monotony > highMonotony }
    }

    static let highMonotony = 2.0

    /// The 7 days to `end` in `loads` (oldest first, nil without heart rate); nil unless all 7 have a load and
    /// they differ. Sample standard deviation, as in `MonthSummary`.
    static func week(loads: [Double?], endingAt end: Int) -> Week? {
        guard end >= acuteDays - 1, end < loads.count else { return nil }
        let days = loads[(end - acuteDays + 1)...end].compactMap { $0 }
        guard days.count == acuteDays, let mean = Baseline.average(days),
              let deviation = MonthSummary.standardDeviation(days), deviation > 0
        else { return nil }
        return Week(load: days.reduce(0, +), monotony: mean / deviation)
    }

    static func word(_ ratio: Double) -> String {
        if ratio >= dangerRatio { return String(localized: "Very high") }
        if ratio > sweetSpot.upperBound { return String(localized: "High") }
        return ratio < sweetSpot.lowerBound ? String(localized: "Low") : String(localized: "Optimal")
    }

    /// Green in the sweet spot, red from the danger zone, yellow between them or below the sweet spot,
    /// where Gabbett also saw higher risk.
    static func rating(_ ratio: Double) -> DayRating {
        if ratio >= dangerRatio { return .poor }
        return sweetSpot.contains(ratio) ? .good : .fair
    }
}

/// The last 4 weeks of workout time by intensity zone, against the polarized model: Seiler 2010 (Int J Sports
/// Physiol Perform 5:276) found successful endurance athletes doing about 80% of their training at low intensity,
/// below the first ventilatory threshold, and most of the rest at high intensity. Seiler counted sessions; counted
/// by heart rate time the low share is higher still (Sylta et al. 2014, Int J Sports Physiol Perform 9:100: elite
/// skiers spent 96% of their time in zone 1 though 87% of their sessions were low), so 80% is the lenient end of
/// the target. The evidence comes from endurance athletes.
nonisolated enum LoadFocus {
    static let days = 28
    static let lowTarget = 0.8

    /// Each zone's share of the total, low first; nil without any workout time.
    static func shares(_ seconds: [TimeInterval]) -> [Double]? {
        let total = seconds.reduce(0, +)
        return total > 0 ? seconds.map { $0 / total } : nil
    }

    static func rating(lowShare: Double) -> DayRating {
        lowShare >= lowTarget ? .good : .fair
    }
}

/// Hours until the heart's parasympathetic (rest) activity is back to normal after training. Stanley, Peake &
/// Buchheit 2013 (Sports Med 43:1259) pooled the studies: up to 24 h after low-intensity exercise, 24–48 h after
/// threshold intensity and at least 48 h after high intensity, with duration mattering less than intensity. A
/// workout's intensity is its average heart rate's `IntensityZones` zone; threshold takes the middle of its range.
/// The morning's overnight HRV and resting heart rate measure that recovery directly, so when this morning's
/// Recovery isn't Good while a workout's time hadn't run out, recovery runs on to the next morning's check.
nonisolated enum RecoveryTime {
    struct Workout: Equatable {
        let end: Date
        /// Nil without heart rate, counted as low intensity.
        let averageHeartRate: Double?
    }

    static func hours(_ zone: IntensityZones.Zone) -> Double {
        switch zone {
        case .low: 24
        case .threshold: 36
        case .high: 48
        }
    }

    /// When the latest-finishing recovery among `workouts` ends; nil when none is still running at `now`.
    /// `wake` is this morning's wake-up, `morningRecovery` this morning's Recovery rating.
    static func recoveredAt(workouts: [Workout], maxHeartRate: Double, now: Date,
                            wake: Date?, morningRecovery: DayRating?) -> Date? {
        let ends = workouts.filter { $0.end <= now }.map { workout in
            let zone = workout.averageHeartRate.map { IntensityZones.zone($0, maxHeartRate: maxHeartRate) } ?? .low
            return workout.end.addingTimeInterval(hours(zone) * 3600)
        }
        guard var recovered = ends.max() else { return nil }
        if let wake, let morningRecovery, morningRecovery != .good, recovered > wake, wake <= now {
            recovered = max(recovered, wake.addingTimeInterval(24 * 3600))
        }
        return recovered > now ? recovered : nil
    }
}

/// Readiness for hard training, from Garmin's inputs, each judged by the published threshold its own card uses:
/// last night's Sleep Score, Recovery Time, HRV Status, the acute:chronic load ratio (above Gabbett's 0.8–1.3 sweet
/// spot) and the last 3 nights against Sleep Need. Garmin also uses stress, which needs all-day HRV that iOS doesn't
/// record, so it's left out. Garmin's weighting isn't published and
/// no study has validated one, so like Recovery the rating counts the inputs that are off.
nonisolated enum TrainingReadiness {
    struct Input {
        var sleepScore: DayRating?
        /// Whether Recovery Time is still counting down.
        var recovering: Bool?
        var hrvStatus: HRVStatus.State?
        var loadRatio: Double?
        /// Average sleep of the last 3 nights and their average need.
        var recentSleep: TimeInterval?
        var recentNeed: TimeInterval = SleepNeed.baseline
    }

    struct Result: Equatable {
        let rating: DayRating
        let measured: Int
        let inRange: Int
        let reason: String

        var word: String {
            switch rating {
            case .good: String(localized: "High")
            case .fair: String(localized: "Moderate")
            case .poor: String(localized: "Low")
            }
        }
    }

    static let historyDays = 3
    /// Fewer inputs than this and the rating would rest on too little; Grada's own rule.
    static let minimumInputs = 3

    private static func hrvReason(_ state: HRVStatus.State) -> String {
        switch state {
        case .balanced: String(localized: "HRV balanced")
        case .unbalanced: String(localized: "HRV unbalanced")
        case .low: String(localized: "HRV low")
        }
    }

    static func status(_ input: Input) -> Result? {
        var checks: [(isOff: Bool, reason: String)] = []
        if let rating = input.sleepScore { checks.append((rating == .poor, String(localized: "Poor sleep"))) }
        if let recovering = input.recovering { checks.append((recovering, String(localized: "Still recovering"))) }
        if let state = input.hrvStatus { checks.append((state != .balanced, hrvReason(state))) }
        if let ratio = input.loadRatio { checks.append((ratio > Strain.sweetSpot.upperBound, String(localized: "Load rising fast"))) }
        if let sleep = input.recentSleep { checks.append((sleep < input.recentNeed, String(localized: "Short sleep \(historyDays) nights"))) }
        guard checks.count >= minimumInputs else { return nil }

        let off = checks.filter(\.isOff)
        let reason = switch off.count {
        case 0: String(localized: "Ready for hard training")
        case 1: off[0].reason
        default: String(localized: "\(off[0].reason) · \(off.count - 1) more off")
        }
        return Result(rating: DayRatings.healthStatus(outOfRange: off.count), measured: checks.count,
                      inRange: checks.count - off.count, reason: reason)
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
