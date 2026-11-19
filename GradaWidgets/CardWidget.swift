import AppIntents
import SwiftUI
import WidgetKit

/// One Grada card on the Home Screen or Lock Screen. It draws what the app last wrote to the App Group
/// container and reads no health data itself (#129).
struct CardWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetCards.widgetKind, intent: SelectCardIntent.self, provider: CardProvider()) { entry in
            CardWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(.secondarySystemGroupedBackground) }
        }
        .configurationDisplayName("Grada Card")
        .description("Shows one of your Grada cards.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

/// A card the app has written for the widgets, offered in the widget's settings under its own title.
struct CardChoice: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Card"
    static let defaultQuery = CardQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct CardQuery: EntityQuery {
    private var all: [CardChoice] {
        (WidgetCards.load()?.cards ?? []).map { CardChoice(id: $0.id, title: $0.title) }
    }

    func entities(for identifiers: [String]) async throws -> [CardChoice] {
        all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [CardChoice] { all }

    func defaultResult() async -> CardChoice? {
        all.first { $0.id == WidgetCards.defaultCardID } ?? all.first
    }
}

struct SelectCardIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Card"
    static let description = IntentDescription("Shows one of your Grada cards.")

    @Parameter(title: "Card")
    var card: CardChoice?
}

struct CardEntry: TimelineEntry {
    let date: Date
    /// Nil before the app has written this card.
    let card: WidgetCard?
    var colorBlind = false
}

struct CardProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CardEntry {
        CardEntry(date: .now, card: WidgetCard(id: WidgetCards.defaultCardID, title: "Recovery", symbol: "arrow.clockwise.heart",
                                                tint: .green, period: "Today", value: "72", unit: "%", comparison: nil,
                                                comparisonWarns: false, style: .rated(.good)))
    }

    func snapshot(for configuration: SelectCardIntent, in context: Context) async -> CardEntry {
        entry(configuration, on: .now)
    }

    /// The app reloads the timeline after each import; the midnight entry clears values that said "Today".
    func timeline(for configuration: SelectCardIntent, in context: Context) async -> Timeline<CardEntry> {
        let now = Date.now
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        return Timeline(entries: [entry(configuration, on: now), entry(configuration, on: midnight)], policy: .never)
    }

    private func entry(_ configuration: SelectCardIntent, on date: Date) -> CardEntry {
        guard let published = WidgetCards.load() else { return CardEntry(date: date, card: nil) }
        let id = configuration.card?.id ?? WidgetCards.defaultCardID
        return CardEntry(date: date, card: published.card(id, on: date), colorBlind: published.colorBlind)
    }
}

struct CardWidgetView: View {
    let entry: CardEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        default: home
        }
    }

    /// Laid out like the Home card: title with the icon top right, the period, then the value.
    private var home: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: entry.card?.title ?? "Grada").font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Image(systemName: entry.card?.symbol ?? "heart.text.square").foregroundStyle(entry.card?.tint.color ?? .green)
            }
            if let card = entry.card, card.value != nil {
                Text(card.period).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                value(card, numberFont: .system(.title, weight: .bold))
                if family == .systemMedium, let comparison = card.comparison {
                    Text(comparison).font(.caption).foregroundStyle(card.comparisonWarns ? Color.orange : .secondary).lineLimit(1)
                }
            } else {
                Spacer(minLength: 0)
                Text("No data yet").font(.headline)
                Text("Open Grada to update.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: entry.card?.symbol ?? "heart.text.square").font(.caption)
                Text(entry.card?.value ?? "–").font(.headline).lineLimit(1).minimumScaleFactor(0.5)
            }
            .padding(4)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text(verbatim: entry.card?.title ?? "Grada")
            } icon: {
                Image(systemName: entry.card?.symbol ?? "heart.text.square")
            }
            .font(.headline).lineLimit(1).widgetAccentable()
            if let card = entry.card, card.value != nil {
                value(card, numberFont: .system(.title3, weight: .bold))
                Text(card.period).font(.caption).lineLimit(1)
            } else {
                Text("Open Grada to update.").font(.caption).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func value(_ card: WidgetCard, numberFont: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(card.value ?? "").font(numberFont)
            if !card.unit.isEmpty { Text(card.unit).font(.subheadline.weight(.semibold)) }
        }
        .foregroundStyle(card.style.color(colorBlind: entry.colorBlind))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}
