import Foundation

/// One card as the widgets show it, already formatted and colored by the app, so a widget only draws it.
nonisolated struct WidgetCard: Codable, Hashable, Identifiable {
    /// The `CardKind` raw value.
    let id: String
    let title: String
    let symbol: String
    let tint: CardTint
    let period: String
    /// Nil means there's no data for this card.
    var value: String?
    let unit: String
    let comparison: String?
    let comparisonWarns: Bool
    let style: CardValueStyle
}

/// The cards the app last wrote for the widgets. Stays in the App Group container on this device: no iCloud,
/// no network (#129).
nonisolated struct WidgetCards: Codable {
    static let appGroup = "group.com.GitHub.TokenCemetery.Grada"
    /// The widget's kind in WidgetKit.
    static let widgetKind = "GradaCard"
    /// The card a new widget shows.
    static let defaultCardID = "recovery"

    /// When the cards were built.
    var date: Date
    var colorBlind: Bool
    var cards: [WidgetCard]

    /// The card as it should read on `day`. Values built on an earlier day are dropped, since their
    /// "Today" no longer holds; the app writes fresh ones on its next import.
    func card(_ id: String, on day: Date, calendar: Calendar = .current) -> WidgetCard? {
        guard var card = cards.first(where: { $0.id == id }) else { return nil }
        if !calendar.isDate(date, inSameDayAs: day) { card.value = nil }
        return card
    }

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "WidgetCards.json")
    }

    /// Nil before the app has written any cards.
    static func load() -> WidgetCards? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetCards.self, from: data)
    }

    func save() throws {
        guard let url = Self.url else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
