import Foundation
import ReaderCore

/// A book's latest reading position: the exact place and zoom any reader on it last left.
/// `pageIndex` is the current page, as saved in `Book.lastReadPageIndex` at the same moment.
nonisolated struct ReaderPosition: Codable, Equatable, Sendable {
    var pageIndex: Int
    /// The page point at the top-left corner of the view.
    var anchor: ReadingAnchor
    /// The PDF view's scale, applied when `isFitWidth` is false.
    var scale: Double
    var isFitWidth: Bool
}

/// Keeps each book's latest exact position in `UserDefaults` under `reader.position.<bookID>`,
/// beside the book's stored last-read page, so every reader that loads the book (a new reader, a
/// woken one, another window, a relaunch) opens at the same place. A position whose page is not
/// the book's stored last-read page is stale (written before a failed save, a restore, another
/// device's merge) and is ignored: the reader then opens at the top of the last-read page.
/// Deleting a book removes its key (`LibraryScreen`), and `-resetState` clears them all.
nonisolated struct ReaderPositionStore {
    static let keyPrefix = "reader.position."

    var defaults: UserDefaults = .standard

    static func key(for bookID: UUID) -> String { keyPrefix + bookID.uuidString }

    func position(for bookID: UUID) -> ReaderPosition? {
        defaults.data(forKey: Self.key(for: bookID)).flatMap { try? JSONDecoder().decode(ReaderPosition.self, from: $0) }
    }

    /// The stored position if it belongs to `book`'s stored last-read page and its anchor is on
    /// a page of the book.
    func position(for book: Book) -> ReaderPosition? {
        guard let position = position(for: book.id), position.pageIndex == book.lastReadPageIndex,
              PageNumbering.isValid(position.anchor.pageIndex, pageCount: book.pageCount) else { return nil }
        return position
    }

    func setPosition(_ position: ReaderPosition, for bookID: UUID) {
        guard position != self.position(for: bookID), let data = try? JSONEncoder().encode(position) else { return }
        defaults.set(data, forKey: Self.key(for: bookID))
    }

    func removePosition(for bookID: UUID) {
        defaults.removeObject(forKey: Self.key(for: bookID))
    }

    /// Removes every book's stored position (`-resetState`).
    func removeAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
