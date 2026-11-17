import SwiftUI
import UserNotifications

/// When the user wakes, and whether the morning report comes as a notification.
struct SleepScheduleView: View {
    @Environment(\.healthSource) private var source
    @Environment(HomeModel.self) private var homeModel
    @AppStorage(SleepSchedule.usesUsualWakeKey) private var usesUsualWake = true
    @AppStorage(SleepSchedule.wakeMinutesKey) private var wakeMinutes = SleepSchedule.defaultWakeMinutes
    @AppStorage(SleepSchedule.morningReportKey) private var morningReport = false
    /// Nil while loading.
    @State private var usualWake: UsualWake?

    private struct UsualWake {
        var weekday: Date?
        var weekend: Date?
    }
    @State private var notificationsDenied = false

    private var calendar: Calendar { .current }
    private var today: Date { calendar.startOfDay(for: .now) }

    var body: some View {
        Form {
            Section {
                Toggle("Use Usual Wake-Up", isOn: $usesUsualWake)
                if usesUsualWake {
                    LabeledContent("Weekdays", value: usual(\.weekday))
                    LabeledContent("Weekends", value: usual(\.weekend))
                } else {
                    DatePicker("Wake-Up", selection: wakeTime, displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("Your usual wake-up is the median of the last \(Bedtime.nights) nights, weekdays and weekends apart. Until there are \(Bedtime.minimumNights) nights, \(time(today.addingTimeInterval(Double(SleepSchedule.defaultWakeMinutes) * 60))) is used.")
            }
            Section {
                Toggle("Morning Report", isOn: morningReportEnabled)
            } footer: {
                if notificationsDenied {
                    Text("Notifications are off for Grada. Turn them on in the Settings app › Notifications › Grada.")
                } else {
                    Text("A notification once last night's sleep is in Apple Health, never before your wake-up. The report is always in Journal.")
                }
            }
        }
        .navigationTitle("Sleep Schedule")
        .task {
            notificationsDenied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
            let next = (1...7).map { calendar.date(byAdding: .day, value: $0, to: today)! }
            let weekday = await plan(next.first { !calendar.isDateInWeekend($0) })
            let weekend = await plan(next.first { calendar.isDateInWeekend($0) })
            // A plan that mixed both kinds of night isn't either's usual time.
            usualWake = UsualWake(weekday: weekday?.weekend == false ? weekday?.wake : nil,
                                  weekend: weekend?.weekend == true ? weekend?.wake : nil)
        }
    }

    private func plan(_ day: Date?) async -> Bedtime.Plan? {
        guard let day else { return nil }
        return try? await SnapshotBuilder(source: source).bedtimePlan(need: SleepNeed.baseline, wakeDay: day)
    }

    private func usual(_ kind: KeyPath<UsualWake, Date?>) -> String {
        guard let usualWake else { return "…" }
        return usualWake[keyPath: kind].map(time) ?? "Not enough nights"
    }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    private var wakeTime: Binding<Date> {
        Binding {
            today.addingTimeInterval(Double(wakeMinutes) * 60)
        } set: { date in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            wakeMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    /// Asks for notification permission when turned on; turning it off withdraws a scheduled report.
    private var morningReportEnabled: Binding<Bool> {
        Binding { morningReport } set: { enabled in
            let center = UNUserNotificationCenter.current()
            guard enabled else {
                morningReport = false
                center.removePendingNotificationRequests(withIdentifiers: [MorningReportNotifier.requestID])
                return
            }
            Task {
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                morningReport = granted
                notificationsDenied = !granted
                // Sends this morning's report now if it's due.
                if granted { await homeModel.importer?.importRecent() }
            }
        }
    }
}
