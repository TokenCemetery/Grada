import SwiftData
import SwiftUI

/// Months scroll vertically under a pinned type picker. Health and Recovery colour each day by how good
/// it was; Training draws each day's sports. Tapping a day opens a sheet with that type's cards for the day.
struct CalendarView: View {
    @Environment(CalendarModel.self) private var model
    @Query private var goalChanges: [GoalChange]
    @AppStorage("calendarMetric") private var metric: CalendarMetric = .health
    @AppStorage("colorBlindPalette") private var colorBlind = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var selectedDay: Date?
    // TODO(#40, v3, Reports): a monthly summary like Whoop's "Month in Review" belongs in reports, not here.

    private var calendar: Calendar { .current }
    private var today: Date { calendar.startOfDay(for: .now) }

    private var months: [Date] {
        guard let first = model.firstMonth else { return [] }
        let current = calendar.dateInterval(of: .month, for: today)!.start
        return sequence(first: first) { calendar.date(byAdding: .month, value: 1, to: $0)! }
            .prefix { $0 <= current }
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(months, id: \.self) { month in
                            MonthView(month: month, metric: metric, today: today, selected: selectedDay, colorBlind: colorBlind) { day in
                                selectedDay = day
                            }
                            .task { await model.reveal(month, metric: metric, goals: GoalHistory(goalChanges)) }
                        }
                    }
                    .padding()
                    .readableWidth()
                }
                // Opens on the current month; no Today button needed.
                .defaultScrollAnchor(.bottom)
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(Color(.systemGroupedBackground))
            // A flag, not `sheet(item:)`: tapping another day while the sheet is open updates it in place.
            .sheet(isPresented: Binding(get: { selectedDay != nil }, set: { if !$0 { selectedDay = nil } })) {
                DaySheet(day: selectedDay ?? today, metric: metric)
                    // The calendar is already showing behind the sheet: pick the type and close the sheet.
                    .environment(\.openCalendar, OpenCalendarAction { picked in
                        if let picked { metric = picked }
                        selectedDay = nil
                    })
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
        .task(id: metric) { await model.load(metric, goals: GoalHistory(goalChanges)) }
        .onChange(of: model.importer?.revision) {
            Task { await model.load(metric, goals: GoalHistory(goalChanges)) }
        }
        .onChange(of: GoalHistory(goalChanges)) {
            Task { await model.load(metric, goals: GoalHistory(goalChanges)) }
        }
    }

    /// Stays put while the months scroll, so the picker and legend are always in view.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A landscape iPhone is too short for the title; the tab bar already names the screen.
            if verticalSizeClass != .compact {
                Text("Calendar")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CalendarMetric.allCases) { option in
                        Button(option.title) { metric = option }
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(option == metric ? Color.accentColor : .primary)
                            .background(option == metric ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground),
                                        in: Capsule())
                    }
                }
                .padding(.horizontal)
            }
            legend.padding(.horizontal)
            WeekdayRow(calendar: calendar).padding(.horizontal)
        }
        .readableWidth()
        .padding(.top, 4)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var legend: some View {
        if metric.isRated {
            ratingLegend
        } else {
            sportLegend
        }
    }

    private var ratingLegend: some View {
        HStack(spacing: 12) {
            ForEach(DayRating.allCases, id: \.self) { rating in
                Label {
                    Text(rating.title)
                } icon: {
                    Circle().fill(rating.fill(colorBlind: colorBlind)).frame(width: 10, height: 10)
                }
            }
            Label {
                Text("No data")
            } icon: {
                Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 10, height: 10)
            }
            Label {
                Text("Workout")
            } icon: {
                Circle().fill(.secondary).frame(width: 4, height: 4)
            }
        }
        .labelStyle(LegendLabelStyle())
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// The most common sports in the loaded history, then rest days.
    private var sportLegend: some View {
        HStack(spacing: 12) {
            ForEach(WorkoutDay.topSports(model.workoutDays.values, limit: 4), id: \.name) { sport in
                Label {
                    Text(sport.name)
                } icon: {
                    Circle().fill(WorkoutColors.color(symbol: sport.symbol)).frame(width: 10, height: 10)
                }
            }
            Label {
                Text("Rest")
            } icon: {
                Circle().fill(Color(.tertiarySystemFill)).frame(width: 6, height: 6)
            }
        }
        .labelStyle(LegendLabelStyle())
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct LegendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

private struct WeekdayRow: View {
    let calendar: Calendar

    var body: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                Text(symbols[(index + shift) % 7])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct MonthView: View {
    @Environment(CalendarModel.self) private var model
    let month: Date
    let metric: CalendarMetric
    let today: Date
    let selected: Date?
    let colorBlind: Bool
    let onSelect: (Date) -> Void

    private var calendar: Calendar { .current }

    private var days: [Date] {
        let range = calendar.range(of: .day, in: .month, for: month)!
        return range.map { calendar.date(byAdding: .day, value: $0 - 1, to: month)! }
    }

    /// Empty cells before the 1st, so it lands under its weekday.
    private var leadingBlanks: Int {
        (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
    }

    /// The month's days in rows of 7, nil for the empty cells before the 1st and after the last day.
    private var weeks: [[Date?]] {
        var cells: [Date?] = Array(repeating: nil, count: leadingBlanks) + days
        cells += Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()
                if metric.isRated { counts } else { trainingTotals }
            }
            // Plain rows, not a LazyVGrid: a lazy grid inside the calendar's LazyVStack left the
            // calendar blank on first open until something changed its layout.
            VStack(spacing: 8) {
                ForEach(weeks.indices, id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { column in
                            Group {
                                if let day = weeks[week][column] { cell(day) } else { Color.clear.frame(height: 1) }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: Date) -> some View {
        Group {
            if metric.isRated {
                DayCell(day: day,
                        rating: model.ratings[day],
                        hasWorkout: model.workoutDays[day] != nil,
                        isToday: day == today,
                        isFuture: day > today,
                        isSelected: day == selected,
                        colorBlind: colorBlind)
            } else {
                TrainingDayCell(day: day,
                                workouts: model.workoutDays[day],
                                isToday: day == today,
                                isFuture: day > today,
                                isSelected: day == selected)
            }
        }
        .onTapGesture { if day <= today { onSelect(day) } }
    }

    /// The month's workouts and their total time.
    private var trainingTotals: some View {
        let month = days.compactMap { model.workoutDays[$0] }
        let count = month.reduce(0) { $0 + $1.workouts }
        let minutes = month.reduce(0) { $0 + $1.minutes }
        return Text(count == 0 ? "No workouts" : "\(count == 1 ? "1 workout" : "\(count) workouts") · \(SnapshotBuilder.hoursMinutes(minutes * 60))")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    /// Green, yellow and red day counts for the month.
    private var counts: some View {
        HStack(spacing: 4) {
            ForEach(DayRating.allCases, id: \.self) { rating in
                let count = days.filter { model.ratings[$0] == rating }.count
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .foregroundStyle(rating.foreground(colorBlind: colorBlind))
                        .background(rating.fill(colorBlind: colorBlind), in: Capsule())
                        .accessibilityLabel("\(count) \(rating.title.lowercased()) days")
                }
            }
        }
    }
}

private struct DayCell: View {
    let day: Date
    let rating: DayRating?
    let hasWorkout: Bool
    let isToday: Bool
    let isFuture: Bool
    let isSelected: Bool
    let colorBlind: Bool

    private let size: CGFloat = 38

    private var textColor: Color {
        if let rating { return rating.foreground(colorBlind: colorBlind) }
        return isFuture ? .secondary.opacity(0.6) : .secondary
    }

    var body: some View {
        VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.footnote.weight(isToday ? .bold : .regular))
                .monospacedDigit()
            Circle()
                .fill(hasWorkout && !isFuture ? textColor : .clear)
                .frame(width: 4, height: 4)
        }
        .foregroundStyle(textColor)
        .frame(width: size, height: size)
        .background { background }
        .overlay {
            if isToday {
                Circle().strokeBorder(.primary, lineWidth: 2).padding(-4)
            } else if isSelected {
                Circle().strokeBorder(.primary, lineWidth: 1.5).padding(-3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isFuture ? [] : .isButton)
    }

    @ViewBuilder
    private var background: some View {
        if let rating {
            Circle().fill(rating.fill(colorBlind: colorBlind))
        } else if isFuture {
            Circle().strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        } else {
            Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 1)
        }
    }

    private var accessibilityText: String {
        var parts = [day.formatted(date: .complete, time: .omitted)]
        parts.append(rating?.title ?? (isFuture ? "Upcoming" : "No data"))
        if hasWorkout { parts.append("Workout") }
        return parts.joined(separator: ", ")
    }
}

/// A Training day: the date over a pie of the day's sports, bigger for longer days. A rest day is a small
/// grey dot.
private struct TrainingDayCell: View {
    let day: Date
    let workouts: WorkoutDay?
    let isToday: Bool
    let isFuture: Bool
    let isSelected: Bool

    private let size: CGFloat = 38

    var body: some View {
        VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.caption2.weight(isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isFuture ? .secondary : .primary)
            if isFuture {
                Spacer(minLength: 0)
            } else {
                SportPie(day: workouts ?? WorkoutDay(), diameter: diameter)
                    .frame(height: 20)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if isToday {
                Circle().strokeBorder(.primary, lineWidth: 2).padding(-4)
            } else if isSelected {
                Circle().strokeBorder(.primary, lineWidth: 1.5).padding(-3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isFuture ? [] : .isButton)
    }

    private var diameter: CGFloat {
        guard let minutes = workouts?.minutes, minutes > 0 else { return 6 }
        return min(10 + CGFloat(minutes) / 10, 20)
    }

    private var accessibilityText: String {
        var parts = [day.formatted(date: .complete, time: .omitted)]
        if isFuture {
            parts.append("Upcoming")
        } else if let workouts, !workouts.sports.isEmpty {
            parts += workouts.sports.map { "\($0.name) \(SnapshotBuilder.hoursMinutes($0.minutes * 60))" }
        } else {
            parts.append("Rest day")
        }
        return parts.joined(separator: ", ")
    }
}

/// The selected day's cards for the calendar type, as they looked at the end of that day.
/// Fully expanded, this sheet is the day view.
private struct DaySheet: View {
    @Environment(CalendarModel.self) private var model
    @Query(sort: \HomeCard.position) private var homeCards: [HomeCard]
    @Query private var goalChanges: [GoalChange]
    @Query private var journalEntries: [JournalEntry]
    let day: Date
    let metric: CalendarMetric
    @State private var snapshots: [CardKind: CardSnapshot] = [:]
    @State private var workouts: [CardSnapshot] = []
    /// The day and type whose cards are loaded.
    @State private var loaded: LoadKey?

    private struct LoadKey: Equatable {
        let day: Date
        let metric: CalendarMetric
    }

    private var isLoaded: Bool { loaded == LoadKey(day: day, metric: metric) }

    /// Each card as it looks on Home, preferring the 7-day variant when Home has both. Cards not on Home
    /// use their default look.
    private var cards: [CardID] {
        let onHome = homeCards.compactMap(\.cardID)
        return metric.kinds.map { kind in
            let variants = onHome.filter { $0.kind == kind }.map(\.variant)
            let variant = variants.contains(.week) ? .week : variants.first ?? kind.defaultVariant
            return CardID(kind: kind, variant: variant)
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(for: MetricRoute.self) { MetricDetailView(route: $0) }
                .navigationDestination(for: WorkoutRoute.self) { WorkoutDetailView(workout: $0.workout) }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.title3.weight(.semibold))
                    .padding(.top, 20)
                let dayKey = DayKey.make(day, calendar: .current)
                DayTagsView(entries: journalEntries.filter { $0.dayKey == dayKey })
                if metric == .training, isLoaded {
                    if workouts.isEmpty {
                        Text("Rest day").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(workouts.indices, id: \.self) { index in
                        CardLink(kind: .lastWorkout, snapshot: workouts[index], day: pastDay)
                    }
                }
                HomeGrid(items: metric.kinds) { card($0) }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .background(Color(.systemGroupedBackground))
        .environment(\.chartLastDay, day)
        .task(id: LoadKey(day: day, metric: metric)) {
            let key = LoadKey(day: day, metric: metric)
            let newSnapshots = await model.snapshots(for: day, cards: cards, goals: GoalHistory(goalChanges))
            // A load cancelled by tapping another day can finish after the newer one; drop it.
            guard !Task.isCancelled else { return }
            snapshots = newSnapshots
            workouts = metric == .training ? model.workoutSnapshots(for: day) : []
            loaded = key
        }
    }

    private var pastDay: Date? { Calendar.current.isDateInToday(day) ? nil : day }

    /// Shows the loading state until this day's values arrive, never the previous day's.
    private func card(_ kind: CardKind) -> some View {
        CardLink(kind: kind, snapshot: isLoaded ? snapshots[kind] : nil, day: pastDay)
    }
}

#Preview {
    CalendarView()
        .environment(CalendarModel(source: SampleDataSource()))
        .environment(\.healthSource, SampleDataSource())
        .modelContainer(for: [HomeCard.self, GoalChange.self, JournalEntry.self], inMemory: true)
}
