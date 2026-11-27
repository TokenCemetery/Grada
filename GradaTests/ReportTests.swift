import Foundation
import Testing
@testable import Grada

struct ReportTests {
    private let today = Date(timeIntervalSince1970: 1_794_787_200)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// One suite per test: Swift Testing runs tests in parallel, and a shared suite gets cleared mid-test.
    private func freshDefaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "ReportTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    @Test func morningNotificationWaitsForTheWakeUp() {
        let wake = today.addingTimeInterval(7 * 3600)
        let early = today.addingTimeInterval(5 * 3600)
        #expect(ReportNotifier.morningAction(now: early, wake: wake, today: today, scheduledDay: nil) == .at(wake))
        #expect(ReportNotifier.morningAction(now: early, wake: wake, today: today, scheduledDay: today) == .at(wake),
                "Newer data replaces the pending report")
    }

    @MainActor
    @Test func morningNotificationAfterTheWakeUpIsSentOnce() {
        let wake = today.addingTimeInterval(7 * 3600)
        let late = today.addingTimeInterval(9 * 3600)
        let yesterday = today.addingTimeInterval(-86_400)
        #expect(ReportNotifier.morningAction(now: late, wake: wake, today: today, scheduledDay: yesterday) == .now)
        #expect(ReportNotifier.morningAction(now: late, wake: wake, today: today, scheduledDay: today) == .skip)
    }

    @MainActor
    @Test func eveningNotificationIsRescheduledUntilItsTime() {
        let time = today.addingTimeInterval(22 * 3600)
        #expect(ReportNotifier.eveningAction(now: today.addingTimeInterval(18 * 3600), at: time) == .at(time))
        #expect(ReportNotifier.eveningAction(now: today.addingTimeInterval(22.5 * 3600), at: time) == .skip)
    }

    /// Seconds, not a calendar minute: a wake-up at 07:00:40 seen at 07:00:20 must still come, 20 seconds later.
    @Test func notificationDelayKeepsTheSeconds() {
        let wake = today.addingTimeInterval(7 * 3600 + 40)
        #expect(ReportNotifier.delay(until: wake, now: today.addingTimeInterval(7 * 3600 + 20)) == 20)
        #expect(ReportNotifier.delay(until: wake, now: wake.addingTimeInterval(5)) == 1, "Never zero or negative")
    }

    @Test func turningTheMorningReportOffForgetsTodaysSchedule() throws {
        let defaults = try freshDefaults()
        defaults.set(today.timeIntervalSince1970, forKey: ReportNotifier.morningScheduledDayKey)
        ReportNotifier.withdraw(ReportNotifier.eveningID, defaults: defaults)
        #expect(defaults.object(forKey: ReportNotifier.morningScheduledDayKey) != nil, "The evening report leaves it")
        ReportNotifier.withdraw(ReportNotifier.morningID, defaults: defaults)
        #expect(defaults.object(forKey: ReportNotifier.morningScheduledDayKey) == nil)
    }

    @Test func morningNotificationFollowsUpThenGivesTodaysFocus() {
        var report = DailyReport(kind: .morning, hasData: true, day: today, calendar: calendar)
        report.followUps = ["You reached 8,000 steps yesterday. 👏", "In bed by 22:40 last night. Nice early night."]
        report.focus = TrainingPlan.recommendation(.easy, reason: "")
        #expect(report.notificationBody == "You reached 8,000 steps yesterday. 👏\nToday: Easy session, 30–40 minutes.",
                "One follow-up, then the focus: no line of numbers")
        report.focusOutcome = .followed
        #expect(["Nice work yesterday", "Great start to the day"].contains(report.notificationTitle))
        report.bodyWarning = true
        #expect(["Take it easy today", "A gentle day today"].contains(report.notificationTitle), "A body warning comes first")
    }

    @Test func eveningNotificationEndsWithTonightsBedtime() {
        var report = DailyReport(kind: .evening, hasData: true, day: today, calendar: calendar)
        #expect(report.notificationBody == "Your report is ready in Journal.", "Never an empty notification")
        report.followUps = ["Steps goal reached today. 👏"]
        report.bedtime = today.addingTimeInterval(22 * 3600 + 45 * 60)
        let body = report.notificationBody
        #expect(body.hasPrefix("Steps goal reached today. 👏\nBed by "))
        #expect(body.hasSuffix(" sets you up for tomorrow."))
    }

    @MainActor
    @Test func sampleDataHasBothReports() async throws {
        let defaults = try freshDefaults()
        let builder = SnapshotBuilder(source: SampleDataSource())
        let morning = try await DailyReport.load(.morning, builder, defaults: defaults)
        #expect(morning.hasData)
        #expect(morning.snapshots[.sleepDuration]?.value != nil)
        #expect(morning.focus != nil, "Today's focus")
        // As for the notification, so the follow-up doesn't depend on the time of day the test runs.
        let evening = try await DailyReport.load(.evening, builder, defaults: defaults, forNotification: true)
        #expect(evening.snapshots[.steps]?.value != nil)
        #expect(evening.recommendations.contains { $0.text.hasPrefix("Go to bed by") }, "Sleep Need gives tonight's bedtime")
        let readiness = try #require(morning.snapshots[.trainingReadiness]?.recommendation)
        let intensity = try #require(evening.snapshots[.intensityMinutes]?.recommendation)
        #expect(!morning.recommendations.contains(readiness) && !evening.recommendations.contains(intensity),
                "The reports say the session and the week's minutes themselves")
        #expect(evening.focus?.text.hasPrefix("Go to bed by") == true, "Tonight's bedtime is the evening's focus")
        #expect(evening.followUps.count == 1, "The evening checks in on this morning's focus")
        #expect(evening.tomorrow != nil)
        let saved = try #require(DayPlanStore.plan(for: Calendar.current.startOfDay(for: .now), defaults: defaults, calendar: .current))
        #expect(saved.focus != nil && saved.training != nil && saved.bedtime != nil, "Saved for tomorrow's follow-up")
    }

    @MainActor
    @Test func trainingSuggestionAgreesWithTheReadinessCard() async throws {
        let builder = SnapshotBuilder(source: SampleDataSource())
        let card = try #require(try await builder.readinessDays(7).last?.result)
        try #require(card.rating != .poor, "Sample data's readiness isn't low; one day of it was")
        let morning = try await DailyReport.load(.morning, builder, defaults: try freshDefaults())
        let training = try #require(morning.training ?? morning.focus)
        #expect(!training.reason.hasPrefix("Training readiness is low"))
    }

    @MainActor
    @Test func morningFollowsUpOnYesterdaysPlan() async throws {
        let defaults = try freshDefaults()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!
        DayPlanStore.saveMorning(DayPlan(focus: .steps, training: .easy, stepsGoal: 1), for: yesterday,
                                 defaults: defaults, calendar: calendar)
        let morning = try await DailyReport.load(.morning, SnapshotBuilder(source: SampleDataSource()), defaults: defaults)
        #expect(morning.focusOutcome == .followed, "Sample data walks more than 1 step a day")
        #expect(morning.followUps.first?.lowercased().contains("steps") == true, "The focus comes first")
    }

    @Test func wakeUpPrefersOwnTimeThenUsualThenDefault() throws {
        let defaults = try freshDefaults()
        let usual = today.addingTimeInterval(6.5 * 3600)
        #expect(SleepSchedule.wake(on: today, usual: usual, defaults: defaults, calendar: calendar) == usual)
        #expect(SleepSchedule.wake(on: today, usual: nil, defaults: defaults, calendar: calendar)
                == today.addingTimeInterval(7 * 3600), "7:00 until there are enough nights")

        defaults.set(false, forKey: SleepSchedule.usesUsualTimesKey)
        defaults.set(5 * 60 + 45, forKey: SleepSchedule.wakeMinutesKey)
        #expect(SleepSchedule.wake(on: today, usual: usual, defaults: defaults, calendar: calendar)
                == today.addingTimeInterval(5.75 * 3600))
    }

    /// On the days clocks change, times stay on the clock rather than shifting an hour (#156).
    @Test func scheduleTimesKeepTheClockTimeWhenClocksChange() throws {
        let defaults = try freshDefaults()
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        for date in [DateComponents(year: 2026, month: 3, day: 29), DateComponents(year: 2026, month: 10, day: 25)] {
            let day = berlin.date(from: date)!
            let wake = SleepSchedule.wake(on: day, usual: nil, defaults: defaults, calendar: berlin)
            let bedtime = SleepSchedule.bedtime(on: day, usual: nil, defaults: defaults, calendar: berlin)
            #expect(berlin.dateComponents([.hour, .minute], from: wake) == DateComponents(hour: 7, minute: 0))
            #expect(berlin.dateComponents([.hour, .minute], from: bedtime) == DateComponents(hour: 23, minute: 0))
        }
    }

    @Test func ownBedtimeAfterMidnightIsTheNextDay() throws {
        let defaults = try freshDefaults()
        #expect(SleepSchedule.bedtime(on: today, usual: nil, defaults: defaults, calendar: calendar)
                == today.addingTimeInterval(23 * 3600), "23:00 until there are enough nights")

        defaults.set(false, forKey: SleepSchedule.usesUsualTimesKey)
        defaults.set(30, forKey: SleepSchedule.bedtimeMinutesKey)
        #expect(SleepSchedule.bedtime(on: today, usual: nil, defaults: defaults, calendar: calendar)
                == today.addingTimeInterval(24.5 * 3600))
        #expect(SleepSchedule.windDown(defaults) == 3600, "An hour unless chosen")
    }
}
