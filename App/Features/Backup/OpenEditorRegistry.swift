import Foundation
import ReaderCore

/// What the reader is working on in one book (see `OpenEditorRegistry.syncBusySurfaces`).
nonisolated struct SyncBusyEditors: Hashable, Sendable {
    var pages: Set<Int> = []
    var notes: Set<UUID> = []
    var noteTargets: Set<NoteTarget> = []

    var isEmpty: Bool { pages.isEmpty && notes.isEmpty && noteTargets.isEmpty }

    mutating func formUnion(_ other: SyncBusyEditors) {
        pages.formUnion(other.pages)
        notes.formUnion(other.notes)
        noteTargets.formUnion(other.noteTargets)
    }
}

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

    /// Live reader sessions on `store` (a closed session, kept by SwiftUI after its reader slept
    /// or was popped, is not one).
    func sessions(of store: LibraryStore) -> [ReaderSession] {
        sessions.compactMap(\.value).filter { $0.store === store && !$0.isClosed }
    }

    /// Live note models on `store`.
    func noteModels(of store: LibraryStore) -> [NotePageModel] {
        noteModels.compactMap(\.value).filter { $0.store === store }
    }

    /// What the reader is working on in one book, for sync (`SyncSurface`): pages with a stroke
    /// in progress or not yet committed or saved (`PageInkSurface`), and notes being edited
    /// (`NotePageModel.isBusyForSync`), by ID (stored, or reserved for its first save) and target.
    func syncBusySurfaces(bookID: UUID, store: LibraryStore) -> SyncBusyEditors {
        var busy = SyncBusyEditors()
        for session in sessions(of: store) where session.book.id == bookID {
            guard let markup = session.markup else { continue }
            for surface in markup.registeredSurfaces {
                guard let page = surface as? PageInkSurface else { continue }
                if page.isStrokeBusy || page.isDirty || markup.isStrokeInProgress(on: page) {
                    busy.pages.insert(page.pageIndex)
                }
            }
        }
        for model in noteModels(of: store) where model.bookID == bookID && model.isBusyForSync {
            if let id = model.noteID { busy.notes.insert(id) }
            busy.noteTargets.insert(model.target)
        }
        return busy
    }

    /// Before sync reads the library: everything pending saves, as `flushAll` does, except note
    /// editors in the middle of a stroke or a text composition (sync leaves those notes alone).
    func flushForSync(store: LibraryStore) async {
        for session in sessions(of: store) {
            await session.suspend()
        }
        for model in noteModels(of: store) where !model.isMidInput {
            await model.flush()
        }
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
