import SwiftUI
import UserNotifications

/// When the user sleeps and wakes, and which reports come as notifications.
struct SleepScheduleView: View {
    @Environment(\.healthSource) private var source
    @Environment(HomeModel.self) private var homeModel
    @AppStorage(SleepSchedule.usesUsualTimesKey) private var usesUsualTimes = true
    @AppStorage(SleepSchedule.bedtimeMinutesKey) private var bedtimeMinutes = SleepSchedule.defaultBedtimeMinutes
    @AppStorage(SleepSchedule.wakeMinutesKey) private var wakeMinutes = SleepSchedule.defaultWakeMinutes
    @AppStorage(SleepSchedule.windDownMinutesKey) private var windDownMinutes = SleepSchedule.defaultWindDownMinutes
    @AppStorage(SleepSchedule.morningReportKey) private var morningReport = false
    @AppStorage(SleepSchedule.eveningReportKey) private var eveningReport = false
    /// Nil while loading.
    @State private var usual: UsualTimes?
    @State private var notificationsDenied = false

    /// Usual bedtime and wake-up for weekday and weekend nights; nil without enough nights of that kind.
    private struct UsualTimes {
        var weekday: Bedtime.Plan?
        var weekend: Bedtime.Plan?
    }

    private var calendar: Calendar { .current }
    private var today: Date { calendar.startOfDay(for: .now) }

    var body: some View {
        Form {
            Section {
                Toggle("Use Usual Times", isOn: $usesUsualTimes)
                if usesUsualTimes {
                    LabeledContent("Weekdays", value: usualText(\.weekday))
                    LabeledContent("Weekends", value: usualText(\.weekend))
                } else {
                    DatePicker("Bedtime", selection: minutes($bedtimeMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("Wake-Up", selection: minutes($wakeMinutes), displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("Your usual times are the medians of the last \(Bedtime.nights) nights, weekdays and weekends apart. Until there are \(Bedtime.minimumNights) nights, \(time(minutes: SleepSchedule.defaultBedtimeMinutes))–\(time(minutes: SleepSchedule.defaultWakeMinutes)) is used.")
            }
            Section {
                Toggle("Morning Report", isOn: enabling($morningReport, id: ReportNotifier.morningID))
                Toggle("Evening Report", isOn: enabling($eveningReport, id: ReportNotifier.eveningID))
                if eveningReport {
                    Picker("Before Bedtime", selection: $windDownMinutes) {
                        ForEach([30, 60, 90, 120], id: \.self) { Text(SnapshotBuilder.hoursMinutes(Double($0) * 60)).tag($0) }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                if notificationsDenied {
                    Text("Notifications are off for Grada. Turn them on in the Settings app › Notifications › Grada.")
                } else {
                    Text("The morning report comes once last night's sleep is in Apple Health, never before your wake-up. The evening report comes before your bedtime, with time to wind down; no study sets how long, so it's your choice. Both are always in Journal.")
                }
            }
        }
        .navigationTitle("Sleep Schedule")
        // A pending report moves with the times.
        .onChange(of: [bedtimeMinutes, wakeMinutes, windDownMinutes, usesUsualTimes ? 1 : 0]) {
            Task { await homeModel.importer?.importRecent() }
        }
        .task {
            notificationsDenied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
            let next = (1...7).map { calendar.date(byAdding: .day, value: $0, to: today)! }
            let weekday = await plan(next.first { !calendar.isDateInWeekend($0) })
            let weekend = await plan(next.first { calendar.isDateInWeekend($0) })
            // A plan that mixed both kinds of night isn't either's usual time.
            usual = UsualTimes(weekday: weekday?.weekend == false ? weekday : nil,
                               weekend: weekend?.weekend == true ? weekend : nil)
        }
    }

    private func plan(_ wakeDay: Date?) async -> Bedtime.Plan? {
        guard let wakeDay else { return nil }
        return try? await SnapshotBuilder(source: source).bedtimePlan(need: SleepNeed.baseline, wakeDay: wakeDay)
    }

    private func usualText(_ kind: KeyPath<UsualTimes, Bedtime.Plan?>) -> String {
        guard let usual else { return "…" }
        return usual[keyPath: kind].map { "\(time($0.usualBedtime))–\(time($0.wake))" } ?? String(localized: "Not enough nights")
    }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    private func time(minutes: Int) -> String { time(today.addingTimeInterval(Double(minutes) * 60)) }

    /// A time of day for minutes after midnight.
    private func minutes(_ value: Binding<Int>) -> Binding<Date> {
        Binding {
            today.addingTimeInterval(Double(value.wrappedValue) * 60)
        } set: { date in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            value.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    /// Asks for notification permission when turned on; turning it off withdraws a scheduled report.
    private func enabling(_ setting: Binding<Bool>, id: String) -> Binding<Bool> {
        Binding { setting.wrappedValue } set: { enabled in
            let center = UNUserNotificationCenter.current()
            guard enabled else {
                setting.wrappedValue = false
                ReportNotifier.withdraw(id)
                return
            }
            Task {
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                setting.wrappedValue = granted
                notificationsDenied = !granted
                // Schedules or sends the report now if it's due.
                if granted { await homeModel.importer?.importRecent() }
            }
        }
    }
}
