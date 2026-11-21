import Foundation
import HealthKit
import SwiftData
import Testing
@testable import Grada

struct CycleTests {
    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: .now) }

    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }

    private func flow(_ offset: Int, _ flow: FlowDay.Flow = .medium, start: Bool = false) -> FlowDay {
        FlowDay(day: day(offset), flow: flow, isCycleStart: start, origin: "Health")
    }

    /// A period day after a week without one starts a cycle; days within a period don't; "no flow" never counts.
    @Test func cyclesStartAfterAWeekWithoutAPeriod() {
        let logged = [flow(-40), flow(-39), flow(-37, .light), flow(-30, .none), flow(-12), flow(-11)]
        #expect(Cycle.starts(logged, calendar: calendar) == [day(-40), day(-12)])
    }

    @Test func anAppsMarkedStartCounts() {
        let logged = [flow(-20), flow(-15, start: true)]
        #expect(Cycle.starts(logged, calendar: calendar) == [day(-20), day(-15)])
    }

    @Test func cycleDayCountsFromTheLastStart() {
        let starts = [day(-40), day(-12)]
        #expect(Cycle.day(day(-12), starts: starts, calendar: calendar) == 1)
        #expect(Cycle.day(day(0), starts: starts, calendar: calendar) == 13)
        #expect(Cycle.day(day(-13), starts: starts, calendar: calendar) == 28)
        #expect(Cycle.day(day(-41), starts: starts, calendar: calendar) == nil, "Before any start")
        #expect(Cycle.day(day(-1), starts: [day(-90)], calendar: calendar) == 90)
        #expect(Cycle.day(day(0), starts: [day(-90)], calendar: calendar) == nil, "Past the longest cycle shown")
    }

    @Test func journalShowsTheCycleDayOnlyForFemale() async {
        let female = CycleSource(sex: .female, flow: [flow(-5), flow(-4)])
        #expect(await Cycle.day(on: day(0), source: female, calendar: calendar) == 6)
        #expect(await Cycle.day(on: day(-5), source: female, calendar: calendar) == 1)
        let male = CycleSource(sex: .male, flow: [flow(-5)])
        #expect(await Cycle.day(on: day(0), source: male, calendar: calendar) == nil)
    }

    @Test func pastDayLeavesOutLaterPeriods() async throws {
        let base = CycleSource(sex: .female, flow: [flow(-30), flow(-2)])
        let past = PastDaySource(base: base, daysAgo: 5, dayEnd: day(-4))
        #expect(try await past.menstrualFlow(days: 60).map(\.day) == [day(-30)])
    }

    /// Read live from the first source with any record, and never from the store.
    @MainActor
    @Test func storedDataReadsFlowLiveFromTheFirstSourceWithAny() async throws {
        let container = try ModelContainer(for: DaySummary.self, WorkoutRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let data = StoredHealthData(container: container, sources: [FlowSource(id: "none", flow: nil),
                                                                    FlowSource(id: "health", flow: [flow(-3)]),
                                                                    FlowSource(id: "other", flow: [flow(-1)])])
        #expect(try await data.menstrualFlow(days: 10).map(\.day) == [day(-3)])
    }

    @MainActor
    @Test func calendarShowsCycleOnlyForFemale() async {
        let female = CalendarModel(source: CycleSource(sex: .female, flow: [flow(-20, .heavy), flow(-19, .light)]))
        await female.load(.cycle, goals: GoalHistory())
        #expect(female.showsCycle)
        #expect(female.flowDays[day(-20)]?.flow == .heavy)
        #expect(female.cycleDays[day(-19)] == 2)
        #expect(female.cycleDays[day(0)] == 21)
        #expect(!female.wristTemperature.isEmpty, "Overlays sleeping wrist temperature")

        let male = CalendarModel(source: CycleSource(sex: .male, flow: [flow(-20)]))
        await male.load(.cycle, goals: GoalHistory())
        #expect(!male.showsCycle)
        #expect(male.flowDays.isEmpty && male.cycleDays.isEmpty, "Nothing read without Female")
    }

    /// A day's flow is its heaviest sample, named by the app that logged it; any sample can mark the start.
    @Test func mergeKeepsTheHeaviestFlowAndItsApp() {
        let merged = FlowDay.merge(day: day(0), samples: [(2, false, "Clue"), (4, false, "Health"), (5, true, "Flo"), (99, false, "Odd")])
        #expect(merged == FlowDay(day: day(0), flow: .heavy, isCycleStart: true, origin: "Health"))
        #expect(FlowDay.merge(day: day(0), samples: [(99, true, "Odd")]) == nil)
        #expect(FlowDay.merge(day: day(0), samples: [(5, false, "Flo")])?.flow == FlowDay.Flow.none)
    }

    /// The "log your period" note is only for no period at all, not for months that just have none.
    @MainActor
    @Test func calendarKnowsWhetherAnyPeriodIsLogged() async {
        let old = CalendarModel(source: CycleSource(sex: .female, flow: [flow(-1500)]))
        #expect(old.loadedMetric == nil)
        await old.load(.cycle, goals: GoalHistory())
        #expect(old.loadedMetric == .cycle)
        #expect(old.flowDays.isEmpty)
        #expect(old.hasPeriods, "A period years ago still counts")

        let noneOnly = CalendarModel(source: CycleSource(sex: .female, flow: [flow(-3, .none)]))
        await noneOnly.load(.cycle, goals: GoalHistory())
        #expect(!noneOnly.hasPeriods, "Logging no flow isn't a period")
    }

    /// A window starting mid-period counts the cycle from its start before the window.
    @MainActor
    @Test func cycleDayCountsFromAStartBeforeTheShownMonths() async {
        // Six months load, and without an earliest day the source has a year of history.
        let firstShown = calendar.date(byAdding: .month, value: -5, to: calendar.dateInterval(of: .month, for: today)!.start)!
        let start = calendar.date(byAdding: .day, value: -3, to: firstShown)!
        let periodStart = FlowDay(day: start, flow: .medium, isCycleStart: false, origin: "Health")
        let model = CalendarModel(source: CycleSource(sex: .female, flow: [periodStart]))
        await model.load(.cycle, goals: GoalHistory())
        #expect(model.flowDays[start] == nil, "Before the shown months")
        #expect(model.cycleDays[firstShown] == 4)
    }

    private func sign(_ offset: Int, _ kind: CycleSign.Kind) -> CycleSign {
        CycleSign(day: day(offset), kind: kind, origin: "Natural Cycles")
    }

    /// Nine nights from `offset`: six low, then three above all of them.
    private func rise(from offset: Int) -> [(day: Date, value: Double)] {
        [36.2, 36.4, 36.3, 36.25, 36.35, 36.3, 36.5, 36.6, 36.65].enumerated().map { (day(offset + $0), $1) }
    }

    /// Mean ± sample SD of the complete cycles, counted from the last start (Bull et al. 2019: a range, not a date).
    @Test func nextPeriodIsAMeanPlusMinusSDRange() throws {
        let starts = [day(-87), day(-59), day(-29), day(0)] // 28, 30, 29 days: mean 29, SD 1
        let prediction = try #require(Cycle.prediction(starts: starts, today: today, calendar: calendar))
        #expect(prediction.earliest == day(28) && prediction.latest == day(30))
        #expect(Cycle.prediction(starts: Array(starts.dropFirst()), today: today, calendar: calendar) == nil, "Two cycles")
        // A 200-day gap hides an unlogged period and doesn't count.
        #expect(Cycle.lengths([day(-400), day(-200), day(-170)], calendar: calendar) == [30])
        // The range has passed: no prediction.
        #expect(Cycle.prediction(starts: starts.dropLast().map { calendar.date(byAdding: .day, value: -40, to: $0)! },
                                 today: today, calendar: calendar) == nil)
    }

    @Test func rangeUsesOnlyTheLastTwelveCycles() throws {
        // Twelve 30-day cycles after one 20-day cycle: the 20 is dropped, so the range is a single day.
        var starts = [day(-380), day(-360)]
        for _ in 0..<12 { starts.append(calendar.date(byAdding: .day, value: 30, to: starts.last!)!) }
        let prediction = try #require(Cycle.prediction(starts: starts, today: day(-1), calendar: calendar))
        #expect(prediction.earliest == prediction.latest)
    }

    /// Marshall 1968: three nights in a row above all six before them; ovulation goes on the last low night.
    @Test func threeOverSixMarksTheLastLowNight() {
        #expect(Cycle.temperatureShift(rise(from: -20), calendar: calendar) == day(-15))
        var flat = rise(from: -20)
        flat[7].value = 36.3
        #expect(Cycle.temperatureShift(flat, calendar: calendar) == nil, "Not above all six")
        var gap = rise(from: -20)
        gap.remove(at: 3)
        #expect(Cycle.temperatureShift(gap, calendar: calendar) == nil, "Nights must be consecutive")
        let noise = [36.30, 36.31, 36.30, 36.32, 36.31, 36.30, 36.33, 36.34, 36.35].enumerated().map { (day: day(-20 + $0), value: $1) }
        #expect(Cycle.temperatureShift(noise, calendar: calendar) == nil, "A few hundredths of a degree isn't a rise")
    }

    @Test func ovulationNeedsEvidenceAndPrefersAnLHTest() {
        let starts = [day(-60), day(-30)]
        let wrist = Dictionary(rise(from: -25).map { ($0.day, $0.value) }) { a, _ in a }
        let basal = rise(from: -55).map { CycleSign(day: $0.day, kind: .basalTemperature($0.value), origin: "Clue") }
        let signs = basal + [sign(-20, .ovulationTest(.luteinizingHormoneSurge)), sign(-19, .ovulationTest(.luteinizingHormoneSurge)),
                             sign(-50, .cervicalMucus(.eggWhite)), sign(-5, .cervicalMucus(.eggWhite)),
                             sign(-4, .ovulationTest(.negative))]
        let ovulations = Cycle.ovulations(starts: starts, signs: signs, wristTemperature: wrist, calendar: calendar)
        #expect(ovulations == [
            Cycle.Ovulation(days: [day(-50)], evidence: .temperatureRise(basal: true), origin: "Clue"),
            Cycle.Ovulation(days: [day(-19), day(-18)], evidence: .lhTest, origin: "Natural Cycles"),
        ], "Mucus and negative tests alone mark nothing")
        let wristOnly = Cycle.ovulations(starts: starts, signs: [], wristTemperature: wrist, wristOrigin: "Apple Watch", calendar: calendar)
        #expect(wristOnly == [Cycle.Ovulation(days: [day(-20)], evidence: .temperatureRise(basal: false), origin: "Apple Watch")])
        #expect(Cycle.ovulations(starts: starts, signs: [sign(-10, .cervicalMucus(.eggWhite))], wristTemperature: [:],
                                 calendar: calendar).isEmpty)
    }

    /// Raw values match Apple Health's.
    @Test func signValuesMatchHealthKit() {
        #expect(CycleSign.OvulationTest(rawValue: HKCategoryValueOvulationTestResult.luteinizingHormoneSurge.rawValue) == .luteinizingHormoneSurge)
        #expect(CycleSign.OvulationTest(rawValue: HKCategoryValueOvulationTestResult.estrogenSurge.rawValue) == .estrogenSurge)
        #expect(CycleSign.CervicalMucus(rawValue: HKCategoryValueCervicalMucusQuality.eggWhite.rawValue) == .eggWhite)
        #expect(CycleSign.CervicalMucus(rawValue: HKCategoryValueCervicalMucusQuality.dry.rawValue) == .dry)
    }

    @MainActor
    @Test func signsReadLiveAndStopAtThePastDay() async throws {
        let container = try ModelContainer(for: DaySummary.self, WorkoutRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let data = StoredHealthData(container: container, sources: [FlowSource(id: "none", flow: nil),
                                                                    FlowSource(id: "health", flow: [flow(-3)])])
        #expect(try await data.cycleSigns(days: 10).map(\.origin) == ["health"])
        let base = CycleSource(sex: .female, flow: [], signs: [sign(-30, .cervicalMucus(.dry)), sign(-2, .cervicalMucus(.dry))])
        let past = PastDaySource(base: base, daysAgo: 5, dayEnd: day(-4))
        #expect(try await past.cycleSigns(days: 60).map(\.day) == [day(-30)])
    }

    @MainActor
    @Test func calendarShowsPredictionAndEvidence() async {
        let logged = [flow(-87), flow(-59), flow(-29), flow(0)]
        let model = CalendarModel(source: CycleSource(sex: .female, flow: logged,
                                                      signs: [sign(-15, .ovulationTest(.luteinizingHormoneSurge)),
                                                              sign(-15, .cervicalMucus(.eggWhite))]))
        await model.load(.cycle, goals: GoalHistory())
        #expect(model.completeCycles == 3)
        #expect(model.prediction == Cycle.Prediction(earliest: day(28), latest: day(30)))
        #expect(model.ovulationDays[day(-14)]?.evidence == .lhTest)
        #expect(model.ovulationDays[day(-13)] != nil)
        #expect(model.signs[day(-15)]?.count == 2)

        let few = CalendarModel(source: CycleSource(sex: .female, flow: [flow(-29), flow(0)]))
        await few.load(.cycle, goals: GoalHistory())
        #expect(few.prediction == nil && few.completeCycles == 1)
    }

    /// Ovulation after a positive test yesterday shows today, never tomorrow.
    @MainActor
    @Test func ovulationIsNeverMarkedAhead() async {
        let model = CalendarModel(source: CycleSource(sex: .female, flow: [flow(-10)],
                                                      signs: [sign(-1, .ovulationTest(.luteinizingHormoneSurge))]))
        await model.load(.cycle, goals: GoalHistory())
        #expect(model.ovulationDays[day(0)] != nil)
        #expect(model.ovulationDays[day(1)] == nil)
    }

    /// A period running into the oldest day read may have started earlier, so it doesn't start a counted cycle.
    @MainActor
    @Test func aPeriodCutOffByTheReadWindowIsntAStart() async {
        let oldest = 1 - Cycle.predictionDays
        let logged = [flow(oldest + 2), flow(oldest + 32), flow(oldest + 62), flow(oldest + 92)]
        let model = CalendarModel(source: CycleSource(sex: .female, flow: logged))
        await model.load(.cycle, goals: GoalHistory())
        #expect(model.completeCycles == 2)
        let marked = CalendarModel(source: CycleSource(sex: .female, flow: [flow(oldest + 2, start: true)] + logged.dropFirst()))
        await marked.load(.cycle, goals: GoalHistory())
        #expect(marked.completeCycles == 3, "An app's own start mark counts")
    }

    @Test func flowOrdersByAmount() {
        #expect(FlowDay.Flow.heavy > .light)
        #expect(FlowDay.Flow.unspecified > .none)
        #expect(!FlowDay.Flow.none.isBleeding)
        #expect(CalendarMetric(rawValue: "cycle") == .cycle)
        #expect(!CalendarMetric.cycle.isRated)
    }
}

/// Sample data with a set sex, logged flow and signs.
private struct CycleSource: HealthDataSource {
    let sex: BiologicalSex
    let flow: [FlowDay]
    var signs: [CycleSign] = []
    let base = SampleDataSource()
    func cycleSigns(days: Int) async throws -> [CycleSign] {
        let calendar = Calendar.current
        let first = calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: .now))!
        return signs.filter { $0.day >= first }
    }
    func biologicalSex() async throws -> BiologicalSex? { sex }
    func menstrualFlow(days: Int) async throws -> [FlowDay] {
        let calendar = Calendar.current
        let first = calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: .now))!
        return flow.filter { $0.day >= first }
    }
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] { try await base.daily(metric, days: days) }
    func sleepNights(days: Int) async throws -> [SleepNight] { try await base.sleepNights(days: days) }
    func standHours(days: Int) async throws -> [DayValue] { try await base.standHours(days: days) }
    func overnight(days: Int) async throws -> [OvernightVitals] { try await base.overnight(days: days) }
    func workouts(days: Int) async throws -> [WorkoutSummary] { try await base.workouts(days: days) }
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] { try await base.heartRate(in: interval) }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { try await base.sleepPeriods(in: interval) }
    func age() async throws -> Int? { 30 }
    func highestHeartRate(days: Int) async throws -> Double? { nil }
}

/// A live source with a set answer for menstrual flow.
private final class FlowSource: LiveHealthSource {
    let id: String
    let flow: [FlowDay]?
    init(id: String, flow: [FlowDay]?) { (self.id, self.flow) = (id, flow) }
    func menstrualFlow(during interval: DateInterval) async throws -> [FlowDay]? { flow }
    func cycleSigns(during interval: DateInterval) async throws -> [CycleSign]? { flow.map { $0.map { CycleSign(day: $0.day, kind: .cervicalMucus(.creamy), origin: id) } } }
}
