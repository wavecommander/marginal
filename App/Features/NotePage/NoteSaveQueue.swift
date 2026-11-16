import Foundation
import ReaderCore

/// Runs the store work of one note (a save's read, merge and write; a delete) one at a time
/// across every `NotePageModel` on that note, in every window.
///
/// Why: a save reads what is stored, merges it with the window's unsaved edits and writes the
/// result, and the ink read and write each suspend (they hop to the ink store). Each model
/// already runs its own saves in order, but two windows on one note could both read the same
/// stored ink before either wrote: the second write then replaced the first, and that window's
/// new strokes were gone from the file and, on the next reconcile, from its own screen. That
/// happens whenever both windows hold unsaved ink and save in the same moment, as when the app
/// goes to the background and every model flushes at once. With this queue the second save reads
/// what the first one wrote and merges it (`NoteInk.merge`). Page ink has the same arrangement in
/// `PageInkQueue`.
///
/// Keyed by the note's book and target, not its ID: two windows that both start a note on an
/// empty target have no ID in common yet.
@MainActor
final class NoteSaveQueue {
    static let shared = NoteSaveQueue()

    private struct Key: Hashable {
        let bookID: UUID
        let target: NoteTarget
    }

    private var tails: [Key: (id: Int, task: Task<Void, Never>)] = [:]
    private var nextID = 0

    /// Runs `operation` after every operation queued earlier for the same note, and returns its
    /// result. Never call it for a note from inside an operation on that note.
    func run<T: Sendable>(bookID: UUID, target: NoteTarget, _ operation: @escaping @MainActor () async -> T) async -> T {
        let key = Key(bookID: bookID, target: target)
        let previous = tails[key]?.task
        nextID += 1
        let id = nextID
        let task = Task { @MainActor () -> T in
            await previous?.value
            let value = await operation()
            if self.tails[key]?.id == id { self.tails[key] = nil }
            return value
        }
        tails[key] = (id, Task { @MainActor in _ = await task.value })
        return await task.value
    }

    /// Number of notes with queued or running operations (tests and diagnostics).
    var busyNoteCount: Int { tails.count }
}
