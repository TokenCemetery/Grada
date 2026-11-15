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

    /// Nil if the stored kind no longer exists. A variant the kind doesn't offer falls back to its default.
    var cardID: CardID? {
        guard let kind else { return nil }
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
    /// Packs cards into rows: a wide card fills a row, squares pair up in order.
    /// A square followed by a wide card sits alone in its row.
    // TODO(#36, iPad release): 3 columns on iPad inside a centered column with a maximum width, like Suunto,
    // so square cards stay square instead of stretching. Pass the column count in from HomeView.
    static func rows<Item: HomeLayoutItem>(for items: [Item]) -> [[Item]] {
        var rows: [[Item]] = []
        var pendingSquare: Item?
        for item in items {
            switch item.size {
            case .wide:
                if let square = pendingSquare { rows.append([square]); pendingSquare = nil }
                rows.append([item])
            case .square:
                if let square = pendingSquare {
                    rows.append([square, item])
                    pendingSquare = nil
                } else {
                    pendingSquare = item
                }
            }
        }
        if let square = pendingSquare { rows.append([square]) }
        return rows
    }
}
