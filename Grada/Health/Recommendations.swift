import Foundation

/// A short recommendation and the reason for it, always shown together.
nonisolated struct Recommendation: Equatable {
    /// SF Symbol for what it's about.
    let symbol: String
    let text: String
    let reason: String
    /// Place among the recommendations given every day: steps 0, bedtime 1. Nil for warnings that come and go.
    var dailyOrder: Int?
}

/// A fixed set of rules, each turning one card's data into a recommendation, or nil when there's nothing to say.
/// Thresholds come from the scores the cards already show, so a recommendation never disagrees with its card.
nonisolated enum Recommendations {
    /// Walking at 100 steps a minute or more is moderate intensity in adults (Tudor-Locke et al. 2018,
    /// Br J Sports Med 52:776).
    static let stepsPerMinute = 100.0

    /// Minutes of walking to today's goal, or a congratulation once it's reached.
    static func steps(today: Double, goal: Double) -> Recommendation {
        guard today < goal else {
            let over = today - goal
            return Recommendation(
                symbol: "checkmark.circle",
                text: String(localized: "Steps goal reached"),
                reason: over >= 1
                    ? String(localized: "\(whole(today)) steps today, \(whole(over)) over your goal of \(whole(goal)).")
                    : String(localized: "\(whole(today)) steps today, right on your goal."),
                dailyOrder: 0
            )
        }
        let left = goal - today
        let minutes = Int((left / stepsPerMinute).rounded(.up))
        return Recommendation(
            symbol: "figure.walk",
            text: minutes == 1 ? String(localized: "Walk about 1 more minute") : String(localized: "Walk about \(minutes) more minutes"),
            reason: String(localized: "\(whole(left)) steps to today's goal of \(whole(goal)). A brisk walk is about \(whole(stepsPerMinute)) steps a minute."),
            dailyOrder: 0
        )
    }

    /// The morning's steps focus: the whole goal, before the day's walking starts.
    static func stepsGoal(_ goal: Double) -> Recommendation {
        Recommendation(
            symbol: "figure.walk",
            text: String(localized: "Reach \(whole(goal)) steps"),
            reason: String(localized: "Your daily goal. A brisk walk is about \(whole(stepsPerMinute)) steps a minute.")
        )
    }

    /// Intensity minutes left to the weekly target, or that it's reached. The week is the last 7 days, as the card counts it.
    static func intensityMinutes(total: Double, target: Double) -> Recommendation {
        let week = String(localized: "\(whole(total)) of \(whole(target)) intensity minutes in the last 7 days.")
        guard total < target else {
            return Recommendation(symbol: "checkmark.circle", text: String(localized: "Weekly goal reached"), reason: week)
        }
        let left = Int((target - total).rounded(.up))
        return Recommendation(
            symbol: "figure.run",
            text: left == 1 ? String(localized: "Get about 1 more intensity minute")
                : String(localized: "Get about \(left) more intensity minutes"),
            reason: "\(week) \(String(localized: "Each brisk minute counts once, and each vigorous minute, like running, counts twice."))"
        )
    }

    /// Below most UK Biobank adults (Windred et al. 2024), whose more regular sleep went with lower mortality.
    static func sleepConsistency(_ index: Double) -> Recommendation? {
        guard SleepConsistency.rating(index) == .poor else { return nil }
        return Recommendation(
            symbol: "clock",
            text: String(localized: "Keep a regular sleep schedule"),
            reason: String(localized: "Your sleep consistency of \(whole(index)) is lower than in most adults. Go to bed and get up at the same times every day, weekends included.")
        )
    }

    /// Mishra et al. 2020 (Nat Biomed Eng 4:1208) saw resting heart rate rise above its personal baseline before
    /// symptoms in most of the infections they tracked; stress, alcohol and too little recovery raise it too.
    static func restingHeartRate(_ value: Double, normal: ClosedRange<Double>) -> Recommendation? {
        guard value > normal.upperBound else { return nil }
        return Recommendation(
            symbol: "heart",
            text: String(localized: "Take it easy today"),
            reason: String(localized: "Resting heart rate \(whole(value)) bpm is above your normal \(whole(normal.lowerBound))–\(whole(normal.upperBound)). It rises with illness, stress, alcohol and too little recovery.")
        )
    }

    /// Kiviniemi et al. 2007 (Eur J Appl Physiol 101:743) trained easy on days HRV fell below its usual range.
    static func hrv(_ state: HRVStatus.State) -> Recommendation? {
        guard state == .low else { return nil }
        return Recommendation(
            symbol: "waveform.path.ecg",
            text: String(localized: "Keep training easy"),
            reason: String(localized: "Your 7-night HRV is well below your baseline. HRV-guided training switches to easy days when it drops this far.")
        )
    }

    /// Outside Gabbett 2016's sweet spot. The ratio guides how fast load changes; it doesn't predict injury.
    static func load(ratio: Double) -> Recommendation? {
        let shown = ratio.formatted(.number.precision(.fractionLength(1)))
        let sweetSpot = "\(Strain.sweetSpot.lowerBound.formatted())–\(Strain.sweetSpot.upperBound.formatted())"
        if ratio > Strain.sweetSpot.upperBound {
            return Recommendation(
                symbol: "chart.bar",
                text: ratio >= Strain.dangerRatio ? String(localized: "Ease off for a few days") : String(localized: "Hold your load steady"),
                reason: String(localized: "This week's load is \(shown)× your 4-week average. Athletes had the fewest injuries when it stayed at \(sweetSpot)×.")
            )
        }
        if ratio < Strain.sweetSpot.lowerBound {
            return Recommendation(
                symbol: "chart.bar",
                text: String(localized: "Build back up gradually"),
                reason: String(localized: "This week's load is \(shown)× your 4-week average. Athletes had the fewest injuries when it stayed at \(sweetSpot)×.")
            )
        }
        return nil
    }

    /// Above Foster's monotony warning: the same load day after day, whatever its size.
    static func monotony(_ monotony: Double) -> Recommendation? {
        guard monotony > Strain.highMonotony else { return nil }
        return Recommendation(
            symbol: "chart.bar.xaxis",
            text: String(localized: "Mix hard and easy days"),
            reason: String(localized: "Your load has barely changed over the last 7 days (monotony \(monotony.formatted(.number.precision(.fractionLength(1)))), above \(Strain.highMonotony.formatted())). Athletes fell ill most often after hard weeks with too few easy days, so make some days easier and others harder.")
        )
    }

    /// The bedtime, the sleep it leaves before the planned wake-up, and, after midnight, Nikbakhtian et al. 2021
    /// (Eur Heart J Digit Health 2:658): in UK Biobank, sleep onset at 22:00–23:00 had the lowest cardiovascular
    /// risk and after midnight the highest. It observed people, so it's a note and doesn't move the bedtime.
    static func bedtime(_ plan: Bedtime.Plan, calendar: Calendar = .current) -> Recommendation {
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let sleep = SnapshotBuilder.hoursMinutes(plan.plannedWake.timeIntervalSince(plan.bedtime))
        let wake = time(plan.plannedWake)
        var reason = switch plan.weekend {
        case true?: String(localized: "That leaves \(sleep) of sleep before \(wake) on the weekend, at most an hour after your usual weekday wake-up.")
        case false?: String(localized: "That leaves \(sleep) of sleep before your usual weekday wake-up at \(wake).")
        case nil: String(localized: "That leaves \(sleep) of sleep before your usual wake-up at \(wake).")
        }
        if plan.payback > 0 {
            reason += " " + String(localized: "It includes \(SnapshotBuilder.hoursMinutes(plan.payback)) toward your \(SnapshotBuilder.hoursMinutes(plan.debt)) of sleep debt; paying it back takes several nights.")
        }
        if calendar.component(.hour, from: plan.bedtime) < 12 {
            let day = calendar.startOfDay(for: plan.bedtime)
            let early = time(day.addingTimeInterval(-2 * 3600)), late = time(day.addingTimeInterval(-3600))
            reason += " " + String(localized: "In a large study, falling asleep between \(early) and \(late) went with the lowest heart disease risk, and after midnight with the highest.")
        }
        return Recommendation(
            symbol: "bed.double",
            text: String(localized: "Go to bed by \(time(plan.bedtime))"),
            reason: reason,
            dailyOrder: 1
        )
    }

    /// Each recommendation once, daily ones first in their own order, so they keep their place as warnings come and go.
    static func dailyFirst(_ items: [Recommendation]) -> [Recommendation] {
        let unique = items.enumerated().filter { index, item in !items[..<index].contains(item) }.map(\.element)
        let daily = unique.compactMap { item in item.dailyOrder.map { (order: $0, item: item) } }
        return daily.sorted { $0.order < $1.order }.map(\.item) + unique.filter { $0.dailyOrder == nil }
    }

    private static func whole(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

/// Tonight's bedtime: the planned wake-up minus the sleep need and part of the sleep debt (`SleepNeed.payback`),
/// and never later than the usual bedtime, since a later one can't add sleep. Time awake in bed isn't added:
/// consumer trackers detect wake poorly (Chinoy et al. 2021, Sleep 44:zsaa291), and the need is learned from the
/// same tracked sleep, so they stay in the same units. Weekends plan from the weekday wake-up: sleeping later on
/// free days is social jetlag (Wittmann et al. 2006, Chronobiol Int 23:497), and each hour of it went with higher
/// odds of overweight (Roenneberg et al. 2012, Curr Biol 22:939). Allowing a weekend up to `weekendShift` later is
/// Grada's choice.
nonisolated enum Bedtime {
    /// One recorded night: when sleep started and ended.
    struct Night: Equatable {
        let wakeDay: Date
        let start: Date
        let end: Date
    }

    struct Plan: Equatable {
        let bedtime: Date
        /// The wake-up the bedtime is for: the usual one, but on a weekend at most `weekendShift` after the weekday one.
        let plannedWake: Date
        /// The usual wake-up and bedtime of nights of the same kind, for report times and Settings.
        let wake: Date
        let usualBedtime: Date
        /// Extra sleep planned toward `debt`, the sleep debt after last night.
        var payback: TimeInterval = 0
        var debt: TimeInterval = 0
        /// Whether the wake-up is the usual weekend or weekday one; nil when too few nights of that kind mixed both.
        let weekend: Bool?
    }

    /// Nights looked back on. Grada's choice; no study sets a window for the usual wake-up.
    static let nights = 14
    /// Nights of the same kind (weekday or weekend) needed; with fewer, all nights count. Grada's choice.
    static let minimumNights = 3
    /// How much later than the weekday schedule a weekend may run. Grada's choice.
    static let weekendShift: TimeInterval = 3600

    /// Usual wake-up and sleep start as offsets from the wake day's midnight: medians.
    private struct Usual {
        let wake: TimeInterval
        let start: TimeInterval
    }

    /// The plan for the night that ends on `wakeDay`, from recent nights. Nil with fewer than `minimumNights`.
    static func plan(nights: [Night], need: TimeInterval, payback: TimeInterval = 0, debt: TimeInterval = 0,
                     wakeDay: Date, calendar: Calendar) -> Plan? {
        let weekend = calendar.isDateInWeekend(wakeDay)
        let weekdays = nights.filter { !calendar.isDateInWeekend($0.wakeDay) }
        let sameKind = weekend ? nights.filter { calendar.isDateInWeekend($0.wakeDay) } : weekdays
        let split = sameKind.count >= minimumNights
        guard let usual = usual(split ? sameKind : nights, calendar: calendar) else { return nil }
        var plannedWake = usual.wake, latest = usual.start
        if weekend, split, weekdays.count >= minimumNights, let weekday = Self.usual(weekdays, calendar: calendar) {
            let shift = min(usual.wake - weekday.wake, weekendShift)
            plannedWake = weekday.wake + shift
            latest = min(weekday.start + shift, usual.start)
        }
        let midnight = calendar.startOfDay(for: wakeDay)
        return Plan(bedtime: midnight.addingTimeInterval(min(plannedWake - need - payback, latest)),
                    plannedWake: midnight.addingTimeInterval(plannedWake),
                    wake: midnight.addingTimeInterval(usual.wake), usualBedtime: midnight.addingTimeInterval(usual.start),
                    payback: payback, debt: debt, weekend: split ? weekend : nil)
    }

    private static func usual(_ nights: [Night], calendar: Calendar) -> Usual? {
        guard nights.count >= minimumNights,
              let wake = median(nights.map { $0.end.timeIntervalSince(calendar.startOfDay(for: $0.wakeDay)) }),
              let start = median(nights.map { $0.start.timeIntervalSince(calendar.startOfDay(for: $0.wakeDay)) })
        else { return nil }
        return Usual(wake: wake, start: start)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
