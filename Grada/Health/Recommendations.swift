import Foundation

/// A short recommendation and the reason for it, always shown together.
nonisolated struct Recommendation: Equatable {
    /// SF Symbol for what it's about.
    let symbol: String
    let text: String
    let reason: String
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
                    : String(localized: "\(whole(today)) steps today, right on your goal.")
            )
        }
        let left = goal - today
        let minutes = Int((left / stepsPerMinute).rounded(.up))
        return Recommendation(
            symbol: "figure.walk",
            text: minutes == 1 ? String(localized: "Walk about 1 more minute") : String(localized: "Walk about \(minutes) more minutes"),
            reason: String(localized: "\(whole(left)) steps to today's goal of \(whole(goal)). A brisk walk is about \(whole(stepsPerMinute)) steps a minute.")
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

    static func bedtime(_ plan: Bedtime.Plan, need: TimeInterval) -> Recommendation {
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let usual = switch plan.weekend {
        case true?: String(localized: "usual weekend wake-up")
        case false?: String(localized: "usual weekday wake-up")
        case nil: String(localized: "usual wake-up")
        }
        let sleepNeed = SnapshotBuilder.hoursMinutes(need)
        let wake = time(plan.wake)
        let reason = plan.awakeInBed >= 60
            ? String(localized: "For \(sleepNeed) of sleep before your \(usual) at \(wake), plus the \(SnapshotBuilder.hoursMinutes(plan.awakeInBed)) you usually lie awake.")
            : String(localized: "For \(sleepNeed) of sleep before your \(usual) at \(wake).")
        return Recommendation(
            symbol: "bed.double",
            text: String(localized: "Go to bed by \(time(plan.bedtime))"),
            reason: reason
        )
    }

    private static func whole(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

/// Tonight's bedtime: the usual wake-up minus the sleep need and the time usually spent awake in bed.
/// Weekdays and weekends are kept apart because people wake later on free days (Wittmann et al. 2006,
/// Chronobiol Int 23:497). No study adds sleep debt to the bedtime, so `SleepNeed` doesn't either.
nonisolated enum Bedtime {
    /// One recorded night: when sleep started and ended, and the time asleep in between.
    struct Night: Equatable {
        let wakeDay: Date
        let start: Date
        let end: Date
        let asleep: TimeInterval
    }

    struct Plan: Equatable {
        let bedtime: Date
        let wake: Date
        /// When sleep usually starts before this wake-up, from the same nights.
        let usualBedtime: Date
        let awakeInBed: TimeInterval
        /// Whether the wake-up is the usual weekend or weekday one; nil when too few nights of that kind mixed both.
        let weekend: Bool?
    }

    /// Nights looked back on. Grada's choice; no study sets a window for the usual wake-up.
    static let nights = 14
    /// Nights of the same kind (weekday or weekend) needed; with fewer, all nights count. Grada's choice.
    static let minimumNights = 3

    /// The plan for the night that ends on `wakeDay`, from recent nights. Nil with fewer than `minimumNights`.
    static func plan(nights: [Night], need: TimeInterval, wakeDay: Date, calendar: Calendar) -> Plan? {
        let weekend = calendar.isDateInWeekend(wakeDay)
        let sameKind = nights.filter { calendar.isDateInWeekend($0.wakeDay) == weekend }
        let used = sameKind.count >= minimumNights ? sameKind : nights
        guard used.count >= minimumNights,
              let wakeOffset = median(used.map { $0.end.timeIntervalSince(calendar.startOfDay(for: $0.wakeDay)) }),
              let startOffset = median(used.map { $0.start.timeIntervalSince(calendar.startOfDay(for: $0.wakeDay)) }),
              let awake = median(used.map { max($0.end.timeIntervalSince($0.start) - $0.asleep, 0) })
        else { return nil }
        let wake = calendar.startOfDay(for: wakeDay).addingTimeInterval(wakeOffset)
        return Plan(bedtime: wake.addingTimeInterval(-need - awake), wake: wake,
                    usualBedtime: calendar.startOfDay(for: wakeDay).addingTimeInterval(startOffset), awakeInBed: awake,
                    weekend: sameKind.count >= minimumNights ? weekend : nil)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
