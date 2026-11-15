import Foundation

/// One editor's permission to save a book's data: revoked for good once the editor has seen
/// `.bookDeleted` for its book.
///
/// Why: a restore replaces a book under the **same ID** (`BookRepository.replaceBook`), posting
/// `.bookDeleted` then `.bookSaved`. Reader and Notebook windows on it close as for a delete, and
/// closing flushes (`ReaderSession.suspend()`, `NotePageModel.flush()`). Without this token that
/// late flush would find the book existing again and write what was on screen over the restored
/// ink or note text. Every pending-save path checks its token and does nothing once revoked.
///
/// A token may have a parent (a note model made by a reader session shares the session's fate):
/// it is revoked when either is.
@MainActor
final class BookSaveToken {
    let bookID: UUID
    private let parent: BookSaveToken?
    private var revokedHere = false

    init(bookID: UUID, parent: BookSaveToken? = nil) {
        self.bookID = bookID
        self.parent = parent
    }

    /// `true` once this token or its parent was revoked.
    var isRevoked: Bool { revokedHere || parent?.isRevoked == true }

    /// The editor saw `.bookDeleted` for its book: no save of it may land from now on.
    func revoke() { revokedHere = true }
}

/// Process-wide gate on asynchronous saves of a book's data (page ink, note text and note ink),
/// used by a restore to make its commit airtight.
///
/// A save that writes ink hops to the ink store's actor, so without a gate a save that started
/// before a restore's commit (a debounce firing just then) could land its file *after* the
/// commit swapped the restored directory in. The restore therefore:
/// 1. flushes every open editor (`OpenEditorRegistry.flushAll`), so nothing pending is lost;
/// 2. `pause`s the books it replaces: new saves of them wait at the gate, and `pause` returns
///    once every save of them already past the gate has finished;
/// 3. commits (synchronously, on the main actor; `.bookDeleted` revokes the closing editors'
///    tokens);
/// 4. `resume`s: waiting saves re-check their token and, revoked, do nothing.
///
/// Only work wrapped in `performSave` is counted. Synchronous record saves on the main actor
/// (the last-read page) cannot interleave with the synchronous commit and need no gate.
/// Never call `performSave` for a book from inside another `performSave` of the same book (a
/// pause would then wait for itself).
@MainActor
final class BookWriteGate {
    static let shared = BookWriteGate()

    /// An active pause (pass it back to `resume`).
    struct Pause: Hashable, Sendable {
        fileprivate let id: UUID
        let bookIDs: Set<UUID>
    }

    private var pausedCounts: [UUID: Int] = [:]
    private var inFlight: [UUID: Int] = [:]
    private var activePauses: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    /// `true` while a restore holds the book paused.
    func isPaused(_ bookID: UUID) -> Bool { (pausedCounts[bookID] ?? 0) > 0 }

    /// Saves of the book currently past the gate (tests and diagnostics).
    func inFlightCount(_ bookID: UUID) -> Int { inFlight[bookID] ?? 0 }

    /// Runs one save of the book's data: waits while the book is paused, then, unless `token` is
    /// revoked, runs `body` counted as in flight. Returns `nil` (without running `body`) when the
    /// token is revoked.
    func performSave<T>(bookID: UUID, token: BookSaveToken?, _ body: @MainActor () async throws -> T) async rethrows -> T? {
        while isPaused(bookID) { await waitForChange() }
        if token?.isRevoked == true { return nil }
        inFlight[bookID, default: 0] += 1
        defer { finishSave(bookID) }
        return try await body()
    }

    /// Pauses saves of `bookIDs` and returns once none is in flight. Always `resume` it.
    func pause(_ bookIDs: Set<UUID>) async -> Pause {
        let pause = Pause(id: UUID(), bookIDs: bookIDs)
        activePauses.insert(pause.id)
        for id in bookIDs { pausedCounts[id, default: 0] += 1 }
        while bookIDs.contains(where: { (inFlight[$0] ?? 0) > 0 }) { await waitForChange() }
        return pause
    }

    /// Ends a pause; waiting saves continue (and re-check their tokens). Idempotent.
    func resume(_ pause: Pause) {
        guard activePauses.remove(pause.id) != nil else { return }
        for id in pause.bookIDs {
            let count = (pausedCounts[id] ?? 1) - 1
            pausedCounts[id] = count > 0 ? count : nil
        }
        wakeWaiters()
    }

    private func finishSave(_ bookID: UUID) {
        let count = (inFlight[bookID] ?? 1) - 1
        inFlight[bookID] = count > 0 ? count : nil
        wakeWaiters()
    }

    private func waitForChange() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    private func wakeWaiters() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}
