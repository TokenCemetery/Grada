import Foundation
import SwiftData
import Testing
@testable import Grada

@MainActor
struct HomeLayoutTests {
    private func kinds(_ rows: [HomeRow<CardID>]) -> [HomeRow<CardKind>] {
        rows.map {
            switch $0 {
            case .cards(let cards): .cards(cards.map(\.kind))
            case .big(let card, let beside): .big(card.kind, beside: beside.map(\.kind))
            }
        }
    }

    @Test func squaresPairUpAndWideCardsFillARow() {
        let rows = HomeLayout.rows(for: [CardKind.sleepStages, .restingHeartRate, .hrv, .steps, .lastWorkout, .activeEnergy])
        #expect(rows == [.cards([.sleepStages]), .cards([.restingHeartRate, .hrv]), .cards([.steps]), .cards([.lastWorkout]), .cards([.activeEnergy])])
    }

    /// A wide card fills a row alone in 2 columns and takes two of 3 beside a square, so no row is left short.
    @Test(arguments: CardPersona.allCases, [2, 3])
    func personaFillsEveryRow(persona: CardPersona, columns: Int) {
        for row in HomeLayout.rows(for: persona.cards, columns: columns) {
            guard case .cards(let cards) = row else {
                Issue.record("\(persona) has a big card, which fills rows differently")
                continue
            }
            let squares = cards.count { $0.size == .square }
            let wides = cards.count - squares
            #expect(squares + 2 * wides == columns, "\(persona) in \(columns) columns: \(cards.map(\.kind))")
        }
    }

    @Test func healthPersonaLayout() {
        #expect(kinds(HomeLayout.rows(for: CardPersona.health.cards)) == [
            .cards([.recovery, .resources]), .cards([.strain, .steps]), .cards([.sleepStages]),
            .cards([.sleepScore, .sleepNeed]), .cards([.lastWorkout]), .cards([.exerciseMinutes, .hrvStatus]),
        ])
    }

    @Test func threeColumnsPutAWideCardBesideTheNextSquare() {
        #expect(kinds(HomeLayout.rows(for: CardPersona.health.cards, columns: 3)) == [
            .cards([.recovery, .resources, .strain]), .cards([.steps, .sleepStages]),
            .cards([.sleepScore, .sleepNeed, .exerciseMinutes]), .cards([.lastWorkout, .hrvStatus]),
        ])
    }

    @Test func threeColumnsPutASquareBeforeAWideCard() {
        let rows = HomeLayout.rows(for: [CardKind.hrvStatus, .recovery, .steps, .activeEnergy, .lastWorkout, .hrv], columns: 3)
        #expect(rows == [.cards([.hrvStatus, .recovery, .steps]), .cards([.activeEnergy, .lastWorkout]), .cards([.hrv])])
    }

    @Test func threeColumnsFillAShortRowWithALaterSquare() {
        let rows = HomeLayout.rows(for: [CardKind.steps, .hrv, .lastWorkout, .recovery], columns: 3)
        #expect(rows == [.cards([.steps, .hrv, .recovery]), .cards([.lastWorkout])])
    }

    @Test func threeColumnsStackTwoSquaresBesideABigCard() {
        let rows = HomeLayout.rows(for: [CardKind.last30Days, .steps, .hrv, .recovery], columns: 3)
        #expect(rows == [.big(.last30Days, beside: [.steps, .hrv]), .cards([.recovery])])
    }

    @Test func bigCardTakesTheFullWidthWithoutTwoSquares() {
        let rows = HomeLayout.rows(for: [CardKind.last30Days, .steps], columns: 3)
        #expect(rows == [.cards([.last30Days]), .cards([.steps])])
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
        guard case .bars(let shares, 1, let ratings?) = week.chart else { Issue.record("\(week.chart)"); return }
        #expect(ratings.count == shares.count)
        #expect(shares.allSatisfy { ($0 ?? 0) <= 1 }, "Each bar is the share of inputs in range")
        #expect(week.rating.map(\.title) == week.value)
    }

    @Test func scoresAreRated() async throws {
        for kind in [CardKind.resources, .hrvStatus, .vo2Max] {
            let snapshot = try await builder.snapshot(for: kind)
            #expect(snapshot.rating != nil, "\(kind) has no rating")
        }
    }
}

struct RatingTests {
    @Test func resourcesBands() {
        #expect([Resources.rating(80), Resources.rating(50), Resources.rating(20)] == [.good, .fair, .poor])
        #expect([Resources.rating(67), Resources.rating(66), Resources.rating(34), Resources.rating(33)] == [.good, .fair, .fair, .poor])
    }

    @Test func wristTempOnlyFlagsARise() {
        let normal = 35.2...36.0
        #expect(DayRatings.range(34.6, normal: normal, higherIsBetter: false) == .good)
        #expect(DayRatings.range(35.6, normal: normal, higherIsBetter: false) == .good)
        #expect(DayRatings.range(36.1, normal: normal, higherIsBetter: false) == .fair)
        #expect(DayRatings.range(36.4, normal: normal, higherIsBetter: false) == .poor)
    }

    @Test func activityDaysRateStepsAgainstThatDaysGoal() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let day = { calendar.date(byAdding: .day, value: $0, to: today)! }
        let goals = GoalHistory([GoalEntry(metric: .steps, value: 6_000, effectiveFrom: day(-2), reason: .edit)])
        let series = [DayValue(day: day(-4), value: 9_000), DayValue(day: day(-3), value: nil),
                      DayValue(day: day(-2), value: 6_000), DayValue(day: day(-1), value: 4_000),
                      DayValue(day: today, value: 3_000)]
        let ratings = DayRatings.rateSteps(series, goals: goals, today: today)
        #expect(ratings[day(-4)] == .fair, "Before any goal, 10,000 steps")
        #expect(ratings[day(-3)] == nil, "No steps, no rating")
        #expect(ratings[day(-2)] == .good)
        #expect(ratings[day(-1)] == .poor)
        #expect(ratings[today] == nil, "Today isn't over")
        let reached = DayRatings.rateSteps([DayValue(day: today, value: 6_500)], goals: goals, today: today)
        #expect(reached[today] == .good)
    }

    @Test func vo2MaxZonesFollowFRIENDPercentiles() {
        let men = VO2MaxZones.bounds(age: 25, sex: .male)
        #expect(men == [40.1, 48.0, 55.2, 61.8])
        #expect(VO2MaxZones.zone(40.0, bounds: men) == .poor)
        #expect(VO2MaxZones.zone(48.0, bounds: men) == .good)
        #expect(VO2MaxZones.zone(65, bounds: men) == .superior)
        #expect(VO2MaxZones.bounds(age: 18, sex: .female) == VO2MaxZones.bounds(age: 25, sex: .female))
        #expect(VO2MaxZones.bounds(age: 85, sex: .male) == VO2MaxZones.bounds(age: 75, sex: .male))
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
        for kind in CardKind.allCases {
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
    private let container: ModelContainer
    private let context: ModelContext
    private let importer: HealthImporter

    init() throws {
        container = try ModelContainer(
            for: HomeCard.self, DaySummary.self, WorkoutRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        let timeline = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        importer = HealthImporter(sources: [], fitFiles: FITFileSource(timelineURL: timeline), container: container)
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

    private func workout(_ id: String, averageHeartRate: Double? = 140) -> WorkoutSummary {
        WorkoutSummary(id: id, start: day(0).addingTimeInterval(3600), duration: 1800, name: "Run",
                       symbol: "figure.run", energyKcal: 300, averageHeartRate: averageHeartRate)
    }

    private let health = HealthKitReader.sourceID

    @Test func savesOnlyDaysWithDataAndUpdatesInPlace() async throws {
        try await importer.save(batch(steps: [nil, 4000, 5000]), from: health)
        #expect(try context.fetchCount(FetchDescriptor<DaySummary>()) == 2)

        try await importer.save(batch(steps: [nil, 4000, 7000]), from: health)
        let summaries = try context.fetch(FetchDescriptor<DaySummary>(sortBy: [SortDescriptor(\.day)]))
        #expect(summaries.map(\.steps) == [4000, 7000])
    }

    @Test func removesDuplicateDays() async throws {
        let key = DayKey.make(today, calendar: calendar)
        context.insert(DaySummary(day: today, dayKey: key, source: health))
        context.insert(DaySummary(day: today, dayKey: key, source: health))
        try context.save()
        try await importer.save(batch(steps: [6000]), from: health)
        #expect(try context.fetchCount(FetchDescriptor<DaySummary>()) == 1)
    }

    /// A day imported 7 hours further east starts 7 hours earlier, before today's start here (#118).
    @Test func findsDaysStoredInAnotherTimeZone() async throws {
        let east = DaySummary(day: today.addingTimeInterval(-7 * 3600), dayKey: DayKey.make(today, calendar: calendar), source: health)
        east.steps = 3000
        context.insert(east)
        try context.save()
        #expect(try await StoredHealthData(container: container).daily(.steps, days: 1).map(\.value) == [3000])

        try await importer.save(batch(steps: [6000]), from: health)
        #expect(try context.fetch(FetchDescriptor<DaySummary>()).map(\.steps) == [6000])
    }

    @Test func syncsWorkoutsWithAppleHealth() async throws {
        try await importer.save(batch(steps: [1000], workouts: [workout("a"), workout("b")]), from: health)
        try await importer.save(batch(steps: [1000], workouts: [workout("b")]), from: health)
        let records = try context.fetch(FetchDescriptor<WorkoutRecord>())
        #expect(records.map(\.healthID) == ["b"])
    }

    @Test func storedDataFeedsCards() async throws {
        try await importer.save(batch(steps: [8000, 9000]), from: health)
        let values = try await StoredHealthData(container: container).daily(.steps, days: 3)
        #expect(values.map(\.value) == [nil, 8000, 9000])
    }

    @Test func storesOvernightVitals() async throws {
        var batch = batch(steps: [8000])
        batch.overnight = [OvernightVitals(wakeDay: today, hrv: 64, heartRate: 49)]
        try await importer.save(batch, from: health)
        let overnight = try await StoredHealthData(container: container).overnight(days: 2)
        #expect(overnight.map(\.hrv) == [nil, 64])
        #expect(overnight.map(\.heartRate) == [nil, 49])
    }

    @Test func savingOneSourceLeavesOthersAlone() async throws {
        try await importer.save(batch(steps: [1000], workouts: [workout("a")]), from: health)
        try await importer.save(batch(steps: [2000], workouts: [workout("x")]), from: "other")
        try await importer.save(batch(steps: [3000]), from: "other")
        let records = try context.fetch(FetchDescriptor<WorkoutRecord>())
        #expect(records.map(\.healthID) == ["a"])
        #expect(records.map(\.source) == [health])
        let summaries = try context.fetch(FetchDescriptor<DaySummary>(sortBy: [SortDescriptor(\.source)]))
        #expect(summaries.map(\.steps) == [1000, 3000])
    }

    @Test func preferredSourceWinsAndOthersFillGaps() async throws {
        try await importer.save(batch(steps: [nil, 5000]), from: "other")
        try await importer.save(batch(steps: [4000, 6000]), from: "preferred")
        let stored = StoredHealthData(container: container, sources: [FakeSource(id: "preferred")])
        #expect(try await stored.daily(.steps, days: 2).map(\.value) == [4000, 6000])

        let reversed = StoredHealthData(container: container, sources: [FakeSource(id: "other"), FakeSource(id: "preferred")])
        #expect(try await reversed.daily(.steps, days: 2).map(\.value) == [4000, 5000])
    }

    @Test func eachSleepComesWholeFromTheFirstSourceWithIt() async throws {
        let hour: TimeInterval = 3600
        let night = { (wake: Int, stage: SleepStage?) in
            [SleepPeriod(start: self.day(wake) - hour, end: self.day(wake) + 3 * hour, stage: stage),
             SleepPeriod(start: self.day(wake) + 3 * hour, end: self.day(wake) + 7 * hour, stage: stage == nil ? nil : .rem)]
        }
        let nap = SleepPeriod(start: day(0) + 13 * hour, end: day(0) + 14 * hour, stage: .core)
        let health = FakeSource(id: HealthKitReader.sourceID)
        health.sleep = night(-1, .core) + [nap]
        let garmin = FakeSource(id: GarminSource.sourceID)
        garmin.sleep = [SleepPeriod(start: day(-1) - 2 * hour, end: day(-1) + 6 * hour, stage: nil),
                        SleepPeriod(start: day(0) - 2 * hour, end: day(0) + 6 * hour, stage: nil)]
        let files = FakeSource(id: FITImport.sourceID)
        files.sleep = night(0, .deep)
        let stored = StoredHealthData(container: container, sources: [health, garmin, files])

        // Apple Health's night and nap, and Garmin's night Apple Health lacks; stages from the FIT file aren't mixed in.
        #expect(try await stored.sleepPeriods(in: DateInterval(start: day(-2), end: .now))
                == night(-1, .core) + [garmin.sleep[1], nap])
    }

    @Test func unreadableFITTimelineIsReplacedByTheNextImport() async throws {
        let timeline = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not JSON".utf8).write(to: timeline)
        let window = DateInterval(start: day(-1), end: day(1))
        #expect(try await FITFileSource(timelineURL: timeline).sleepPeriods(in: window).isEmpty)

        var writer = FITWriter()
        writer.fileID()
        writer.message(275, [(253, 4, FITWriter.time(day(0) - 3600)), (0, 1, 2)])
        writer.message(275, [(253, 4, FITWriter.time(day(0) + 6 * 3600)), (0, 1, 1)])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fit")
        try writer.bytes.write(to: file)
        _ = try await FITFileSource(timelineURL: timeline).read([file])
        #expect(try await FITFileSource(timelineURL: timeline).sleepPeriods(in: window)
                == [SleepPeriod(start: day(0) - 3600, end: day(0) + 6 * 3600, stage: .core)])
    }

    @Test func importedFITNightReachesSleepScore() async throws {
        // A week of 22:00 to 07:00 nights, each with two 6-minute awakenings: only a stage timeline counts them.
        // One night per file, as watches export them.
        let hour: TimeInterval = 3600
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for wake in -7...(-1) {
            var writer = FITWriter()
            writer.fileID()
            let bed = day(wake) - 2 * hour
            for (offset, level) in [(0, 2), (3 * hour, 1), (3 * hour + 360, 3), (5 * hour, 1), (5 * hour + 360, 4), (9 * hour, 1)] as [(TimeInterval, Int64)] {
                writer.message(275, [(253, 4, FITWriter.time(bed + offset)), (0, 1, level)])
            }
            try writer.bytes.write(to: folder.appendingPathComponent("sleep\(wake).fit"))
        }
        _ = try await importer.importFiles([folder])
        _ = try await importer.importFiles([folder])

        let stored = StoredHealthData(container: container, sources: importer.liveSources)
        let lastNight = try await stored.sleepPeriods(in: DateInterval(start: day(-2) + 12 * hour, end: day(-1) + 12 * hour))
        #expect(lastNight.map(\.stage) == [.core, .awake, .deep, .awake, .rem], "Importing the file again keeps one timeline")

        var builder = SnapshotBuilder(source: stored)
        builder.now = day(-1) + 12 * hour
        let result = try #require(try await builder.sleepScoreDays(1).first?.result)
        #expect(result.reason == "Woke up often")
    }

    @Test func heartRateComesPerDayFromTheFirstSourceWithIt() async throws {
        let hour = { (day: Int, bpm: Double) in TimedValue(date: self.day(day).addingTimeInterval(3600), value: bpm) }
        let health = FakeSource(id: HealthKitReader.sourceID)
        health.heartRate = [hour(-1, 60)]
        let garmin = FakeSource(id: "garminConnect")
        garmin.heartRate = [hour(-2, 70), hour(-1, 71), hour(0, 72)]
        let stored = StoredHealthData(container: container, sources: [health, garmin])
        let window = DateInterval(start: day(-2), end: day(1))

        #expect(try await stored.heartRate(in: window) == [hour(-2, 70), hour(-1, 60), hour(0, 72)])
        #expect(garmin.heartRateAsked == [window])

        health.heartRate = [hour(-2, 60), hour(-1, 61), hour(0, 62)]
        _ = try await stored.heartRate(in: window)
        #expect(garmin.heartRateAsked.count == 1, "Not asked when Apple Health has every day")
    }

    @Test func importedWorkoutGetsHeartRateOverItsTime() async throws {
        let health = FakeSource(id: HealthKitReader.sourceID)
        let garmin = FakeSource(id: "garminConnect")
        let start = day(-1).addingTimeInterval(8 * 3600)
        garmin.heartRate = [TimedValue(date: start.addingTimeInterval(-600), value: 70),
                            TimedValue(date: start.addingTimeInterval(300), value: 140),
                            TimedValue(date: start.addingTimeInterval(900), value: 160)]
        let stored = StoredHealthData(container: container, sources: [health, garmin])

        for source in ["garminConnect", "fitFiles"] {
            let workout = WorkoutSummary(id: source, start: start, duration: 1800, name: "Run", symbol: "figure.run",
                                         energyKcal: nil, averageHeartRate: nil, source: source)
            let detail = try await stored.workoutDetail(workout)
            #expect(detail.heartRate.map(\.value) == [140, 160], "\(source)")
            #expect(detail.maxHeartRate == 160)
        }
    }

    @Test func enteredProfileStandsInForAppleHealth() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var stored = StoredHealthData(container: container, sources: [FakeSource(id: HealthKitReader.sourceID)])
        stored.defaults = defaults
        #expect(try await stored.age() == nil)
        #expect(try await stored.biologicalSex() == nil)

        defaults.set(calendar.date(byAdding: .year, value: -40, to: day(-1))!.timeIntervalSince1970, forKey: EnteredProfile.birthDateKey)
        defaults.set(BiologicalSex.female.rawValue, forKey: EnteredProfile.sexKey)
        #expect(try await stored.age() == 40)
        #expect(try await stored.biologicalSex() == .female)
        // Entered values aren't a source's (#121).
        #expect(stored.providesProfile() == (age: false, sex: false))
        #expect(try await HealthProfile.load(from: stored).maxHeartRate == Resources.maxHeartRate(age: 40, highestRecorded: nil))
    }

    @Test func sameNightFromTwoSourcesCountsOnce() async throws {
        var first = batch(steps: [nil])
        first.sleepNights = [SleepNight(wakeDay: today, stages: [.core: 5 * 3600, .deep: 3600], unspecified: 0)]
        var second = batch(steps: [nil])
        second.sleepNights = [SleepNight(wakeDay: today, stages: [:], unspecified: 8 * 3600)]
        try await importer.save(first, from: "preferred")
        try await importer.save(second, from: "other")
        let nights = try await StoredHealthData(container: container, sources: [FakeSource(id: "preferred")]).sleepNights(days: 1)
        #expect(nights.map(\.asleep) == [6 * 3600])
    }

    @Test func sameWorkoutFromTwoSourcesCountsOnce() async throws {
        try await importer.save(batch(steps: [nil], workouts: [workout("watch", averageHeartRate: nil)]), from: "preferred")
        try await importer.save(batch(steps: [nil], workouts: [workout("band")]), from: "other")
        let workouts = try await StoredHealthData(container: container, sources: [FakeSource(id: "preferred")]).workouts(days: 1)
        #expect(workouts.map(\.id) == ["watch"])
    }

    @Test func listsWhereDataCameFromByLastDay() async throws {
        var older = batch(steps: [5000, nil])
        older.origins[.steps] = [day(-1): ["iPhone", "Apple Watch"]]
        try await importer.save(older, from: health)
        var latest = batch(steps: [6000], workouts: [workout("run")])
        latest.workouts[0].origin = "Garmin Connect · Forerunner 265"
        latest.origins[.steps] = [today: ["Apple Watch"]]
        latest.origins[.hrv] = [today: ["Oura"]]
        try await importer.save(latest, from: health)

        let origins = try await StoredHealthData(container: container).origins()
        #expect(origins[.steps] == [DataOrigin(name: "Apple Watch", lastDay: today), DataOrigin(name: "iPhone", lastDay: day(-1))])
        #expect(origins[.hrv]?.map(\.name) == ["Oura"])
        #expect(origins[.workouts] == [DataOrigin(name: "Garmin Connect · Forerunner 265", lastDay: today)])
        #expect(origins[.sleep] == nil)
    }

    @Test func originsFollowTheSourceWhoseValuesAreUsed() async throws {
        var preferred = batch(steps: [4000])
        preferred.origins[.steps] = [today: ["Watch"]]
        var other = batch(steps: [5000])
        other.origins[.steps] = [today: ["Band"]]
        try await importer.save(other, from: "other")
        try await importer.save(preferred, from: "preferred")
        let origins = try await StoredHealthData(container: container, sources: [FakeSource(id: "preferred")]).origins()
        #expect(origins[.steps]?.map(\.name) == ["Watch"])
    }

    @Test func fileImportsAddUpAndRepeatingChangesNothing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let run = folder.appendingPathComponent("run.fit"), hrv = folder.appendingPathComponent("hrv.fit")
        try FITImportTests.activity(start: day(0).addingTimeInterval(3600)).write(to: run)
        try FITImportTests.hrv([(day(0).addingTimeInterval(2 * 3600), 50)]).write(to: hrv)

        _ = try await importer.importFiles([run])
        _ = try await importer.importFiles([hrv])
        _ = try await importer.importFiles([run, hrv])
        let stored = StoredHealthData(container: container)
        #expect(try await stored.workouts(days: 1).map(\.name) == ["Run"])
        #expect(try await stored.overnight(days: 1).map(\.hrv) == [50])
        #expect(try context.fetchCount(FetchDescriptor<DaySummary>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<WorkoutRecord>()) == 1)
    }

    @Test func importedHRVJoinsANightAppleHealthHasSleepFor() async throws {
        var fromHealth = batch(steps: [nil])
        fromHealth.overnight = [OvernightVitals(wakeDay: today, heartRate: 48, bedtime: today - 3600, wakeTime: today + 7 * 3600)]
        try await importer.save(fromHealth, from: health)
        var fromFile = batch(steps: [nil])
        fromFile.overnight = [OvernightVitals(wakeDay: today, hrv: 50)]
        try await importer.save(fromFile, from: FITImport.sourceID, merging: true)

        let nights = try await StoredHealthData(container: container, sources: [FakeSource(id: health)]).overnight(days: 1)
        #expect(nights.map(\.hrv) == [50])
        #expect(nights.map(\.heartRate) == [48])
        #expect(nights.map(\.bedtime) == [today - 3600])
    }

    @Test func reimportFillsInOriginOfKeptWorkouts() async throws {
        try await importer.save(batch(steps: [nil], workouts: [workout("run")]), from: health)
        var again = batch(steps: [nil], workouts: [workout("run")])
        again.workouts[0].origin = "Apple Watch"
        try await importer.save(again, from: health)
        #expect(try context.fetch(FetchDescriptor<WorkoutRecord>()).map(\.origin) == ["Apple Watch"])
    }
}

/// A source that only exists to set the merge order.
private final class FakeSource: HealthSource {
    let id: String
    var sleep: [SleepPeriod] = []
    var heartRate: [TimedValue] = []
    private(set) var heartRateAsked: [DateInterval] = []
    init(id: String) { self.id = id }
    var name: String { id }
    var isAvailable: Bool { true }
    func requestAuthorization() async throws {}
    func earliestSampleDate() async throws -> Date? { nil }
    func batch(for days: DateInterval) async throws -> HealthBatch { HealthBatch(days: days) }
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] {
        heartRateAsked.append(interval)
        return heartRate.filter { interval.contains($0.date) }
    }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { sleep }
    func hourly(_ metric: QuantityMetric, in interval: DateInterval) async throws -> [TimedValue] { [] }
    func workoutDetail(_ summary: WorkoutSummary) async throws -> WorkoutDetail { WorkoutDetail() }
    func highestHeartRate(days: Int) async throws -> Double? { nil }
    func age() -> Int? { nil }
    func biologicalSex() -> BiologicalSex? { nil }
}

struct SourceMergeTests {
    private let calendar = Calendar.current
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func workout(_ id: String, offset: TimeInterval = 0, duration: TimeInterval = 3600,
                         energy: Double? = 400, heartRate: Double? = 140) -> WorkoutSummary {
        WorkoutSummary(id: id, start: start + offset, duration: duration, name: "Run", symbol: "figure.run",
                       energyKcal: energy, averageHeartRate: heartRate)
    }

    @Test func overlappingWorkoutsKeepTheMostDetailed() {
        let watch = workout("watch")
        let band = workout("band", offset: 120, heartRate: nil)
        #expect(SourceMerge.uniqueWorkouts([band, watch]).map(\.id) == ["watch"])
    }

    @Test func workoutsThatBarelyOverlapStaySeparate() {
        let run = workout("run")
        let walk = workout("walk", offset: 3000, duration: 1800)
        #expect(SourceMerge.uniqueWorkouts([run, walk]).map(\.id) == ["walk", "run"])
    }

    @Test func shortWorkoutInsideALongOneIsADuplicate() {
        let long = workout("long", duration: 7200)
        let short = workout("short", offset: 600, duration: 1200)
        #expect(SourceMerge.uniqueWorkouts([long, short]).map(\.id) == ["long"])
    }

    private func days(_ count: Int, before end: Date) -> [Date] {
        (1...count).reversed().map { calendar.date(byAdding: .day, value: -$0, to: end)! }
    }

    @Test func mainAppIsTheOneWithMostDays() {
        let end = calendar.startOfDay(for: start)
        let recent = days(10, before: end)
        let values = [
            "watch": recent.map { DayValue(day: $0, value: 50) },
            "band": recent.suffix(3).map { DayValue(day: $0, value: 70) },
        ]
        #expect(SourceMerge.rankByCoverage(values, endingBefore: end, calendar: calendar) == ["watch", "band"])
    }

    @Test func otherAppsFillDaysTheMainAppMissed() {
        let end = calendar.startOfDay(for: start)
        let recent = days(3, before: end)
        let values = [
            "watch": [DayValue(day: recent[0], value: 50), DayValue(day: recent[2], value: 52)],
            "band": recent.map { DayValue(day: $0, value: 70) },
        ]
        let merged = SourceMerge.firstAvailable(values, order: ["watch", "band"], days: recent)
        #expect(merged.map(\.value) == [50, 70, 52])
    }

    @Test func coverageTiesBreakByNameForAStableOrder() {
        let end = calendar.startOfDay(for: start)
        let day = days(1, before: end)
        let values = ["b": day.map { DayValue(day: $0, value: 1) }, "a": day.map { DayValue(day: $0, value: 2) }]
        #expect(SourceMerge.rankByCoverage(values, endingBefore: end, calendar: calendar) == ["a", "b"])
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

struct SeparateSleepTests {
    private let calendar = Calendar.current
    private var midnight: Date { calendar.startOfDay(for: .now) }
    private func at(_ hours: Double) -> Date { midnight.addingTimeInterval(hours * 3600) }

    @Test func napStaysOutOfTheNight() {
        let night = SleepPeriod(start: at(-1), end: at(7), stage: .core)
        let nap = SleepPeriod(start: at(14), end: at(14.75), stage: .core)
        #expect(SleepNight.mainSleep([nap, night], start: \.start, end: \.end) == [night])

        let napHRV = TimedValue(date: at(14.5), value: 90)
        let vitals = OvernightVitals.make(hrv: [napHRV], heartRate: [napHRV], sleep: [night, nap], calendar: calendar)
        #expect(vitals == [OvernightVitals(wakeDay: midnight, bedtime: at(-1), wakeTime: at(7))])
    }

    @Test func eveningDozeStaysOutOfTheNight() {
        let doze = SleepPeriod(start: at(-4.5), end: at(-4), stage: nil)
        let night = SleepPeriod(start: at(-1), end: at(7), stage: nil)
        #expect(SleepNight.mainSleep([doze, night], start: \.start, end: \.end) == [night])
    }

    @Test func wakingInTheNightKeepsOneNight() {
        let periods = [SleepPeriod(start: at(-1), end: at(3), stage: .core), SleepPeriod(start: at(3), end: at(4), stage: .awake),
                       SleepPeriod(start: at(5), end: at(7), stage: .rem)]
        #expect(SleepNight.mainSleep(periods, start: \.start, end: \.end) == periods)
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

    /// A highest recorded heart rate barely above resting isn't used as max; Apple's exercise minutes are (#172).
    @Test func tooLowMaxHeartRateFallsBackToExerciseMinutes() async throws {
        let source = LowMaxSource()
        let minutes = try await SnapshotBuilder(source: source).intensityDays(7).map(\.value)
        #expect(minutes == (try await source.daily(.exerciseMinutes, days: 7)).map(\.value))
    }
}

/// Sample data with exercise minutes on every third day only, as if the watch was worn a third of the time.
private struct SparseExerciseSource: HealthDataSource {
    let base = SampleDataSource()
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] {
        let series = try await base.daily(metric, days: days)
        guard metric == .exerciseMinutes else { return series }
        return series.enumerated().map { DayValue(day: $0.element.day, value: $0.offset.isMultiple(of: 3) ? 30 : nil) }
    }
    func sleepNights(days: Int) async throws -> [SleepNight] { try await base.sleepNights(days: days) }
    func standHours(days: Int) async throws -> [DayValue] { try await base.standHours(days: days) }
    func overnight(days: Int) async throws -> [OvernightVitals] { try await base.overnight(days: days) }
    func workouts(days: Int) async throws -> [WorkoutSummary] { try await base.workouts(days: days) }
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] { try await base.heartRate(in: interval) }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { try await base.sleepPeriods(in: interval) }
    func age() async throws -> Int? { try await base.age() }
    func biologicalSex() async throws -> BiologicalSex? { try await base.biologicalSex() }
    func highestHeartRate(days: Int) async throws -> Double? { try await base.highestHeartRate(days: days) }
}

/// Sample data (resting about 54) with no age and a highest heart rate of 70, too close to resting to set zones.
private struct LowMaxSource: HealthDataSource {
    let base = SampleDataSource()
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] { try await base.daily(metric, days: days) }
    func sleepNights(days: Int) async throws -> [SleepNight] { try await base.sleepNights(days: days) }
    func standHours(days: Int) async throws -> [DayValue] { try await base.standHours(days: days) }
    func overnight(days: Int) async throws -> [OvernightVitals] { try await base.overnight(days: days) }
    func workouts(days: Int) async throws -> [WorkoutSummary] { try await base.workouts(days: days) }
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] { try await base.heartRate(in: interval) }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { try await base.sleepPeriods(in: interval) }
    func age() async throws -> Int? { nil }
    func biologicalSex() async throws -> BiologicalSex? { try await base.biologicalSex() }
    func highestHeartRate(days: Int) async throws -> Double? { 70 }
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

    @Test func averageInsideBaselineIsBalanced() async throws {
        let result = try #require(status(window: Array(repeating: 61, count: 7)))
        #expect(result.state == .balanced)
        #expect(abs(result.baseline.lowerBound - 58.487) < 0.01)
        #expect(abs(result.baseline.upperBound - 61.484) < 0.01)
    }

    @Test func averageAboveOrSlightlyBelowIsUnbalanced() async throws {
        #expect(try #require(status(window: Array(repeating: 66, count: 7))).state == .unbalanced)
        #expect(try #require(status(window: Array(repeating: 57.5, count: 7))).state == .unbalanced)
    }

    /// More than one SD (0.05 in ln terms) below the baseline mean: 54 ms is ln −0.105.
    @Test func averageWellBelowIsLow() async throws {
        #expect(try #require(status(window: Array(repeating: 54, count: 7))).state == .low)
        #expect(try #require(status(window: Array(repeating: 50, count: 7))).state == .low)
    }

    @Test func missingNightsAreSkipped() async throws {
        let result = try #require(status(window: [nil, 61, nil, 61, nil, 61, 61]))
        #expect(abs(result.average - 61) < 1e-9)
    }
}

@MainActor
struct RecoveryTests {
    /// ln SD ≈ 0.035, below the 0.05 floor, so HRV is off below the geometric mean × e^−0.025 ≈ 59.46 ms.
    private let hrvHistory: [Double] = [58, 62, 60, 64, 60, 58, 62, 60, 64, 62]
    /// Mean 54, SD ≈ 0.82 → 1.5 bpm floor, so resting HR is off above 54.75.
    private let rhrHistory: [Double] = [54, 55, 53, 54, 55, 53, 54, 54, 55, 53]
    /// Mean 14.5, SD ≈ 0.2 → 1 breath floor, so breathing is off above 15.5.
    private let breathingHistory: [Double] = [14.2, 14.6, 14.4, 14.8, 14.5, 14.3, 14.7, 14.5]

    private func input(hrv: Double? = 61, rhr: Double? = 54, asleep: TimeInterval? = 8 * 3600,
                       breathing: Double? = nil) -> Recovery.Input {
        Recovery.Input(hrv: hrv, hrvHistory: hrv == nil ? [] : hrvHistory, restingHeartRate: rhr,
                       restingHeartRateHistory: rhr == nil ? [] : rhrHistory, asleep: asleep,
                       respiratoryRate: breathing, respiratoryRateHistory: breathing == nil ? [] : breathingHistory)
    }

    @Test func calibratingWithoutEnoughHistory() {
        let input = Recovery.Input(hrv: 60, hrvHistory: [60, 61], restingHeartRate: 54, restingHeartRateHistory: [54], asleep: 8 * 3600)
        #expect(Recovery.status(input) == nil)
    }

    @Test func nothingOffIsGood() async throws {
        let result = try #require(Recovery.status(input(breathing: 14.6)))
        #expect(result == Recovery.Result(rating: .good, measured: 4, inRange: 4, reason: "Close to your normal"))
    }

    /// HRV and resting HR flag at the smallest worthwhile change, 0.5 SD, and only in the direction of fatigue.
    @Test func hrvAndRestingHeartRateFlagAtHalfASD() async throws {
        #expect(try #require(Recovery.status(input(hrv: 59.6))).rating == .good)
        #expect(try #require(Recovery.status(input(hrv: 59.3))).reason == "HRV below normal")
        #expect(try #require(Recovery.status(input(hrv: 80))).rating == .good, "High HRV isn't a fatigue sign")
        #expect(try #require(Recovery.status(input(rhr: 54.7))).rating == .good)
        #expect(try #require(Recovery.status(input(rhr: 55))).reason == "Resting HR high")
        #expect(try #require(Recovery.status(input(rhr: 48))).rating == .good, "Low resting HR isn't a fatigue sign")
    }

    /// AASM/SRS: at least 7 hours.
    @Test func sleepUnderSevenHoursIsOff() async throws {
        #expect(try #require(Recovery.status(input(asleep: 7 * 3600))).rating == .good)
        let short = try #require(Recovery.status(input(asleep: 7 * 3600 - 60)))
        #expect(short.rating == .fair)
        #expect(short.reason == "Short sleep")
    }

    @Test func onlyRaisedBreathingIsOff() async throws {
        #expect(try #require(Recovery.status(input(breathing: 15.4))).rating == .good)
        #expect(try #require(Recovery.status(input(breathing: 12))).rating == .good)
        #expect(try #require(Recovery.status(input(breathing: 15.6))).reason == "Breathing rate up")
    }

    @Test func twoOrMoreOffIsPoorAndCounted() async throws {
        let result = try #require(Recovery.status(input(hrv: 50, rhr: 58, asleep: 5 * 3600, breathing: 17)))
        #expect(result == Recovery.Result(rating: .poor, measured: 4, inRange: 0, reason: "HRV below normal · 3 more off"))
        #expect(try #require(Recovery.status(input(hrv: 50, asleep: 6 * 3600))).rating == .poor)
    }

    @Test func missingHRVUsesRestingHeartRateAlone() async throws {
        let result = try #require(Recovery.status(input(hrv: nil, asleep: nil)))
        #expect(result == Recovery.Result(rating: .good, measured: 1, inRange: 1, reason: "Close to your normal"))
    }
}

@MainActor
struct OvernightVitalsTests {
    @Test func usesOnlyReadingsTakenWhileAsleep() async throws {
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

    @Test func sleepCharges() async throws {
        let night = [SleepPeriod(start: start, end: hours(8), stage: .core)]
        let level = try #require(run(8, heartRate: 50, sleep: night, startLevel: 20).last).value
        #expect(level > 70)
    }

    @Test func calmDayDrainsSlowly() async throws {
        let level = try #require(run(10, heartRate: 65, startLevel: 80).last).value
        #expect(level < 80 && level > 50)
    }

    @Test func calmDaytimeRestCharges() async throws {
        let level = try #require(run(2, heartRate: 56, startLevel: 50).last).value
        #expect(level > 50)
    }

    @Test func workoutDrainsMoreThanRest() async throws {
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
    /// AASM/SRS (Watson et al. 2015): adults need at least 7 hours.
    @Test func needIsTheSevenHourGuideline() {
        #expect(SleepNeed.baseline == 7 * 3600)
        #expect(Recovery.minimumSleep == SleepNeed.baseline)
    }

    @Test func shortfallCountsOnlyNightsBelowTheirNeed() {
        let shortfalls = SleepNeed.shortfalls(asleep: [6 * 3600, nil, 7 * 3600, 9 * 3600, 7.5 * 3600],
                                              need: [7 * 3600, 7 * 3600, 7 * 3600, 7 * 3600, 8 * 3600])
        #expect(shortfalls.map { $0 / 3600 } == [1, 0, 0, 0, 0.5])
    }

    /// Van Dongen et al. 2003: deficits build over 14 nights. Long nights don't pay it back early.
    @Test func debtSumsTheLastFourteenNights() {
        let shortfalls: [TimeInterval] = [3600] + Array(repeating: 0, count: 13) + [1800, 0]
        let debt = SleepNeed.debt(shortfalls: shortfalls)
        #expect(debt[0] == 3600)
        #expect(debt[13] == 3600, "Still inside the 14-night window")
        #expect(debt[14] == 1800, "The first night has dropped out")
        #expect(debt[15] == 1800)
    }

    @Test func cardShowsNeedDebtAndAWeekOfShortfalls() async throws {
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .sleepNeed)
        #expect(snapshot.value == "7h 00m")
        guard case .bars(let shortfalls, _, _) = snapshot.chart else { Issue.record("\(snapshot.chart)"); return }
        #expect(shortfalls.count == 7)
    }
}

@MainActor
struct SleepConsistencyTests {
    /// Noon; nights are placed in hours after it, so 11 is 23:00 and 19 is 07:00 the next morning.
    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    private func night(_ day: Int, from start: Double, to end: Double, stage: SleepStage? = .core) -> SleepPeriod {
        SleepPeriod(start: noon.addingTimeInterval((Double(day) * 24 + start) * 3600),
                    end: noon.addingTimeInterval((Double(day) * 24 + end) * 3600), stage: stage)
    }

    @Test func identicalDaysScore100() async throws {
        let sleep = (0..<7).map { night($0, from: 11, to: 19) }
        #expect(try #require(SleepConsistency.index(sleep: sleep, start: noon)) == 100)
    }

    /// Phillips et al. 2017: 200 × P − 100. Alternating 23:00–07:00 and 01:00–09:00 nights differ in 4 of every
    /// 24 hours, so P = 20/24 and the index is 200 × 20/24 − 100 ≈ 66.7.
    @Test func twoHourShiftEveryOtherNightMatchesTheFormula() async throws {
        let sleep = (0..<7).map { $0.isMultiple(of: 2) ? night($0, from: 11, to: 19) : night($0, from: 13, to: 21) }
        let index = try #require(SleepConsistency.index(sleep: sleep, start: noon))
        #expect(abs(index - (200 * 20 / 24 - 100)) < 0.01)
    }

    /// Random states agree half the time: 200 × 0.5 − 100 = 0. Sleeping exactly the opposite half of each
    /// consecutive day gives −100.
    @Test func oppositeDaysScoreMinus100() async throws {
        let sleep = (0..<7).map { $0.isMultiple(of: 2) ? night($0, from: 0, to: 12) : night($0, from: 12, to: 24) }
        #expect(try #require(SleepConsistency.index(sleep: sleep, start: noon)) == -100)
    }

    @Test func daysWithoutARecordAreLeftOutAndTooFewGiveNothing() async throws {
        let missingOne = (0..<7).filter { $0 != 3 }.map { night($0, from: 11, to: 19) }
        #expect(try #require(SleepConsistency.index(sleep: missingOne, start: noon)) == 100, "Pairs with day 3 are skipped")
        let fourDays = (0..<4).map { night($0, from: 11, to: 19) }
        #expect(SleepConsistency.index(sleep: fourDays, start: noon) == nil)
    }

    @Test func awakeInBedCountsAsAwake() async throws {
        var sleep = (0..<7).map { night($0, from: 11, to: 19) }
        sleep.append(night(3, from: 14, to: 16, stage: .awake))
        // Day 3 is still asleep 01:00–03:00 in its core period, so the awake entry changes nothing.
        #expect(try #require(SleepConsistency.index(sleep: sleep, start: noon)) == 100)
    }

    /// UK Biobank (Windred et al. 2024): median 81.0, lower quartile 73.8.
    @Test func ratedAgainstUKBiobankAdults() {
        #expect(SleepConsistency.rating(81) == .good)
        #expect(SleepConsistency.rating(80.9) == .fair)
        #expect(SleepConsistency.rating(73.8) == .fair)
        #expect(SleepConsistency.rating(73.7) == .poor)
    }

    @Test func cardShowsTheIndexAndAWeek() async throws {
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .sleepConsistency)
        #expect(snapshot.value != nil && snapshot.value != "Calibrating")
        #expect(snapshot.rating != nil)
        guard case .bars(let days, 100, _) = snapshot.chart else { Issue.record("\(snapshot.chart)"); return }
        #expect(days.count == 7)
    }
}

@MainActor
struct HealthAgeTests {
    /// Exercise per week comes from the days with data, not all 30: 30 minutes on each worn day is 210 a week (#173).
    @Test func exerciseCountsOnlyDaysWithData() async throws {
        let inputs = try await SnapshotBuilder(source: SparseExerciseSource()).healthAgeInputs(age: 40, count: 1)
        #expect(inputs.last?.input.exerciseMinutesPerWeek == 210)
    }

    @Test func fitHabitsLowerHealthAge() async throws {
        let fit = HealthAge.Input(age: 40, sex: .male, sleepHours: 7.5, dailySteps: 11_000, restingHeartRate: 50,
                                  vo2Max: 50, exerciseMinutesPerWeek: 250)
        let unfit = HealthAge.Input(age: 40, sex: .male, sleepHours: 5.5, dailySteps: 3_000, restingHeartRate: 75,
                                    vo2Max: 30, exerciseMinutesPerWeek: 20)
        #expect(try #require(HealthAge.age(fit)) < 35)
        #expect(try #require(HealthAge.age(unfit)) > 50)
    }

    /// A typical adult who meets the guidelines is their own age.
    @Test func typicalAdultIsTheirOwnAge() async throws {
        let typical = HealthAge.Input(age: 45, sex: .female, sleepHours: 7.5, dailySteps: 7_803, restingHeartRate: 71,
                                      vo2Max: 26.7, exerciseMinutesPerWeek: 200)
        #expect(abs(try #require(HealthAge.age(typical)) - 45) < 0.001)
    }

    /// FRIEND registry medians: a 45-year-old woman at 26.7 is average, while a man at 26.7 is 11.1 below his.
    @Test func vo2MaxIsComparedWithTheNormForAgeAndSex() async throws {
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
/// Records the intervals its highest heart rate is asked for.
private final class HighestHeartRateSource: LiveHealthSource {
    let id = HealthKitReader.sourceID
    private(set) var asked: [DateInterval] = []
    func highestHeartRate(in interval: DateInterval) async throws -> Double? {
        asked.append(interval)
        return 190
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

    /// A past day's highest heart rate is read only up to that day, so a later maximum can't change its zones (#170).
    @Test func highestHeartRateEndsOnThePastDay() async throws {
        let calendar = Calendar.current
        let dayEnd = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: .now))!
        let live = HighestHeartRateSource()
        let stored = StoredHealthData(container: try ModelStores.makeInMemoryContainer(), sources: [live])
        let source = PastDaySource(base: stored, daysAgo: 3, dayEnd: dayEnd)
        #expect(try await source.highestHeartRate(days: 365) == 190)
        #expect(live.asked.last?.end == dayEnd)
        #expect(live.asked.last?.start == calendar.date(byAdding: .day, value: -365, to: dayEnd))
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

    /// Switching type while a load runs shows the type switched to, whichever load finishes last (#171).
    @Test func latestLoadWins() async {
        let model = CalendarModel(source: SampleDataSource())
        let first = Task { await model.load(.recovery, goals: GoalHistory()) }
        await Task.yield()
        await model.load(.activity, goals: GoalHistory())
        await first.value
        #expect(model.loadedMetric == .activity)
    }

    @Test func savedMetricsMapToTheirType() {
        #expect(CalendarMetric(rawValue: "healthStatus") == .health)
        #expect(CalendarMetric(rawValue: "hrv") == .health)
        #expect(CalendarMetric(rawValue: "restingHeartRate") == .health)
        #expect(CalendarMetric(rawValue: "sleep") == .recovery)
        #expect(CalendarMetric(rawValue: "steps") == .activity)
        #expect(CalendarMetric(rawValue: "training") == .activity)
        #expect(CalendarMetric.allCases.allSatisfy { CalendarMetric(rawValue: $0.rawValue) == $0 })
    }

    @Test func cardsOpenTheirType() {
        #expect(CardKind.healthStatus.calendarMetric == .health)
        #expect(CardKind.wristTemperature.calendarMetric == .health)
        #expect(CardKind.recovery.calendarMetric == .recovery)
        #expect(CardKind.sleepStages.calendarMetric == .recovery)
        #expect(CardKind.steps.calendarMetric == .activity)
        #expect(CardKind.last30Days.calendarMetric == .workouts)
        #expect(CardKind.lastWorkout.calendarMetric == .workouts)
        #expect(CardKind.weeklyTraining.calendarMetric == .activity)
        for metric in CalendarMetric.allCases {
            #expect(metric.kinds.allSatisfy { $0.calendarMetric == metric }, "\(metric) sheet holds only its own cards")
        }
    }

    @Test func recoveryAndActivityRateDaysAndWorkoutsDoesnt() async {
        let model = CalendarModel(source: SampleDataSource())
        await model.load(.recovery, goals: GoalHistory())
        #expect(!model.ratings.isEmpty)
        await model.load(.activity, goals: GoalHistory())
        #expect(!model.ratings.isEmpty)
        await model.load(.workouts, goals: GoalHistory())
        #expect(model.ratings.isEmpty, "Workouts draws sports, not ratings")
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

    /// Stored workouts are named from their type in the current language, so a language change doesn't list a sport
    /// twice (#196).
    @Test func storedWorkoutsTakeTheCurrentLanguagesName() throws {
        let start = calendar.startOfDay(for: .now).addingTimeInterval(8 * 3600)
        let walking = try #require(WorkoutNames.rawType(symbol: "figure.walk"))
        func stored(_ id: String, name: String, symbol: String, type: Int?) -> WorkoutSummary {
            WorkoutRecord(WorkoutSummary(id: id, start: start, duration: 1800, name: name, symbol: symbol, energyKcal: nil,
                                         averageHeartRate: nil, activityType: type)).summary
        }
        let walk = String(localized: "Walk", comment: "Workout type name")

        let typed = stored("a", name: "Ходьба", symbol: "figure.walk.retired", type: walking)
        #expect(typed.name == walk && typed.symbol == "figure.walk", "The type names it, whatever symbol was saved")
        let older = stored("b", name: "Ходьба", symbol: "figure.walk", type: nil)
        #expect(older.name == walk && older.activityType == walking, "Saved before types were kept: from its symbol")
        let unknown = stored("c", name: "Kitesurf", symbol: "figure.kite", type: nil)
        #expect(unknown.name == "Kitesurf" && unknown.activityType == nil, "Neither known: its stored name")
        let workout = String(localized: "Workout", comment: "Workout type name")
        #expect(WorkoutNames.info(rawType: -1).name == workout && WorkoutNames.info(rawType: 99_999).name == workout,
                "A type Grada can't read is a generic workout")

        let day = WorkoutDay.byDay([typed, older], calendar: calendar).values.first
        #expect(day?.sports.count == 1 && day?.workouts == 2)
    }

    @Test func daySheetListsThatDaysWorkouts() async throws {
        let model = CalendarModel(source: SampleDataSource())
        await model.load(.activity, goals: GoalHistory())
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

    /// A weekly total starts with the first whole week, so the period's cut-off week doesn't chart as a dip (#162).
    @Test func weeklyTotalsStartWithAWholeWeek() async throws {
        let trend = try #require(try await TrendBuilder(source: SampleDataSource()).trend(for: .weeklyTraining, period: .year))
        let firstDay = calendar.date(byAdding: .day, value: -(TrendPeriod.year.days - 1), to: today)!
        #expect(try #require(trend.points.first).date >= firstDay)
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

    /// Rated bars match the card's day colors, and weekly bars average them (#197).
    @Test func ratedTrendsColorDaysAndWeeks() async throws {
        let builder = TrendBuilder(source: SampleDataSource())
        let month = try #require(try await builder.trend(for: .recovery, period: .month))
        // Sample data is seeded from the oldest day asked for, so compare the same 30 days.
        let days = try await SnapshotBuilder(source: SampleDataSource()).recoveryDays(TrendPeriod.month.days)
        #expect(month.points.map(\.rating) == days.map { $0.result?.rating })
        #expect(month.points.contains { $0.rating != nil })
        let year = try #require(try await builder.trend(for: .recovery, period: .year))
        #expect(year.points.contains { $0.rating != nil })
        #expect(TrendBuilder.averageRating([.good, .poor]) == .fair)
        #expect(TrendBuilder.averageRating([.good, .good, .fair]) == .good)
        #expect(TrendBuilder.averageRating([.fair, .poor, .poor]) == .poor)
        #expect(TrendBuilder.averageRating([]) == nil)
    }

    /// Resources charts each day's peak, colored by the card's bands, for W and M only (#198).
    @Test func resourcesTrendShowsDailyPeaks() async throws {
        let builder = TrendBuilder(source: SampleDataSource())
        let week = try #require(try await builder.trend(for: .resources, period: .week))
        #expect(week.points.count == 7)
        #expect(week.points.contains { $0.value != nil })
        for point in week.points {
            #expect(point.rating == point.value.map { Resources.rating(Int($0.rounded())) })
            if let value = point.value { #expect((0...100).contains(value)) }
        }
        #expect(try await builder.trend(for: .resources, period: .month)?.points.count == 30)
        #expect(try await builder.trend(for: .resources, period: .year) == nil)
        #expect(TrendPeriod.available(for: .resources) == [.week, .month])
        #expect(TrendPeriod.available(for: .recovery) == TrendPeriod.allCases)
    }

    @Test func everyCardWithADetailScreenHasAnExplanation() {
        for kind in CardKind.gallery + [.healthStatus] where !kind.opensCalendar {
            #expect(!kind.explanation.isEmpty)
        }
    }

    /// Cards built from other inputs, plus those that grade a reading against a reference, must say what
    /// they rest on: published sources, or a note on what Grada estimated itself.
    @Test func everyCalculatedCardCitesSourcesOrSaysItEstimates() {
        let graded: [CardKind] = [.sleepNeed, .sleepConsistency, .vo2Max, .racePredictor]
        for kind in CardKind.allCases where !kind.basedOn.isEmpty || graded.contains(kind) {
            #expect(!kind.sources.isEmpty || kind.estimateNote != nil, "\(kind)")
        }
        for source in CardKind.allCases.flatMap(\.sources) {
            if let url = source.url { #expect(url.scheme == "https", "\(source.citation)") }
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
        let missed = Goals.adjustments(.intensityMinutes, history: goals, daily: week(ending: 7, [30, 30, 30, 30, nil, nil, nil]),
                                       today: day(7), calendar: calendar)
        #expect(missed.map(\.value) == [190])
    }

    /// A week with too few measured days doesn't lower a weekly goal; it could be missing data (#157).
    @Test func weeklyGoalIsNotLoweredFromAFewDays() {
        let goals = history([GoalEntry(metric: .intensityMinutes, value: 200, effectiveFrom: day(0), reason: .preset)])
        #expect(Goals.adjustments(.intensityMinutes, history: goals, daily: week(ending: 7, [20, nil, nil, nil, nil, nil, nil]),
                                  today: day(7), calendar: calendar).isEmpty)
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
        store.toggle(.illness, on: today)
        #expect(store.entries(on: today)[.illness] != nil)
        store.toggle(.illness, on: today)
        #expect(store.entries(on: today).isEmpty)
    }

    @Test func amountTagsStartAtTheirInitialAmountAndCanChange() {
        store.toggle(.alcohol, on: today)
        #expect(store.entries(on: today)[.alcohol]?.amount == 1)
        store.setAmount(3, for: .alcohol, on: today)
        #expect(store.entries(on: today)[.alcohol]?.amount == 3)
        #expect(JournalTag.alcohol.label(amount: 3) == "Alcohol · 3 drinks")
        #expect(JournalTag.illness.label(amount: nil) == "Illness")
    }

    @Test func entriesOfRemovedTagsAreIgnoredButKept() throws {
        let removed = JournalEntry(day: today, tag: .meditation, amount: nil)
        removed.tagRawValue = "stress"
        context.insert(removed)
        try context.save()
        #expect(store.entries(on: today).isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<JournalEntry>()) == 1)
    }

    @Test func tagsBelongToTheirOwnDay() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        store.toggle(.caffeine, on: yesterday)
        #expect(store.entries(on: today).isEmpty)
        #expect(store.entries(on: yesterday)[.caffeine] != nil)
    }

    @Test func duplicateEntriesFromSyncAreMerged() throws {
        context.insert(JournalEntry(day: today, tag: .meditation, amount: nil))
        context.insert(JournalEntry(day: today, tag: .meditation, amount: nil))
        try context.save()
        #expect(store.entries(on: today).count == 1)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<JournalEntry>()) == 1)
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

    @Test func trainingLoadSplitsByZone() {
        #expect(TrainingLoad.edwardsTRIMP(timeInZones: [0, 0, 0, 0, 0]) == 0)
        #expect(TrainingLoad.edwardsTRIMPByZone(timeInZones: [600, 0, 1200, 0, 300]) == [10, 0, 60, 0, 25])
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
        let metric = DistanceUnits(symbol: "figure.pool.swim", isUS: false)
        #expect(metric.splitMeters == 100)
        #expect(metric.splitName == "100 m")
        #expect(metric.distance(1500) == "\(1500.formatted()) m")
        #expect(metric.paceOrSpeed(meters: 1000, seconds: 1200).value == "2:00 /100m")
        #expect(metric.pace(meters: 100, seconds: 110) == "1:50")

        let us = DistanceUnits(symbol: "figure.pool.swim", isUS: true)
        #expect(us.splitName == "100 yd")
        #expect(us.distance(914.4) == "\(1000.formatted()) yd")
        #expect(us.paceOrSpeed(meters: 914.4, seconds: 1200).value == "2:00 /100yd")
    }

    @Test func runsSplitPerKilometerOrMile() {
        #expect(DistanceUnits(symbol: "figure.run", isUS: false).paceOrSpeed(meters: 5000, seconds: 1500).value == "5:00 /km")
        #expect(DistanceUnits(symbol: "figure.run", isUS: true).splitMeters == 1_609.344)
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

    /// Gompertz: adult mortality doubles about every 8 years (Finch et al. 1990), so a risk ratio of 2 is 8 years.
    @Test func riskRatiosTurnIntoYearsByTheMortalityDoublingTime() {
        #expect(HealthAge.years(riskRatio: 2) == 8)
        #expect(HealthAge.years(riskRatio: 1) == 0)
        #expect(HealthAge.years(riskRatio: 0.5) == -8)
    }

    /// Kodama et al. 2009: RR 0.87 per MET (3.5 ml/kg·min). Zhang et al. 2016: RR 1.09 per 10 bpm. Both against
    /// the norm for age and sex (FRIEND median VO₂ max, NHANES median resting pulse).
    @Test func healthAgeFitnessFollowsKodamaAndZhang() throws {
        func years(_ input: HealthAge.Input, _ name: String) -> Double? {
            HealthAge.impacts(input).first { $0.name == name }?.years
        }
        let fitter = try #require(years(HealthAge.Input(age: 35, sex: .male, vo2Max: 42.4 + 3.5), "VO₂ Max"))
        #expect(abs(fitter - 8 * log2(0.87)) < 1e-9)
        #expect(HealthAge.expectedRestingHeartRate(age: 35, sex: .male) == 69)
        #expect(HealthAge.expectedRestingHeartRate(age: 65, sex: .female) == 70)
        let faster = try #require(years(HealthAge.Input(age: 35, sex: .male, restingHeartRate: 79), "Resting HR"))
        #expect(abs(faster - 8 * log2(1.09)) < 1e-9)
    }

    /// Paluch et al. 2022: quartile medians 3553, 5801, 7842 and 10 901 steps, HRs 1, 0.60, 0.55 and 0.47.
    @Test func stepsRiskFollowsPaluchQuartiles() {
        #expect(HealthAge.stepsRisk(3_553) == 1)
        #expect(abs(HealthAge.stepsRisk(5_801) - 0.60) < 1e-9)
        #expect(abs(HealthAge.stepsRisk(7_842) - 0.55) < 1e-9)
        #expect(abs(HealthAge.stepsRisk(10_901) - 0.47) < 1e-9)
        #expect(HealthAge.stepsRisk(1_000) == 1, "Flat below the lowest median")
        #expect(HealthAge.stepsRisk(20_000) == 0.47, "Flat above the highest median")
        let between = HealthAge.stepsRisk((5_801 + 7_842) / 2)
        #expect(between < 0.60 && between > 0.55)
    }

    /// Cappuccio et al. 2010: short sleep RR 1.12, long sleep RR 1.30, against 7–8 hours.
    @Test func sleepRiskFollowsCappuccio() {
        #expect(HealthAge.sleepRisk(6.5) == 1.12)
        #expect(HealthAge.sleepRisk(7) == 1)
        #expect(HealthAge.sleepRisk(8) == 1)
        #expect(HealthAge.sleepRisk(9) == 1.30)
    }

    /// Arem et al. 2015, against the 150-minute guideline (HR 0.69 vs none): none is 1/0.69, below it 0.80/0.69,
    /// 2–3× the guideline 0.63/0.69.
    @Test func exerciseRiskFollowsArem() {
        #expect(abs(HealthAge.exerciseRisk(0) - 1 / 0.69) < 1e-9)
        #expect(abs(HealthAge.exerciseRisk(100) - 0.80 / 0.69) < 1e-9)
        #expect(HealthAge.exerciseRisk(150) == 1)
        #expect(HealthAge.exerciseRisk(299) == 1)
        #expect(abs(HealthAge.exerciseRisk(400) - 0.63 / 0.69) < 1e-9)
    }

    /// FRIEND registry (Kaminsky et al. 2015, Table 3): the 25th, 50th, 75th and 90th percentiles of measured
    /// treadmill VO₂ max start Fair, Good, Excellent and Superior, for each decade from 20–29 to 70–79.
    @Test func vo2MaxZonesMatchFRIENDTable3() {
        let men: [[Double]] = [
            [40.1, 48.0, 55.2, 61.8], [35.9, 42.4, 49.2, 56.5], [31.9, 37.8, 45.0, 52.1],
            [27.1, 32.6, 39.7, 45.6], [23.7, 28.2, 34.5, 40.3], [20.4, 24.4, 30.4, 36.6],
        ]
        let women: [[Double]] = [
            [30.5, 37.6, 44.7, 51.3], [25.3, 30.2, 36.1, 41.4], [22.1, 26.7, 32.4, 38.4],
            [19.9, 23.4, 27.6, 32.0], [17.2, 20.0, 23.8, 27.0], [15.6, 18.3, 20.8, 23.1],
        ]
        for (index, age) in [25, 35, 45, 55, 65, 75].enumerated() {
            #expect(VO2MaxZones.bounds(age: age, sex: .male) == men[index], "Men at \(age)")
            #expect(VO2MaxZones.bounds(age: age, sex: .female) == women[index], "Women at \(age)")
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
        #expect(TrainingLoad.edwardsTRIMP(timeInZones: Array(repeating: 600, count: 5)) == 150)
        #expect(TrainingLoad.edwardsTRIMP(timeInZones: [0, 0, 45 * 60, 0, 0]) == 135)
    }

    /// ACSM (Garber et al. 2011, Table 1): very light below 30% of heart rate reserve, light 30–39%, moderate
    /// 40–59%, vigorous 60–89% (near-maximal 90%+ is folded into vigorous).
    @Test func dayIntensityBandsFollowACSM() {
        // Resting 50, max 190: reserve 140, so light from 92 bpm, moderate from 106 and vigorous from 134.
        let expected: [(Double, DayIntensity.Band)] = [
            (91.9, .veryLight), (92, .light), (105.9, .light), (106, .moderate),
            (133.9, .moderate), (134, .vigorous), (190, .vigorous),
        ]
        for (heartRate, band) in expected {
            #expect(DayIntensity.band(heartRate, restingHeartRate: 50, maxHeartRate: 190) == band, "\(heartRate) bpm")
        }
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

struct DayIntensityTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// One reading every 5 minutes from `start`.
    private func readings(_ heartRates: [Double]) -> [TimedValue] {
        heartRates.enumerated().map { TimedValue(date: start.addingTimeInterval(Double($0.offset) * 300), value: $0.element) }
    }

    @Test func countsFiveMinutesPerReadingByBand() {
        let seconds = DayIntensity.time(heartRate: readings([60, 95, 95, 120, 150]), sleep: [], workouts: [],
                                        restingHeartRate: 50, maxHeartRate: 190)
        #expect(seconds == [.veryLight: 300, .light: 600, .moderate: 300, .vigorous: 300])
    }

    @Test func skipsSleepAndWorkoutsButNotAwakeInBed() {
        let sleep = [SleepPeriod(start: start, end: start.addingTimeInterval(600), stage: .core),
                     SleepPeriod(start: start.addingTimeInterval(600), end: start.addingTimeInterval(900), stage: .awake)]
        let workout = DateInterval(start: start.addingTimeInterval(900), duration: 600)
        let seconds = DayIntensity.time(heartRate: readings([55, 55, 60, 150, 150, 95]), sleep: sleep, workouts: [workout],
                                        restingHeartRate: 50, maxHeartRate: 190)
        #expect(seconds == [.veryLight: 300, .light: 300])
    }

    @MainActor
    @Test func cardShowsTodayAndAWeekOfBands() async throws {
        #expect(CardKind.gallery.contains(.dayIntensity))
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .dayIntensity, variant: .week)
        #expect(snapshot.value != nil)
        #expect(snapshot.comparison?.hasSuffix("very light") == true)
        guard case .intensity(let days) = snapshot.chart else { Issue.record("\(snapshot.chart)"); return }
        #expect(days.count == 7)
    }
}
