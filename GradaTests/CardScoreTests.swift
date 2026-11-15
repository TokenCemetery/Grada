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
    }

    @Test func everyIndicatorMetScores100() throws {
        let result = try #require(SleepScore.score(quality: quality(), need: 7 * 3600, regularity: 85, age: 35))
        #expect(result == SleepScore.Result(score: 100, rating: .good, reason: "All indicators met"))
    }

    /// NSF cut-offs: efficiency 85%, WASO 20 minutes, one awakening over 5 minutes (two from 65).
    @Test func nsfCutOffs() throws {
        let short = try #require(SleepScore.score(quality: quality(asleepHours: 6.9), need: 7 * 3600, regularity: 85, age: 35))
        #expect(short == SleepScore.Result(score: 80, rating: .fair, reason: "Short sleep"))
        let awake = try #require(SleepScore.score(quality: quality(wakeMinutes: 21), need: 7 * 3600, regularity: 85, age: 35))
        #expect(awake.reason == "Long time awake")
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
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .sleepScore)
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

struct StressTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Resting 50, max 190: reserve 140, so 100 is 40% of it, 106 bpm.
    @Test func levelRunsFromRestingToTheModerateFloor() {
        #expect(Stress.level(50, restingHeartRate: 50, maxHeartRate: 190) == 0)
        #expect(Stress.level(45, restingHeartRate: 50, maxHeartRate: 190) == 0)
        #expect(Stress.level(78, restingHeartRate: 50, maxHeartRate: 190) == 50)
        #expect(Stress.level(150, restingHeartRate: 50, maxHeartRate: 190) == 100)
    }

    @Test func bandsAreGarminsQuarters() {
        #expect(Stress.band(25) == .rest)
        #expect(Stress.band(26) == .low)
        #expect(Stress.band(51) == .medium)
        #expect(Stress.band(76) == .high)
        #expect(Stress.band(76).rating == .poor)
    }

    /// Resources keeps draining from 15% of heart rate reserve.
    @Test func resourcesDrainsAtTheSameShare() {
        #expect(Stress.drainLevel == 37.5)
    }

    @Test func timelineSkipsSleepAndWorkouts() {
        let readings = [50.0, 78, 150, 64].enumerated().map { TimedValue(date: start + Double($0.offset) * 300, value: $0.element) }
        let sleep = [SleepPeriod(start: start, end: start + 300, stage: .core)]
        let workout = DateInterval(start: start + 600, duration: 300)
        let levels = Stress.timeline(heartRate: readings, sleep: sleep, workouts: [workout], restingHeartRate: 50, maxHeartRate: 190)
        #expect(levels.map(\.value) == [50, 25])
    }

    @MainActor
    @Test func cardShowsTodaysAverageAndTimeline() async throws {
        #expect(CardKind.gallery.contains(.stress))
        let snapshot = try await SnapshotBuilder(source: SampleDataSource()).snapshot(for: .stress)
        #expect(snapshot.value != nil)
        #expect(snapshot.comparison?.hasSuffix("high") == true, "\(snapshot.comparison ?? "")")
        guard case .intraday(_, let domain) = snapshot.chart else { Issue.record("\(snapshot.chart)"); return }
        #expect(domain == 0...100)
    }
}

struct TrainingReadinessTests {
    private func input(sleep: DayRating? = .good, recovering: Bool? = false, hrv: HRVStatus.State? = .balanced,
                       ratio: Double? = 1.0, recentSleep: TimeInterval? = 7.5 * 3600, stress: Double? = 30) -> TrainingReadiness.Input {
        TrainingReadiness.Input(sleepScore: sleep, recovering: recovering, hrvStatus: hrv, loadRatio: ratio,
                                recentSleep: recentSleep, recentStress: stress)
    }

    @Test func nothingOffIsHigh() throws {
        let result = try #require(TrainingReadiness.status(input()))
        #expect(result == TrainingReadiness.Result(rating: .good, measured: 6, inRange: 6, reason: "Ready for hard training"))
        #expect(result.word == "High")
    }

    /// Each input uses its own card's threshold: red sleep, still recovering, HRV not balanced, ratio above 1.3,
    /// 3 nights under the need, and medium stress or more.
    @Test func eachInputFlagsAtItsCardsThreshold() throws {
        #expect(try #require(TrainingReadiness.status(input(sleep: .fair))).rating == .good)
        #expect(try #require(TrainingReadiness.status(input(sleep: .poor))).reason == "Poor sleep")
        #expect(try #require(TrainingReadiness.status(input(recovering: true))).reason == "Still recovering")
        #expect(try #require(TrainingReadiness.status(input(hrv: .low))).reason == "HRV low")
        #expect(try #require(TrainingReadiness.status(input(ratio: 1.3))).rating == .good)
        #expect(try #require(TrainingReadiness.status(input(ratio: 1.31))).reason == "Load rising fast")
        #expect(try #require(TrainingReadiness.status(input(recentSleep: 6.9 * 3600))).reason == "Short sleep 3 nights")
        #expect(try #require(TrainingReadiness.status(input(stress: 50))).rating == .good)
        #expect(try #require(TrainingReadiness.status(input(stress: 51))).reason == "Stress high 3 days")
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
