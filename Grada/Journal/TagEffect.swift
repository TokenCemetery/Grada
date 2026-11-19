import Foundation

/// How a journal tag changes the night after: the nights after days with the tag against nights after days
/// without it, from the user's own data (#103).
///
/// A difference counts only when it's more than twice its standard error (Welch), so a 95% interval for it
/// leaves out zero. With night-to-night HRV varying 10–20%, a few nights can't separate a one-drink effect,
/// and this keeps such noise from reading as an effect.
nonisolated struct TagEffect: Equatable {
    enum Metric: CaseIterable {
        case hrv, sleepingHeartRate, sleep, rem, deep, awake

        var title: String {
            switch self {
            case .hrv: String(localized: "HRV")
            case .sleepingHeartRate: String(localized: "Sleeping HR")
            case .sleep: String(localized: "Sleep")
            case .rem: String(localized: "REM")
            case .deep: String(localized: "Deep sleep")
            case .awake: String(localized: "Awake", comment: "Sleep stage: time awake during the night")
            }
        }
    }

    enum Change: Equatable {
        /// Fewer than `minimumNights` nights on a side.
        case notEnough
        /// Within what the nights' own spread explains.
        case withinVariation
        /// Nights with the tag minus nights without, in the metric's units.
        case changed(Double)
    }

    struct Row: Equatable {
        let metric: Metric
        /// Nil with fewer than `minimumNights` nights.
        let with: Double?
        let without: Double?
        let nightsWith: Int
        let nightsWithout: Int
        let change: Change
    }

    /// The tags Grada compares and the outcomes the evidence links them to: alcohol lowers HRV and raises heart
    /// rate in a dose-dependent way (Pietilä et al. 2018, JMIR Ment Health 5:e23); caffeine's evidence is on sleep
    /// (Gardiner et al. 2023, Sleep Med Rev 69:101764), so only its sleep outcomes are shown.
    static let compared: [(tag: JournalTag, metrics: [Metric])] = [
        (.alcohol, [.hrv, .sleepingHeartRate, .sleep, .rem]),
        (.caffeine, [.sleep, .deep, .awake]),
    ]
    /// Nights after these days are left out of every comparison: they'd skew both sides.
    static let excluding: Set<JournalTag> = [.illness, .nightShift]
    /// Nights each side needs before a difference is shown; no study sets one, so 5 is Grada's estimate.
    static let minimumNights = 5
    /// Days looked back over: long enough to collect tagged nights, short enough to reflect current habits.
    static let windowDays = 90

    /// One metric's row from its values on the nights with and without the tag.
    static func row(_ metric: Metric, with tagged: [Double], without untagged: [Double]) -> Row {
        let enough = tagged.count >= minimumNights && untagged.count >= minimumNights
        let with = enough ? Baseline.average(tagged) : nil
        let without = enough ? Baseline.average(untagged) : nil
        guard let with, let without,
              let taggedSD = MonthSummary.standardDeviation(tagged), let untaggedSD = MonthSummary.standardDeviation(untagged)
        else {
            return Row(metric: metric, with: with, without: without, nightsWith: tagged.count, nightsWithout: untagged.count,
                       change: .notEnough)
        }
        let difference = with - without
        let standardError = (taggedSD * taggedSD / Double(tagged.count) + untaggedSD * untaggedSD / Double(untagged.count)).squareRoot()
        return Row(metric: metric, with: with, without: without, nightsWith: tagged.count, nightsWithout: untagged.count,
                   change: abs(difference) > 2 * standardError ? .changed(difference) : .withinVariation)
    }

    /// Each compared tag's rows. `logged` holds each day key's tags; `nights` holds each night's values by the
    /// day it ended. A tag on day D pairs with the night ending on D + 1.
    static func effects(logged: [String: Set<JournalTag>], nights: [Date: [Metric: Double]],
                        calendar: Calendar, now: Date = .now) -> [JournalTag: [Row]] {
        let today = calendar.startOfDay(for: now)
        let pairs: [(tags: Set<JournalTag>, night: [Metric: Double])] = (1...windowDays).compactMap { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let tags = logged[DayKey.make(day, calendar: calendar)] ?? []
            guard excluding.isDisjoint(with: tags), let night = nights[calendar.date(byAdding: .day, value: 1, to: day)!]
            else { return nil }
            return (tags, night)
        }
        var result: [JournalTag: [Row]] = [:]
        for (tag, metrics) in compared {
            let with = pairs.filter { $0.tags.contains(tag) }, without = pairs.filter { !$0.tags.contains(tag) }
            result[tag] = metrics.map { metric in
                row(metric, with: with.compactMap { $0.night[metric] }, without: without.compactMap { $0.night[metric] })
            }
        }
        return result
    }

    /// One line for under the tag: the changes beyond the usual variation, or what's still missing.
    static func caption(_ rows: [Row]) -> String {
        guard rows.contains(where: { $0.change != .notEnough }) else {
            let logged = rows.map(\.nightsWith).max() ?? 0
            return logged < minimumNights ? String(localized: "Night after: \(logged) of \(minimumNights) days logged")
                : String(localized: "Night after: needs more nights to compare")
        }
        let changes = rows.compactMap { row -> String? in
            guard case .changed(let difference) = row.change else { return nil }
            let size = switch row.metric {
            case .hrv: String(localized: "\(Int(abs(difference).rounded())) ms")
            case .sleepingHeartRate: String(localized: "\(Int(abs(difference).rounded())) bpm")
            case .sleep, .rem, .deep, .awake: SnapshotBuilder.hoursMinutes(abs(difference))
            }
            return "\(row.metric.title) \(difference > 0 ? "↑" : "↓") \(size)"
        }
        return changes.isEmpty ? String(localized: "Night after: no clear change")
            : String(localized: "Night after: \(changes.joined(separator: " · "))")
    }

    /// Each night's values over the window, by the day it ended. Stages only for nights that have them.
    static func nights(source: HealthDataSource) async throws -> [Date: [Metric: Double]] {
        var result: [Date: [Metric: Double]] = [:]
        for night in try await source.overnight(days: windowDays + 1) {
            result[night.wakeDay, default: [:]][.hrv] = night.hrv
            result[night.wakeDay, default: [:]][.sleepingHeartRate] = night.heartRate
        }
        for night in try await source.sleepNights(days: windowDays + 1) where night.asleep > 0 {
            result[night.wakeDay, default: [:]][.sleep] = night.asleep
            guard !night.stages.isEmpty else { continue }
            result[night.wakeDay, default: [:]][.rem] = night.stages[.rem] ?? 0
            result[night.wakeDay, default: [:]][.deep] = night.stages[.deep] ?? 0
            result[night.wakeDay, default: [:]][.awake] = night.stages[.awake] ?? 0
        }
        return result
    }
}
