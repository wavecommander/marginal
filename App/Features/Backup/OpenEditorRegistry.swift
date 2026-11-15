import Foundation
import ReaderCore

/// The live editors of the process: every `ReaderSession` (page ink, the note editor surface,
/// the last-read page) and every `NotePageModel` (note text and note ink), held weakly. They
/// register themselves when created; the backup engine uses this to save everything pending
/// before it reads a snapshot and before a restore commits (`AppEnvironment.flushOpenEditors()`).
@MainActor
final class OpenEditorRegistry {
    static let shared = OpenEditorRegistry()

    private final class Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    private var sessions: [Weak<ReaderSession>] = []
    private var noteModels: [Weak<NotePageModel>] = []

    init() {}

    func register(_ session: ReaderSession) {
        sessions.removeAll { $0.value == nil }
        sessions.append(Weak(session))
    }

    func register(_ model: NotePageModel) {
        noteModels.removeAll { $0.value == nil }
        noteModels.append(Weak(model))
    }

    /// Live reader sessions on `store`.
    func sessions(of store: LibraryStore) -> [ReaderSession] {
        sessions.compactMap(\.value).filter { $0.store === store }
    }

    /// Live note models on `store`.
    func noteModels(of store: LibraryStore) -> [NotePageModel] {
        noteModels.compactMap(\.value).filter { $0.store === store }
    }

    /// Saves everything pending in every live editor on `store` and waits for it: each reader
    /// session's last-read page and markup surfaces (`suspend()`), each note model (`flush()`),
    /// then every page-ink save still queued (pages that left the screen hand their save to the
    /// queue). Editors whose book was deleted or replaced save nothing (`BookSaveToken`).
    func flushAll(store: LibraryStore) async {
        for session in sessions(of: store) {
            await session.suspend()
        }
        for model in noteModels(of: store) {
            await model.flush()
        }
        let bookIDs = (try? store.books.allBooks().map(\.id)) ?? []
        for bookID in bookIDs {
            await PageInkQueue.shared.drain(bookID: bookID)
        }
    }
}
