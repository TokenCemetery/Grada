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
        let bed = Recommendations.bedtime(Bedtime.Plan(bedtime: wake.addingTimeInterval(-8 * 3600), plannedWake: wake, wake: wake,
                                                       usualBedtime: wake.addingTimeInterval(-8 * 3600), weekend: nil))
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

    @Test func intensityMinutesLeftToTheWeeklyTarget() {
        let behind = Recommendations.intensityMinutes(total: 92.4, target: 150)
        #expect(behind.text == "Get about 58 more intensity minutes", "57.6 left, rounded up")
        #expect(behind.reason.hasPrefix("92 of 150 intensity minutes in the last 7 days."))
        #expect(Recommendations.intensityMinutes(total: 149.5, target: 150).text == "Get about 1 more intensity minute")
        #expect(Recommendations.intensityMinutes(total: 150, target: 150).text == "Weekly goal reached")
        #expect(Recommendations.intensityMinutes(total: 210, target: 150).reason == "210 of 150 intensity minutes in the last 7 days.")
    }

    @Test func onlyPoorSleepConsistencySuggestsARegularSchedule() throws {
        let recommendation = try #require(Recommendations.sleepConsistency(65))
        #expect(recommendation.text == "Keep a regular sleep schedule")
        #expect(recommendation.reason.contains("consistency of 65"))
        #expect(Recommendations.sleepConsistency(SleepConsistency.populationLowerQuartile) == nil, "Fair from the lower quartile")
        #expect(Recommendations.sleepConsistency(90) == nil)
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
    /// (a negative start is the evening before).
    private func night(_ offset: Int, _ start: Double, _ end: Double) -> Bedtime.Night {
        let wakeDay = day(offset)
        return Bedtime.Night(wakeDay: wakeDay, start: wakeDay.addingTimeInterval(start * 3600),
                             end: wakeDay.addingTimeInterval(end * 3600))
    }

    @Test func weekdayBedtimeFromUsualWakeAndNeed() throws {
        // Weekdays wake at 6:30–7:00, the weekend at 9:00.
        let nights = [night(-7, -1, 7), night(-6, -1, 6.5), night(-5, -1, 6.75),
                      night(-2, 0, 9), night(-1, 0, 9)]
        let plan = try #require(Bedtime.plan(nights: nights, need: 8 * 3600, wakeDay: monday, calendar: calendar))
        #expect(plan.weekend == false)
        #expect(plan.wake == monday.addingTimeInterval(6.75 * 3600), "Median of the three weekday wake-ups")
        #expect(plan.plannedWake == plan.wake)
        #expect(plan.bedtime == monday.addingTimeInterval((6.75 - 8) * 3600), "22:45 the evening before")
        #expect(plan.usualBedtime == monday.addingTimeInterval(-3600), "Weekday nights started at 23:00")
    }

    @Test func weekendNightsAreKeptApart() throws {
        let nights = [night(-7, -1, 7), night(-6, -1, 7), night(-5, -1, 7),
                      night(-9, 0, 9), night(-2, 0, 9.5), night(-1, 0, 8.5)]
        let saturday = day(5)
        let plan = try #require(Bedtime.plan(nights: nights, need: 8 * 3600, wakeDay: saturday, calendar: calendar))
        #expect(plan.weekend == true)
        #expect(plan.wake == saturday.addingTimeInterval(9 * 3600), "The usual weekend wake-up, for report times")
        #expect(plan.plannedWake == saturday.addingTimeInterval(8 * 3600), "At most an hour after the weekday 7:00")
        #expect(plan.bedtime == saturday, "Midnight: 8 hours before 8:00, and an hour after the weekday 23:00")
    }

    @Test func weekendWithinAnHourKeepsItsOwnTimes() throws {
        let nights = [night(-7, -1, 7), night(-6, -1, 7), night(-5, -1, 7),
                      night(-9, -0.5, 7.5), night(-2, -0.5, 7.5), night(-1, -0.5, 7.5)]
        let saturday = day(5)
        let plan = try #require(Bedtime.plan(nights: nights, need: 7 * 3600, wakeDay: saturday, calendar: calendar))
        #expect(plan.plannedWake == saturday.addingTimeInterval(7.5 * 3600))
        #expect(plan.bedtime == saturday.addingTimeInterval(-0.5 * 3600))
    }

    @Test func neverLaterThanTheUsualBedtime() throws {
        // In bed 23:00–8:00 every weekday: a 7-hour need alone would allow 1:00.
        let nights = [night(-7, -1, 8), night(-6, -1, 8), night(-5, -1, 8)]
        let plan = try #require(Bedtime.plan(nights: nights, need: 7 * 3600, wakeDay: monday, calendar: calendar))
        #expect(plan.bedtime == monday.addingTimeInterval(-3600))
    }

    @Test func debtPaybackMovesTheBedtimeEarlier() throws {
        // Usually asleep 2:00–9:00 on weekdays: 7 hours of need and an hour of payback mean 1:00.
        let nights = [night(-7, 2, 9), night(-6, 2, 9), night(-5, 2, 9)]
        let plan = try #require(Bedtime.plan(nights: nights, need: 7 * 3600, payback: 3600, debt: 4 * 3600,
                                             wakeDay: monday, calendar: calendar))
        #expect(plan.bedtime == monday.addingTimeInterval(3600))
        let reason = Recommendations.bedtime(plan, calendar: calendar).reason
        #expect(reason.contains("It includes 1h 00m toward your 4h 00m of sleep debt; paying it back takes several nights."))
        let rested = try #require(Bedtime.plan(nights: nights, need: 7 * 3600, wakeDay: monday, calendar: calendar))
        #expect(!Recommendations.bedtime(rested, calendar: calendar).reason.contains("sleep debt"))
    }

    @Test func paybackIsAtMostAnHourAndStaysInTheRecommendedRange() {
        let hour: TimeInterval = 3600
        #expect(SleepNeed.payback(debt: 3 * 60, need: 7 * hour, age: 30) == 0, "Under the debt shown")
        #expect(SleepNeed.payback(debt: 20 * 60, need: 7 * hour, age: 30) == 20 * 60, "All of a small debt")
        #expect(SleepNeed.payback(debt: 5 * hour, need: 7.5 * hour, age: 30) == hour, "An hour a night at most")
        #expect(SleepNeed.payback(debt: 5 * hour, need: 8.5 * hour, age: 30) == 0.5 * hour, "Up to 9 hours in all")
        #expect(SleepNeed.payback(debt: 5 * hour, need: 7.5 * hour, age: 70) == 0.5 * hour, "Up to 8 hours from 65")
        #expect(SleepNeed.payback(debt: 5 * hour, need: 9.5 * hour, age: 30) == 0, "A goal above the range adds nothing")
    }

    @Test func bedtimeReasonGivesTheSleepItLeaves() {
        let wake = monday.addingTimeInterval(8 * 3600)
        let plan = { (bedtime: Double, weekend: Bool?) in
            Bedtime.Plan(bedtime: monday.addingTimeInterval(bedtime * 3600), plannedWake: wake, wake: wake,
                         usualBedtime: monday.addingTimeInterval(bedtime * 3600), weekend: weekend)
        }
        let weekday = Recommendations.bedtime(plan(-1, false), calendar: calendar).reason
        #expect(weekday.hasPrefix("That leaves 9h 00m of sleep before your usual weekday wake-up at "))
        #expect(!weekday.contains("heart disease"), "Before midnight")
        let weekend = Recommendations.bedtime(plan(1, true), calendar: calendar).reason
        #expect(weekend.hasPrefix("That leaves 7h 00m of sleep before "))
        #expect(weekend.contains("on the weekend, at most an hour after your usual weekday wake-up."))
        #expect(weekend.contains("went with the lowest heart disease risk, and after midnight with the highest."))
    }

    @Test func tooFewNightsOfOneKindUseAllNights() throws {
        let nights = [night(-7, -1, 7), night(-6, -1, 7), night(-5, -1, 7), night(-1, 0, 9)]
        let plan = try #require(Bedtime.plan(nights: nights, need: 7 * 3600, wakeDay: day(5), calendar: calendar))
        #expect(plan.weekend == nil, "One weekend night isn't enough, so the wake-up mixes both")
        #expect(plan.wake == day(5).addingTimeInterval(7 * 3600))
    }

    @Test func personalSleepNeedFromFreeNights() {
        let hours = { (values: [Double]) in values.map { $0 * 3600 } }
        #expect(SleepNeed.personal(freeNights: hours([8, 8, 8]), age: 30) == SleepNeed.baseline, "Too few nights")
        #expect(SleepNeed.personal(freeNights: hours([7, 7.5, 7.5, 8]), age: 30) == 7.5 * 3600)
        #expect(SleepNeed.personal(freeNights: hours([6, 6, 6.5, 6.5]), age: 30) == 7 * 3600, "Never under the guideline")
        #expect(SleepNeed.personal(freeNights: hours([10, 10, 10, 10]), age: 30) == 9 * 3600)
        #expect(SleepNeed.personal(freeNights: hours([10, 10, 10, 10]), age: 70) == 8 * 3600, "7–8 hours from 65")
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
