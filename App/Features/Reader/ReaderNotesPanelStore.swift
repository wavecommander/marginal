import Foundation

/// How the notes panel was left in a book: shown or hidden, which tab, how wide. Kept per book in
/// `UserDefaults` under `reader.notesPanel.<bookID>` so reopening a book finds the panel as it was
/// closed. A book that was never opened has nothing stored, and its panel starts closed. Deleting a
/// book removes its key (`LibraryScreen`), and `-resetState` clears them all.
nonisolated struct ReaderNotesPanelStore {
    static let keyPrefix = "reader.notesPanel."

    struct Value: Codable, Equatable, Sendable {
        var isVisible: Bool
        var tab: ReaderSession.NotesTab
        var width: Double
    }

    var defaults: UserDefaults = .standard

    static func key(for bookID: UUID) -> String { keyPrefix + bookID.uuidString }

    func value(for bookID: UUID) -> Value? {
        defaults.data(forKey: Self.key(for: bookID)).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    func setValue(_ value: Value, for bookID: UUID) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.key(for: bookID))
    }

    func removeValue(for bookID: UUID) {
        defaults.removeObject(forKey: Self.key(for: bookID))
    }

    /// Removes every book's stored panel state (`-resetState`).
    func removeAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
