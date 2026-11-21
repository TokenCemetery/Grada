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
/// with no period day in the `gapDays` before it. Cycle day 1 is the start.
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

/// A fertility sign logged in Apple Health (#138): a basal body temperature, an ovulation test or cervical mucus.
/// Grada only reads it, never stores it.
nonisolated struct CycleSign: Equatable {
    /// Raw values match `HKCategoryValueOvulationTestResult`.
    enum OvulationTest: Int {
        case negative = 1, luteinizingHormoneSurge, indeterminate, estrogenSurge

        var title: String {
            switch self {
            case .negative: String(localized: "ovulationTest.negative", defaultValue: "Negative", comment: "Ovulation test result")
            case .luteinizingHormoneSurge: String(localized: "ovulationTest.lhSurge", defaultValue: "LH surge", comment: "Ovulation test result: luteinizing hormone surge, i.e. positive")
            case .indeterminate: String(localized: "ovulationTest.indeterminate", defaultValue: "Indeterminate", comment: "Ovulation test result")
            case .estrogenSurge: String(localized: "ovulationTest.estrogenSurge", defaultValue: "Estrogen surge", comment: "Ovulation test result")
            }
        }
    }

    /// Raw values match `HKCategoryValueCervicalMucusQuality`.
    enum CervicalMucus: Int {
        case dry = 1, sticky, creamy, watery, eggWhite

        var title: String {
            switch self {
            case .dry: String(localized: "mucus.dry", defaultValue: "Dry", comment: "Cervical mucus quality")
            case .sticky: String(localized: "mucus.sticky", defaultValue: "Sticky", comment: "Cervical mucus quality")
            case .creamy: String(localized: "mucus.creamy", defaultValue: "Creamy", comment: "Cervical mucus quality")
            case .watery: String(localized: "mucus.watery", defaultValue: "Watery", comment: "Cervical mucus quality")
            case .eggWhite: String(localized: "mucus.eggWhite", defaultValue: "Egg white", comment: "Cervical mucus quality")
            }
        }
    }

    enum Kind: Equatable {
        /// In °C.
        case basalTemperature(Double)
        case ovulationTest(OvulationTest)
        case cervicalMucus(CervicalMucus)
    }

    let day: Date
    let kind: Kind
    /// The app that logged it, e.g. "Health".
    let origin: String?
}

nonisolated extension Cycle {
    /// Complete cycles a next-period range needs. Grada's choice: fewer give no usable spread.
    static let minimumCycles = 3
    /// The most recent complete cycles the range averages.
    static let predictionCycles = 12
    /// Days of logged periods read for the range: enough for `predictionCycles` cycles of up to 45 days.
    static let predictionDays = 560

    /// The lengths of complete cycles, oldest first: days from each start to the next. A cycle longer than
    /// `maximumCycleDay` days probably hides an unlogged period, so it's left out.
    static func lengths(_ starts: [Date], calendar: Calendar) -> [Int] {
        zip(starts, starts.dropFirst())
            .map { calendar.dateComponents([.day], from: $0, to: $1).day! }
            .filter { $0 <= maximumCycleDay }
    }

    /// When the next period is likely to start: from the last start, the mean of the last `predictionCycles`
    /// complete cycle lengths ± their sample standard deviation. Nil with fewer than `minimumCycles` cycles, or once
    /// the whole range has passed.
    struct Prediction: Equatable {
        let earliest: Date
        let latest: Date

        func contains(_ day: Date) -> Bool { earliest <= day && day <= latest }
    }

    static func prediction(starts: [Date], today: Date, calendar: Calendar) -> Prediction? {
        let lengths = lengths(starts, calendar: calendar).suffix(predictionCycles).map(Double.init)
        guard lengths.count >= minimumCycles, let last = starts.last else { return nil }
        let mean = lengths.reduce(0, +) / Double(lengths.count)
        let sd = (lengths.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lengths.count - 1)).squareRoot()
        let earliest = calendar.date(byAdding: .day, value: Int((mean - sd).rounded()), to: last)!
        let latest = calendar.date(byAdding: .day, value: Int((mean + sd).rounded()), to: last)!
        return latest >= today ? Prediction(earliest: earliest, latest: latest) : nil
    }

    /// Ovulation supported by logged evidence, never counted back from a period.
    struct Ovulation: Equatable {
        enum Evidence: Equatable {
            /// A positive (luteinizing-hormone surge) ovulation test the day before the first marked day.
            case lhTest
            /// A sustained rise by the three-over-six rule in basal body or sleeping wrist temperature.
            case temperatureRise(basal: Bool)

            var title: String {
                switch self {
                case .lhTest: String(localized: "Positive LH test")
                case .temperatureRise(basal: true): String(localized: "Basal body temperature rise")
                case .temperatureRise(basal: false): String(localized: "Wrist temperature rise")
                }
            }
        }

        /// The days ovulation is likely on: the 1–2 days after a positive test, or the night before a rise.
        let days: [Date]
        let evidence: Evidence
        /// The app that logged the test or temperatures.
        let origin: String?
    }

    /// Nights of a sustained rise: three in a row each above all of the six nights before them (Marshall's
    /// three-over-six rule), the third at least `riseMargin` °C above them. The margin is Grada's choice, so day-to-day
    /// noise of a few hundredths of a degree doesn't count as a rise.
    static let lowNights = 6
    static let highNights = 3
    static let riseMargin = 0.2

    /// The last low night before the first three-over-six rise in `nights`, which must be consecutive days.
    static func temperatureShift(_ nights: [(day: Date, value: Double)], calendar: Calendar) -> Date? {
        let nights = nights.sorted { $0.day < $1.day }
        let span = lowNights + highNights
        guard nights.count >= span else { return nil }
        for end in span...nights.count {
            let window = nights[(end - span)..<end]
            let first = window.first!.day, last = window.last!.day
            guard calendar.dateComponents([.day], from: first, to: last).day == span - 1 else { continue }
            let low = window.prefix(lowNights).map(\.value).max()!
            if window.suffix(highNights).allSatisfy({ $0.value > low }), window.last!.value >= low + riseMargin {
                return window[window.startIndex + lowNights - 1].day
            }
        }
        return nil
    }

    /// Ovulation in each cycle with evidence, first positive LH test first, then a basal body temperature rise, then a
    /// sleeping wrist temperature rise. Cervical mucus never counts on its own.
    static func ovulations(starts: [Date], signs: [CycleSign], wristTemperature: [Date: Double], wristOrigin: String? = nil,
                           calendar: Calendar) -> [Ovulation] {
        // Each cycle runs from a start to the day before the next; days before the first start make one too.
        func cycle(of day: Date) -> Int { starts.lastIndex { $0 <= day }.map { $0 + 1 } ?? 0 }
        let basal = signs.compactMap { sign -> (day: Date, value: Double, origin: String?)? in
            if case .basalTemperature(let value) = sign.kind { (sign.day, value, sign.origin) } else { nil }
        }
        let tests = signs.filter { $0.kind == .ovulationTest(.luteinizingHormoneSurge) }.sorted { $0.day < $1.day }
        let wrist = wristTemperature.map { (day: $0.key, value: $0.value) }
        let cycles = Set(basal.map { cycle(of: $0.day) } + tests.map { cycle(of: $0.day) } + wrist.map { cycle(of: $0.day) })
        return cycles.sorted().compactMap { index in
            if let test = tests.first(where: { cycle(of: $0.day) == index }) {
                let days = (1...2).map { calendar.date(byAdding: .day, value: $0, to: test.day)! }
                return Ovulation(days: days, evidence: .lhTest, origin: test.origin)
            }
            let ofCycle = basal.filter { cycle(of: $0.day) == index }
            if let day = temperatureShift(ofCycle.map { ($0.day, $0.value) }, calendar: calendar) {
                return Ovulation(days: [day], evidence: .temperatureRise(basal: true),
                                 origin: ofCycle.first { $0.day == day }?.origin)
            }
            if let day = temperatureShift(wrist.filter { cycle(of: $0.day) == index }, calendar: calendar) {
                return Ovulation(days: [day], evidence: .temperatureRise(basal: false), origin: wristOrigin)
            }
            return nil
        }
    }
}
