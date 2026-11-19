import SwiftUI

/// How good a day was for one metric; drives the calendar's day colours. Shared with the widgets, which only
/// need the value colors; the calendar's colors are in `Grada/Calendar/DayRating.swift`.
nonisolated enum DayRating: String, CaseIterable, Codable {
    case good, fair, poor

    /// A card value in this rating's color. Yellow text is unreadable on a light card, so fair is orange.
    func text(colorBlind: Bool) -> Color {
        switch (self, colorBlind) {
        case (.good, false): .green
        case (.fair, _): .orange
        case (.poor, false): .red
        case (.good, true): .blue
        case (.poor, true): .primary
        }
    }
}

/// How a card colors its value. Home cards and widgets both draw it, so a widget matches its card.
nonisolated enum CardValueStyle: Codable, Hashable {
    case plain
    case rated(DayRating)
    case good
    case warning

    func color(colorBlind: Bool) -> Color {
        switch self {
        case .plain: .primary
        case .rated(let rating): rating.text(colorBlind: colorBlind)
        case .good: .green
        case .warning: .orange
        }
    }
}

/// A card category's icon color. System colors already adapt to light and dark mode.
nonisolated enum CardTint: String, Codable {
    case green, indigo, red, orange, teal

    var color: Color {
        switch self {
        case .green: .green
        case .indigo: .indigo
        case .red: .red
        case .orange: .orange
        case .teal: .teal
        }
    }
}
