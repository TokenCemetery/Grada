import Foundation
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

    @Test func flowOrdersByAmount() {
        #expect(FlowDay.Flow.heavy > .light)
        #expect(FlowDay.Flow.unspecified > .none)
        #expect(!FlowDay.Flow.none.isBleeding)
        #expect(CalendarMetric(rawValue: "cycle") == .cycle)
        #expect(!CalendarMetric.cycle.isRated)
    }
}

/// Sample data with a set sex and logged flow.
private struct CycleSource: HealthDataSource {
    let sex: BiologicalSex
    let flow: [FlowDay]
    let base = SampleDataSource()
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
}
