import Foundation
import Testing
@testable import Grada

struct MorningReportTests {
    private let today = Date(timeIntervalSince1970: 1_794_787_200)

    @Test func notificationWaitsForTheWakeUp() {
        let wake = today.addingTimeInterval(7 * 3600)
        let early = today.addingTimeInterval(5 * 3600)
        #expect(MorningReportNotifier.action(now: early, wake: wake, today: today, scheduledDay: nil) == .at(wake))
        #expect(MorningReportNotifier.action(now: early, wake: wake, today: today, scheduledDay: today) == .at(wake),
                "Newer data replaces the pending report")
    }

    @Test func notificationAfterTheWakeUpIsSentOnce() {
        let wake = today.addingTimeInterval(7 * 3600)
        let late = today.addingTimeInterval(9 * 3600)
        let yesterday = today.addingTimeInterval(-86_400)
        #expect(MorningReportNotifier.action(now: late, wake: wake, today: today, scheduledDay: yesterday) == .now)
        #expect(MorningReportNotifier.action(now: late, wake: wake, today: today, scheduledDay: today) == .skip)
    }

    @Test func summaryLeavesOutCalibratingScores() {
        var report = MorningReport(hasSleep: true)
        report.snapshots[.sleepDuration] = CardSnapshot(period: "Last night", value: "7h 20m")
        report.snapshots[.sleepScore] = CardSnapshot(period: "Last night", value: "Calibrating")
        report.snapshots[.recovery] = CardSnapshot(period: "Today", value: "Good")
        report.snapshots[.healthStatus] = CardSnapshot(period: "Last night", value: "All in range")
        #expect(report.summary == "Slept 7h 20m · Recovery Good · All in range")
    }

    @Test func sampleDataHasLastNight() async throws {
        let report = try await MorningReport.load(SnapshotBuilder(source: SampleDataSource()))
        #expect(report.hasSleep)
        #expect(report.snapshots[.sleepDuration]?.value != nil)
        #expect(!report.summary.isEmpty)
    }

    @Test func wakeUpPrefersOwnTimeThenUsualThenDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "MorningReportTests"))
        defaults.removePersistentDomain(forName: "MorningReportTests")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let usual = today.addingTimeInterval(6.5 * 3600)

        #expect(SleepSchedule.wake(on: today, usual: usual, defaults: defaults, calendar: calendar) == usual)
        #expect(SleepSchedule.wake(on: today, usual: nil, defaults: defaults, calendar: calendar)
                == today.addingTimeInterval(7 * 3600), "7:00 until there are enough nights")

        defaults.set(false, forKey: SleepSchedule.usesUsualWakeKey)
        defaults.set(5 * 60 + 45, forKey: SleepSchedule.wakeMinutesKey)
        #expect(SleepSchedule.wake(on: today, usual: usual, defaults: defaults, calendar: calendar)
                == today.addingTimeInterval(5.75 * 3600))
    }
}
