import Foundation

/// A day of menstrual flow logged in Apple Health by Cycle Tracking, Clue, Flo or another app (#137). Grada only
/// reads it, never stores it.
nonisolated struct FlowDay: Equatable {
    /// Apple Health's flow values; raw values match `HKCategoryValueVaginalBleeding`.
    enum Flow: Int, Comparable {
        case unspecified = 1, light, medium, heavy, none

        /// A period day; "none" is logged to say there was no flow.
        var isBleeding: Bool { self != .none }

        static func < (lhs: Flow, rhs: Flow) -> Bool { lhs.weight < rhs.weight }

        /// None, then unspecified, light, medium and heavy.
        private var weight: Int { self == .none ? 0 : rawValue }

        var title: String {
            switch self {
            case .unspecified: String(localized: "cycle.period", defaultValue: "Period", comment: "Menstrual period, logged without an amount of flow")
            case .light: String(localized: "Light flow")
            case .medium: String(localized: "Medium flow")
            case .heavy: String(localized: "Heavy flow")
            case .none: String(localized: "No flow")
            }
        }
    }

    let day: Date
    /// The heaviest flow logged that day.
    let flow: Flow
    /// The logging app marked this day as the start of a cycle.
    let isCycleStart: Bool
    /// The app that logged the heaviest flow, e.g. "Health".
    let origin: String?

    /// One day from all its logged samples (raw flow value, start mark, app): the heaviest flow and the app that
    /// logged it, a start if any sample says so. Nil without a known flow value.
    static func merge(day: Date, samples: [(value: Int, isStart: Bool, origin: String?)]) -> FlowDay? {
        let known = samples.compactMap { sample in Flow(rawValue: sample.value).map { (flow: $0, origin: sample.origin) } }
        guard let heaviest = known.max(by: { $0.flow < $1.flow }) else { return nil }
        return FlowDay(day: day, flow: heaviest.flow, isCycleStart: samples.contains(where: \.isStart), origin: heaviest.origin)
    }
}

/// Cycle days from logged periods: a cycle starts on a day the logging app marks as a start, or on a period day
/// with no period day in the `gapDays` before it. Cycle day 1 is the start. Nothing here predicts or estimates.
nonisolated enum Cycle {
    /// Period days closer together than this belong to one period. Grada's choice: a week covers spotting and
    /// gaps in logging within a period, and is far shorter than any cycle.
    static let gapDays = 7
    /// Past this many days since the last start, the cycle day isn't shown: a period probably wasn't logged.
    /// Grada's choice.
    static let maximumCycleDay = 90
    /// Days read before the first shown day, so its cycle day can count from an earlier start.
    static let lookbackDays = maximumCycleDay
    /// How far back a period anywhere counts as having cycle data, before telling the user to log one.
    static let historyDays = 3650

    /// Start days, oldest first.
    static func starts(_ days: [FlowDay], calendar: Calendar) -> [Date] {
        var starts: [Date] = []
        var lastBleeding: Date?
        for day in days.sorted(by: { $0.day < $1.day }) where day.flow.isBleeding {
            let gap = lastBleeding.map { calendar.dateComponents([.day], from: $0, to: day.day).day! }
            if day.isCycleStart || gap.map({ $0 > gapDays }) ?? true {
                starts.append(day.day)
            }
            lastBleeding = day.day
        }
        return starts
    }

    /// The cycle day of `day`, counting the last start on or before it as day 1; nil without one in
    /// `maximumCycleDay` days.
    static func day(_ day: Date, starts: [Date], calendar: Calendar) -> Int? {
        guard let start = starts.last(where: { $0 <= day }) else { return nil }
        let number = calendar.dateComponents([.day], from: start, to: day).day! + 1
        return number <= maximumCycleDay ? number : nil
    }

    /// Whether cycle features show at all: only with Female as the profile's sex.
    static func isShown(source: HealthDataSource) async -> Bool {
        (try? await source.biologicalSex()) == .female
    }

    /// The cycle day of `day` from the logged periods, for Journal; nil unless cycle features show.
    static func day(on day: Date, source: HealthDataSource, calendar: Calendar) async -> Int? {
        guard await isShown(source: source) else { return nil }
        let today = calendar.startOfDay(for: .now)
        let back = (calendar.dateComponents([.day], from: day, to: today).day ?? 0) + lookbackDays
        guard let flow = try? await source.menstrualFlow(days: back + 1) else { return nil }
        return Cycle.day(day, starts: starts(flow.filter { $0.day <= day }, calendar: calendar), calendar: calendar)
    }
}
