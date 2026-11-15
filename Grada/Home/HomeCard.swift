import Foundation
import SwiftData

/// A card the user placed on the home screen.
/// Defaults on every property and no unique constraints keep this ready for CloudKit sync.
@Model
final class HomeCard {
    var kindRawValue: String = ""
    var position: Int = 0
    /// Empty for cards saved before variants existed; they show their kind's default variant.
    var variantRawValue: String = ""

    init(_ card: CardID, position: Int) {
        self.kindRawValue = card.kind.rawValue
        self.variantRawValue = card.variant.rawValue
        self.position = position
    }

    /// Nil if the stored kind no longer exists in this app version.
    var kind: CardKind? { CardKind(rawValue: kindRawValue) }

    /// Nil if the stored kind no longer exists or is retired. A variant the kind doesn't offer falls back to its default.
    var cardID: CardID? {
        guard let kind, !kind.isRetired else { return nil }
        let variant = CardVariant(rawValue: variantRawValue).flatMap { kind.variants.contains($0) ? $0 : nil }
        return CardID(kind: kind, variant: variant ?? kind.defaultVariant)
    }
}

/// Anything HomeLayout can pack into rows.
protocol HomeLayoutItem: Hashable {
    var size: CardSize { get }
}

extension CardKind: HomeLayoutItem {}

extension CardID: HomeLayoutItem {
    var size: CardSize { kind.size }
}

enum HomeLayout {
    /// Packs cards into rows: a wide card fills a row, squares fill rows of `columns` in order.
    /// Squares waiting when a wide card arrives sit in a short row of their own.
    static func rows<Item: HomeLayoutItem>(for items: [Item], columns: Int = 2) -> [[Item]] {
        var rows: [[Item]] = []
        var pendingSquares: [Item] = []
        for item in items {
            switch item.size {
            case .wide:
                if !pendingSquares.isEmpty { rows.append(pendingSquares); pendingSquares = [] }
                rows.append([item])
            case .square:
                pendingSquares.append(item)
                if pendingSquares.count == columns { rows.append(pendingSquares); pendingSquares = [] }
            }
        }
        if !pendingSquares.isEmpty { rows.append(pendingSquares) }
        return rows
    }
}
