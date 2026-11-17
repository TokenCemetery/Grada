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

    /// Stored values as they are, for moving cards between stores.
    init(kindRawValue: String, position: Int, variantRawValue: String) {
        self.kindRawValue = kindRawValue
        self.position = position
        self.variantRawValue = variantRawValue
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

/// One row of the home grid.
enum HomeRow<Item: HomeLayoutItem>: Hashable {
    /// Cards left to right. Squares take one column; a wide or big card takes the columns the squares leave.
    case cards([Item])
    /// A big card two columns wide, with two rows of squares filling the remaining columns beside it.
    case big(Item, beside: [Item])
}

enum HomeLayout {
    /// Packs cards into rows in order. With 3 or more columns, a wide or big card pulls the next squares up
    /// beside it, and a short row of squares pulls later squares up, so rows don't end in holes.
    /// With 2 columns nothing moves: wide and big cards fill a row and squares pair up.
    static func rows<Item: HomeLayoutItem>(for items: [Item], columns: Int = 2) -> [HomeRow<Item>] {
        var remaining = items
        var rows: [HomeRow<Item>] = []

        /// Removes and returns the first `count` squares still waiting, in order.
        func takeSquares(_ count: Int) -> [Item] {
            var taken: [Item] = []
            var index = remaining.startIndex
            while taken.count < count, index < remaining.endIndex {
                if remaining[index].size == .square {
                    taken.append(remaining.remove(at: index))
                } else {
                    index += 1
                }
            }
            return taken
        }

        while !remaining.isEmpty {
            let item = remaining.removeFirst()
            switch item.size {
            case .square:
                var row = [item]
                while row.count < columns, remaining.first?.size == .square {
                    row.append(remaining.removeFirst())
                }
                let gap = columns - row.count
                if gap >= 2, remaining.first?.size == .wide {
                    row.append(remaining.removeFirst())
                } else if gap > 0, columns >= 3 {
                    row += takeSquares(gap)
                }
                rows.append(.cards(row))
            case .wide:
                rows.append(.cards([item] + takeSquares(max(columns - 2, 0))))
            case .big:
                let besideCount = 2 * (columns - 2)
                if besideCount > 0, remaining.count(where: { $0.size == .square }) >= besideCount {
                    rows.append(.big(item, beside: takeSquares(besideCount)))
                } else {
                    rows.append(.cards([item]))
                }
            }
        }
        return rows
    }
}
