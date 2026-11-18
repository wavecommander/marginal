import Foundation
import ReaderCore
import ReaderSync

/// Writes a computed change into a book record by record and file by file through
/// `LibraryStore`, with one change origin, so every open window reloads what it shows exactly as
/// for another window's change and no window closes (never `replaceBook`). Used by sync
/// (`LibrarySyncCore.apply`, `createBook`) and by the duplicate-book merge.
///
/// Callers hold `BookWriteGate` paused for the book while it runs, so no editor's save lands in
/// the middle; a save that was waiting re-reads what is stored and merges over it.
@MainActor
struct LibraryChangeWriter {
    let store: LibraryStore
    let origin: ChangeOrigin
    /// A note page's band layout for a text (the note editor's).
    var layout: (String) -> NoteBandLayout = { NotePageLayoutEngine.shared.bandLayout(for: $0) }

    // MARK: Records

    /// Writes `diff` (from `current`, the book as stored, to `target`) record by record: the
    /// title and reading position, headings, highlights, bookmarks (verbatim), then notes
    /// (removed ones first, a note moving to another target removed and saved again, so a target
    /// is free before a note takes it). Synchronous: nothing lands between the writes.
    func writeRecords(_ diff: BookArchiveDiff, target: BookArchive, current: BookArchive) throws {
        let bookID = current.book.id
        try store.perform(as: origin) {
            if diff.titleChanged || diff.readingPositionChanged, var book = try store.books.book(id: bookID) {
                book.title = target.book.title
                book.lastReadPageIndex = target.book.lastReadPageIndex
                book.lastOpenedAt = target.book.lastOpenedAt
                try store.books.save(book)
            }

            for id in diff.userHeadings.removed { try store.headings.deleteUserHeading(id: id) }
            for var heading in diff.userHeadings.changed + diff.userHeadings.added {
                heading.bookID = bookID
                try store.headings.save(heading)
            }

            for id in diff.highlights.removed { try store.highlights.deleteHighlight(id: id) }
            for var highlight in diff.highlights.changed + diff.highlights.added {
                highlight.bookID = bookID
                try store.highlights.save(highlight)
            }

            let keptPages = Set(target.bookmarks.map(\.pageIndex))
            for id in diff.bookmarks.removed {
                guard let old = current.bookmarks.first(where: { $0.id == id }), !keptPages.contains(old.pageIndex) else { continue }
                if try store.bookmarks.bookmarks(bookID: bookID).contains(where: { $0.id == id }) {
                    try store.bookmarks.setBookmarked(false, bookID: bookID, pageIndex: old.pageIndex)
                }
            }
            for var bookmark in diff.bookmarks.changed + diff.bookmarks.added {
                bookmark.bookID = bookID
                try store.bookmarks.save(bookmark)
            }

            let currentNotes = Dictionary(current.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in diff.notes.removed { try store.notes.deleteNote(id: id) }
            for note in diff.notes.changed where currentNotes[note.id].map({ $0.target != note.target }) ?? false {
                try store.notes.deleteNote(id: note.id)   // the record only: its ink file stays
            }
            for var note in diff.notes.changed + diff.notes.added {
                note.bookID = bookID
                try store.notes.save(note)
            }
        }
    }

    // MARK: Files

    /// Writes and removes the book's files: ink through the store (posting `.pageInkChanged` and
    /// `.noteInkChanged`), the cover and `conversion.json` beside the book (then `.bookSaved`).
    func writeFiles(bookID: UUID, write: [SyncFileKey: Data], remove: Set<SyncFileKey>) async throws {
        var bookFilesChanged = false
        for key in write.keys.sorted() {
            let data = write[key]!
            switch key {
            case .pageInk(let page): try await store.savePageInk(data, bookID: bookID, pageIndex: page, origin: origin)
            case .noteInk(let id): try await store.saveNoteInk(data, bookID: bookID, noteID: id, origin: origin)
            case .cover, .conversion:
                try await Self.writeFile(data, to: url(of: key, bookID: bookID))
                bookFilesChanged = true
            }
        }
        for key in remove.sorted() {
            switch key {
            case .pageInk(let page): try await store.deletePageInk(bookID: bookID, pageIndex: page, origin: origin)
            case .noteInk(let id): try await store.deleteNoteInk(bookID: bookID, noteID: id, origin: origin)
            case .cover, .conversion:
                try await Self.removeFile(url(of: key, bookID: bookID))
                bookFilesChanged = true
            }
        }
        if bookFilesChanged {
            CoverCache.shared.remove(at: url(of: .cover, bookID: bookID))
            store.hub.post(.bookSaved(bookID: bookID), origin: origin)
        }
    }

    /// Where one of a book's files lives.
    func url(of key: SyncFileKey, bookID: UUID) -> URL {
        switch key {
        case .pageInk(let page): store.url(forRelativePath: BookStorageLayout.pageInkPath(bookID: bookID, pageIndex: page))
        case .noteInk(let id): store.url(forRelativePath: BookStorageLayout.noteInkPath(bookID: bookID, noteID: id))
        case .cover: store.url(forRelativePath: ImportService.coverRelativePath(bookID: bookID))
        case .conversion: store.bookDirectoryURL(bookID: bookID).appendingPathComponent(ImportPipeline.conversionRecordFileName)
        }
    }

    @concurrent
    nonisolated private static func writeFile(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    @concurrent
    nonisolated private static func removeFile(_ url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    // MARK: Notes after their ink

    /// What the app does after writing notes and their ink: `hasInk` follows the ink file, a
    /// note with ink and no `bandLayout` gets the layout of its text (the layout the merged ink
    /// is anchored to), one without ink has none, and a note left empty (no text, no ink) is
    /// removed, as the editor would. Only the notes in `noteIDs` are looked at.
    func settleNotes(bookID: UUID, noteIDs: Set<UUID>) async throws {
        for id in noteIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let note = try store.notes.note(id: id), note.bookID == bookID else { continue }
            let hasFile = await Self.exists(url(of: .noteInk(id), bookID: bookID))
            var settled = note
            settled.hasInk = hasFile
            if hasFile {
                if settled.bandLayout == nil { settled.bandLayout = layout(settled.text) }
            } else {
                settled.bandLayout = nil
            }
            if settled.isEmpty {
                try await store.deleteNote(id: id, origin: origin)
            } else if settled != note {
                try store.perform(as: origin) { _ = try store.notes.save(settled) }
            }
        }
    }

    @concurrent
    nonisolated private static func exists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
