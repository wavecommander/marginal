import Foundation
import CoreGraphics
import Testing
@testable import ReaderCore

/// An ink store that can be told to fail specific operations.
actor FlakyInkStore: InkStore {
    enum Failure: Error { case injected }
    let inner = InMemoryInkStore()
    var failRemoveBook = false
    var failWrites = false
    var failNoteDelete = false

    func set(removeBook: Bool? = nil, writes: Bool? = nil, noteDelete: Bool? = nil) {
        if let removeBook { failRemoveBook = removeBook }
        if let writes { failWrites = writes }
        if let noteDelete { failNoteDelete = noteDelete }
    }

    func pageInk(bookID: UUID, pageIndex: Int) async throws -> Data? { try await inner.pageInk(bookID: bookID, pageIndex: pageIndex) }
    func savePageInk(_ data: Data, bookID: UUID, pageIndex: Int) async throws {
        if failWrites { throw Failure.injected }
        try await inner.savePageInk(data, bookID: bookID, pageIndex: pageIndex)
    }
    func deletePageInk(bookID: UUID, pageIndex: Int) async throws {
        if failWrites { throw Failure.injected }
        try await inner.deletePageInk(bookID: bookID, pageIndex: pageIndex)
    }
    func inkedPageIndices(bookID: UUID) async throws -> [Int] { try await inner.inkedPageIndices(bookID: bookID) }
    func noteInk(bookID: UUID, noteID: UUID) async throws -> Data? { try await inner.noteInk(bookID: bookID, noteID: noteID) }
    func saveNoteInk(_ data: Data, bookID: UUID, noteID: UUID) async throws {
        if failWrites { throw Failure.injected }
        try await inner.saveNoteInk(data, bookID: bookID, noteID: noteID)
    }
    func deleteNoteInk(bookID: UUID, noteID: UUID) async throws {
        if failNoteDelete || failWrites { throw Failure.injected }
        try await inner.deleteNoteInk(bookID: bookID, noteID: noteID)
    }
    func removeBook(bookID: UUID) async throws {
        if failRemoveBook { throw Failure.injected }
        try await inner.removeBook(bookID: bookID)
    }
}

/// A record store whose book writes always fail.
@MainActor
final class BrokenBookStore: InMemoryRecordStore {
    struct Broken: Error {}
    override func storeBook(_ book: Book) throws { throw Broken() }
    override func removeBook(id: UUID) throws -> Bool { throw Broken() }
    override func storeArchive(_ archive: BookArchive, removing ids: Set<UUID>) throws -> [UUID] { throw Broken() }
}

@MainActor
@Suite("LibraryStore")
struct LibraryStoreTests {
    let bookID = uuid(2001)
    let origin = ChangeOrigin(label: "window A")

    func makeStore(ink: FlakyInkStore = FlakyInkStore()) throws -> (LibraryStore, EventRecorder) {
        let records = InMemoryRecordStore()
        try records.save(Book(id: bookID, title: "B", fingerprint: "fp", fileName: "book.pdf", pageCount: 50, fileSize: 1))
        let store = LibraryStore(records: records, inkStore: ink, rootDirectory: URL(fileURLWithPath: "/tmp/root", isDirectory: true))
        return (store, EventRecorder(store.hub))
    }

    func highlight(_ n: Int, page: Int) -> Highlight {
        Highlight(id: uuid(n), bookID: bookID, pageIndex: page, rects: [CGRect(x: 0, y: 0, width: 1, height: 1)],
                  color: .yellow, text: "h", createdAt: fixedDate)
    }

    @Test func bookMutationsPost() throws {
        let (store, recorder) = try makeStore()
        var book = try #require(try store.books.book(id: bookID))
        book.lastReadPageIndex = 9
        try store.perform(as: origin) { try store.books.save(book) }
        try store.books.deleteBook(id: bookID)
        try store.books.deleteBook(id: bookID)               // unknown now: no post
        #expect(recorder.events == [
            StoreChangeEvent(change: .bookSaved(bookID: bookID), origin: origin),
            StoreChangeEvent(change: .bookDeleted(bookID: bookID), origin: nil),
        ])
    }

    @Test func noteMutationsPost() throws {
        let (store, recorder) = try makeStore()
        let note = Note(id: uuid(1), bookID: bookID, target: .page(3), text: "hi", createdAt: fixedDate)
        let anchor = HeadingAnchor(userHeadingID: uuid(77))
        try store.perform(as: origin) {
            try store.notes.save(note)
            try store.notes.retarget(noteID: note.id, to: .heading(anchor))
            try store.notes.retarget(noteID: note.id, to: .heading(anchor))     // no-op: no post
            var emptied = note
            emptied.target = .heading(anchor)
            emptied.text = "  "
            #expect(try store.notes.save(emptied) == nil)                       // deletes
            #expect(try store.notes.save(emptied) == nil)                       // nothing there: no post
            try store.notes.save(note)
            try store.notes.deleteNote(id: note.id)
            try store.notes.deleteNote(id: note.id)                             // unknown: no post
        }
        #expect(recorder.changes == [
            .noteSaved(bookID: bookID, target: .page(3), noteID: uuid(1)),
            .noteRemoved(bookID: bookID, target: .page(3), noteID: uuid(1)),
            .noteSaved(bookID: bookID, target: .heading(anchor), noteID: uuid(1)),
            .noteRemoved(bookID: bookID, target: .heading(anchor), noteID: uuid(1)),
            .noteSaved(bookID: bookID, target: .page(3), noteID: uuid(1)),
            .noteRemoved(bookID: bookID, target: .page(3), noteID: uuid(1)),
        ])
        #expect(recorder.events.allSatisfy { $0.origin == origin })
    }

    @Test func highlightBookmarkAndHeadingMutationsPost() throws {
        let (store, recorder) = try makeStore()
        var h = highlight(1, page: 4)
        try store.highlights.save(h)
        h.color = .blue
        try store.highlights.save(h)
        h.pageIndex = 6
        try store.highlights.save(h)
        try store.highlights.deleteHighlight(id: h.id)
        try store.highlights.deleteHighlight(id: h.id)
        try store.bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 2)
        try store.bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 2)      // unchanged: no post
        try store.bookmarks.setBookmarked(false, bookID: bookID, pageIndex: 2)
        try store.bookmarks.setBookmarked(false, bookID: bookID, pageIndex: 3)     // unchanged: no post
        let heading = UserHeading(id: uuid(5), bookID: bookID, title: "U", pageIndex: 1, parent: nil, createdAt: fixedDate)
        try store.headings.save(heading)
        try store.headings.deleteUserHeading(id: heading.id)
        try store.headings.deleteUserHeading(id: heading.id)
        #expect(recorder.changes == [
            .highlightsChanged(bookID: bookID, pageIndex: 4),
            .highlightsChanged(bookID: bookID, pageIndex: 4),
            .highlightsChanged(bookID: bookID, pageIndex: 4),       // moved away from page 4…
            .highlightsChanged(bookID: bookID, pageIndex: 6),       // …to page 6
            .highlightsChanged(bookID: bookID, pageIndex: 6),
            .bookmarksChanged(bookID: bookID, pageIndex: 2),
            .bookmarksChanged(bookID: bookID, pageIndex: 2),
            .userHeadingsChanged(bookID: bookID),
            .userHeadingsChanged(bookID: bookID),
        ])
        #expect(recorder.events.allSatisfy { $0.origin == nil })
    }

    @Test func failedMutationsPostNothing() async throws {
        let (store, recorder) = try makeStore()
        let stranger = uuid(9999)
        let note = Note(id: uuid(1), bookID: bookID, target: .page(3), text: "hi")
        try store.notes.save(note)
        recorder.reset()
        store.perform(as: origin) {
            #expect(throws: RepositoryError.self) { try store.notes.save(Note(bookID: bookID, target: .page(3), text: "dup")) }
            #expect(throws: RepositoryError.self) { try store.notes.save(Note(bookID: stranger, target: .page(3), text: "x")) }
            #expect(throws: RepositoryError.self) { try store.notes.retarget(noteID: uuid(404), to: .page(1)) }
            #expect(throws: RepositoryError.self) { try store.highlights.save(Highlight(bookID: stranger, pageIndex: 0, rects: [], color: .green, text: "")) }
            #expect(throws: RepositoryError.self) { try store.bookmarks.setBookmarked(true, bookID: stranger, pageIndex: 0) }
            #expect(throws: RepositoryError.self) { try store.headings.save(UserHeading(bookID: stranger, title: "x", pageIndex: 0, parent: nil)) }
        }
        let ink = FlakyInkStore()
        await ink.set(writes: true)
        let (inkStore, inkRecorder) = try makeStore(ink: ink)
        await #expect(throws: FlakyInkStore.Failure.self) { try await inkStore.savePageInk(Data([1]), bookID: bookID, pageIndex: 0, origin: origin) }
        await #expect(throws: FlakyInkStore.Failure.self) { try await inkStore.deleteNoteInk(bookID: bookID, noteID: uuid(1), origin: origin) }

        let broken = LibraryStore(records: BrokenBookStore(), inkStore: InMemoryInkStore(), rootDirectory: URL(fileURLWithPath: "/tmp"))
        let brokenRecorder = EventRecorder(broken.hub)
        #expect(throws: BrokenBookStore.Broken.self) { try broken.books.save(Book(title: "x", fingerprint: "x", fileName: "x", pageCount: 1, fileSize: 1)) }
        await #expect(throws: BrokenBookStore.Broken.self) { try await broken.deleteBook(id: bookID, origin: origin) }

        #expect(recorder.events.isEmpty)
        #expect(inkRecorder.events.isEmpty)
        #expect(brokenRecorder.events.isEmpty)
    }

    @Test func performIsNestingSafe() throws {
        let (store, recorder) = try makeStore()
        let inner = ChangeOrigin(label: "inner")
        #expect(store.currentOrigin == nil)
        try store.perform(as: origin) {
            try store.bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 1)
            try store.perform(as: inner) { try store.bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 2) }
            try store.perform(as: nil) { try store.bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 3) }
            #expect(store.currentOrigin == origin)
            struct Bail: Error {}
            #expect(throws: Bail.self) { try store.perform(as: inner) { throw Bail() } }
            try store.bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 4)
        }
        try store.bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 5)
        #expect(store.currentOrigin == nil)
        #expect(recorder.events.map(\.origin) == [origin, inner, nil, origin, nil])
    }

    @Test func inkMethodsWriteThenPostWithOrigin() async throws {
        let (store, recorder) = try makeStore()
        try await store.savePageInk(Data([1]), bookID: bookID, pageIndex: 3, origin: origin)
        try await store.saveNoteInk(Data([2]), bookID: bookID, noteID: uuid(8), origin: nil)
        #expect(try await store.pageInk(bookID: bookID, pageIndex: 3) == Data([1]))
        #expect(try await store.noteInk(bookID: bookID, noteID: uuid(8)) == Data([2]))
        #expect(try await store.inkedPageIndices(bookID: bookID) == [3])
        try await store.deletePageInk(bookID: bookID, pageIndex: 3, origin: origin)
        try await store.deleteNoteInk(bookID: bookID, noteID: uuid(8), origin: origin)
        #expect(try await store.pageInk(bookID: bookID, pageIndex: 3) == nil)
        #expect(recorder.events == [
            StoreChangeEvent(change: .pageInkChanged(bookID: bookID, pageIndex: 3), origin: origin),
            StoreChangeEvent(change: .noteInkChanged(bookID: bookID, noteID: uuid(8)), origin: nil),
            StoreChangeEvent(change: .pageInkChanged(bookID: bookID, pageIndex: 3), origin: origin),
            StoreChangeEvent(change: .noteInkChanged(bookID: bookID, noteID: uuid(8)), origin: origin),
        ])
    }

    @Test func deleteBookRemovesRecordsAndFilesAndPostsOnce() async throws {
        let (store, recorder) = try makeStore()
        try store.notes.save(Note(bookID: bookID, target: .page(1), text: "n"))
        try store.highlights.save(highlight(3, page: 2))
        try await store.savePageInk(Data([1]), bookID: bookID, pageIndex: 1, origin: nil)
        try await store.savePageInk(Data([1]), bookID: bookID, pageIndex: 4, origin: nil)
        let summary = try await store.deletionSummary(bookID: bookID)
        #expect(summary == BookDeletionSummary(records: BookRecordCounts(notes: 1, highlights: 1), inkedPages: 2))
        recorder.reset()

        try await store.deleteBook(id: bookID, origin: origin)
        #expect(recorder.events == [StoreChangeEvent(change: .bookDeleted(bookID: bookID), origin: origin)])
        #expect(try store.books.book(id: bookID) == nil)
        #expect(try store.notes.notes(bookID: bookID).isEmpty)
        #expect(try await store.inkedPageIndices(bookID: bookID).isEmpty)
        #expect(store.currentOrigin == nil)
    }

    @Test func deleteBookWhenFileRemovalFails() async throws {
        let ink = FlakyInkStore()
        let (store, recorder) = try makeStore(ink: ink)
        try await store.savePageInk(Data([1]), bookID: bookID, pageIndex: 1, origin: nil)
        recorder.reset()
        await ink.set(removeBook: true)
        do {
            try await store.deleteBook(id: bookID, origin: origin)
            Issue.record("expected bookFilesNotRemoved")
        } catch let error as LibraryStoreError {
            guard case .bookFilesNotRemoved(let id, _) = error else { Issue.record("wrong error \(error)"); return }
            #expect(id == bookID)
        }
        // The records are gone and windows were told; the files are left for a retry.
        #expect(try store.books.book(id: bookID) == nil)
        #expect(recorder.changes == [.bookDeleted(bookID: bookID)])
        #expect(try await store.inkedPageIndices(bookID: bookID) == [1])
        await ink.set(removeBook: false)
        try await store.removeBookFiles(bookID: bookID)
        #expect(try await store.inkedPageIndices(bookID: bookID).isEmpty)
        #expect(recorder.changes == [.bookDeleted(bookID: bookID)])
    }

    @Test func deleteNoteRemovesItsInk() async throws {
        let (store, recorder) = try makeStore()
        let inked = Note(id: uuid(1), bookID: bookID, target: .page(1), text: "", hasInk: true)
        let plain = Note(id: uuid(2), bookID: bookID, target: .page(2), text: "plain")
        try store.notes.save(inked)
        try store.notes.save(plain)
        try await store.saveNoteInk(Data([7]), bookID: bookID, noteID: inked.id, origin: nil)
        recorder.reset()

        try await store.deleteNote(id: inked.id, origin: origin)
        try await store.deleteNote(id: plain.id, origin: origin)
        try await store.deleteNote(id: uuid(404), origin: origin)       // unknown: no-op
        #expect(recorder.events == [
            StoreChangeEvent(change: .noteRemoved(bookID: bookID, target: .page(1), noteID: inked.id), origin: origin),
            StoreChangeEvent(change: .noteInkChanged(bookID: bookID, noteID: inked.id), origin: origin),
            StoreChangeEvent(change: .noteRemoved(bookID: bookID, target: .page(2), noteID: plain.id), origin: origin),
        ])
        #expect(try await store.noteInk(bookID: bookID, noteID: inked.id) == nil)
        #expect(try store.notes.noteCount(bookID: bookID) == 0)
    }

    @Test func deleteNoteWhenInkRemovalFails() async throws {
        let ink = FlakyInkStore()
        let (store, recorder) = try makeStore(ink: ink)
        let inked = Note(id: uuid(1), bookID: bookID, target: .page(1), text: "", hasInk: true)
        try store.notes.save(inked)
        try await store.saveNoteInk(Data([7]), bookID: bookID, noteID: inked.id, origin: nil)
        recorder.reset()
        await ink.set(noteDelete: true)
        await #expect(throws: LibraryStoreError.self) { try await store.deleteNote(id: inked.id, origin: origin) }
        #expect(try store.notes.note(id: inked.id) == nil)
        #expect(recorder.changes == [.noteRemoved(bookID: bookID, target: .page(1), noteID: inked.id)])
        await ink.set(noteDelete: false)
        try await store.deleteNoteInk(bookID: bookID, noteID: inked.id, origin: origin)
        #expect(try await store.noteInk(bookID: bookID, noteID: inked.id) == nil)
    }

    @Test func twoWindowsOnOneStore() throws {
        let (store, _) = try makeStore()
        let windowA = ChangeOrigin(label: "A"), windowB = ChangeOrigin(label: "B")
        var reloadA: [StoreChange] = [], reloadB: [StoreChange] = []
        let tokenA = store.hub.observe { if !$0.isFrom(windowA) && $0.change.bookID == bookID { reloadA.append($0.change) } }
        let tokenB = store.hub.observe { if !$0.isFrom(windowB) && $0.change.bookID == bookID { reloadB.append($0.change) } }
        try store.perform(as: windowA) { try store.highlights.save(highlight(1, page: 5)) }
        try store.perform(as: windowB) { try store.bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 5) }
        #expect(reloadA == [.bookmarksChanged(bookID: bookID, pageIndex: 5)])
        #expect(reloadB == [.highlightsChanged(bookID: bookID, pageIndex: 5)])
        _ = (tokenA, tokenB)
    }

    @Test func inMemoryStorePassesConformanceThroughLibraryStore() async throws {
        let store = LibraryStore.inMemory()
        let recorder = EventRecorder(store.hub)
        try RepositoryConformance.verifyRecordStores(books: store.books, notes: store.notes, highlights: store.highlights,
                                                     bookmarks: store.bookmarks, headings: store.headings)
        try await RepositoryConformance.verifyInkStore(store.inkStore)
        #expect(!recorder.events.isEmpty)
        #expect(recorder.changes.last.map { if case .bookDeleted = $0 { true } else { false } } == true)
    }

    @Test func replaceBookPostsDeletesThenSave() throws {
        let (store, recorder) = try makeStore()
        let removed = uuid(3001), unknown = uuid(3002), newcomer = uuid(4001)
        try store.books.save(Book(id: removed, title: "Old", fingerprint: "fp-old", fileName: "o.pdf", pageCount: 5, fileSize: 1))
        recorder.reset()

        // Replacing an existing book and removing another: a delete for each book that existed
        // (ascending by uuidString; nothing for the unknown ID), then the save.
        let archive = BookArchive(book: Book(id: bookID, title: "Restored", fingerprint: "fp", fileName: "book.pdf", pageCount: 50, fileSize: 1),
                                  notes: [Note(id: uuid(1), bookID: bookID, target: .page(2), text: "n", createdAt: fixedDate)])
        try store.perform(as: origin) { try store.books.replaceBook(archive, removing: [unknown, removed]) }
        #expect(recorder.events == [
            StoreChangeEvent(change: .bookDeleted(bookID: bookID), origin: origin),
            StoreChangeEvent(change: .bookDeleted(bookID: removed), origin: origin),
            StoreChangeEvent(change: .bookSaved(bookID: bookID), origin: origin),
        ])
        #expect(try store.books.book(id: removed) == nil)
        #expect(try store.notes.note(id: uuid(1)) == archive.notes[0])

        // A book that did not exist before: only the save.
        recorder.reset()
        try store.books.replaceBook(BookArchive(book: Book(id: newcomer, title: "New", fingerprint: "fp-new", fileName: "n.pdf",
                                                           pageCount: 1, fileSize: 1)), removing: [])
        #expect(recorder.events == [StoreChangeEvent(change: .bookSaved(bookID: newcomer), origin: nil)])

        // A refusal posts nothing.
        recorder.reset()
        #expect(throws: RepositoryError.fingerprintInUse(existingBookID: bookID)) {
            try store.books.replaceBook(BookArchive(book: Book(id: newcomer, title: "Clash", fingerprint: "fp", fileName: "n.pdf",
                                                               pageCount: 1, fileSize: 1)), removing: [])
        }
        let broken = LibraryStore(records: BrokenBookStore(), inkStore: InMemoryInkStore(), rootDirectory: URL(fileURLWithPath: "/tmp"))
        let brokenRecorder = EventRecorder(broken.hub)
        #expect(throws: BrokenBookStore.Broken.self) { try broken.books.replaceBook(archive, removing: []) }
        #expect(recorder.events.isEmpty)
        #expect(brokenRecorder.events.isEmpty)
    }

    @Test func archiveIsTheBookWithAllItsRecords() throws {
        let (store, _) = try makeStore()
        #expect(try store.archive(bookID: uuid(404)) == nil)
        let other = uuid(3001)
        try store.books.save(Book(id: other, title: "Other", fingerprint: "fp-other", fileName: "o.pdf", pageCount: 5, fileSize: 1))
        try store.notes.save(Note(bookID: other, target: .page(1), text: "not mine"))
        let notes = [Note(id: uuid(1), bookID: bookID, target: .page(3), text: "p3", createdAt: fixedDate),
                     Note(id: uuid(2), bookID: bookID, target: .heading(HeadingAnchor(userHeadingID: uuid(5))), text: "h",
                          hasInk: true, createdAt: fixedDate)]
        for note in notes { try store.notes.save(note) }
        try store.highlights.save(highlight(3, page: 9))
        try store.highlights.save(highlight(4, page: 1))
        try store.bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 7)
        let heading = UserHeading(id: uuid(5), bookID: bookID, title: "U", pageIndex: 1, parent: nil, createdAt: fixedDate)
        try store.headings.save(heading)

        let archive = try #require(try store.archive(bookID: bookID))
        #expect(archive.book == (try store.books.book(id: bookID)))
        #expect(Set(archive.notes) == Set(notes))
        #expect(archive.highlights == [highlight(4, page: 1), highlight(3, page: 9)])
        #expect(archive.bookmarks == (try store.bookmarks.bookmarks(bookID: bookID)))
        #expect(archive.bookmarks.map(\.pageIndex) == [7])
        #expect(archive.userHeadings == [heading])
        #expect(archive.isConsistent)

        // Restoring it into an empty store reproduces it exactly.
        let copy = LibraryStore.inMemory()
        try copy.books.replaceBook(archive, removing: [])
        let restored = try #require(try copy.archive(bookID: bookID))
        #expect(restored.book == archive.book && Set(restored.notes) == Set(archive.notes)
                && restored.highlights == archive.highlights && restored.bookmarks == archive.bookmarks
                && Set(restored.userHeadings) == Set(archive.userHeadings))
    }

    @Test func contentHashURLAndHasDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore.inMemory(rootDirectory: root)
        let book = Book(id: bookID, title: "B", fingerprint: "fp", fileName: "book.pdf", pageCount: 50, fileSize: 1)
        #expect(store.contentHashURL(bookID: bookID).path == root.appendingPathComponent("Books/\(bookID.uuidString)/document.sha256").path)
        #expect(store.contentHashURL(bookID: bookID).path
                == store.url(forRelativePath: BookStorageLayout.contentHashPath(bookID: bookID)).path)
        #expect(!store.hasDocument(book))
        try FileManager.default.createDirectory(at: store.bookDirectoryURL(bookID: bookID), withIntermediateDirectories: true)
        try Data("%PDF-".utf8).write(to: store.documentURL(for: book))
        #expect(store.hasDocument(book))
        // Callable off the main actor.
        let offMain = await Task.detached { store.hasDocument(book) }.value
        #expect(offMain)
        var renamed = book
        renamed.fileName = "other.pdf"
        #expect(!store.hasDocument(renamed))
    }

    @Test func fileLocations() throws {
        let (store, _) = try makeStore()
        let book = try #require(try store.books.book(id: bookID))
        let id = bookID.uuidString
        #expect(store.bookDirectoryURL(bookID: bookID).path == "/tmp/root/Books/\(id)")
        #expect(store.documentURL(for: book).path == "/tmp/root/Books/\(id)/book.pdf")
        #expect(store.pageInkDirectoryURL(bookID: bookID).path == "/tmp/root/Books/\(id)/ink")
        #expect(store.noteInkDirectoryURL(bookID: bookID).path == "/tmp/root/Books/\(id)/notes")
        #expect(store.url(forRelativePath: BookStorageLayout.pageInkPath(bookID: bookID, pageIndex: 3)).path == "/tmp/root/Books/\(id)/ink/3.drawing")
        #expect(LibraryStore.inMemory().rootDirectory.lastPathComponent == "TactileTextsInMemory")
    }
}
