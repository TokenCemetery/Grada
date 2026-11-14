import Foundation
import SwiftData

/// A card the user placed on the home screen.
/// Defaults on every property and no unique constraints keep this ready for CloudKit sync.
@Model
final class HomeCard {
    var kindRawValue: String = ""
    var position: Int = 0

    init(kind: CardKind, position: Int) {
        self.kindRawValue = kind.rawValue
        self.position = position
    }

    /// Nil if the stored kind no longer exists in this app version.
    var kind: CardKind? { CardKind(rawValue: kindRawValue) }
}

enum HomeLayout {
    /// Packs cards into rows: a wide card fills a row, squares pair up in order.
    /// A square followed by a wide card sits alone in its row.
    static func rows(for kinds: [CardKind]) -> [[CardKind]] {
        var rows: [[CardKind]] = []
        var pendingSquare: CardKind?
        for kind in kinds {
            switch kind.size {
            case .wide:
                if let square = pendingSquare { rows.append([square]); pendingSquare = nil }
                rows.append([kind])
            case .square:
                if let square = pendingSquare {
                    rows.append([square, kind])
                    pendingSquare = nil
                } else {
                    pendingSquare = kind
                }
            }
        }
        if let square = pendingSquare { rows.append([square]) }
        return rows
    }
}
