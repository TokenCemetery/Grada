import Foundation
import Testing
@testable import Grada

struct RecommendationTests {
    @Test func stepsLeftBecomeWalkingMinutes() throws {
        let recommendation = Recommendations.steps(today: 8_420, goal: 10_000)
        #expect(recommendation.text == "Walk about 16 more minutes", "1,580 steps at 100 a minute, rounded up")
        #expect(recommendation.reason.contains("today's goal"))
    }

    @Test func reachedStepsGoalIsCongratulated() {
        #expect(Recommendations.steps(today: 10_000, goal: 10_000).text == "Steps goal reached")
        #expect(Recommendations.steps(today: 10_000, goal: 10_000).reason.contains("right on your goal"))
        #expect(Recommendations.steps(today: 12_000, goal: 10_000).reason.contains("over your goal"))
    }

    @Test func dailyRecommendationsComeFirstStepsThenBedtimeAndOnce() throws {
        let rest = try #require(Recommendations.restingHeartRate(62, normal: 52...58))
        let load = try #require(Recommendations.load(ratio: 1.4))
        let steps = Recommendations.steps(today: 8_420, goal: 10_000)
        let wake = Date(timeIntervalSince1970: 1_800_000_000)
        let bed = Recommendations.bedtime(Bedtime.Plan(bedtime: wake.addingTimeInterval(-8 * 3600), wake: wake,
                                                       usualBedtime: wake.addingTimeInterval(-8 * 3600),
                                                       awakeInBed: 0, weekend: nil), need: 8 * 3600)
        // Morning's warnings, then the evening's bedtime, steps and Strain again, as the Journal combines them.
        #expect(Recommendations.dailyFirst([rest, load, bed, steps, load]) == [steps, bed, rest, load])
    }

    @Test func restingHeartRateAboveNormalRangeSuggestsRest() throws {
        let recommendation = try #require(Recommendations.restingHeartRate(62, normal: 52...58))
        #expect(recommendation.text == "Take it easy today")
        #expect(recommendation.reason.contains("62 bpm is above your normal 52–58"))
        #expect(Recommendations.restingHeartRate(58, normal: 52...58) == nil, "The upper bound is still normal")
        #expect(Recommendations.restingHeartRate(48, normal: 52...58) == nil, "A low resting heart rate is no concern")
    }

    @Test func onlyLowHRVSuggestsEasyTraining() {
        #expect(Recommendations.hrv(.low)?.text == "Keep training easy")
        #expect(Recommendations.hrv(.unbalanced) == nil)
        #expect(Recommendations.hrv(.balanced) == nil)
    }

    @Test func loadOutsideSweetSpot() {
        #expect(Recommendations.load(ratio: 1.6)?.text == "Ease off for a few days")
        #expect(Recommendations.load(ratio: 1.4)?.text == "Hold your load steady")
        #expect(Recommendations.load(ratio: 0.6)?.text == "Build back up gradually")
        #expect(Recommendations.load(ratio: 1.0) == nil)
        #expect(Recommendations.load(ratio: 1.3) == nil)
    }
}

struct BedtimeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Monday 2026-11-16.
    private let monday = Date(timeIntervalSince1970: 1_794_787_200)

    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: monday)! }

    /// A night ending `offset` days from Monday: asleep from `start` to `end` hours after that day's midnight
    /// (a negative start is the evening before), with `awake` minutes of it awake.
    private func night(_ offset: Int, _ start: Double, _ end: Double, awake: Double = 0) -> Bedtime.Night {
        let wakeDay = day(offset)
        return Bedtime.Night(wakeDay: wakeDay, start: wakeDay.addingTimeInterval(start * 3600),
                             end: wakeDay.addingTimeInterval(end * 3600), asleep: (end - start) * 3600 - awake * 60)
    }

    @Test func weekdayBedtimeFromUsualWakeNeedAndTimeAwake() throws {
        // Weekdays wake at 6:30–7:00, the weekend at 9:00.
        let nights = [night(-7, -1, 7, awake: 20), night(-6, -1, 6.5, awake: 10), night(-5, -1, 6.75, awake: 30),
                      night(-2, 0, 9), night(-1, 0, 9)]
        let plan = try #require(Bedtime.plan(nights: nights, need: 7.5 * 3600, wakeDay: monday, calendar: calendar))
        #expect(plan.weekend == false)
        #expect(plan.wake == monday.addingTimeInterval(6.75 * 3600), "Median of the three weekday wake-ups")
        #expect(plan.awakeInBed == 20 * 60)
        #expect(plan.bedtime == monday.addingTimeInterval((6.75 - 7.5) * 3600 - 20 * 60), "22:55 the evening before")
        #expect(plan.usualBedtime == monday.addingTimeInterval(-3600), "Weekday nights started at 23:00")
    }

    @Test func weekendNightsAreKeptApart() throws {
        let nights = [night(-7, -1, 7), night(-6, -1, 7), night(-5, -1, 7),
                      night(-9, 0, 9), night(-2, 0, 9.5), night(-1, 0, 8.5)]
        let saturday = day(5)
        let plan = try #require(Bedtime.plan(nights: nights, need: 8 * 3600, wakeDay: saturday, calendar: calendar))
        #expect(plan.weekend == true)
        #expect(plan.wake == saturday.addingTimeInterval(9 * 3600))
        #expect(plan.bedtime == saturday.addingTimeInterval(3600))
    }

    @Test func tooFewNightsOfOneKindUseAllNights() throws {
        let nights = [night(-7, -1, 7), night(-6, -1, 7), night(-5, -1, 7), night(-1, 0, 9)]
        let plan = try #require(Bedtime.plan(nights: nights, need: 7 * 3600, wakeDay: day(5), calendar: calendar))
        #expect(plan.weekend == nil, "One weekend night isn't enough, so the wake-up mixes both")
        #expect(plan.wake == day(5).addingTimeInterval(7 * 3600))
    }

    @Test func calibratingWithFewerThanThreeNights() {
        #expect(Bedtime.plan(nights: [night(-2, -1, 7), night(-1, -1, 7)], need: 7 * 3600, wakeDay: monday,
                             calendar: calendar) == nil)
    }

    @Test func medianOfEvenCountAveragesTheMiddle() {
        #expect(Bedtime.median([4, 1, 3, 2]) == 2.5)
        #expect(Bedtime.median([]) == nil)
    }
}
