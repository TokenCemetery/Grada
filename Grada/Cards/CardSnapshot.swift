import Foundation

/// Everything a card needs to render, already formatted.
struct CardSnapshot {
    enum Tone { case neutral, good, warning }

    enum Chart {
        case none
        /// Seven values, oldest first; the last one is today.
        case bars([Double?])
        /// Seven nights, oldest first, each bar split by sleep stage; nil where there's no night.
        case sleep([SleepNight?])
        case line([Double?], normalRange: ClosedRange<Double>?)
        /// A horizontal 0–100% goal bar, like Suunto's Steps card.
        case progress(value: Double, goal: Double)
        /// Today from 0:00: hours since midnight and value. A nil domain fits the values.
        case intraday([(hour: Double, value: Double)], domain: ClosedRange<Double>?)

        /// Bar charts sit beside the value on wide cards.
        var isBars: Bool {
            switch self {
            case .bars, .sleep: true
            case .none, .line, .intraday, .progress: false
            }
        }
    }

    enum Detail {
        case none
        case sleepStages([SleepStage: TimeInterval])
        case workout(WorkoutSummary)
        /// Workout minutes per day for the last 30 days, oldest first.
        case days([Double])
        case vitals([VitalStatus])
        /// A row of small labelled values, e.g. race times or health age contributors.
        case stats([(value: String, label: String)])
    }

    var period: String
    /// Nil means Apple Health has no data for this card.
    var value: String?
    var unit: String = ""
    var comparison: String?
    var tone: Tone = .neutral
    var chart: Chart = .none
    var detail: Detail = .none

    static func noData(period: String) -> CardSnapshot {
        CardSnapshot(period: period, value: nil)
    }
}

struct VitalStatus: Equatable {
    enum State { case inRange, outOfRange, calibrating, noData }

    let name: String
    let state: State
}
