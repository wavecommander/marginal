import Foundation
import PDFKit

/// Which way a book's pages run in the reader: one above the other (the default) or side by
/// side. Chosen per book from the reader's More menu or View menu and kept for that book.
nonisolated enum ReaderScrollDirection: String, CaseIterable, Codable, Sendable {
    case vertical, horizontal

    /// PDFKit's display direction for this choice.
    var pdfDisplayDirection: PDFDisplayDirection {
        switch self {
        case .vertical: .vertical
        case .horizontal: .horizontal
        }
    }
}

/// Stores each book's scroll direction in `UserDefaults` under `reader.scrollDirection.<bookID>`.
/// A view preference like the accent and the Library sort, so it lives beside them rather than
/// in the book store. A missing or unknown value reads as `.vertical`; choosing `.vertical`
/// removes the key, so only books turned sideways leave anything behind. Deleting a book
/// removes its key (`LibraryScreen`), and `-resetState` clears them all.
nonisolated struct ReaderScrollDirectionStore {
    static let keyPrefix = "reader.scrollDirection."

    var defaults: UserDefaults = .standard

    static func key(for bookID: UUID) -> String { keyPrefix + bookID.uuidString }

    func direction(for bookID: UUID) -> ReaderScrollDirection {
        defaults.string(forKey: Self.key(for: bookID)).flatMap(ReaderScrollDirection.init(rawValue:)) ?? .vertical
    }

    func setDirection(_ direction: ReaderScrollDirection, for bookID: UUID) {
        if direction == .vertical {
            defaults.removeObject(forKey: Self.key(for: bookID))
        } else {
            defaults.set(direction.rawValue, forKey: Self.key(for: bookID))
        }
    }

    func removeDirection(for bookID: UUID) {
        defaults.removeObject(forKey: Self.key(for: bookID))
    }

    /// Removes every book's stored direction (`-resetState`).
    func removeAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
