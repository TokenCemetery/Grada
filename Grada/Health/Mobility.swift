import Foundation
import HealthKit

/// Walking speed and Walking Steadiness from iPhone (#136). Studenski et al. 2011 (JAMA 305:50) pooled 9 cohorts of
/// adults 65 and older: survival rose with every 0.1 m/s of gait speed, 1.0 m/s or faster meant longer survival than
/// age and sex alone predict, about 0.8 m/s sat at the median, and they suggested below 0.6 m/s may mark a higher
/// risk. Those come from timed walks on a course; iPhone measures everyday walking, so the bands are a guide.
nonisolated enum Mobility {
    /// Studenski's cut-offs, in metres per second.
    static let longerSurvival = 1.0
    static let medianSurvival = 0.8
    static let higherRisk = 0.6
    /// The age Studenski's cohorts started at; younger people's speed isn't rated against them.
    static let studiedFromAge = 65
    /// Days averaged for the card's speed, so one day of mostly indoor walking doesn't set its colour; Walking
    /// Steadiness older than this isn't shown. Grada's choice.
    static let recentDays = 7

    /// Green from 1.0 m/s, red below 0.6, orange between.
    static func rating(metersPerSecond speed: Double) -> DayRating {
        if speed >= longerSurvival { return .good }
        return speed >= higherRisk ? .fair : .poor
    }

    /// Kilometres an hour, or miles an hour in the US.
    static func speed(_ metersPerSecond: Double, usesMetric: Bool) -> Double {
        metersPerSecond * (usesMetric ? 3.6 : 2.236_936)
    }

    static func speedUnit(usesMetric: Bool) -> String {
        usesMetric ? String(localized: "km/h", comment: "Unit: kilometres per hour") : String(localized: "mph", comment: "Unit: miles per hour")
    }

    /// Apple's own Walking Steadiness classes.
    enum Steadiness {
        case ok, low, veryLow

        /// Apple's classification of a Walking Steadiness percentage; nil if Apple can't class it.
        init?(percent: Double) {
            guard let apple = try? HKAppleWalkingSteadinessClassification(for: HKQuantity(unit: .percent(), doubleValue: percent / 100))
            else { return nil }
            switch apple {
            case .ok: self = .ok
            case .low: self = .low
            case .veryLow: self = .veryLow
            @unknown default: return nil
            }
        }

        var title: String {
            switch self {
            case .ok: String(localized: "steadiness.ok", defaultValue: "OK", comment: "Apple Walking Steadiness class")
            case .low: String(localized: "steadiness.low", defaultValue: "Low", comment: "Apple Walking Steadiness class")
            case .veryLow: String(localized: "steadiness.veryLow", defaultValue: "Very Low", comment: "Apple Walking Steadiness class")
            }
        }

        var rating: DayRating {
            switch self {
            case .ok: .good
            case .low: .fair
            case .veryLow: .poor
            }
        }
    }
}
