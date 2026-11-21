import Foundation

/// A day's morning or evening summary: a few cards and the recommendations that go with them.
struct DailyReport {
    enum Kind {
        /// Last night's sleep, recovery, vitals and readiness.
        case morning
        /// Today's activity and training against goals, and tonight's bedtime.
        case evening

        var title: String {
            switch self {
            case .morning: String(localized: "Morning Report")
            case .evening: String(localized: "Evening Report")
            }
        }

        /// The cards it shows, in order.
        var kinds: [CardKind] {
            switch self {
            case .morning: [.sleepScore, .sleepDuration, .recovery, .healthStatus, .trainingReadiness]
            case .evening: [.steps, .activeEnergy, .intensityMinutes, .weeklyTraining, .strain]
            }
        }

        /// Cards it doesn't show but takes recommendations from, besides its own.
        var adviceKinds: [CardKind] {
            switch self {
            case .morning: [.restingHeartRate, .hrvStatus, .strain]
            // Tonight's bedtime; the recommendation already says the sleep need, so no row repeats it.
            case .evening: [.sleepNeed]
            }
        }
    }

    let kind: Kind
    /// False when there's nothing to report: the morning report waits for the night that ended on its day.
    var hasData = false
    var snapshots: [CardKind: CardSnapshot] = [:]
    var recommendations: [Recommendation] = []

    /// The report for the builder's day. Recommendations come only for today, as on the cards.
    static func load(_ kind: Kind, _ builder: SnapshotBuilder) async throws -> DailyReport {
        if kind == .morning {
            let day = builder.calendar.startOfDay(for: builder.now)
            let nights = try await builder.source.sleepNights(days: 1)
            guard nights.contains(where: { $0.wakeDay == day && $0.asleep > 0 }) else { return DailyReport(kind: kind) }
        }
        var report = DailyReport(kind: kind, hasData: true)
        // Advice-only cards first: the evening's bedtime matters most, and the notification shows two at most.
        for card in kind.adviceKinds + kind.kinds {
            let snapshot = try await builder.snapshot(for: card)
            if kind.kinds.contains(card) { report.snapshots[card] = snapshot }
            // Both reports take Strain's, so a card's advice is listed once.
            if let recommendation = snapshot.recommendation, !report.recommendations.contains(recommendation) {
                report.recommendations.append(recommendation)
            }
        }
        return report
    }

    /// One line for the notification, e.g. "Slept 7h 20m · Recovery Good · All in range".
    var summary: String {
        // Calibrating scores have nothing to say yet.
        let value = { (card: CardKind) in self.snapshots[card]?.value.flatMap { $0 == String(localized: "Calibrating") ? nil : $0 } }
        let parts: [String?] = switch kind {
        case .morning:
            [value(.sleepDuration).map { String(localized: "Slept \($0)") },
             value(.sleepScore).map { String(localized: "Sleep Score \($0)") },
             value(.recovery).map { String(localized: "Recovery \($0)") }, value(.healthStatus)]
        case .evening:
            [value(.steps).map { String(localized: "\($0) steps") },
             value(.intensityMinutes).map { String(localized: "\($0) intensity min this week") },
             value(.strain).map { String(localized: "Strain \($0)") }]
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// The notification's text: the summary, then up to two recommendations.
    var notificationBody: String {
        ([summary] + recommendations.prefix(2).map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// When the user sleeps and wakes, for the reports: their own times, or the usual ones from recent nights.
/// Kept on this device.
nonisolated enum SleepSchedule {
    static let usesUsualTimesKey = "sleepSchedule.usesUsualTimes"
    /// Minutes after midnight.
    static let wakeMinutesKey = "sleepSchedule.wakeMinutes"
    /// Minutes after midnight; before noon means after midnight.
    static let bedtimeMinutesKey = "sleepSchedule.bedtimeMinutes"
    /// Minutes before bedtime that the evening report comes.
    static let windDownMinutesKey = "sleepSchedule.windDownMinutes"
    static let morningReportKey = "sleepSchedule.morningReport"
    static let eveningReportKey = "sleepSchedule.eveningReport"
    /// Until there are enough nights for usual times.
    static let defaultWakeMinutes = 7 * 60
    static let defaultBedtimeMinutes = 23 * 60
    /// No study sets how long before bed to wind down (Irish et al. 2015 found sleep hygiene advice largely
    /// untested), so this is Grada's choice.
    static let defaultWindDownMinutes = 60

    /// The wake-up on `day`: the user's own time, else `usual`, else the default.
    static func wake(on day: Date, usual: Date?, defaults: UserDefaults = .standard, calendar: Calendar) -> Date {
        if usesUsualTimes(defaults), let usual { return usual }
        let minutes = usesUsualTimes(defaults) ? defaultWakeMinutes : defaults.object(forKey: wakeMinutesKey) as? Int ?? defaultWakeMinutes
        return time(minutes, on: day, calendar: calendar)
    }

    /// The bedtime on the evening of `day`: the user's own time, else `usual`, else the default.
    static func bedtime(on day: Date, usual: Date?, defaults: UserDefaults = .standard, calendar: Calendar) -> Date {
        if usesUsualTimes(defaults), let usual { return usual }
        let minutes = usesUsualTimes(defaults) ? defaultBedtimeMinutes
            : defaults.object(forKey: bedtimeMinutesKey) as? Int ?? defaultBedtimeMinutes
        // A bedtime before noon is after midnight, so on the next calendar day.
        let start = calendar.startOfDay(for: day)
        let evening = minutes < 12 * 60 ? calendar.date(byAdding: .day, value: 1, to: start)! : start
        return time(minutes, on: evening, calendar: calendar)
    }

    /// The clock time `minutes` after midnight on `day`. Adding seconds to midnight would be an hour off on the
    /// days clocks change.
    static func time(_ minutes: Int, on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)!
    }

    static func windDown(_ defaults: UserDefaults = .standard) -> TimeInterval {
        Double(defaults.object(forKey: windDownMinutesKey) as? Int ?? defaultWindDownMinutes) * 60
    }

    private static func usesUsualTimes(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: usesUsualTimesKey) as? Bool ?? true
    }
}
