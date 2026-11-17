import Foundation

/// One morning's summary: last night's sleep, recovery, vitals and readiness, with today's recommendations.
struct MorningReport {
    /// The cards it summarizes, in order.
    static let kinds: [CardKind] = [.sleepScore, .sleepDuration, .recovery, .healthStatus, .trainingReadiness]
    /// Cards whose recommendations it gathers.
    static let recommendationKinds: [CardKind] = [.restingHeartRate, .hrvStatus, .strain]

    /// False until the night that ended on the report's day is recorded; the report then has nothing else.
    var hasSleep = false
    var snapshots: [CardKind: CardSnapshot] = [:]
    var recommendations: [Recommendation] = []

    /// The report for the builder's day. Recommendations come only for today, as on the cards.
    static func load(_ builder: SnapshotBuilder) async throws -> MorningReport {
        let day = builder.calendar.startOfDay(for: builder.now)
        let nights = try await builder.source.sleepNights(days: 1)
        guard nights.contains(where: { $0.wakeDay == day && $0.asleep > 0 }) else { return MorningReport() }
        var report = MorningReport(hasSleep: true)
        for kind in kinds {
            report.snapshots[kind] = try await builder.snapshot(for: kind)
        }
        for kind in recommendationKinds {
            if let recommendation = try await builder.snapshot(for: kind).recommendation {
                report.recommendations.append(recommendation)
            }
        }
        return report
    }

    /// One line for the notification, e.g. "Slept 7h 20m · Recovery Good · All in range".
    var summary: String {
        // Calibrating scores have nothing to say yet.
        let value = { (kind: CardKind) in self.snapshots[kind]?.value.flatMap { $0 == "Calibrating" ? nil : $0 } }
        return [value(.sleepDuration).map { "Slept \($0)" }, value(.sleepScore).map { "Sleep Score \($0)" },
                value(.recovery).map { "Recovery \($0)" }, value(.healthStatus)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// When the user wakes, for the morning report: their own time, or the usual one from recent nights.
/// Kept on this device.
nonisolated enum SleepSchedule {
    static let usesUsualWakeKey = "sleepSchedule.usesUsualWake"
    /// Minutes after midnight.
    static let wakeMinutesKey = "sleepSchedule.wakeMinutes"
    static let morningReportKey = "sleepSchedule.morningReport"
    /// Until there are enough nights for a usual wake-up.
    static let defaultWakeMinutes = 7 * 60

    /// The wake-up on `day`: the user's own time, else `usual`, else the default.
    static func wake(on day: Date, usual: Date?, defaults: UserDefaults = .standard, calendar: Calendar) -> Date {
        let usesUsual = defaults.object(forKey: usesUsualWakeKey) as? Bool ?? true
        if usesUsual, let usual { return usual }
        let minutes = usesUsual ? defaultWakeMinutes : defaults.object(forKey: wakeMinutesKey) as? Int ?? defaultWakeMinutes
        return calendar.startOfDay(for: day).addingTimeInterval(Double(minutes) * 60)
    }
}
