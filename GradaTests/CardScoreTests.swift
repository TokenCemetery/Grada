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
