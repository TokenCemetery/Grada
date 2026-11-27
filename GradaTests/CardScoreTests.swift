import Foundation
import Testing
@testable import Grada

struct SleepScoreTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func period(_ fromMinute: Double, _ toMinute: Double, _ stage: SleepStage?) -> SleepPeriod {
        SleepPeriod(start: start.addingTimeInterval(fromMinute * 60), end: start.addingTimeInterval(toMinute * 60), stage: stage)
    }

    private func quality(asleepHours: Double = 8, wakeMinutes: Double = 10, awakenings: Int = 1) -> SleepScore.Quality {
        SleepScore.Quality(asleep: asleepHours * 3600, wakeAfterOnset: wakeMinutes * 60, longAwakenings: awakenings)
    }

    /// Gaps and awake periods between asleep stretches are time awake; only those over 5 minutes are awakenings.
    @Test func qualityCountsWakeBetweenSleep() throws {
        let night = [period(0, 120, .core), period(120, 126, .awake), period(126, 240, .deep),
                     period(243, 480, .rem), period(480, 490, .awake)]
        let quality = try #require(SleepScore.quality(night))
        #expect(quality.asleep == 471 * 60)
        #expect(quality.wakeAfterOnset == 9 * 60, "The final wake-up isn't WASO")
        #expect(quality.longAwakenings == 1)
    }

    @Test func noQualityWithoutStages() {
        #expect(SleepScore.quality([period(0, 480, nil)]) == nil)
        #expect(SleepScore.quality(SleepNight(wakeDay: start, stages: [:], unspecified: 8 * 3600)) == nil)
    }

    /// Garmin's API gives stage totals only: awake is WASO, and awakenings can't be counted, so that check is left out.
    @Test func stageTotalsScoreWithoutTheAwakeningsCheck() throws {
        let night = SleepNight(wakeDay: start, stages: [.deep: 3600, .core: 4 * 3600, .rem: 2.5 * 3600, .awake: 25 * 60], unspecified: 0)
        let quality = try #require(SleepScore.quality(night))
        #expect(quality == SleepScore.Quality(asleep: 7.5 * 3600, wakeAfterOnset: 25 * 60, longAwakenings: nil))
        let result = try #require(SleepScore.score(quality: quality, need: 7 * 3600, regularity: 85, age: 35))
        #expect(result == SleepScore.Result(score: 75, rating: .fair, reason: "Long time awake"))
    }

    @Test func everyIndicatorMetScores100() throws {
        let result = try #require(SleepScore.score(quality: quality(), need: 7 * 3600, regularity: 85, age: 35))
        #expect(result == SleepScore.Result(score: 100, rating: .good, reason: "All indicators met"))
    }

    /// NSF cut-offs: efficiency 85%, WASO 20 minutes (30 from 65), one awakening over 5 minutes (two from 65).
    @Test func nsfCutOffs() throws {
        let short = try #require(SleepScore.score(quality: quality(asleepHours: 6.9), need: 7 * 3600, regularity: 85, age: 35))
        #expect(short == SleepScore.Result(score: 80, rating: .fair, reason: "Short sleep"))
        let awake = try #require(SleepScore.score(quality: quality(wakeMinutes: 21), need: 7 * 3600, regularity: 85, age: 35))
        #expect(awake.reason == "Long time awake")
        #expect(try #require(SleepScore.score(quality: quality(wakeMinutes: 25), need: 7 * 3600, regularity: 85, age: 70)).rating == .good)
        #expect(try #require(SleepScore.score(quality: quality(wakeMinutes: 31), need: 7 * 3600, regularity: 85, age: 70)).reason == "Long time awake")
        // 90 minutes awake in 8 hours asleep is 84% efficiency and over 20 minutes of WASO.
        let restless = try #require(SleepScore.score(quality: quality(wakeMinutes: 90), need: 7 * 3600, regularity: 85, age: 35))
        #expect(restless == SleepScore.Result(score: 60, rating: .poor, reason: "Low sleep efficiency · 1 more"))
        #expect(try #require(SleepScore.score(quality: quality(awakenings: 2), need: 7 * 3600, regularity: 85, age: 35)).rating == .fair)
        #expect(try #require(SleepScore.score(quality: quality(awakenings: 2), need: 7 * 3600, regularity: 85, age: 70)).rating == .good)
    }

    @Test func irregularWeekIsMissed() throws {
        let result = try #require(SleepScore.score(quality: quality(), need: 7 * 3600, regularity: 70, age: 35))
        #expect(result.reason == "Irregular schedule")
    }

    @Test func calibratingWithoutRegularityOrStages() {
        #expect(SleepScore.score(quality: quality(), need: 7 * 3600, regularity: nil, age: 35) == nil)
        #expect(SleepScore.score(quality: nil, need: 7 * 3600, regularity: 85, age: 35) == nil)
    }

    @MainActor
    @Test func cardShowsLastNightWithAWeekOfBars() async throws {
        #expect(CardKind.gallery.contains(.sleepScore))
        // As of yesterday noon, so last night is complete whatever the time now (sample nights end at 07:00).
        var builder = SnapshotBuilder(source: SampleDataSource())
        builder.now = Calendar.current.date(byAdding: .hour, value: -12, to: Calendar.current.startOfDay(for: .now))!
        let snapshot = try await builder.snapshot(for: .sleepScore)
        // Sample nights wake for 5 minutes every 90, 25 minutes in all: over the 20-minute WASO cut-off.
        #expect(snapshot.value == "80")
        #expect(snapshot.comparison == "Long time awake")
        guard case .bars(let scores, let target, _) = snapshot.chart else { Issue.record("\(snapshot.chart)"); return }
        #expect(scores.count == 7)
        #expect(target == 100)
    }
}

struct StrainTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Edwards: max 200, so 10 minutes at 150 bpm (zone 3) score 30 and 5 minutes at 185 (zone 5) score 25.
    @Test func loadIsEdwardsTRIMPOverTheDay() {
        let readings = [TimedValue(date: start, value: 150), TimedValue(date: start + 300, value: 150),
                        TimedValue(date: start + 600, value: 185), TimedValue(date: start + 900, value: 80)]
        #expect(Strain.load(heartRate: readings, end: start + 1_200, maxHeartRate: 200) == 55)
    }

    @Test func ratioIsSevenDayAgainstTwentyEightDayAverage() throws {
        let loads: [Double?] = Array(repeating: 100, count: 21) + Array(repeating: 200, count: 7)
        let ratio = try #require(Strain.ratio(loads: loads, endingAt: 27))
        #expect(ratio.acute == 200)
        #expect(ratio.chronic == 125)
        #expect(ratio.value == 1.6)
    }

    @Test func calibratingWithoutThreeWeeksOfData() {
        let loads: [Double?] = Array(repeating: nil, count: 8) + Array(repeating: 100, count: 20)
        #expect(Strain.ratio(loads: loads, endingAt: 27) == nil)
        #expect(Strain.ratio(loads: Array(repeating: 100, count: 28) + [nil, nil, nil, nil], endingAt: 31) == nil,
                "Fewer than 4 of the last 7 days")
    }

    /// Foster 1998: monotony is the week's mean daily load over its standard deviation, strain the weekly load
    /// times monotony.
    @Test func monotonyAndStrainFollowFoster() throws {
        // The 7 days ending at index 7: mean 100, sample SD 20.
        let loads: [Double?] = [nil, 80, 120, 80, 120, 80, 120, 100]
        let week = try #require(Strain.week(loads: loads, endingAt: 7))
        #expect(week.load == 700)
        #expect(abs(week.monotony - 5) < 0.000_001)
        #expect(abs(week.strain - 3500) < 0.001)
        #expect(week.isMonotonous)
        #expect(Strain.week(loads: loads, endingAt: 6) == nil, "Needs a load on all 7 days")
        #expect(Strain.week(loads: Array(repeating: 100, count: 7), endingAt: 6) == nil, "No variation, no monotony")
        let varied = try #require(Strain.week(loads: [0, 200, 0, 200, 0, 200, 100], endingAt: 6))
        #expect(!varied.isMonotonous)
    }

    @Test func monotonyRecommendationAboveTwo() {
        #expect(Recommendations.monotony(2.0) == nil)
        #expect(Recommendations.monotony(2.1)?.text == "Mix hard and easy days")
    }

    /// Today's week ends yesterday, a past day's week on that day.
    @Test func todaysWeekEndsYesterday() async throws {
        let calendar = Calendar.current
        var builder = SnapshotBuilder(source: AlternatingLoadSource())
        builder.now = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: .now)!
        let days = try #require(try await builder.strainDays(2))
        #expect(days[1].week != nil)
        #expect(days[1].week == days[0].week)

        builder.now = calendar.date(byAdding: .day, value: -1, to: builder.now)!
        let past = try #require(try await builder.strainDays(2))
        #expect(past[1].week == days[0].week, "Yesterday's week ends yesterday when shown as a past day")
        #expect(past[1].week != past[0].week)
    }

    @MainActor
    @Test func monotonousWeekRecommendsMixingDays() async throws {
        let calendar = Calendar.current
        var builder = SnapshotBuilder(source: AlternatingLoadSource())
        builder.now = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: .now)!
        let snapshot = try await builder.snapshot(for: .strain)
        #expect(snapshot.rating == .good, "The load ratio is in the sweet spot, so it has no advice")
        #expect(snapshot.recommendation?.text == "Mix hard and easy days")

        builder.now = calendar.date(byAdding: .day, value: -1, to: builder.now)!
        #expect(try await builder.snapshot(for: .strain).recommendation == nil, "No advice on past days")
    }

    @MainActor
    @Test func detailChartsMonotonyAndStrain() async throws {
        let trends = try await TrendBuilder(source: AlternatingLoadSource()).extraTrends(for: .strain, period: .month)
        try #require(trends.count == 2)
        #expect(trends[0].title == "Training Monotony · High")
        #expect(trends[0].normalRange == 0...Strain.highMonotony)
        #expect(trends[1].title == "Training Strain")
        #expect(trends[0].points.dropLast().allSatisfy { $0.value != nil })
        #expect(trends[0].points.last?.value == nil, "Today's week ends yesterday, so today has no point")
    }

    @MainActor
    @Test func detailChartsLoadRatioOverZones() async throws {
        let source = AlternatingLoadSource()
        let trend = try #require(try await TrendBuilder(source: source).trend(for: .strain, period: .month))
        let days = try #require(try await SnapshotBuilder(source: source).strainDays(TrendPeriod.month.days))
        #expect(trend.points.map(\.value) == days.map { $0.ratio?.value }, "Each day plots its own ratio (#212)")
        #expect(trend.normalRange == nil)
        #expect(trend.zones.map(\.rating) == [.fair, .good, .fair, .poor])
        #expect(trend.zones[1].range == Strain.sweetSpot)
        #expect(trend.zones[3].range.lowerBound == Strain.dangerRatio)
    }

    /// Gabbett 2016: sweet spot 0.8–1.3, danger zone from 1.5.
    @Test func ratingFollowsGabbett() {
        #expect(Strain.rating(1.0) == .good)
        #expect(Strain.rating(0.8) == .good)
        #expect(Strain.rating(1.3) == .good)
        #expect(Strain.rating(0.7) == .fair)
        #expect(Strain.rating(1.4) == .fair)
        #expect(Strain.rating(1.5) == .poor)
        #expect(Strain.word(1.5) == "Very high")
        #expect(Strain.word(0.7) == "Low")
    }

    @MainActor
    @Test func cardShowsTodaysLoadAndTheRatio() async throws {
        #expect(CardKind.gallery.contains(.strain))
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .strain)
        #expect(snapshot.unit == "TRIMP")
        #expect(snapshot.comparison?.contains("ratio") == true, "\(snapshot.comparison ?? "")")
        guard case .bars(let loads, _, _) = snapshot.chart else { Issue.record("\(snapshot.chart)"); return }
        #expect(loads.count == 7)
    }
}

/// Heart rate at 150 bpm (zone 4 at age 30) every morning for 50 minutes on even days and 60 on odd ones, so
/// daily loads alternate 200 and 240: monotony about 10, ratio about 1.
private struct AlternatingLoadSource: HealthDataSource {
    let base = SampleDataSource()
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] {
        let calendar = Calendar.current
        var readings: [TimedValue] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            let start = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
            let ordinal = calendar.ordinality(of: .day, in: .era, for: day)!
            // Readings every 5 minutes, as a heart rate reading counts for at most `HeartRateZones.maxGap`.
            let minutes = ordinal.isMultiple(of: 2) ? 50 : 60
            readings += stride(from: 0, to: minutes, by: 5).map { TimedValue(date: start + Double($0 * 60), value: 150) }
            readings.append(TimedValue(date: start + Double(minutes * 60), value: 70))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return readings.filter { interval.contains($0.date) }
    }
    func age() async throws -> Int? { 30 }
    func highestHeartRate(days: Int) async throws -> Double? { nil }
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] { try await base.daily(metric, days: days) }
    func sleepNights(days: Int) async throws -> [SleepNight] { try await base.sleepNights(days: days) }
    func standHours(days: Int) async throws -> [DayValue] { try await base.standHours(days: days) }
    func overnight(days: Int) async throws -> [OvernightVitals] { try await base.overnight(days: days) }
    func workouts(days: Int) async throws -> [WorkoutSummary] { try await base.workouts(days: days) }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { try await base.sleepPeriods(in: interval) }
    func biologicalSex() async throws -> BiologicalSex? { try await base.biologicalSex() }
}

struct RecoveryTimeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    /// Seiler 2010: threshold from 82% of max heart rate, high from 88%.
    @Test func zonesFollowSeiler() {
        #expect(IntensityZones.zone(163, maxHeartRate: 200) == .low)
        #expect(IntensityZones.zone(164, maxHeartRate: 200) == .threshold)
        #expect(IntensityZones.zone(176, maxHeartRate: 200) == .high)
    }

    /// Stanley et al. 2013: up to 24 h after low, 24–48 h after threshold, at least 48 h after high intensity.
    @Test func hoursFollowIntensity() {
        let start = { (heartRate: Double?) in
            RecoveryTime.recoveredAt(workouts: [.init(end: self.hoursAgo(10), averageHeartRate: heartRate)],
                                     maxHeartRate: 200, now: self.now, wake: nil, morningRecovery: nil)
        }
        #expect(start(140) == hoursAgo(10 - 24))
        #expect(start(nil) == hoursAgo(10 - 24), "Without heart rate a workout counts as low")
        #expect(start(170) == hoursAgo(10 - 36))
        #expect(start(180) == hoursAgo(10 - 48))
    }

    @Test func latestRecoveryWinsAndEndsOnTime() {
        let workouts: [RecoveryTime.Workout] = [.init(end: hoursAgo(40), averageHeartRate: 180),
                                                .init(end: hoursAgo(2), averageHeartRate: 140)]
        #expect(RecoveryTime.recoveredAt(workouts: workouts, maxHeartRate: 200, now: now, wake: nil, morningRecovery: nil)
                == hoursAgo(2 - 24))
        #expect(RecoveryTime.recoveredAt(workouts: [.init(end: hoursAgo(30), averageHeartRate: 140)], maxHeartRate: 200,
                                         now: now, wake: nil, morningRecovery: nil) == nil)
    }

    /// Waking up still recovering with this morning's Recovery off runs on to the next morning.
    @Test func morningRecoveryExtendsToTheNextMorning() {
        let workouts: [RecoveryTime.Workout] = [.init(end: hoursAgo(30), averageHeartRate: 170)]
        let wake = hoursAgo(3)
        #expect(RecoveryTime.recoveredAt(workouts: workouts, maxHeartRate: 200, now: now, wake: wake, morningRecovery: .fair)
                == wake.addingTimeInterval(24 * 3600))
        #expect(RecoveryTime.recoveredAt(workouts: workouts, maxHeartRate: 200, now: now, wake: wake, morningRecovery: .good)
                == hoursAgo(30 - 36))
    }

    @MainActor
    @Test func cardBuildsFromSampleData() async throws {
        #expect(CardKind.gallery.contains(.recoveryTime))
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .recoveryTime)
        #expect(snapshot.value != nil)
        guard case .progress = snapshot.chart else { Issue.record("\(snapshot.chart)"); return }
    }
}

struct TrainingReadinessTests {
    private func input(sleep: DayRating? = .good, recovering: Bool? = false, hrv: HRVStatus.State? = .balanced,
                       ratio: Double? = 1.0, recentSleep: TimeInterval? = 7.5 * 3600) -> TrainingReadiness.Input {
        TrainingReadiness.Input(sleepScore: sleep, recovering: recovering, hrvStatus: hrv, loadRatio: ratio,
                                recentSleep: recentSleep)
    }

    @Test func nothingOffIsHigh() throws {
        let result = try #require(TrainingReadiness.status(input()))
        #expect(result == TrainingReadiness.Result(rating: .good, measured: 5, inRange: 5, reason: "Ready for hard training"))
        #expect(result.word == "High")
    }

    /// Each input uses its own card's threshold: red sleep, still recovering, HRV not balanced, ratio above 1.3,
    /// and 3 nights under the need.
    @Test func eachInputFlagsAtItsCardsThreshold() throws {
        #expect(try #require(TrainingReadiness.status(input(sleep: .fair))).rating == .good)
        #expect(try #require(TrainingReadiness.status(input(sleep: .poor))).reason == "Poor sleep")
        #expect(try #require(TrainingReadiness.status(input(recovering: true))).reason == "Still recovering")
        #expect(try #require(TrainingReadiness.status(input(hrv: .low))).reason == "HRV low")
        #expect(try #require(TrainingReadiness.status(input(ratio: 1.3))).rating == .good)
        #expect(try #require(TrainingReadiness.status(input(ratio: 1.31))).reason == "Load rising fast")
        #expect(try #require(TrainingReadiness.status(input(recentSleep: 6.9 * 3600))).reason == "Short sleep 3 nights")
    }

    @Test func twoOffIsLow() throws {
        let result = try #require(TrainingReadiness.status(input(recovering: true, hrv: .unbalanced)))
        #expect(result.rating == .poor)
        #expect(result.word == "Low")
        #expect(result.reason == "Still recovering · 1 more off")
    }

    @Test func calibratingWithFewerThanThreeInputs() {
        #expect(TrainingReadiness.status(input(sleep: nil, recovering: nil, hrv: nil, ratio: nil)) == nil)
    }

    @MainActor
    @Test func cardBuildsFromSampleData() async throws {
        #expect(CardKind.gallery.contains(.trainingReadiness))
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .trainingReadiness)
        #expect(["High", "Moderate", "Low"].contains(snapshot.value ?? ""), "\(snapshot.value ?? "nil")")
        guard case .bars(let days, _, _) = snapshot.chart else { Issue.record("\(snapshot.chart)"); return }
        #expect(days.count == 7)
    }
}

struct LoadFocusTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Max 200: low below 164 bpm, threshold from 164, high from 176; each reading lasts until the next, up to 5 minutes.
    @Test func timeSplitsBySeilerZone() {
        let readings = [TimedValue(date: start, value: 140), TimedValue(date: start + 60, value: 170),
                        TimedValue(date: start + 120, value: 180), TimedValue(date: start + 900, value: 120)]
        #expect(IntensityZones.time(readings, end: start + 960, maxHeartRate: 200) == [120, 60, 300])
    }

    /// Seiler 2010: about 80% of training at low intensity.
    @Test func eightyPercentLowMeetsTheTarget() throws {
        let shares = try #require(LoadFocus.shares([8 * 3600, 600, 2 * 3600 - 600]))
        #expect(shares[0] == 0.8)
        #expect(LoadFocus.rating(lowShare: shares[0]) == .good)
        #expect(LoadFocus.rating(lowShare: 0.79) == .fair)
        #expect(LoadFocus.shares([0, 0, 0]) == nil)
    }

    @MainActor
    @Test func cardSplitsFourWeeksIntoThreeZones() async throws {
        #expect(CardKind.gallery.contains(.loadFocus))
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .loadFocus)
        #expect(snapshot.unit == "low")
        guard case .rows(let rows) = snapshot.detail else { Issue.record("\(snapshot.detail)"); return }
        #expect(rows.map(\.label) == ["Low · <82% max HR", "Threshold · ≥82% max HR", "High · ≥88% max HR"])
    }
}

struct ScoreBreakdownTests {
    /// The thresholds Recovery rates against, as RecoveryTests derives them: HRV off below ≈59.46 ms,
    /// resting HR above 54.75 bpm, sleep under 7 hours, breathing above 15.5.
    @Test func recoveryChecksShowEachThreshold() throws {
        let input = Recovery.Input(hrv: 59.3, hrvHistory: [58, 62, 60, 64, 60, 58, 62, 60, 64, 62],
                                   restingHeartRate: 54, restingHeartRateHistory: [54, 55, 53, 54, 55, 53, 54, 54, 55, 53],
                                   asleep: 8 * 3600, respiratoryRate: 14.6,
                                   respiratoryRateHistory: [14.2, 14.6, 14.4, 14.8, 14.5, 14.3, 14.7, 14.5])
        let checks = try #require(Recovery.checks(input))
        #expect(checks.map(\.kind) == [.hrv, .restingHeartRate, .sleep, .breathing])
        #expect(abs(checks[0].limit - 59.46) < 0.01)
        #expect(checks[0].isOff)
        #expect(checks[1].limit == 54.75)
        #expect(checks[2].limit == 7 * 3600)
        #expect(abs(checks[3].limit - 15.5) < 0.000_1)
        #expect(checks.filter(\.isOff).map(\.reason) == ["HRV below normal"])
        #expect(Recovery.status(input)?.reason == "HRV below normal", "Status counts the same checks")
    }

    /// Each step's cause takes the change actually applied, so the amounts add up to the level's change.
    @Test func resourcesContributionsAddUpToTheChange() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let interval = DateInterval(start: start, duration: 6 * 3600)
        let sleep = [SleepPeriod(start: start, end: start + 2 * 3600, stage: .deep)]
        let workout = DateInterval(start: start + 3 * 3600, duration: 3600)
        let heartRate = stride(from: 0.0, through: 6 * 3600, by: 300).map { offset in
            TimedValue(date: start + offset, value: offset < 2 * 3600 ? 48 : (workout.contains(start + offset) ? 160 : 80))
        }
        let steps = Resources.steps(interval: interval, heartRate: heartRate, sleep: sleep, workouts: [workout],
                                    restingHeartRate: 50, maxHeartRate: 190, startLevel: 95)
        #expect(steps.map { TimedValue(date: $0.date, value: $0.level) }
                == Resources.timeline(interval: interval, heartRate: heartRate, sleep: sleep, workouts: [workout],
                                      restingHeartRate: 50, maxHeartRate: 190, startLevel: 95))
        let amounts = Resources.contributions(steps, from: start)
        #expect(abs(amounts.values.reduce(0, +) - (steps.last!.level - steps.first!.level)) < 0.000_1)
        #expect(amounts[.sleep]! > 0, "Sleep charges, capped at 100")
        #expect(amounts[.workout]! < 0)
        #expect(amounts[.raisedHeartRate]! < 0, "80 bpm is above 15% of the reserve")
    }

    @MainActor
    @Test func detailScreensListTheInputs() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let source = SampleDataSource()
        let recovery = try await Breakdown.load(for: .recovery, day: today, period: .month, source: source, calendar: calendar)
        guard case .recovery(let checks) = recovery else { Issue.record("\(String(describing: recovery))"); return }
        #expect(checks.first?.kind == .hrv)
        let resources = try await Breakdown.load(for: .resources, day: today, period: .month, source: source, calendar: calendar)
        guard case .resources(let midnight, let now, let amounts, let nowLabel) = resources else {
            Issue.record("\(String(describing: resources))"); return
        }
        #expect(abs(amounts.values.reduce(0, +) - (now - midnight)) < 0.000_1)
        #expect(nowLabel == String(localized: "Now"))
        // A past day speaks of its end and its own night, as its card does (#206).
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let past = try await Breakdown.load(for: .resources, day: yesterday, period: .month, source: source, calendar: calendar)
        guard case .resources(_, _, _, let pastLabel) = past else { Issue.record("\(String(describing: past))"); return }
        #expect(pastLabel == String(localized: "End of day"))
        let sleep = try await Breakdown.load(for: .sleepDuration, day: yesterday, period: .month, source: source, calendar: calendar)
        #expect(sleep?.title == String(localized: "Night before"))
    }
}

struct RelatedCardTests {
    @Test func retiredInputsLinkToTheirReplacement() {
        #expect(CardKind.recovery.related.title == "Based on")
        #expect(CardKind.recovery.related.kinds == [.hrvStatus, .heartRate, .sleepDuration, .respiratoryRate])
        #expect(CardKind.resources.related.kinds == [.heartRate, .sleepStages], "No duplicate Heart Rate")
    }

    @Test func replacementsListWhatTheRetiredCardAffected() {
        #expect(CardKind.hrvStatus.related.title == "Affects", "HRV doesn't link to itself")
        #expect(CardKind.hrvStatus.related.kinds == [.healthStatus, .recovery])
        #expect(CardKind.heartRate.related.kinds == [.resources, .dayIntensity, .strain, .healthStatus, .recovery, .healthAge])
    }

    @Test func scoresListTheDataOfWhatTheyAreBasedOn() {
        #expect(CardKind.steps.dataKinds == [.steps])
        #expect(CardKind.heartRate.dataKinds.isEmpty, "Read live, not imported")
        #expect(CardKind.recovery.dataKinds == [.overnightHRV, .hrv, .restingHeartRate, .sleep, .respiratoryRate])
        #expect(CardKind.trainingReadiness.dataKinds.contains(.workouts))
    }

    @Test func noDetailScreenLinksToARetiredCard() {
        for kind in CardKind.allCases {
            #expect(kind.related.kinds.allSatisfy { !$0.isRetired && $0 != kind }, "\(kind)")
        }
    }
}

@MainActor
struct HealthAgeTrendTests {
    /// Each point uses the same 30-day window as the card, so the chart ends on the card's value.
    @Test func trendEndsOnTheCardsValue() async throws {
        let source = StableDailySource()
        let card = try await SnapshotBuilder(source: source).snapshot(for: .healthAge)
        let trend = try #require(try await TrendBuilder(source: source).trend(for: .healthAge, period: .month))
        #expect(trend.points.count == 30)
        let last = try #require(trend.points.last?.value)
        #expect(last.formatted(.number.precision(.fractionLength(1))) == card.value)
    }
}

/// Sample data whose daily values don't depend on how many days are asked for: `SampleDataSource` generates
/// them from the start of the requested range.
private struct StableDailySource: HealthDataSource {
    let base = SampleDataSource()
    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] {
        Array(try await base.daily(metric, days: 400).suffix(days))
    }
    func sleepNights(days: Int) async throws -> [SleepNight] { Array(try await base.sleepNights(days: 400).suffix(days)) }
    func standHours(days: Int) async throws -> [DayValue] { try await base.standHours(days: days) }
    func overnight(days: Int) async throws -> [OvernightVitals] { try await base.overnight(days: days) }
    func workouts(days: Int) async throws -> [WorkoutSummary] { try await base.workouts(days: days) }
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] { try await base.heartRate(in: interval) }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { try await base.sleepPeriods(in: interval) }
    func age() async throws -> Int? { try await base.age() }
    func biologicalSex() async throws -> BiologicalSex? { try await base.biologicalSex() }
    func highestHeartRate(days: Int) async throws -> Double? { try await base.highestHeartRate(days: days) }
}

struct VitalGaugeTests {
    /// Respiratory rate's gauge keeps its decimal, so its green band matches the range its rating uses (#165).
    @Test func gaugeUsesTheMetricsPrecision() async throws {
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .respiratoryRate)
        guard case .range(_, _, _, _, let decimals) = snapshot.chart else { Issue.record("Expected a range gauge"); return }
        #expect(decimals == QuantityMetric.respiratoryRate.decimals)
    }
}
