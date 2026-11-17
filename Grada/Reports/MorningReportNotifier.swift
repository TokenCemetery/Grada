import Foundation
import Observation
import os
import SwiftData
import UserNotifications

/// Sends the morning report as a local notification once last night's sleep is recorded, never before the
/// wake-up. Runs after each import of new Health data, including in the background.
final class MorningReportNotifier {
    static let requestID = "morningReport"
    /// The day the latest report was scheduled for, in seconds since 1970.
    static let scheduledDayKey = "morningReport.scheduledDay"

    enum Action: Equatable {
        case skip
        case now
        case at(Date)
    }

    private let source: HealthDataSource
    private let context: ModelContext
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "Grada", category: "MorningReport")

    init(source: HealthDataSource, context: ModelContext) {
        self.source = source
        self.context = context
    }

    /// Before the wake-up, (re)schedules today's report for it, so newer data replaces the pending one. From the
    /// wake-up on, sends it now unless today's was already scheduled, which has then been delivered.
    nonisolated static func action(now: Date, wake: Date, today: Date, scheduledDay: Date?) -> Action {
        if now < wake { return .at(wake) }
        return scheduledDay == today ? .skip : .now
    }

    func update() async {
        guard defaults.bool(forKey: SleepSchedule.morningReportKey) else { return }
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        do {
            var builder = SnapshotBuilder(source: source)
            builder.goals = GoalHistory(try context.fetch(FetchDescriptor<GoalChange>()))
            let report = try await MorningReport.load(builder)
            guard report.hasSleep else { return }
            let usual = try await builder.bedtimePlan(need: SleepNeed.baseline, wakeDay: today)?.wake
            let wake = SleepSchedule.wake(on: today, usual: usual, defaults: defaults, calendar: calendar)
            let scheduled = (defaults.object(forKey: Self.scheduledDayKey) as? Double).map(Date.init(timeIntervalSince1970:))

            let trigger: UNNotificationTrigger?
            switch Self.action(now: now, wake: wake, today: today, scheduledDay: scheduled) {
            case .skip: return
            case .now: trigger = nil
            case .at(let date):
                trigger = UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
            }
            let content = UNMutableNotificationContent()
            content.title = "Morning Report"
            content.body = ([report.summary] + report.recommendations.prefix(1).map(\.text))
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            content.sound = .default
            try await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: Self.requestID, content: content, trigger: trigger))
            defaults.set(today.timeIntervalSince1970, forKey: Self.scheduledDayKey)
        } catch {
            logger.error("Morning report not sent: \(error.localizedDescription)")
        }
    }
}

/// Opens Journal on today when a report notification is tapped, and shows report banners while the app is open.
@Observable
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Grows with each tapped report; Journal and the tab bar react to the change.
    private(set) var journalRequests = 0

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run { journalRequests += 1 }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
