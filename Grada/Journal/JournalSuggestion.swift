import Foundation

/// A tag Grada suggests for a day from health data (#104). It's only shown: the journal keeps it once the user
/// confirms it, so the journal stays the user's own record and calculations use only confirmed tags.
nonisolated struct JournalSuggestion: Equatable {
    let tag: JournalTag
    /// Why, e.g. "Resting HR and breathing above your normal".
    let reason: String
    /// Logged with the tag when confirmed (nap minutes); nil for yes/no tags.
    var amount: Double?

    /// One vital from the night that ended on the day, with the nights before it.
    struct Vital {
        enum Kind { case hrv, restingHeartRate, breathing, temperature }
        let kind: Kind
        let value: Double?
        let history: [Double]
    }

    /// Possible illness when at least two vitals are outside the user's normal range in the direction illness
    /// moves them: HRV down, resting heart rate, breathing and temperature up. These are Health Status's ranges.
    /// One vital alone never counts: HRV drops after a hard workout or a drink too. After a day with Alcohol,
    /// heart rate and HRV are explained, so breathing or temperature must be among them. Vitals without a
    /// value or still calibrating are skipped. Resting heart rate rose before symptoms in most COVID-19 cases a
    /// wearable study looked at (Mishra et al. 2020, Nat Biomed Eng 4:1208).
    static func illness(_ vitals: [Vital], alcoholDayBefore: Bool) -> JournalSuggestion? {
        let off = vitals.compactMap { vital -> Vital.Kind? in
            let metric: QuantityMetric = switch vital.kind {
            case .hrv: .hrv
            case .restingHeartRate: .restingHeartRate
            case .breathing: .respiratoryRate
            case .temperature: .wristTemperature
            }
            guard let value = vital.value,
                  let range = Baseline.normalRange(history: vital.history, minimumHalfWidth: metric.minimumHalfWidth)
            else { return nil }
            let isOff = vital.kind == .hrv ? value < range.lowerBound : value > range.upperBound
            return isOff ? vital.kind : nil
        }
        guard off.count >= 2 else { return nil }
        if alcoholDayBefore, !off.contains(.breathing), !off.contains(.temperature) { return nil }
        let names = off.map { kind in
            switch kind {
            case .hrv: "HRV low"
            case .restingHeartRate: "resting HR high"
            case .breathing: "breathing fast"
            case .temperature: "temperature up"
            }
        }
        return JournalSuggestion(tag: .illness, reason: names.joined(separator: ", ").capitalizedFirst)
    }

    /// Daytime sleep that isn't anyone's night: asleep periods starting on `day` outside the main sleep of the night
    /// they count toward (#101). Under 10 minutes is more likely a doze on the sofa than a nap; Grada's estimate.
    static func nap(_ periods: [SleepPeriod], day: Date, calendar: Calendar) -> JournalSuggestion? {
        let main = Dictionary(grouping: periods) { SleepNight.wakeDay(forEnd: $0.end, calendar: calendar) }
            .values.flatMap { SleepNight.mainSleep($0, start: \.start, end: \.end) }
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)!
        let naps = periods.filter { $0.stage != .awake && $0.start >= day && $0.start < dayEnd && !main.contains($0) }
        let asleep = naps.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard asleep >= 10 * 60, let amount = JournalTag.nap.amount else { return nil }
        let minutes = min(max((asleep / 60 / amount.step).rounded() * amount.step, amount.range.lowerBound), amount.range.upperBound)
        return JournalSuggestion(tag: .nap, reason: "\(SnapshotBuilder.hoursMinutes(asleep)) of daytime sleep", amount: minutes)
    }

    /// Any mindful session of 5 minutes or more; Breathe sessions of a minute aren't a meditation. Grada's estimate.
    static func meditation(_ time: TimeInterval?) -> JournalSuggestion? {
        guard let time, time >= 5 * 60 else { return nil }
        return JournalSuggestion(tag: .meditation, reason: "\(SnapshotBuilder.hoursMinutes(time)) of mindful sessions")
    }

    /// 30 minutes or more in daylight; no study sets a bar for "time outdoors", so it's Grada's estimate.
    static func outdoorTime(_ time: TimeInterval?) -> JournalSuggestion? {
        guard let time, time >= 30 * 60 else { return nil }
        return JournalSuggestion(tag: .outdoorTime, reason: "\(SnapshotBuilder.hoursMinutes(time)) in daylight")
    }

    /// The suggestions for `day`. `alcoholDayBefore` is whether Alcohol is logged on the day before, whose night
    /// ended this morning.
    static func load(day: Date, alcoholDayBefore: Bool, source: HealthDataSource,
                     calendar: Calendar) async throws -> [JournalSuggestion] {
        let day = calendar.startOfDay(for: day)
        let asOf = PastDaySource.asOf(day, base: source, calendar: calendar)
        // Health Status's 30 nights of baseline, plus the night itself.
        let days = 31
        var vitals: [Vital] = []
        for (kind, metric) in [(Vital.Kind.hrv, QuantityMetric.hrv), (.restingHeartRate, .restingHeartRate),
                               (.breathing, .respiratoryRate), (.temperature, .wristTemperature)] {
            let series = try await SnapshotBuilder.vitalSeries(metric, days: days, source: asOf)
            // The series ends on `day`; the night that ended that morning is its last value.
            vitals.append(Vital(kind: kind, value: series.last?.value, history: series.dropLast().compactMap(\.value)))
        }
        let periods = try await source.sleepPeriods(in: DateInterval(start: day.addingTimeInterval(-12 * 3600),
                                                                     end: calendar.date(byAdding: .day, value: 2, to: day)!))
        let suggestions = [
            illness(vitals, alcoholDayBefore: alcoholDayBefore),
            nap(periods, day: day, calendar: calendar),
            meditation(try await source.time(in: .mindfulness, on: day)),
            outdoorTime(try await source.time(in: .daylight, on: day)),
        ]
        return suggestions.compactMap { $0 }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
