import Foundation

/// Heart rate recovery: how far heart rate falls in the first minute after a workout ends (#131).
nonisolated enum HeartRateRecovery {
    /// A drop of 12 bpm or less from peak exercise to one minute later was abnormal in Cole et al. 1999, whose
    /// patients walked slowly in that minute (a cool-down). Standing still, heart rate falls faster: without a
    /// cool-down Watanabe et al. 2001 used 18 bpm, so this cut-off only flags clearly slow recoveries.
    static let slowCutOff = 12.0
    /// How far from one minute after the end the reading may be. Apple Watch records heart rate every few
    /// seconds while a workout runs and less often after; Grada's estimate.
    static let readingTolerance: TimeInterval = 15
    /// How long after a workout's end Apple's own one-minute recovery sample may start; Grada's estimate.
    static let sampleWindow: TimeInterval = 5 * 60
    /// The last reading `derived` uses, relative to the end.
    static var readingWindow: TimeInterval { 60 + readingTolerance }
    /// How far back the card looks for the latest recovery; an older one isn't today's fitness. Grada's estimate.
    static let cardDays = 14

    /// The peak in the last minute of the workout minus the reading closest to one minute after it ends.
    /// Nil without readings on both sides, or when heart rate rose, which means something other than
    /// recovery was going on.
    static func derived(_ readings: [TimedValue], end: Date) -> Double? {
        let peak = readings.filter { $0.date >= end.addingTimeInterval(-60) && $0.date <= end }.map(\.value).max()
        let target = end.addingTimeInterval(60)
        let after = readings
            .filter { $0.date > end && abs($0.date.timeIntervalSince(target)) <= readingTolerance }
            .min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
        guard let peak, let after, peak >= after.value else { return nil }
        return peak - after.value
    }

    /// Whether a workout starts between `end` and the last reading `derived` uses: that minute's heart rate
    /// then belongs to the next workout, such as a cool-down logged on its own.
    static func isFollowed(end: Date, byStarts starts: [Date]) -> Bool {
        starts.contains { $0 >= end && $0 <= end.addingTimeInterval(readingWindow) }
    }

    /// Each of Apple's samples goes to the workout that ended last before it, within `sampleWindow`; a sample may be
    /// stamped up to a minute before the end it measures. A workout keeps its first sample.
    static func match(_ samples: [TimedValue], to workouts: [(id: String, end: Date)]) -> [String: Double] {
        var result: [String: Double] = [:]
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            let ended = workouts.filter {
                sample.date >= $0.end.addingTimeInterval(-60) && sample.date <= $0.end.addingTimeInterval(sampleWindow)
            }
            guard let workout = ended.max(by: { $0.end < $1.end }), result[workout.id] == nil else { continue }
            result[workout.id] = sample.value
        }
        return result
    }

    /// Per day, the recovery after that day's last workout with one; nil on days without.
    static func byDay(_ values: [String: Double], workouts: [WorkoutSummary], days: [Date], calendar: Calendar) -> [DayValue] {
        let latest = Dictionary(grouping: workouts.filter { values[$0.id] != nil }) { calendar.startOfDay(for: $0.start) }
            .mapValues { $0.max { $0.start < $1.start }! }
        return days.map { day in DayValue(day: day, value: latest[day].flatMap { values[$0.id] }) }
    }

    static func rating(_ value: Double) -> DayRating {
        value > slowCutOff ? .good : .fair
    }
}
