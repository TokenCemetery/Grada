import SwiftData
import SwiftUI

/// Months scroll vertically under a pinned metric picker; each day is a dot coloured by how good it was.
/// Tapping a day opens a sheet with that day's Home cards.
struct CalendarView: View {
    @Environment(CalendarModel.self) private var model
    @AppStorage("calendarMetric") private var metric: CalendarMetric = .healthStatus
    @AppStorage("colorBlindPalette") private var colorBlind = false
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
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(months, id: \.self) { month in
                                MonthView(month: month, today: today, selected: selectedDay, colorBlind: colorBlind) { day in
                                    selectedDay = day
                                }
                                .id(month)
                            }
                        }
                        .padding()
                    }
                    .defaultScrollAnchor(.bottom)
                }
                .navigationTitle("Calendar")
                .toolbar {
                    Button("Today") {
                        withAnimation { proxy.scrollTo(months.last, anchor: .bottom) }
                        selectedDay = today
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            // A flag, not `sheet(item:)`: tapping another day while the sheet is open updates it in place.
            .sheet(isPresented: Binding(get: { selectedDay != nil }, set: { if !$0 { selectedDay = nil } })) {
                DaySheet(day: selectedDay ?? today)
                    // The calendar is already showing behind the sheet: pick the metric and close the sheet.
                    .environment(\.openCalendar, OpenCalendarAction { picked in
                        if let picked { metric = picked }
                        selectedDay = nil
                    })
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
        .task(id: metric) { await model.load(metric) }
        .onChange(of: model.importer?.revision) {
            Task { await model.load(metric) }
        }
    }

    /// Stays put while the months scroll, so the picker and legend are always in view.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            Divider()
        }
        .padding(.top, 4)
    }

    private var legend: some View {
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
    let today: Date
    let selected: Date?
    let colorBlind: Bool
    let onSelect: (Date) -> Void

    private var calendar: Calendar { .current }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    private var days: [Date] {
        let range = calendar.range(of: .day, in: .month, for: month)!
        return range.map { calendar.date(byAdding: .day, value: $0 - 1, to: month)! }
    }

    /// Empty cells before the 1st, so it lands under its weekday.
    private var leadingBlanks: Int {
        (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()
                counts
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<leadingBlanks, id: \.self) { _ in Color.clear.frame(height: 1) }
                ForEach(days, id: \.self) { day in
                    DayCell(day: day,
                            rating: model.ratings[day],
                            hasWorkout: model.workoutDays.contains(day),
                            isToday: day == today,
                            isFuture: day > today,
                            isSelected: day == selected,
                            colorBlind: colorBlind)
                        .onTapGesture { if day <= today { onSelect(day) } }
                }
            }
        }
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

/// The selected day's Home cards in Home order, as they looked at the end of that day.
/// Fully expanded, this sheet is the day view.
private struct DaySheet: View {
    @Environment(CalendarModel.self) private var model
    @Query(sort: \HomeCard.position) private var cards: [HomeCard]
    let day: Date
    @State private var snapshots: [CardKind: CardSnapshot] = [:]
    @State private var loadedDay: Date?

    private var kinds: [CardKind] { cards.compactMap(\.kind) }

    var body: some View {
        NavigationStack {
            content.navigationDestination(for: MetricRoute.self) { MetricDetailView(route: $0) }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.title3.weight(.semibold))
                    .padding(.top, 20)
                card(.healthStatus)
                ForEach(HomeLayout.rows(for: kinds), id: \.self) { row in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(row) { card($0) }
                        if row.count == 1, row[0].size == .square {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .background(Color(.systemGroupedBackground))
        .task(id: day) {
            snapshots = await model.snapshots(for: day, kinds: [.healthStatus] + kinds)
            loadedDay = day
        }
    }

    /// Shows the loading state until this day's values arrive, never the previous day's.
    private func card(_ kind: CardKind) -> some View {
        CardLink(kind: kind, snapshot: loadedDay == day ? snapshots[kind] : nil,
                 day: Calendar.current.isDateInToday(day) ? nil : day)
    }
}

#Preview {
    CalendarView()
        .environment(CalendarModel(source: SampleDataSource()))
        .environment(\.healthSource, SampleDataSource())
        .modelContainer(for: HomeCard.self, inMemory: true)
}
