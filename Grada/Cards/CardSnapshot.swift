import Foundation

/// Everything a card needs to render, already formatted.
struct CardSnapshot {
    enum Tone { case neutral, good, warning }

    enum Chart {
        case none
        /// Seven values, oldest first; the last one is today. With a target, a full bar means the target was reached.
        /// With ratings, each day's bar takes its rating's color.
        case bars([Double?], target: Double? = nil, ratings: [DayRating?]? = nil)
        /// Seven nights, oldest first, each bar split by sleep stage; nil where there's no night.
        /// With a target in hours, a full bar means the target was reached.
        case sleep([SleepNight?], target: Double? = nil)
        case line([Double?], normalRange: ClosedRange<Double>?)
        /// A horizontal 0–100% goal bar, like Suunto's Steps card. Cards without a goal measure against
        /// their 7-day average instead.
        case progress(value: Double, goal: Double, isAverage: Bool = false)
        /// Today's value as a marker on a track: green over the normal range, then yellow and red away from it.
        /// `below` and `above` are how far past each bound stays yellow before red; nil keeps that side green,
        /// infinity keeps it yellow. Edge labels show `decimals` digits; 0 snaps the scale to whole numbers.
        case range(value: Double, normalRange: ClosedRange<Double>, below: Double?, above: Double?, decimals: Int = 0)
        /// A value on a track split into VO₂ max fitness zones; `bounds` are the lower bounds of zones 2–5.
        case zones(value: Double, bounds: [Double])
        /// Today from 0:00: hours since midnight and value. A nil domain fits the values.
        case intraday([(hour: Double, value: Double)], domain: ClosedRange<Double>?)

        /// A one-sided range colored like `DayRatings.range`: only the unhealthy side turns yellow, then red.
        static func range(value: Double, normalRange: ClosedRange<Double>, higherIsBetter: Bool, decimals: Int) -> Chart {
            let slight = DayRatings.slightMiss(normalRange)
            return .range(value: value, normalRange: normalRange,
                          below: higherIsBetter ? slight : nil, above: higherIsBetter ? nil : slight, decimals: decimals)
        }

        /// Bar charts sit beside the value on wide cards.
        var isBars: Bool {
            switch self {
            case .bars, .sleep: true
            case .none, .line, .intraday, .progress, .range, .zones: false
            }
        }
    }

    enum Detail {
        case none
        case sleepStages([SleepStage: TimeInterval])
        case workout(WorkoutSummary)
        /// Workouts per day for the last 30 days, oldest first.
        case days([WorkoutDay])
        case vitals([VitalStatus])
        /// A row of small labelled values, e.g. race times.
        case stats([(value: String, label: String)])
        /// A short list of labelled values, each colored by its rating, e.g. health age contributors.
        case rows([(label: String, value: String, rating: DayRating?)])
    }

    var period: String
    /// Nil means Apple Health has no data for this card.
    var value: String?
    var unit: String = ""
    var comparison: String?
    var tone: Tone = .neutral
    /// Colors the value red, yellow or green. Nil keeps it neutral.
    var rating: DayRating?
    var chart: Chart = .none
    var detail: Detail = .none

    static func noData(period: String) -> CardSnapshot {
        CardSnapshot(period: period, value: nil)
    }
}

/// One day's workouts: minutes per sport, longest first.
struct WorkoutDay: Equatable {
    struct Sport: Equatable {
        let name: String
        let symbol: String
        var minutes: Double
    }

    var sports: [Sport] = []
    var workouts = 0

    var minutes: Double { sports.reduce(0) { $0 + $1.minutes } }

    /// Workouts grouped by the start of their day.
    static func byDay(_ workouts: [WorkoutSummary], calendar: Calendar) -> [Date: WorkoutDay] {
        var result: [Date: WorkoutDay] = [:]
        for workout in workouts {
            let day = calendar.startOfDay(for: workout.start)
            var entry = result[day, default: WorkoutDay()]
            entry.workouts += 1
            if let sport = entry.sports.firstIndex(where: { $0.name == workout.name }) {
                entry.sports[sport].minutes += workout.duration / 60
            } else {
                entry.sports.append(.init(name: workout.name, symbol: workout.symbol, minutes: workout.duration / 60))
            }
            result[day] = entry
        }
        for day in result.keys {
            result[day]?.sports.sort { $0.minutes > $1.minutes }
        }
        return result
    }

    /// Up to `limit` sports by the days they appear on, most first.
    static func topSports(_ days: some Sequence<WorkoutDay>, limit: Int) -> [(name: String, symbol: String)] {
        var counts: [String: (symbol: String, days: Int)] = [:]
        for day in days {
            for sport in day.sports {
                counts[sport.name, default: (sport.symbol, 0)].days += 1
            }
        }
        return counts.sorted { $0.value.days > $1.value.days || ($0.value.days == $1.value.days && $0.key < $1.key) }
            .prefix(limit)
            .map { (name: $0.key, symbol: $0.value.symbol) }
    }
}

struct VitalStatus: Equatable {
    enum State { case inRange, outOfRange, calibrating, noData }

    let name: String
    let state: State
    /// Green, yellow or red for a measured vital; nil while calibrating or without data.
    var rating: DayRating?
}
