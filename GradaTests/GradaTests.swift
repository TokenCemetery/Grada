import Foundation
import SwiftData
import Testing
@testable import Grada

@MainActor
struct HomeLayoutTests {
    @Test func squaresPairUpAndWideCardsFillARow() {
        let rows = HomeLayout.rows(for: [.sleepStages, .restingHeartRate, .hrv, .steps, .lastWorkout, .activeEnergy])
        #expect(rows == [[.sleepStages], [.restingHeartRate, .hrv], [.steps], [.lastWorkout], [.activeEnergy]])
    }

    @Test func defaultSetLayout() {
        let rows = HomeLayout.rows(for: CardKind.defaultSet)
        #expect(rows == [[.sleepStages], [.restingHeartRate, .hrv], [.steps, .activeEnergy], [.lastWorkout], [.last30Days]])
    }
}

@MainActor
struct BaselineTests {
    @Test func calibratingUntilSevenDays() {
        #expect(Baseline.normalRange(history: [50, 52, 51, 49, 50, 51], minimumHalfWidth: 1) == nil)
    }

    @Test func rangeIsMeanPlusMinusTwoStandardDeviations() throws {
        let range = try #require(Baseline.normalRange(history: [48, 50, 52, 48, 50, 52, 50], minimumHalfWidth: 0))
        // Mean 50, sample SD ≈ 1.633.
        #expect(abs(range.lowerBound - 46.73) < 0.01)
        #expect(abs(range.upperBound - 53.27) < 0.01)
    }

    @Test func rangeNeverNarrowerThanMinimum() throws {
        let range = try #require(Baseline.normalRange(history: Array(repeating: 54, count: 10), minimumHalfWidth: 3))
        #expect(range == 51...57)
    }
}

@MainActor
struct SnapshotBuilderTests {
    @Test func durationFormatting() {
        #expect(SnapshotBuilder.hoursMinutes(7 * 3600 + 42 * 60) == "7h 42m")
        #expect(SnapshotBuilder.hoursMinutes(45 * 60) == "45m")
        #expect(SnapshotBuilder.signedMinutes(18 * 60) == "+18m")
        #expect(SnapshotBuilder.signedMinutes(-75 * 60) == "−1h 15m")
    }

    @Test func everyCardBuildsFromSampleData() async throws {
        let builder = SnapshotBuilder(source: SampleDataSource())
        for kind in CardKind.allCases where !kind.isPlanned {
            let snapshot = try await builder.snapshot(for: kind)
            #expect(snapshot.value != nil, "\(kind) has no value")
        }
    }
}

@MainActor
struct HealthImporterTests {
    private let calendar = Calendar.current
    private let context: ModelContext
    private let importer: HealthImporter

    init() throws {
        let container = try ModelContainer(
            for: HomeCard.self, DaySummary.self, WorkoutRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        importer = HealthImporter(reader: HealthKitReader(), context: context)
    }

    private var today: Date { calendar.startOfDay(for: .now) }
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }

    private func batch(steps: [Double?], workouts: [WorkoutSummary] = []) -> HealthBatch {
        let days = DateInterval(start: day(-(steps.count - 1)), end: day(1))
        var batch = HealthBatch(days: days)
        batch.daily[.steps] = steps.enumerated().map { DayValue(day: day($0.offset - (steps.count - 1)), value: $0.element) }
        batch.workouts = workouts
        return batch
    }

    private func workout(_ id: String) -> WorkoutSummary {
        WorkoutSummary(id: id, start: day(0).addingTimeInterval(3600), duration: 1800, name: "Run",
                       symbol: "figure.run", energyKcal: 300, averageHeartRate: 140)
    }

    @Test func savesOnlyDaysWithDataAndUpdatesInPlace() throws {
        try importer.save(batch(steps: [nil, 4000, 5000]))
        #expect(try context.fetchCount(FetchDescriptor<DaySummary>()) == 2)

        try importer.save(batch(steps: [nil, 4000, 7000]))
        let summaries = try context.fetch(FetchDescriptor<DaySummary>(sortBy: [SortDescriptor(\.day)]))
        #expect(summaries.map(\.steps) == [4000, 7000])
    }

    @Test func removesDuplicateDays() throws {
        let key = DayKey.make(today, calendar: calendar)
        context.insert(DaySummary(day: today, dayKey: key))
        context.insert(DaySummary(day: today, dayKey: key))
        try importer.save(batch(steps: [6000]))
        #expect(try context.fetchCount(FetchDescriptor<DaySummary>()) == 1)
    }

    @Test func syncsWorkoutsWithAppleHealth() throws {
        try importer.save(batch(steps: [1000], workouts: [workout("a"), workout("b")]))
        try importer.save(batch(steps: [1000], workouts: [workout("b")]))
        let records = try context.fetch(FetchDescriptor<WorkoutRecord>())
        #expect(records.map(\.healthID) == ["b"])
    }

    @Test func storedDataFeedsCards() async throws {
        try importer.save(batch(steps: [8000, 9000]))
        let values = try await StoredHealthData(context: context).daily(.steps, days: 3)
        #expect(values.map(\.value) == [nil, 8000, 9000])
    }

    @Test func storesOvernightVitals() async throws {
        var batch = batch(steps: [8000])
        batch.overnight = [OvernightVitals(wakeDay: today, hrv: 64, heartRate: 49)]
        try importer.save(batch)
        let overnight = try await StoredHealthData(context: context).overnight(days: 2)
        #expect(overnight.map(\.hrv) == [nil, 64])
        #expect(overnight.map(\.heartRate) == [nil, 49])
    }
}

/// Sample data as it looks just after midnight: nothing recorded yet for the night ending today.
private struct BeforeWakeUpSource: HealthDataSource {
    let base = SampleDataSource()
    let today = Calendar.current.startOfDay(for: .now)

    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] {
        try await base.daily(metric, days: days).map { $0.day == today ? DayValue(day: $0.day, value: nil) : $0 }
    }
    func standHours(days: Int) async throws -> [DayValue] { try await base.standHours(days: days) }
    func overnight(days: Int) async throws -> [OvernightVitals] {
        try await base.overnight(days: days).map { $0.wakeDay == today ? OvernightVitals(wakeDay: today) : $0 }
    }
    func sleepNights(days: Int) async throws -> [SleepNight] {
        try await base.sleepNights(days: days).filter { $0.wakeDay != today }
    }
    func workouts(days: Int) async throws -> [WorkoutSummary] { try await base.workouts(days: days) }
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] { try await base.heartRate(in: interval) }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { try await base.sleepPeriods(in: interval) }
    func age() async throws -> Int? { try await base.age() }
    func highestHeartRate(days: Int) async throws -> Double? { try await base.highestHeartRate(days: days) }
}

@MainActor
struct AfterMidnightTests {
    private let builder = SnapshotBuilder(source: BeforeWakeUpSource())

    @Test func sleepShowsYesterdaysNight() async throws {
        for kind in [CardKind.sleepDuration, .sleepStages] {
            let snapshot = try await builder.snapshot(for: kind)
            #expect(snapshot.period == "Yesterday")
            #expect(snapshot.value != nil)
        }
    }

    @Test func healthStatusShowsYesterdaysVitals() async throws {
        let snapshot = try await builder.snapshot(for: .healthStatus)
        #expect(snapshot.period == "Yesterday")
        #expect(snapshot.value != nil)
    }

    @Test func todaysNightWinsOnceRecorded() async throws {
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .sleepStages)
        #expect(snapshot.period == "Last night")
    }
}

@MainActor
struct SleepChartTests {
    @Test func nightSplitsIntoStageHours() {
        let night = SleepNight(wakeDay: .now, stages: [.deep: 3600, .core: 7200, .rem: 1800, .awake: 900], unspecified: 1800)
        #expect(SleepStage.chartOrder.map { night.hours(in: $0) } == [1, 2.5, 0.5, 0.25])
    }

    @Test func sleepCardsChartSevenNights() async throws {
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .sleepStages)
        guard case .sleep(let nights) = snapshot.chart else { Issue.record("Expected a sleep chart"); return }
        #expect(nights.count == 7)
        #expect(nights.last??.stages[.deep] != nil)
    }
}

@MainActor
struct RecoveryTests {
    private let hrvHistory: [Double] = [58, 62, 60, 64, 60, 58, 62, 60, 64, 62]
    private let rhrHistory: [Double] = [54, 55, 53, 54, 55, 53, 54, 54, 55, 53]

    @Test func calibratingWithoutEnoughHistory() {
        let input = Recovery.Input(hrv: 60, hrvHistory: [60, 61], restingHeartRate: 54, restingHeartRateHistory: [54], asleep: 8 * 3600)
        #expect(Recovery.score(input) == nil)
    }

    @Test func normalNightScoresGood() throws {
        let input = Recovery.Input(hrv: 61, hrvHistory: hrvHistory, restingHeartRate: 54,
                                   restingHeartRateHistory: rhrHistory, asleep: 8 * 3600)
        let result = try #require(Recovery.score(input))
        #expect(result.score >= 67)
        #expect(result.reason == "Close to your normal")
    }

    @Test func lowHRVDragsScoreDownAndIsNamed() throws {
        let input = Recovery.Input(hrv: 48, hrvHistory: hrvHistory, restingHeartRate: 54,
                                   restingHeartRateHistory: rhrHistory, asleep: 8 * 3600)
        let result = try #require(Recovery.score(input))
        #expect(result.score < 50)
        #expect(result.reason == "HRV below normal")
    }

    @Test func shortSleepIsNamed() throws {
        let input = Recovery.Input(hrv: 61, hrvHistory: hrvHistory, restingHeartRate: 54,
                                   restingHeartRateHistory: rhrHistory, asleep: 5 * 3600)
        #expect(try #require(Recovery.score(input)).reason == "Short sleep")
    }

    @Test func raisedBreathingLowersScoreAndIsNamed() throws {
        let history: [Double] = [14.2, 14.6, 14.4, 14.8, 14.5, 14.3, 14.7, 14.5]
        let normal = Recovery.Input(hrv: 61, hrvHistory: hrvHistory, restingHeartRate: 54, restingHeartRateHistory: rhrHistory,
                                    asleep: 8 * 3600, respiratoryRate: 14.5, respiratoryRateHistory: history)
        var raised = normal
        raised.respiratoryRate = 17.5
        let normalResult = try #require(Recovery.score(normal))
        let raisedResult = try #require(Recovery.score(raised))
        #expect(raisedResult.score < normalResult.score - 10)
        #expect(raisedResult.reason == "Breathing rate up")
    }

    @Test func lowBreathingDoesNotRaiseScore() throws {
        let history: [Double] = [14.2, 14.6, 14.4, 14.8, 14.5, 14.3, 14.7, 14.5]
        let base = Recovery.Input(hrv: 61, hrvHistory: hrvHistory, restingHeartRate: 54, restingHeartRateHistory: rhrHistory,
                                  asleep: 8 * 3600)
        var low = base
        low.respiratoryRate = 12
        low.respiratoryRateHistory = history
        #expect(Recovery.score(low) == Recovery.score(base))
    }

    @Test func missingHRVUsesRestingHeartRateAlone() throws {
        let input = Recovery.Input(hrv: nil, hrvHistory: [], restingHeartRate: 50,
                                   restingHeartRateHistory: rhrHistory, asleep: nil)
        let result = try #require(Recovery.score(input))
        #expect(result.score > 65)
        #expect(result.reason == "Resting HR low")
    }
}

@MainActor
struct OvernightVitalsTests {
    @Test func usesOnlyReadingsTakenWhileAsleep() throws {
        let calendar = Calendar.current
        let wakeDay = calendar.startOfDay(for: .now)
        func at(_ hours: Double) -> Date { wakeDay.addingTimeInterval(hours * 3600) }
        let sleep = [
            SleepPeriod(start: at(-1), end: at(3), stage: .core),
            SleepPeriod(start: at(3), end: at(3.5), stage: .awake),
            SleepPeriod(start: at(3.5), end: at(7), stage: .deep),
        ]
        let hrv = [TimedValue(date: at(-3), value: 20), TimedValue(date: at(2), value: 60),
                   TimedValue(date: at(5), value: 70), TimedValue(date: at(12), value: 30)]
        let heartRate = [TimedValue(date: at(1), value: 52), TimedValue(date: at(3.2), value: 45),
                         TimedValue(date: at(5), value: 49), TimedValue(date: at(10), value: 40)]
        let nights = OvernightVitals.make(hrv: hrv, heartRate: heartRate, sleep: sleep, calendar: calendar)
        #expect(nights == [OvernightVitals(wakeDay: wakeDay, hrv: 65, heartRate: 49, bedtime: at(-1), wakeTime: at(7))])
    }

    @Test func eveningSleepCountsTowardNextMorning() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        #expect(SleepNight.wakeDay(forEnd: today.addingTimeInterval(23.5 * 3600), calendar: calendar) == tomorrow)
        #expect(SleepNight.wakeDay(forEnd: today.addingTimeInterval(7 * 3600), calendar: calendar) == today)
        #expect(SleepNight.wakeDay(forEnd: today.addingTimeInterval(14 * 3600), calendar: calendar) == today)
    }
}

@MainActor
struct ResourcesTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private func hours(_ value: Double) -> Date { start.addingTimeInterval(value * 3600) }

    private func run(_ length: Double, heartRate: Double?, sleep: [SleepPeriod] = [], workouts: [DateInterval] = [],
                     startLevel: Double = 50) -> [TimedValue] {
        let interval = DateInterval(start: start, end: hours(length))
        let samples = heartRate.map { bpm in
            stride(from: 0, to: length * 3600, by: Resources.step).map { TimedValue(date: start.addingTimeInterval($0), value: bpm) }
        } ?? []
        return Resources.timeline(interval: interval, heartRate: samples, sleep: sleep, workouts: workouts,
                                  restingHeartRate: 55, maxHeartRate: 185, startLevel: startLevel)
    }

    @Test func sleepCharges() throws {
        let night = [SleepPeriod(start: start, end: hours(8), stage: .core)]
        let level = try #require(run(8, heartRate: 50, sleep: night, startLevel: 20).last).value
        #expect(level > 70)
    }

    @Test func calmDayDrainsSlowly() throws {
        let level = try #require(run(10, heartRate: 65, startLevel: 80).last).value
        #expect(level < 80 && level > 50)
    }

    @Test func calmDaytimeRestCharges() throws {
        let level = try #require(run(2, heartRate: 56, startLevel: 50).last).value
        #expect(level > 50)
    }

    @Test func workoutDrainsMoreThanRest() throws {
        let workout = [DateInterval(start: start, duration: 3600)]
        let worked = try #require(run(1, heartRate: 150, workouts: workout, startLevel: 80).last).value
        let rested = try #require(run(1, heartRate: 60, startLevel: 80).last).value
        #expect(worked < rested - 10)
    }

    @Test func staysWithinZeroAndHundred() {
        let night = [SleepPeriod(start: start, end: hours(24), stage: .deep)]
        #expect(run(24, heartRate: 45, sleep: night, startLevel: 90).allSatisfy { $0.value <= 100 })
        let workout = [DateInterval(start: start, duration: 24 * 3600)]
        #expect(run(24, heartRate: 180, workouts: workout, startLevel: 10).allSatisfy { $0.value >= 0 })
    }

    @Test func maxHeartRateFromAgeFirst() {
        #expect(Resources.maxHeartRate(age: 40, highestRecorded: 195) == 180)
        #expect(Resources.maxHeartRate(age: nil, highestRecorded: 195) == 195)
    }
}

@MainActor
struct SleepNeedTests {
    @Test func shortNightsBuildDebtAndLongNightsRepayIt() {
        let debt = SleepNeed.debt(asleep: [6 * 3600, nil, 7 * 3600, 10 * 3600, 9 * 3600])
        // 7 h after 2 h of debt: three quarters of it remain, plus the new hour.
        #expect(debt.map { $0 / 3600 } == [2, 2, 2.5, 0, 0])
    }

    @Test func steadyShortfallSettlesInsteadOfGrowing() {
        let debt = SleepNeed.debt(asleep: Array(repeating: 7.5 * 3600, count: 60))
        #expect(abs(debt.last! - 2 * 3600) < 60)
    }

    @Test func needAddsPartOfDebtAndTraining() {
        #expect(SleepNeed.need(debt: 0, trainingTime: 0) == 8 * 3600)
        // A quarter of 2 h debt, plus 15 min for an hour of training.
        #expect(SleepNeed.need(debt: 2 * 3600, trainingTime: 3600) == 8 * 3600 + 30 * 60 + 15 * 60)
        // Both extras are capped.
        #expect(SleepNeed.need(debt: 10 * 3600, trainingTime: 6 * 3600) == 8 * 3600 + 90 * 60 + 45 * 60)
    }
}

@MainActor
struct SleepConsistencyTests {
    @Test func sameTimesEveryNightScoresFull() throws {
        let result = try #require(SleepConsistency.score(bedtimes: [1380, 1380, 1380], wakeTimes: [420, 420, 420]))
        #expect(result.score == 100)
    }

    @Test func bedtimesAcrossMidnightAreNotFarApart() throws {
        // 23:30, 00:30, 23:30, 00:30: half an hour either side, not 23 hours.
        let result = try #require(SleepConsistency.score(bedtimes: [1410, 30, 1410, 30], wakeTimes: [420, 420, 420, 420]))
        #expect(result.bedtimeSpread == 30)
        #expect(result.score == 88)
    }

    @Test func needsThreeNights() {
        #expect(SleepConsistency.score(bedtimes: [1380, 1380], wakeTimes: [420, 420]) == nil)
    }
}

@MainActor
struct HealthAgeTests {
    @Test func fitHabitsLowerHealthAge() throws {
        let fit = HealthAge.Input(age: 40, sleepHours: 7.5, sleepConsistency: 85, dailySteps: 11_000, restingHeartRate: 50,
                                  vo2Max: 50, moderateMinutesPerWeek: 250, vigorousMinutesPerWeek: 90, strengthMinutesPerWeek: 90)
        let unfit = HealthAge.Input(age: 40, sleepHours: 5.5, sleepConsistency: 50, dailySteps: 3_000, restingHeartRate: 75,
                                    vo2Max: 30, moderateMinutesPerWeek: 20, vigorousMinutesPerWeek: 0, strengthMinutesPerWeek: 0)
        #expect(try #require(HealthAge.age(fit)) < 35)
        #expect(try #require(HealthAge.age(unfit)) > 50)
    }

    @Test func needsThreeInputs() {
        #expect(HealthAge.age(HealthAge.Input(age: 40, dailySteps: 8_000, restingHeartRate: 60)) == nil)
    }

    @Test func paceComparesRecentWithBaseline() {
        #expect(HealthAge.pace(recent: 38, baseline: 38) == 1)
        #expect(HealthAge.pace(recent: 37, baseline: 38) == 0.5)
        #expect(HealthAge.pace(recent: 30, baseline: 38) == -1)
    }
}

@MainActor
struct RacePredictorTests {
    /// Jack Daniels' published VDOT tables: VDOT 50 runs 5K in 19:57 and a marathon in 3:10:49.
    @Test func matchesDanielsTables() {
        #expect(abs(RacePredictor.time(meters: 5_000, vo2Max: 50) - (19 * 60 + 57)) < 5)
        #expect(abs(RacePredictor.time(meters: 42_195, vo2Max: 50) - (3 * 3600 + 10 * 60 + 49)) < 30)
    }

    @Test func formatsRaceTimes() {
        #expect(SnapshotBuilder.raceTime(19 * 60 + 57) == "19:57")
        #expect(SnapshotBuilder.raceTime(3 * 3600 + 10 * 60 + 49) == "3:10:49")
    }
}

@MainActor
struct PlannedCardTests {
    @Test func plannedCardsStayOutOfTheGallery() {
        #expect(!CardKind.gallery.contains(.trainingReadiness))
        #expect(!CardKind.gallery.contains(.loadFocus))
    }
}

@MainActor
struct HealthProfileTests {
    @Test func maxHeartRateComesFromAgeWhenKnown() async throws {
        let profile = try await HealthProfile.load(from: SampleDataSource())
        #expect(profile.age == 35)
        #expect(profile.maxHeartRate == 185)
        #expect(profile.maxHeartRateSource == .age)
        #expect(profile.restingHeartRate != nil)
    }
}
