import Foundation
import Observation
import os
import SwiftData
import UserNotifications

/// Sends the morning and evening reports and the afternoon check-in as local notifications. Runs after each
/// import of new Health data, including in the background, so each pending notification carries the latest numbers.
final class ReportNotifier {
    static let morningID = "morningReport"
    static let eveningID = "eveningReport"
    /// The day the latest morning report was scheduled for, in seconds since 1970.
    static let morningScheduledDayKey = "morningReport.scheduledDay"

    enum Action: Equatable {
        case skip
        case now
        case at(Date)
    }

    private let source: HealthDataSource
    private let context: ModelContext
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "Grada", category: "Reports")

    init(source: HealthDataSource, context: ModelContext) {
        self.source = source
        self.context = context
    }

    /// The morning report waits for last night's sleep and the wake-up. Before the wake-up it is (re)scheduled
    /// for it, so newer data replaces the pending one; from the wake-up on, it's sent now unless today's was
    /// already scheduled, which has then been delivered.
    nonisolated static func morningAction(now: Date, wake: Date, today: Date, scheduledDay: Date?) -> Action {
        if now < wake { return .at(wake) }
        return scheduledDay == today ? .skip : .now
    }

    /// The evening report comes at its time each day with the latest numbers; once that has passed, today's is done.
    nonisolated static func eveningAction(now: Date, at time: Date) -> Action {
        now < time ? .at(time) : .skip
    }

    /// Seconds until `date`, at least one. A calendar trigger would drop the seconds and could land in the past.
    nonisolated static func delay(until date: Date, now: Date) -> TimeInterval {
        max(date.timeIntervalSince(now), 1)
    }

    /// Withdraws a pending report. The morning one also forgets it was scheduled today, so turning it back on
    /// later that day sends it.
    static func withdraw(_ id: String, defaults: UserDefaults = .standard) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        if id == morningID { defaults.removeObject(forKey: morningScheduledDayKey) }
    }

    func update() async {
        let morning = defaults.bool(forKey: SleepSchedule.morningReportKey)
        let evening = defaults.bool(forKey: SleepSchedule.eveningReportKey)
        let checkIn = defaults.bool(forKey: SleepSchedule.checkInKey)
        guard morning || evening || checkIn else { return }
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        do {
            var builder = SnapshotBuilder(source: source)
            builder.goals = GoalHistory(try context.fetch(FetchDescriptor<GoalChange>()))
            // Loaded even when it isn't sent: it saves today's plan, which the check-in and the evening report follow.
            let report = try await DailyReport.load(.morning, builder, defaults: defaults)
            if morning, report.hasData {
                let usual = try await builder.bedtimePlan(need: SleepNeed.baseline, wakeDay: today)?.wake
                let wake = SleepSchedule.wake(on: today, usual: usual, defaults: defaults, calendar: calendar)
                let scheduled = (defaults.object(forKey: Self.morningScheduledDayKey) as? Double)
                    .map(Date.init(timeIntervalSince1970:))
                let action = Self.morningAction(now: now, wake: wake, today: today, scheduledDay: scheduled)
                if try await send(title: report.notificationTitle, body: report.notificationBody, id: Self.morningID, action: action) {
                    defaults.set(today.timeIntervalSince1970, forKey: Self.morningScheduledDayKey)
                }
            }
            guard evening || checkIn else { return }
            let usual = try await builder.bedtimePlan(need: SleepNeed.baseline, wakeDay: tomorrow)?.usualBedtime
            let bedtime = SleepSchedule.bedtime(on: today, usual: usual, defaults: defaults, calendar: calendar)
            if evening {
                let action = Self.eveningAction(now: now, at: bedtime.addingTimeInterval(-SleepSchedule.windDown(defaults)))
                if action == .skip {
                    // The time has passed, or moved earlier than now: nothing should still wait for tonight.
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.eveningID])
                } else {
                    let report = try await DailyReport.load(.evening, builder, defaults: defaults, forNotification: true)
                    _ = try await send(title: report.notificationTitle, body: report.notificationBody, id: Self.eveningID, action: action)
                }
            } else {
                // Saves tonight's bedtime for tomorrow's follow-up, which the evening report does when it's sent.
                _ = try await DailyReport.load(.evening, builder, defaults: defaults)
            }
            if checkIn {
                // Rescheduled with each import, so a goal reached in the meantime withdraws it.
                let action = Self.eveningAction(now: now, at: bedtime.addingTimeInterval(-CheckIn.beforeBedtime))
                if action != .skip, let message = try await CheckIn.message(builder, defaults: defaults) {
                    _ = try await send(title: message.title, body: message.body, id: CheckIn.id, action: action)
                } else {
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [CheckIn.id])
                }
            }
        } catch {
            logger.error("Report not sent: \(error.localizedDescription)")
        }
    }

    /// Adds or replaces the notification; false when `action` is to skip.
    private func send(title: String, body: String, id: String, action: Action) async throws -> Bool {
        let trigger: UNNotificationTrigger?
        switch action {
        case .skip: return false
        case .now: trigger = nil
        case .at(let date):
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.delay(until: date, now: .now), repeats: false)
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        return true
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
