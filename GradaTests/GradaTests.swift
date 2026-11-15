import Foundation
import SwiftData
import Testing
@testable import Grada

@MainActor
struct HomeLayoutTests {
    @Test func squaresPairUpAndWideCardsFillARow() {
        let rows = HomeLayout.rows(for: [CardKind.sleepStages, .restingHeartRate, .hrv, .steps, .lastWorkout, .activeEnergy])
        #expect(rows == [[.sleepStages], [.restingHeartRate, .hrv], [.steps], [.lastWorkout], [.activeEnergy]])
    }

    @Test func defaultSetLayout() {
        let rows = HomeLayout.rows(for: CardKind.defaultSet).map { $0.map(\.kind) }
        #expect(rows == [[.sleepStages], [.hrvStatus, .recovery], [.steps, .activeEnergy], [.lastWorkout], [.last30Days]])
    }
}

@MainActor
struct CardVariantTests {
    private let builder = SnapshotBuilder(source: SampleDataSource())

    @Test func cardsSavedBeforeVariantsKeepTheirLook() {
        let card = HomeCard(CardID(kind: .distance), position: 0)
        card.variantRawValue = ""
        #expect(card.cardID == CardID(kind: .distance, variant: .week))
    }

    @Test func unsupportedVariantFallsBackToTheDefault() {
        let card = HomeCard(CardID(kind: .heartRate, variant: .week), position: 0)
        #expect(card.cardID == CardID(kind: .heartRate, variant: .current))
        let recovery = HomeCard(CardID(kind: .recovery, variant: .current), position: 0)
        #expect(recovery.cardID == CardID(kind: .recovery, variant: .week))
    }

    @Test func retiredCardsLeaveHomeAndTheGallery() {
        #expect(HomeCard(CardID(kind: .restingHeartRate), position: 0).cardID == nil)
        #expect(HomeCard(CardID(kind: .hrv), position: 0).cardID == nil)
        #expect(!CardID.gallery.contains { $0.kind.isRetired })
    }

    @Test func everyVariantBuildsFromSampleData() async throws {
        for card in CardID.gallery {
            let snapshot = try await builder.snapshot(for: card.kind, variant: card.variant)
            #expect(snapshot.value != nil, "\(card) has no value")
        }
    }

    @Test func totalsWithAGoal() async throws {
        var builder = builder
        builder.goals = GoalHistory([GoalEntry(metric: .steps, value: 9_000, effectiveFrom: Calendar.current.startOfDay(for: .now), reason: .edit)])
        let current = try await builder.snapshot(for: .steps, variant: .current)
        let week = try await builder.snapshot(for: .steps, variant: .week)
        guard case .progress(_, 9_000, false) = current.chart else { Issue.record("\(current.chart)"); return }
        guard case .bars(let days, 9_000, nil) = week.chart else { Issue.record("\(week.chart)"); return }
        #expect(days.count == 7)
        #expect(current.value == week.value)
    }

    @Test func totalsWithoutAGoalUseTheAverage() async throws {
        let current = try await builder.snapshot(for: .distance, variant: .current)
        let week = try await builder.snapshot(for: .distance, variant: .week)
        guard case .progress(_, _, true) = current.chart else { Issue.record("\(current.chart)"); return }
        guard case .bars(_, nil, nil) = week.chart else { Issue.record("\(week.chart)"); return }
    }

    @Test func sleepFillsTowardItsGoal() async throws {
        let week = try await builder.snapshot(for: .sleepDuration, variant: .week)
        guard case .sleep(let nights, let target?) = week.chart else { Issue.record("\(week.chart)"); return }
        #expect(nights.count == 7)
        #expect(target > 0)
    }

    @Test func wristTempShowsTheTemperatureAndTheWeek() async throws {
        #expect(CardKind.wristTemperature.defaultVariant == .week)
        var builder = builder
        builder.usesMetric = true
        let snapshot = try await builder.snapshot(for: .wristTemperature, variant: .week)
        guard case .line(let values, let range?) = snapshot.chart else { Issue.record("\(snapshot.chart)"); return }
        #expect(values.count == 7)
        let value = try #require(snapshot.value.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) })
        #expect((30...40).contains(value), "Shows the temperature, not the change")
        #expect((30...40).contains(range.lowerBound))
        #expect(snapshot.rating != nil)

        let current = try await builder.snapshot(for: .wristTemperature, variant: .current)
        guard case .range(_, let gauge, nil, _?, 1) = current.chart else { Issue.record("\(current.chart)"); return }
        #expect(gauge == range, "Only a rise warns, on the same range as the week")
    }

    @Test func vitalsMarkTheRange() async throws {
        for kind in [CardKind.oxygenSaturation, .respiratoryRate] {
            let snapshot = try await builder.snapshot(for: kind)
            guard case .range(_, _, let below, let above, _) = snapshot.chart else { Issue.record("\(kind): \(snapshot.chart)"); continue }
            if kind == .oxygenSaturation {
                #expect(below != nil && above == nil, "Only low blood oxygen warns")
            } else {
                #expect(below == nil && above != nil, "Only a high respiratory rate warns")
            }
            #expect(snapshot.rating != nil)
        }
    }

    @Test func hrvCurrentWarnsOnBothSides() async throws {
        #expect(CardKind.hrvStatus.defaultVariant == .week)
        let snapshot = try await builder.snapshot(for: .hrvStatus, variant: .current)
        guard case .range(_, let baseline, let below?, let above?, 0) = snapshot.chart else { Issue.record("\(snapshot.chart)"); return }
        #expect(below == (baseline.upperBound - baseline.lowerBound) / 2, "Red from twice the half-width under the mean")
        #expect(above == .infinity, "Above the baseline stays yellow")
    }

    @Test func heartRateDrawsTodaysCurve() async throws {
        let snapshot = try await builder.snapshot(for: .heartRate)
        guard case .intraday(let points, _) = snapshot.chart, !points.isEmpty else { Issue.record("\(snapshot.chart)"); return }
        #expect(snapshot.rating != nil, "Rated by today's resting heart rate")
        #expect(snapshot.comparison?.contains("Resting") == true)
    }

    @Test func recoveryColorsEachDay() async throws {
        let week = try await builder.snapshot(for: .recovery, variant: .week)
        guard case .bars(let scores, 100, let ratings?) = week.chart else { Issue.record("\(week.chart)"); return }
        #expect(ratings.count == scores.count)
        #expect(week.rating != nil)
    }

    @Test func scoresAreRated() async throws {
        for kind in [CardKind.resources, .hrvStatus, .vo2Max] {
            let snapshot = try await builder.snapshot(for: kind)
            #expect(snapshot.rating != nil, "\(kind) has no rating")
        }
    }
}

struct RatingTests {
    @Test func recoveryBands() {
        #expect([Recovery.rating(80), Recovery.rating(50), Recovery.rating(20)] == [.good, .fair, .poor])
        #expect([Recovery.rating(67), Recovery.rating(66), Recovery.rating(34), Recovery.rating(33)] == [.good, .fair, .fair, .poor])
    }

    @Test func wristTempOnlyFlagsARise() {
        let normal = 35.2...36.0
        #expect(DayRatings.range(34.6, normal: normal, higherIsBetter: false) == .good)
        #expect(DayRatings.range(35.6, normal: normal, higherIsBetter: false) == .good)
        #expect(DayRatings.range(36.1, normal: normal, higherIsBetter: false) == .fair)
        #expect(DayRatings.range(36.4, normal: normal, higherIsBetter: false) == .poor)
    }

    @Test func vo2MaxZonesFollowTheCooperTable() {
        let men = VO2MaxZones.bounds(age: 25, sex: .male)
        #expect(men == [36.5, 42.5, 46.5, 52.5])
        #expect(VO2MaxZones.zone(36.4, bounds: men) == .poor)
        #expect(VO2MaxZones.zone(42.5, bounds: men) == .good)
        #expect(VO2MaxZones.zone(60, bounds: men) == .superior)
        #expect(VO2MaxZones.bounds(age: 25, sex: .female) == [29.0, 33.0, 37.0, 41.1])
        #expect(VO2MaxZones.bounds(age: 70, sex: .male) == VO2MaxZones.bounds(age: 60, sex: .male))
    }

    @Test func raceTrendIgnoresSmallChanges() {
        #expect(RacePredictor.trend(from: 48, to: 48.4) == "Steady")
        #expect(RacePredictor.trend(from: 48, to: 48.6) == "Improving")
        #expect(RacePredictor.trend(from: 48, to: 47.4) == "Declining")
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

    @Test func hrvStatusShowsAStatusWithEnoughHistory() async throws {
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .hrvStatus)
        #expect(snapshot.value != "Calibrating")
        let comparison = try #require(snapshot.comparison)
        #expect(["Balanced", "Unbalanced", "Low"].contains { comparison.hasPrefix($0) }, "\(comparison)")
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
    func biologicalSex() async throws -> BiologicalSex? { try await base.biologicalSex() }
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

    @Test func workoutsCalendarKeepsEverySportOfADay() async throws {
        let snapshot = try await builder.snapshot(for: .last30Days)
        guard case .days(let days) = snapshot.detail else { Issue.record("\(snapshot.detail)"); return }
        let twoSports = try #require(days.first { $0.sports.count == 2 }, "Sample strength days add an evening walk")
        #expect(twoSports.sports.map(\.name) == ["Strength", "Walk"], "Longest first")
        #expect(twoSports.minutes == 80)
    }

    @Test func healthStatusShowsYesterdaysVitals() async throws {
        let snapshot = try await builder.snapshot(for: .healthStatus)
        #expect(snapshot.period == "Yesterday")
        #expect(snapshot.value != nil)
        guard case .vitals(let vitals) = snapshot.detail else { Issue.record("\(snapshot.detail)"); return }
        for vital in vitals {
            let measured = vital.state == .inRange || vital.state == .outOfRange
            #expect((vital.rating != nil) == measured, "\(vital.name): only measured vitals are colored")
            #expect((vital.rating == .good) == (vital.state == .inRange), "\(vital.name): green means in range")
        }
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
        guard case .sleep(let nights, _) = snapshot.chart else { Issue.record("Expected a sleep chart"); return }
        #expect(nights.count == 7)
        #expect(nights.last??.stages[.deep] != nil)
    }
}

struct IntensityMinutesTests {
    private func values(_ heartRates: [Double]) -> [TimedValue] {
        heartRates.enumerated().map { TimedValue(date: Date(timeIntervalSince1970: Double($0.offset) * 300), value: $0.element) }
    }

    /// Resting 60 and max 180: moderate from 108 bpm, vigorous from 132.
    @Test func vigorousCountsDoubleAndLightIsIgnored() {
        let total = IntensityMinutes.total(heartRate: values([100, 107, 108, 131, 132, 170]), restingHeartRate: 60, maxHeartRate: 180)
        #expect(total == 2 * 5 + 2 * 10)
    }

    @Test func noReserveCountsNothing() {
        #expect(IntensityMinutes.total(heartRate: values([150]), restingHeartRate: 180, maxHeartRate: 180) == 0)
    }

    @Test func cardShowsTheLast7DaysAgainstTheTarget() async throws {
        let builder = SnapshotBuilder(source: SampleDataSource())
        let snapshot = try await builder.snapshot(for: .intensityMinutes)
        #expect(snapshot.period == "Last 7 days")
        let total = try await builder.intensityDays(7).compactMap(\.value).reduce(0, +)
        #expect(snapshot.value == total.formatted(.number.precision(.fractionLength(0))))
        let comparison = try #require(snapshot.comparison)
        #expect(comparison.hasSuffix("of 150") || comparison == "Goal reached", "\(comparison)")
    }
}

struct HRVStatusTests {
    /// 20 nights of 58 and 62 ms: ln SD ≈ 0.034, so the 0.05 floor applies and the baseline is the geometric
    /// mean 59.97 × e^±0.025, about 58.49–61.48.
    private let history: [Double?] = (0..<20).map { $0.isMultiple(of: 2) ? 58 : 62 }

    private func status(window: [Double?], history: [Double?]? = nil) -> HRVStatus.Result? {
        let nights = (history ?? self.history) + window
        return HRVStatus.status(nights: nights, endingAt: nights.count - 1)
    }

    @Test func calibratingWithoutTwoWeeksOfBaseline() {
        #expect(status(window: Array(repeating: 60, count: 7), history: Array(repeating: 60, count: 13)) == nil)
    }

    @Test func calibratingWithFewerThanThreeNightsInTheWindow() {
        #expect(status(window: [60, nil, nil, nil, nil, nil, 60]) == nil)
    }

    @Test func averageInsideBaselineIsBalanced() throws {
        let result = try #require(status(window: Array(repeating: 61, count: 7)))
        #expect(result.state == .balanced)
        #expect(abs(result.baseline.lowerBound - 58.487) < 0.01)
        #expect(abs(result.baseline.upperBound - 61.484) < 0.01)
    }

    @Test func averageAboveOrSlightlyBelowIsUnbalanced() throws {
        #expect(try #require(status(window: Array(repeating: 66, count: 7))).state == .unbalanced)
        #expect(try #require(status(window: Array(repeating: 57.5, count: 7))).state == .unbalanced)
    }

    /// More than one SD (0.05 in ln terms) below the baseline mean: 54 ms is ln −0.105.
    @Test func averageWellBelowIsLow() throws {
        #expect(try #require(status(window: Array(repeating: 54, count: 7))).state == .low)
        #expect(try #require(status(window: Array(repeating: 50, count: 7))).state == .low)
    }

    @Test func missingNightsAreSkipped() throws {
        let result = try #require(status(window: [nil, 61, nil, 61, nil, 61, 61]))
        #expect(abs(result.average - 61) < 1e-9)
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
        #expect(Resources.maxHeartRate(age: 60, highestRecorded: nil) == 166, "Tanaka: 208 − 0.7 × age, not 220 − age")
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
        let fit = HealthAge.Input(age: 40, sex: .male, sleepHours: 7.5, sleepConsistency: 85, dailySteps: 11_000, restingHeartRate: 50,
                                  vo2Max: 50, moderateMinutesPerWeek: 250, vigorousMinutesPerWeek: 90, strengthMinutesPerWeek: 90)
        let unfit = HealthAge.Input(age: 40, sex: .male, sleepHours: 5.5, sleepConsistency: 50, dailySteps: 3_000, restingHeartRate: 75,
                                    vo2Max: 30, moderateMinutesPerWeek: 20, vigorousMinutesPerWeek: 0, strengthMinutesPerWeek: 0)
        #expect(try #require(HealthAge.age(fit)) < 35)
        #expect(try #require(HealthAge.age(unfit)) > 50)
    }

    /// FRIEND registry medians: a 45-year-old woman at 26.7 is average, while a man at 26.7 is 11.1 below his.
    @Test func vo2MaxIsComparedWithTheNormForAgeAndSex() throws {
        func vo2Years(_ sex: BiologicalSex?) -> Double? {
            HealthAge.impacts(HealthAge.Input(age: 45, sex: sex, vo2Max: 26.7)).first { $0.name == "VO₂ Max" }?.years
        }
        #expect(vo2Years(.female) == 0)
        #expect(try #require(vo2Years(.male)) > 4)
        #expect(vo2Years(nil) == nil, "Without sex there is no norm to compare with")
        #expect(HealthAge.expectedVO2Max(age: 18, sex: .male) == 48.0)
        #expect(HealthAge.expectedVO2Max(age: 85, sex: .female) == 18.3)
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
        #expect(profile.maxHeartRate == 183.5)
        #expect(profile.maxHeartRateSource == .age)
        #expect(profile.restingHeartRate != nil)
    }
}

@MainActor
struct DayRatingTests {
    @Test func goalMetricsUseSeventyPercentForYellow() {
        #expect(DayRatings.goal(10_000, goal: 10_000) == .good)
        #expect(DayRatings.goal(7_000, goal: 10_000) == .fair)
        #expect(DayRatings.goal(6_999, goal: 10_000) == .poor)
    }

    /// Normal 48–72 (half-width 12): slightly below means less than 6 under the range.
    @Test func higherIsBetterOnlyPenalizesLowValues() {
        #expect(DayRatings.range(90, normal: 48...72, higherIsBetter: true) == .good)
        #expect(DayRatings.range(44, normal: 48...72, higherIsBetter: true) == .fair)
        #expect(DayRatings.range(41, normal: 48...72, higherIsBetter: true) == .poor)
    }

    @Test func lowerIsBetterOnlyPenalizesHighValues() {
        #expect(DayRatings.range(40, normal: 49...55, higherIsBetter: false) == .good)
        #expect(DayRatings.range(56, normal: 49...55, higherIsBetter: false) == .fair)
        #expect(DayRatings.range(57, normal: 49...55, higherIsBetter: false) == .poor)
    }

    @Test func healthStatusCountsVitalsOutOfRange() {
        #expect(DayRatings.healthStatus(outOfRange: 0) == .good)
        #expect(DayRatings.healthStatus(outOfRange: 1) == .fair)
        #expect(DayRatings.healthStatus(outOfRange: 2) == .poor)
    }

    @Test func vitalTilesRateBothDirections() {
        let normal = 49.0...55.0  // slightly off means less than 1.5 outside
        #expect(DayRatings.vital(52, normal: normal) == .good)
        #expect(DayRatings.vital(48, normal: normal) == .fair)
        #expect(DayRatings.vital(56, normal: normal) == .fair)
        #expect(DayRatings.vital(47, normal: normal) == .poor)
        #expect(DayRatings.vital(57, normal: normal) == .poor)
    }

    @Test func daysStayUnratedWhileCalibrating() {
        let start = Calendar.current.startOfDay(for: .now)
        let series = (0..<10).map { DayValue(day: start.addingTimeInterval(Double($0) * 86_400), value: 54) }
        let ratings = DayRatings.rateVital(series, metric: .restingHeartRate, higherIsBetter: false, baselineDays: 30)
        #expect(ratings[series[6].day] == nil)
        #expect(ratings[series[7].day] == .good)
        #expect(ratings.count == 3)
    }
}

@MainActor
struct PastDaySourceTests {
    @Test func seriesEndOnThePastDay() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!
        let source = PastDaySource(base: SampleDataSource(), daysAgo: 3,
                                   dayEnd: calendar.date(byAdding: .day, value: 1, to: threeDaysAgo)!)
        let steps = try await source.daily(.steps, days: 8)
        #expect(steps.count == 8)
        #expect(steps.last?.day == threeDaysAgo)
        #expect(try await source.sleepNights(days: 8).allSatisfy { $0.wakeDay <= threeDaysAgo })
        #expect(try await source.workouts(days: 30).allSatisfy { $0.start < calendar.date(byAdding: .day, value: 1, to: threeDaysAgo)! })
    }

    @Test func pastDayCardsDontSayToday() async throws {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -5, to: calendar.startOfDay(for: .now))!
        let snapshots = await CalendarModel(source: SampleDataSource()).snapshots(for: day, cards: [CardID(kind: .steps), CardID(kind: .sleepNeed)], goals: GoalHistory())
        #expect(snapshots[.steps]?.period == "That day")
        #expect(snapshots[.sleepNeed]?.period == "That night")
    }

    @Test func pastDayCardsDontSayNowOrLastNight() async throws {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -5, to: calendar.startOfDay(for: .now))!
        let kinds: [CardKind] = [.healthStatus, .resources, .sleepStages, .wristTemperature, .hrvStatus]
        let snapshots = await CalendarModel(source: SampleDataSource()).snapshots(for: day, cards: kinds.map { CardID(kind: $0) }, goals: GoalHistory())
        #expect(snapshots[.resources]?.period == "End of day")
        #expect(snapshots[.sleepStages]?.period == "Night before")
        for kind in kinds {
            #expect(!["Now", "Last night", "Today", "Tonight"].contains(snapshots[kind]?.period ?? ""), "\(kind)")
        }
    }
}

@MainActor
struct CalendarTypeTests {
    private let calendar = Calendar.current

    @Test func savedMetricsMapToTheirType() {
        #expect(CalendarMetric(rawValue: "healthStatus") == .health)
        #expect(CalendarMetric(rawValue: "hrv") == .health)
        #expect(CalendarMetric(rawValue: "restingHeartRate") == .health)
        #expect(CalendarMetric(rawValue: "sleep") == .recovery)
        #expect(CalendarMetric(rawValue: "steps") == .training)
        #expect(CalendarMetric.allCases.allSatisfy { CalendarMetric(rawValue: $0.rawValue) == $0 })
    }

    @Test func cardsOpenTheirType() {
        #expect(CardKind.healthStatus.calendarMetric == .health)
        #expect(CardKind.wristTemperature.calendarMetric == .health)
        #expect(CardKind.recovery.calendarMetric == .recovery)
        #expect(CardKind.sleepStages.calendarMetric == .recovery)
        #expect(CardKind.steps.calendarMetric == .training)
        #expect(CardKind.last30Days.calendarMetric == .training)
        for metric in CalendarMetric.allCases {
            #expect(metric.kinds.allSatisfy { $0.calendarMetric == metric }, "\(metric) sheet holds only its own cards")
        }
    }

    @Test func recoveryRatesDaysAndTrainingDoesnt() async {
        let model = CalendarModel(source: SampleDataSource())
        await model.load(.recovery, goals: GoalHistory())
        #expect(!model.ratings.isEmpty)
        await model.load(.training, goals: GoalHistory())
        #expect(model.ratings.isEmpty)
        let twoSports = model.workoutDays.values.first { $0.sports.count == 2 }
        #expect(twoSports?.workouts == 2, "Sample strength days add an evening walk")
    }

    @Test func daySheetChartsEndOnTheSelectedDay() async throws {
        let day = calendar.date(byAdding: .day, value: -5, to: calendar.startOfDay(for: .now))!
        let snapshots = await CalendarModel(source: SampleDataSource()).snapshots(for: day, cards: [CardID(kind: .steps, variant: .week), CardID(kind: .recovery, variant: .week)], goals: GoalHistory())
        guard case .bars(let steps, _, _) = snapshots[.steps]?.chart else { Issue.record("Steps keeps its 7-day bars"); return }
        #expect(steps.count == 7)
        guard case .bars = snapshots[.recovery]?.chart else { Issue.record("Recovery keeps its chart"); return }
        let letters = calendar.veryShortStandaloneWeekdaySymbols
        #expect(WeekdayLabels.symbols(count: 7, endingOn: day).last == letters[calendar.component(.weekday, from: day) - 1])
    }

    @Test func daySheetListsThatDaysWorkouts() async throws {
        let model = CalendarModel(source: SampleDataSource())
        await model.load(.training, goals: GoalHistory())
        let day = try #require(model.workoutDays.first { $0.value.workouts == 2 }?.key)
        let cards = model.workoutSnapshots(for: day)
        #expect(cards.map(\.comparison) == ["Strength", "Walk"], "Earliest first")
    }
}

@MainActor
struct TrendBuilderTests {
    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: .now) }

    @Test func monthHasOnePointPerDayEndingToday() async throws {
        let trend = try #require(try await TrendBuilder(source: SampleDataSource()).trend(for: .steps, period: .month))
        #expect(trend.points.count == 30)
        #expect(trend.points.last?.date == today)
        #expect(trend.average != nil)
    }

    @Test func longPeriodsShowWeeklyPoints() async throws {
        let trend = try #require(try await TrendBuilder(source: SampleDataSource()).trend(for: .restingHeartRate, period: .year))
        #expect((52...54).contains(trend.points.count))
        #expect(trend.normalRange != nil)
    }

    @Test func pastDayTrendsEndOnThatDay() async throws {
        let day = calendar.date(byAdding: .day, value: -10, to: today)!
        let source = PastDaySource.asOf(day, base: SampleDataSource(), calendar: calendar)
        for kind in [CardKind.sleepStages, .hrv, .recovery, .weeklyTraining, .sleepNeed, .healthStatus] {
            let trend = try #require(try await TrendBuilder(source: source).trend(for: kind, period: .week), "\(kind)")
            #expect(trend.points.count == 7, "\(kind)")
            #expect(trend.points.last?.date == day, "\(kind)")
        }
    }

    @Test func everyCardWithADetailScreenHasAnExplanationAndValidLinks() {
        for kind in CardKind.gallery + [.healthStatus] where !kind.opensCalendar {
            #expect(!kind.explanation.isEmpty)
            #expect((kind.affects + kind.basedOn).allSatisfy { !$0.isPlanned })
        }
    }
}

struct GoalTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Monday.
    private var monday: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))! }

    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: monday)! }

    private func history(_ entries: [GoalEntry]) -> GoalHistory { GoalHistory(entries, calendar: calendar) }

    /// The 7 days before `weekEnding` with these values; nil leaves a day out.
    private func week(ending weekEnding: Int, _ values: [Double?]) -> [Date: Double] {
        var result: [Date: Double] = [:]
        for (index, value) in values.enumerated() { result[day(weekEnding - 7 + index)] = value }
        return result
    }

    private func steps(_ value: Double, from offset: Int, _ reason: GoalEntry.Reason = .preset) -> GoalEntry {
        GoalEntry(metric: .steps, value: value, effectiveFrom: day(offset), reason: reason)
    }

    @Test func pastDaysUseTheGoalInEffectThen() {
        let goals = history([steps(8_000, from: 0), steps(8_500, from: 7, .automatic)])
        #expect(goals.value(.steps, on: day(-1)) == nil)
        #expect(goals.value(.steps, on: day(3)) == 8_000)
        #expect(goals.value(.steps, on: day(7)) == 8_500)
    }

    @Test func firstAdjustmentIsTheFirstMondayAtLeastAWeekLater() {
        #expect(Goals.adjustmentDate(after: day(0), calendar: calendar) == day(7))
        #expect(Goals.adjustmentDate(after: day(2), calendar: calendar) == day(14))
    }

    @Test func editedSleepHoldsUntilTheNextAdjustmentThenFollowsSleepNeed() {
        let goals = history([GoalEntry(metric: .sleep, value: 8.5 * 3600, effectiveFrom: day(2), reason: .edit)])
        #expect(goals.value(.sleep, on: day(13)) == 8.5 * 3600)
        #expect(goals.value(.sleep, on: day(14)) == nil)
    }

    @Test func dailyGoalRisesAfterFiveHitsAndFallsAfterTwoOrFewer() {
        let goals = history([steps(8_000, from: 0)])
        let up = Goals.adjustments(.steps, history: goals, daily: week(ending: 7, [9_000, 9_000, 9_000, 9_000, 9_000, 1_000, 1_000]),
                                   today: day(7), calendar: calendar)
        #expect(up == [steps(8_500, from: 7, .automatic)])
        let down = Goals.adjustments(.steps, history: goals, daily: week(ending: 7, [9_000, 9_000, 1_000, 1_000, 1_000, 1_000, 1_000]),
                                     today: day(7), calendar: calendar)
        #expect(down.map(\.value) == [7_500])
        let same = Goals.adjustments(.steps, history: goals, daily: week(ending: 7, [9_000, 9_000, 9_000, 1_000, 1_000, 1_000, 1_000]),
                                     today: day(7), calendar: calendar)
        #expect(same.isEmpty)
    }

    @Test func dailyGoalKeepsWithFewerThanFourMeasuredDays() {
        let goals = history([steps(8_000, from: 0)])
        let daily = week(ending: 7, [1_000, 1_000, 1_000, nil, nil, nil, nil])
        #expect(Goals.adjustments(.steps, history: goals, daily: daily, today: day(7), calendar: calendar).isEmpty)
    }

    @Test func editedGoalHoldsAWeekThenAdjustsFromTheUsersValue() {
        let goals = history([steps(8_000, from: 0), steps(10_000, from: 9, .edit)])
        let daily = week(ending: 14, Array(repeating: 1_000, count: 7)).merging(week(ending: 21, Array(repeating: 1_000, count: 7))) { a, _ in a }
        #expect(Goals.adjustments(.steps, history: goals, daily: daily, today: day(14), calendar: calendar).isEmpty)
        #expect(Goals.adjustments(.steps, history: goals, daily: daily, today: day(21), calendar: calendar).map(\.value) == [9_500])
    }

    @Test func weeklyGoalUsesTheWeekTotal() {
        let goals = history([GoalEntry(metric: .intensityMinutes, value: 200, effectiveFrom: day(0), reason: .preset)])
        let met = Goals.adjustments(.intensityMinutes, history: goals, daily: week(ending: 7, [50, 50, 50, 50, nil, nil, nil]),
                                    today: day(7), calendar: calendar)
        #expect(met.map(\.value) == [210])
        let missed = Goals.adjustments(.intensityMinutes, history: goals, daily: week(ending: 7, [30, 30, 30, nil, nil, nil, nil]),
                                       today: day(7), calendar: calendar)
        #expect(missed.map(\.value) == [190])
    }

    @Test func intensityNeverDropsBelowTheWHOMinimum() {
        let goals = history([GoalEntry(metric: .intensityMinutes, value: 150, effectiveFrom: day(0), reason: .preset)])
        #expect(Goals.adjustments(.intensityMinutes, history: goals, daily: week(ending: 7, [0, 0, 0, 0, 0, 0, 0]),
                                  today: day(7), calendar: calendar).isEmpty)
    }

    @Test func smallGoalsMoveByAtLeastOneStep() {
        let goals = history([GoalEntry(metric: .workouts, value: 3, effectiveFrom: day(0), reason: .preset)])
        let result = Goals.adjustments(.workouts, history: goals, daily: week(ending: 7, [1, 1, 1, 0, 0, 0, 0]),
                                       today: day(7), calendar: calendar)
        #expect(result.map(\.value) == [4])
    }

    @Test func missedMondaysAreCaughtUpButOnlyTheLastFour() {
        let goals = history([steps(8_000, from: 0)])
        var daily: [Date: Double] = [:]
        for offset in 0..<70 { daily[day(offset)] = 30_000 }
        let result = Goals.adjustments(.steps, history: goals, daily: daily, today: day(70), calendar: calendar)
        #expect(result.map(\.effectiveFrom) == [42, 49, 56, 63, 70].map(day).filter { $0 >= day(42) })
        #expect(result.count == 5)
    }

    @Test func lastWeekUsesTheMedianForDailyGoalsAndTheTotalForWeeklyOnes() {
        let goals = Goals.fromLastWeek([.steps: [6_000, 8_100, 7_000, nil, 9_000, 1_000, 8_000, 8_200],
                                        .workouts: [1, 0, 1, 0, 1, 0, 0],
                                        .floors: [nil, nil]], fallback: .balanced)
        #expect(goals[.steps] == 8_000)
        #expect(goals[.workouts] == 3)
        #expect(goals[.floors] == GoalPreset.balanced.goals[.floors])
    }
}

struct GoalCardTests {
    @Test func goalMetricsCompareWithTheGoalAndShowProgress() async throws {
        var builder = SnapshotBuilder(source: SampleDataSource())
        let today = Calendar.current.startOfDay(for: .now)
        builder.goals = GoalHistory([GoalEntry(metric: .steps, value: 1_000_000, effectiveFrom: today, reason: .edit)])
        let snapshot = try await builder.snapshot(for: .steps)
        let goalText = 1_000_000.0.formatted(.number.precision(.fractionLength(0)))
        #expect(snapshot.comparison?.hasSuffix("of \(goalText)") == true, "\(snapshot.comparison ?? "")")
        guard case .progress(_, let goal, _) = snapshot.chart else {
            Issue.record("Expected a progress bar")
            return
        }
        #expect(goal == 1_000_000)
    }

    @Test func sleepComparesWithItsGoal() async throws {
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .sleepDuration)
        #expect(snapshot.comparison?.hasSuffix("goal") == true, "\(snapshot.comparison ?? "")")
    }
}

@MainActor
struct JournalTests {
    private let context: ModelContext
    private let store: JournalStore
    private let today = Calendar.current.startOfDay(for: .now)

    init() throws {
        let container = try ModelContainer(for: JournalEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        store = JournalStore(context: context)
    }

    @Test func togglingMarksAndUnmarksATag() {
        store.toggle(.stress, on: today)
        #expect(store.entries(on: today)[.stress] != nil)
        store.toggle(.stress, on: today)
        #expect(store.entries(on: today).isEmpty)
    }

    @Test func amountTagsStartAtTheirInitialAmountAndCanChange() {
        store.toggle(.alcohol, on: today)
        #expect(store.entries(on: today)[.alcohol]?.amount == 1)
        store.setAmount(3, for: .alcohol, on: today)
        #expect(store.entries(on: today)[.alcohol]?.amount == 3)
        #expect(JournalTag.alcohol.label(amount: 3) == "Alcohol · 3 drinks")
        #expect(JournalTag.stress.label(amount: nil) == "Stress")
    }

    @Test func tagsBelongToTheirOwnDay() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        store.toggle(.caffeine, on: yesterday)
        #expect(store.entries(on: today).isEmpty)
        #expect(store.entries(on: yesterday)[.caffeine] != nil)
    }

    @Test func duplicateEntriesFromSyncAreMerged() throws {
        context.insert(JournalEntry(day: today, tag: .sauna, amount: nil))
        context.insert(JournalEntry(day: today, tag: .sauna, amount: nil))
        try context.save()
        #expect(store.entries(on: today).count == 1)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<JournalEntry>()) == 1)
    }

    @Test func hiddenTagsRoundTrip() throws {
        var hidden = HiddenTags()
        hidden.set(.nap, hidden: true)
        hidden.set(.sauna, hidden: true)
        let restored = try #require(HiddenTags(rawValue: hidden.rawValue))
        #expect(restored.contains(.nap) && restored.contains(.sauna) && !restored.contains(.alcohol))
    }
}

struct WorkoutDetailTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func minutes(_ values: [Double]) -> [TimedValue] {
        values.enumerated().map { TimedValue(date: start.addingTimeInterval(Double($0.offset) * 60), value: $0.element) }
    }

    @Test func zonesFollowShareOfMaxHeartRate() {
        #expect(HeartRateZones.zone(90, maxHeartRate: 200) == nil)
        #expect(HeartRateZones.zone(100, maxHeartRate: 200) == 1)
        #expect(HeartRateZones.zone(150, maxHeartRate: 200) == 3)
        #expect(HeartRateZones.zone(199, maxHeartRate: 200) == 5)
    }

    @Test func timeInZonesCountsUntilTheNextReadingAndCapsGaps() {
        // 1 minute in zone 3, then a reading in zone 5 followed by a 20-minute gap to the end.
        let readings = minutes([150, 185])
        let seconds = HeartRateZones.time(readings, end: start.addingTimeInterval(21 * 60), maxHeartRate: 200)
        #expect(seconds == [0, 0, 60, 0, HeartRateZones.maxGap])
    }

    @Test func trainingEffectGrowsWithLoadAndCapsAtFive() {
        #expect(TrainingEffect.aerobic(timeInZones: [0, 0, 0, 0, 0]) == 0)
        let steadyRun = TrainingEffect.aerobic(timeInZones: [0, 0, 45 * 60, 0, 0])
        #expect((2.8...3.2).contains(steadyRun))
        #expect(TrainingEffect.label(steadyRun) == "Maintaining" || TrainingEffect.label(steadyRun) == "Improving")
        #expect(TrainingEffect.aerobic(timeInZones: [0, 0, 0, 0, 300 * 60]) == 5)
        #expect(TrainingEffect.label(5) == "Overreaching")
    }

    @Test func splitsInterpolateEachKilometer() {
        // 250 m a minute for 9 minutes: two full kilometers in 4 minutes each, then 250 m.
        let track = (1...9).map { TimedValue(date: start.addingTimeInterval(Double($0) * 60), value: Double($0) * 250) }
        let splits = Splits.make(track: track, heartRate: minutes(Array(repeating: 140, count: 10)), start: start)
        #expect(splits.map(\.meters) == [1000, 1000, 250])
        #expect(splits.map(\.duration) == [240, 240, 60])
        #expect(splits.first?.averageHeartRate == 140)
    }

    @Test func shortLastStretchIsDropped() {
        let track = [TimedValue(date: start.addingTimeInterval(300), value: 1050)]
        #expect(Splits.make(track: track, heartRate: [], start: start).map(\.meters) == [1000])
    }

    @Test func sampleRunHasEverySection() async throws {
        let run = try #require(try await SampleDataSource().workouts(days: 7).first { $0.name == "Run" })
        let detail = try await SampleDataSource().workoutDetail(run)
        #expect(detail.heartRate.count > 30)
        #expect((detail.distance ?? 0) > 5000)
        #expect(detail.route.count > 1)
        #expect(Splits.make(track: detail.distanceTrack, heartRate: detail.heartRate, start: run.start).count > 4)
    }

    @Test func swimsSplitAndPacePer100() {
        let metric = DistanceUnits(sport: "Swim", isUS: false)
        #expect(metric.splitMeters == 100)
        #expect(metric.splitName == "100 m")
        #expect(metric.distance(1500) == "1500 m")
        #expect(metric.paceOrSpeed(meters: 1000, seconds: 1200).value == "2:00 /100m")
        #expect(metric.pace(meters: 100, seconds: 110) == "1:50")

        let us = DistanceUnits(sport: "Swim", isUS: true)
        #expect(us.splitName == "100 yd")
        #expect(us.distance(914.4) == "1000 yd")
        #expect(us.paceOrSpeed(meters: 914.4, seconds: 1200).value == "2:00 /100yd")
    }

    @Test func runsSplitPerKilometerOrMile() {
        #expect(DistanceUnits(sport: "Run", isUS: false).paceOrSpeed(meters: 5000, seconds: 1500).value == "5:00 /km")
        #expect(DistanceUnits(sport: "Run", isUS: true).splitMeters == 1_609.344)
    }
}

/// Calculations checked against the numbers published in the papers and tables they come from.
struct PublishedReferenceTests {
    /// Tanaka, Monahan & Seals 2001 (JACC 37:153): 208 − 0.7 × age; the paper's example is 166 bpm at 60.
    /// Cross-checked with maximal treadmill tests in the FRIEND registry (Kaminsky et al. 2015, Mayo Clin Proc
    /// 90:1515, Table 2): the prediction at each decade's midpoint is within one SD of the measured mean.
    @Test func maxHeartRateMatchesTanakaAndMeasuredFRIENDValues() throws {
        #expect(Resources.maxHeartRate(age: 60, highestRecorded: nil) == 166)
        // Decade → measured HRmax mean and SD for men, then women.
        let measured: [(age: Int, men: (Double, Double), women: (Double, Double))] = [
            (25, (190, 11), (189, 12)), (35, (185, 11), (184, 11)), (45, (176, 14), (176, 14)),
            (55, (168, 14), (167, 15)), (65, (158, 17), (157, 17)), (75, (147, 20), (147, 21)),
        ]
        for decade in measured {
            let predicted = try #require(Resources.maxHeartRate(age: decade.age, highestRecorded: nil))
            #expect(abs(predicted - decade.men.0) <= decade.men.1, "Men at \(decade.age)")
            #expect(abs(predicted - decade.women.0) <= decade.women.1, "Women at \(decade.age)")
        }
    }

    /// FRIEND registry 50th percentiles of measured treadmill VO₂ max (Kaminsky et al. 2015, Table 3).
    @Test func vo2MaxNormIsTheFRIENDMedian() {
        let men = [48.0, 42.4, 37.8, 32.6, 28.2, 24.4]
        let women = [37.6, 30.2, 26.7, 23.4, 20.0, 18.3]
        for (index, age) in [25, 35, 45, 55, 65, 75].enumerated() {
            #expect(HealthAge.expectedVO2Max(age: age, sex: .male) == men[index], "Men at \(age)")
            #expect(HealthAge.expectedVO2Max(age: age, sex: .female) == women[index], "Women at \(age)")
        }
    }

    /// Cooper Institute norms for men, lower bounds of Fair, Good, Excellent and Superior, ages 13–19 to 60+.
    /// The women's rows aren't covered: no source confirming them has been found yet (#74).
    @Test func vo2MaxZonesMatchTheCooperTableForMen() {
        let rows: [(age: Int, bounds: [Double])] = [
            (16, [38.4, 45.2, 51.0, 56.0]), (25, [36.5, 42.5, 46.5, 52.5]), (35, [35.5, 41.0, 45.0, 49.5]),
            (45, [33.6, 39.0, 43.8, 48.1]), (55, [31.0, 35.8, 41.0, 45.4]), (65, [26.1, 32.3, 36.5, 44.3]),
        ]
        for row in rows {
            #expect(VO2MaxZones.bounds(age: row.age, sex: .male) == row.bounds, "Men at \(row.age)")
        }
    }

    /// Daniels & Gilbert (1979) equivalent race times for VDOT 30–70 (5K, 10K, half marathon, marathon), as the
    /// published equations give them in VDOT calculators. The printed tables in Daniels' Running Formula round
    /// a few seconds differently (`matchesDanielsTables` checks those).
    @Test func raceTimesMatchTheDanielsTable() {
        let table: [(vdot: Double, times: [TimeInterval])] = [
            (30, [30 * 60 + 41, 3600 + 3 * 60 + 49, 2 * 3600 + 21 * 60 + 17, 4 * 3600 + 49 * 60 + 49]),
            (40, [24 * 60 + 6, 50 * 60 + 1, 3600 + 50 * 60 + 54, 3 * 3600 + 49 * 60 + 37]),
            (50, [19 * 60 + 56, 41 * 60 + 20, 3600 + 31 * 60 + 31, 3 * 3600 + 10 * 60 + 40]),
            (60, [17 * 60 + 3, 35 * 60 + 22, 3600 + 18 * 60 + 9, 2 * 3600 + 43 * 60 + 22]),
            (70, [14 * 60 + 56, 31 * 60 + 1, 3600 + 8 * 60 + 23, 2 * 3600 + 23 * 60 + 13]),
        ]
        for row in table {
            for (distance, published) in zip(RacePredictor.distances, row.times) {
                let time = RacePredictor.time(meters: distance.meters, vo2Max: row.vdot)
                #expect(abs(time - published) <= 1, "VDOT \(row.vdot) \(distance.name)")
            }
        }
    }

    /// Edwards (1993): zones at 50, 60, 70, 80 and 90% of max heart rate, weighted 1–5.
    @Test func zonesAndTRIMPFollowEdwards() {
        #expect(HeartRateZones.zone(99.9, maxHeartRate: 200) == nil)
        for (zone, share) in [0.5, 0.6, 0.7, 0.8, 0.9].enumerated() {
            #expect(HeartRateZones.zone(200 * share, maxHeartRate: 200) == zone + 1)
        }
        // 10 minutes in each zone: 10 × (1 + 2 + 3 + 4 + 5).
        #expect(TrainingEffect.edwardsTRIMP(timeInZones: Array(repeating: 600, count: 5)) == 150)
        #expect(TrainingEffect.edwardsTRIMP(timeInZones: [0, 0, 45 * 60, 0, 0]) == 135)
    }

    /// ACSM (Garber et al. 2011, Med Sci Sports Exerc 43:1334, Table 1): moderate is 40–59% of heart rate reserve,
    /// vigorous 60–89%. WHO 2020 (Bull et al., Br J Sports Med 54:1451): 150 minutes of moderate activity a week,
    /// or 75 of vigorous, so a vigorous minute counts as two.
    @Test func intensityMinutesFollowACSMAndWHO() {
        // Resting 50, max 190: reserve 140, so moderate from 106 bpm and vigorous from 134.
        func minutes(_ heartRate: Double, bins: Int = 1) -> Double {
            let values = (0..<bins).map { TimedValue(date: Date(timeIntervalSince1970: Double($0) * 300), value: heartRate) }
            return IntensityMinutes.total(heartRate: values, restingHeartRate: 50, maxHeartRate: 190)
        }
        #expect(minutes(105.9) == 0)
        #expect(minutes(106) == 5)
        #expect(minutes(133.9) == 5)
        #expect(minutes(134) == 10)
        // 75 vigorous minutes meet the weekly target, as do 150 moderate ones.
        #expect(minutes(150, bins: 15) == IntensityMinutes.weeklyTarget)
        #expect(minutes(120, bins: 30) == IntensityMinutes.weeklyTarget)
    }
}
