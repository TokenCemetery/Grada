import Foundation

/// Weekly moderate and vigorous minutes against the WHO target, like Garmin Intensity Minutes.
nonisolated enum IntensityMinutes {
    /// WHO: at least 150 minutes of moderate activity a week, or 75 vigorous. The guideline doesn't say "counts
    /// double"; that follows from the 150-to-75 ratio.
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
            case .veryLight: String(localized: "Very light")
            case .light: String(localized: "Light")
            case .moderate: String(localized: "Moderate")
            case .vigorous: String(localized: "Vigorous")
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

/// Seiler's three intensity zones by share of max heart rate: low below the first ventilatory threshold, threshold
/// between the two, high above the second. Seiler & Kjerland 2006 (Scand J Med Sci Sports
/// 16:49) built the three zones from those thresholds. Seiler 2010 (Int J Sports Physiol Perform 5:276, Table 1)
/// shows the Norwegian Olympic five-zone scale, whose zone 3, the band between the thresholds, is 82–87% of max
/// heart rate; Sylta et al. 2014 (Int J Sports Physiol Perform 9:100) collapsed that scale into three zones.
nonisolated enum IntensityZones {
    enum Zone: Int, CaseIterable {
        case low, threshold, high

        var title: String {
            switch self {
            case .low: String(localized: "Low")
            case .threshold: String(localized: "Threshold")
            case .high: String(localized: "High")
            }
        }
    }

    /// Lower bounds of threshold and high.
    static let lowerBounds = [0.82, 0.88]

    static func zone(_ heartRate: Double, maxHeartRate: Double) -> Zone {
        Zone(rawValue: lowerBounds.filter { heartRate / maxHeartRate >= $0 }.count)!
    }

    /// Seconds in low, threshold and high. Each reading lasts until the next, up to `HeartRateZones.maxGap`;
    /// the last one lasts until `end`.
    static func time(_ heartRate: [TimedValue], end: Date, maxHeartRate: Double) -> [TimeInterval] {
        var seconds = Array(repeating: 0.0, count: Zone.allCases.count)
        for (index, reading) in heartRate.enumerated() {
            let next = index + 1 < heartRate.count ? heartRate[index + 1].date : end
            seconds[zone(reading.value, maxHeartRate: maxHeartRate).rawValue] +=
                min(max(next.timeIntervalSince(reading.date), 0), HeartRateZones.maxGap)
        }
        return seconds
    }
}
