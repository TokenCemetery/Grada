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

    @Test func morningNotificationWaitsForTheWakeUp() {
        let wake = today.addingTimeInterval(7 * 3600)
        let early = today.addingTimeInterval(5 * 3600)
        #expect(ReportNotifier.morningAction(now: early, wake: wake, today: today, scheduledDay: nil) == .at(wake))
        #expect(ReportNotifier.morningAction(now: early, wake: wake, today: today, scheduledDay: today) == .at(wake),
                "Newer data replaces the pending report")
    }

    @Test func morningNotificationAfterTheWakeUpIsSentOnce() {
        let wake = today.addingTimeInterval(7 * 3600)
        let late = today.addingTimeInterval(9 * 3600)
        let yesterday = today.addingTimeInterval(-86_400)
        #expect(ReportNotifier.morningAction(now: late, wake: wake, today: today, scheduledDay: yesterday) == .now)
        #expect(ReportNotifier.morningAction(now: late, wake: wake, today: today, scheduledDay: today) == .skip)
    }

    @Test func eveningNotificationIsRescheduledUntilItsTime() {
        let time = today.addingTimeInterval(22 * 3600)
        #expect(ReportNotifier.eveningAction(now: today.addingTimeInterval(18 * 3600), at: time) == .at(time))
        #expect(ReportNotifier.eveningAction(now: today.addingTimeInterval(22.5 * 3600), at: time) == .skip)
    }

    @Test func morningSummaryLeavesOutCalibratingScores() {
        var report = DailyReport(kind: .morning, hasData: true)
        report.snapshots[.sleepDuration] = CardSnapshot(period: "Last night", value: "7h 20m")
        report.snapshots[.sleepScore] = CardSnapshot(period: "Last night", value: "Calibrating")
        report.snapshots[.recovery] = CardSnapshot(period: "Today", value: "Good")
        report.snapshots[.healthStatus] = CardSnapshot(period: "Last night", value: "All in range")
        #expect(report.summary == "Slept 7h 20m · Recovery Good · All in range")
    }

    @Test func eveningBodyHasTotalsThenTwoRecommendations() {
        var report = DailyReport(kind: .evening, hasData: true)
        report.snapshots[.steps] = CardSnapshot(period: "Today", value: "8,420")
        report.snapshots[.intensityMinutes] = CardSnapshot(period: "Last 7 days", value: "95")
        report.recommendations = [Recommendation(symbol: "lightbulb", text: "Walk about 16 more minutes", reason: ""),
                                  Recommendation(symbol: "lightbulb", text: "Go to bed by 22:55", reason: ""),
                                  Recommendation(symbol: "lightbulb", text: "Hold your load steady", reason: "")]
        #expect(report.notificationBody == "8,420 steps · 95 intensity min this week\nWalk about 16 more minutes\nGo to bed by 22:55")
    }

    @Test func sampleDataHasBothReports() async throws {
        let builder = SnapshotBuilder(source: SampleDataSource())
        let morning = try await DailyReport.load(.morning, builder)
        #expect(morning.hasData)
        #expect(morning.snapshots[.sleepDuration]?.value != nil)
        let evening = try await DailyReport.load(.evening, builder)
        #expect(evening.snapshots[.steps]?.value != nil)
        #expect(evening.recommendations.contains { $0.text.hasPrefix("Go to bed by") }, "Sleep Need gives tonight's bedtime")
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
