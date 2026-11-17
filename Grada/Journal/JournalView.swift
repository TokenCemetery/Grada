import SwiftData
import SwiftUI

/// Tags for today or a past day, grouped like the tag list. Amount tags show a stepper once marked.
struct JournalView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.healthSource) private var healthSource
    @Environment(HomeModel.self) private var homeModel
    @Query private var goalChanges: [GoalChange]
    @State private var morning: DailyReport?
    @State private var evening: DailyReport?
    /// A report row's detail screen.
    @State private var openedRoute: MetricRoute?
    @Query private var allEntries: [JournalEntry]
    @State private var day = Calendar.current.startOfDay(for: .now)
    /// The day the reports are for, so another day's aren't shown while these load.
    @State private var loadedDay: Date?
    /// Changes on every save, for the haptic and the checkmark bounce.
    @State private var saves = 0
    /// The last 90 nights, for how Alcohol and Caffeine change the night after.
    @State private var nights: [Date: [TagEffect.Metric: Double]]?
    /// Tags health data suggests for the shown day, and the day they're for.
    @State private var suggestions: (day: Date, items: [JournalSuggestion]) = (.distantPast, [])
    /// Suggestions the user dismissed, as "dayKey:tag".
    @AppStorage("dismissedJournalSuggestions") private var dismissed = ""

    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: .now) }
    private var store: JournalStore { JournalStore(context: modelContext) }

    /// The shown day's entries; the first wins if iCloud delivered duplicates.
    private var entries: [JournalTag: JournalEntry] {
        let key = DayKey.make(day, calendar: calendar)
        var result: [JournalTag: JournalEntry] = [:]
        for entry in allEntries where entry.dayKey == key {
            if let tag = entry.tag, result[tag] == nil { result[tag] = entry }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DayPicker(day: $day, today: today, isSaved: !entries.isEmpty, saves: saves)
                }
                Section {
                    VStack(spacing: 24) {
                        ReportColumns(morning: morning, evening: evening, day: day) { openedRoute = $0 }
                        if !recommendations.isEmpty {
                            RecommendationsView(recommendations: recommendations)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    // The tags' explanation sits just above them.
                    Text("Log what happened during the day: Grada links it to the night after, so evening drinks go on the day you had them.\n\nA dashed circle is a tag Grada suggests from your health data: tap it to keep it.\n\nUnder Alcohol and Caffeine, the night after days you logged them is compared with other nights in the last \(TagEffect.windowDays) days. A change shows only when it's clearly bigger than how much your nights vary, each side needs \(TagEffect.minimumNights) nights, and nights after Illness or Night shift are left out.\n\nTags are saved as you tap them.")
                }
                let captions = effectCaptions
                let suggested = shownSuggestions
                ForEach(JournalTag.Group.allCases, id: \.self) { group in
                    Section(group.title) {
                        ForEach(group.tags) { row($0, caption: captions[$0], suggestion: suggested[$0]) }
                    }
                }
            }
            .navigationTitle("Journal")
            .toolbar {
                NavigationLink { MonthSummaryView(day: day) } label: {
                    Label("Month Summary", systemImage: "calendar.badge.clock")
                }
            }
            .sensoryFeedback(.selection, trigger: saves)
            .navigationDestination(for: MetricRoute.self) { MetricDetailView(route: $0) }
            .navigationDestination(item: $openedRoute) { MetricDetailView(route: $0) }
            .navigationDestination(for: WorkoutRoute.self) { WorkoutDetailView(workout: $0.workout) }
            // Reloads for another day and whenever new Health data is saved.
            .task(id: ReportKey(day: day, revision: homeModel.importer?.revision ?? 0)) {
                if loadedDay != day { (morning, evening) = (nil, nil) }
                var builder = SnapshotBuilder.forDay(day, source: healthSource, calendar: calendar)
                builder.goals = GoalHistory(goalChanges)
                let loadedMorning = (try? await DailyReport.load(.morning, builder)) ?? DailyReport(kind: .morning)
                let loadedEvening = (try? await DailyReport.load(.evening, builder)) ?? DailyReport(kind: .evening)
                guard !Task.isCancelled else { return }
                (morning, evening) = (loadedMorning, loadedEvening)
                loadedDay = day
            }
            .task(id: homeModel.importer?.revision ?? 0) {
                nights = try? await TagEffect.nights(source: healthSource)
            }
            .task(id: SuggestionKey(day: day, revision: homeModel.importer?.revision ?? 0, alcoholDayBefore: alcoholDayBefore)) {
                let items = (try? await JournalSuggestion.load(day: day, alcoholDayBefore: alcoholDayBefore,
                                                               source: healthSource, calendar: calendar)) ?? []
                guard !Task.isCancelled else { return }
                suggestions = (day, items)
            }
            // A tapped report notification opens today's.
            .onChange(of: NotificationRouter.shared.journalRequests) { day = today }
        }
    }

    /// Both reports' recommendations, each once: both take Strain's.
    private var recommendations: [Recommendation] {
        let all = (morning?.recommendations ?? []) + (evening?.recommendations ?? [])
        return all.enumerated().filter { index, item in !all[..<index].contains(item) }.map(\.element)
    }

    private struct ReportKey: Equatable {
        let day: Date
        let revision: Int
    }

    /// Each compared tag's line on the night after, from every logged day and the loaded nights.
    private var effectCaptions: [JournalTag: String] {
        guard let nights else { return [:] }
        var logged: [String: Set<JournalTag>] = [:]
        for entry in allEntries {
            if let tag = entry.tag { logged[entry.dayKey, default: []].insert(tag) }
        }
        return TagEffect.effects(logged: logged, nights: nights, calendar: calendar).mapValues(TagEffect.caption)
    }

    private var alcoholDayBefore: Bool {
        let key = DayKey.make(calendar.date(byAdding: .day, value: -1, to: day)!, calendar: calendar)
        return allEntries.contains { $0.dayKey == key && $0.tag == .alcohol }
    }

    /// The shown day's suggestions by tag, without tags already logged or dismissed.
    private var shownSuggestions: [JournalTag: JournalSuggestion] {
        guard suggestions.day == day else { return [:] }
        let logged = entries
        let key = DayKey.make(day, calendar: calendar)
        let dismissedKeys = Set(dismissed.split(separator: ",").map(String.init))
        return Dictionary(suggestions.items.filter { logged[$0.tag] == nil && !dismissedKeys.contains("\(key):\($0.tag.rawValue)") }
            .map { ($0.tag, $0) }) { first, _ in first }
    }

    private func dismiss(_ suggestion: JournalSuggestion) {
        // The latest 200 are plenty: suggestions only show for days someone goes back to.
        let keys = dismissed.split(separator: ",").map(String.init) + ["\(DayKey.make(day, calendar: calendar)):\(suggestion.tag.rawValue)"]
        dismissed = keys.suffix(200).joined(separator: ",")
    }

    private struct SuggestionKey: Equatable {
        let day: Date
        let revision: Int
        let alcoholDayBefore: Bool
    }

    @ViewBuilder
    private func row(_ tag: JournalTag, caption: String?, suggestion: JournalSuggestion?) -> some View {
        let entry = entries[tag]
        let caption = suggestion.map { "Suggested · \($0.reason)" } ?? caption
        HStack {
            Button {
                store.toggle(tag, on: day)
                if let amount = suggestion?.amount { store.setAmount(amount, for: tag, on: day) }
                saves += 1
            } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tag.title)
                            if let caption {
                                Text(caption).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: tag.symbol)
                    }
                    Spacer()
                    Image(systemName: entry != nil ? "checkmark.circle.fill" : suggestion != nil ? "circle.dashed" : "circle")
                        .foregroundStyle(entry != nil || suggestion != nil ? Color.accentColor : Color.secondary)
                        .imageScale(.large)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tag.title)
            .accessibilityValue(caption ?? "")
            .accessibilityAddTraits(entry == nil ? [] : .isSelected)
            if let suggestion {
                Button { dismiss(suggestion) } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .tint(.secondary)
                .accessibilityLabel("Dismiss suggested \(tag.title)")
            }
        }
        if let entry, let amount = tag.amount {
            Stepper(amount.formatted(entry.amount ?? amount.initial),
                    value: Binding(get: { entry.amount ?? amount.initial },
                                   set: {
                                       store.setAmount($0, for: tag, on: day)
                                       saves += 1
                                   }),
                    in: amount.range, step: amount.step)
                .padding(.leading, 36)
        }
    }
}

/// Previous and next day around the date, which opens a calendar to jump to any past day.
private struct DayPicker: View {
    @Binding var day: Date
    let today: Date
    /// Every tap saves at once, and there's no Save button: a checkmark beside the date says so.
    let isSaved: Bool
    /// Changes on every save, to bounce the checkmark.
    let saves: Int
    @State private var isPickingDay = false
    private let calendar = Calendar.current

    var body: some View {
        HStack {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous day")
            Spacer()
            Button { isPickingDay = true } label: {
                Text(title).font(.headline).foregroundStyle(.primary)
            }
            .overlay(alignment: .trailing) {
                if isSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: saves)
                        .offset(x: 26)
                        .accessibilityLabel("Saved")
                }
            }
            .popover(isPresented: $isPickingDay) {
                DatePicker("Day", selection: Binding(get: { day }, set: {
                    day = calendar.startOfDay(for: $0)
                    isPickingDay = false
                }), in: ...today, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding()
                    .frame(minWidth: 320)
                    .presentationCompactAdaptation(.popover)
            }
            Spacer()
            Button { move(1) } label: { Image(systemName: "chevron.right") }
                .disabled(day >= today)
                .accessibilityLabel("Next day")
        }
        .buttonStyle(.borderless)
    }

    /// "Today", otherwise the weekday and date, with the year only outside the current one.
    private var title: String {
        if day == today { return "Today" }
        let format = Date.FormatStyle.dateTime.weekday(.wide).day().month(.abbreviated)
        return calendar.isDate(day, equalTo: today, toGranularity: .year)
            ? day.formatted(format)
            : day.formatted(format.year())
    }

    private func move(_ days: Int) {
        day = min(calendar.date(byAdding: .day, value: days, to: day)!, today)
    }
}

/// The day's tags as a wrapped row, for the calendar's day sheet.
struct DayTagsView: View {
    let entries: [JournalEntry]

    var body: some View {
        let tagged = entries.compactMap { entry in entry.tag.map { (tag: $0, amount: entry.amount) } }
            .sorted { JournalTag.allCases.firstIndex(of: $0.tag)! < JournalTag.allCases.firstIndex(of: $1.tag)! }
        if !tagged.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(tagged, id: \.tag) { item in
                    Label(item.tag.label(amount: item.amount), systemImage: item.tag.symbol)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                }
            }
        }
    }
}

/// Lays children out left to right, wrapping to a new line when the row is full.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview {
    JournalView()
        .environment(HomeModel(source: SampleDataSource()))
        .environment(\.healthSource, SampleDataSource())
        .modelContainer(for: [JournalEntry.self, GoalChange.self], inMemory: true)
}
