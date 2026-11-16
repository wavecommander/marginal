import Foundation
import ReaderCore
import ReaderStore
import Testing
@testable import TactileTexts

/// One book shown in several windows at once (two readers and a Notebook): every window's
/// outline and Notebook tree follow the same stored data.
@MainActor
struct BookIndexTests {
    struct Fixture {
        let store: LibraryStore
        let book: Book
        @MainActor var documentURL: URL { store.documentURL(for: book) }
    }

    static let smallPDF = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out/small.pdf")

    /// A store with one book, `small.pdf` (12 pages; "1 Linear Systems" p1 with 1.1 p2 and 1.2
    /// p4; "2 Vector Spaces" p5 with 2.1 p6 and 2.2 p8; "3 Eigenvalues" p9 with 3.1 p10 and 3.2
    /// p12). With `withPDF: false` the book has its record but no file (restored without PDFs).
    private func makeFixture(withPDF: Bool = true) throws -> Fixture {
        let store = try LibraryStore.ephemeral()
        let book = Book(title: "Small", fingerprint: "index-\(UUID().uuidString)", fileName: "small.pdf",
                        pageCount: 12, fileSize: 1)
        try store.books.save(book)
        let fixture = Fixture(store: store, book: book)
        if withPDF { try addPDF(fixture) }
        return fixture
    }

    private func addPDF(_ fixture: Fixture) throws {
        let url = fixture.documentURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.smallPDF, to: url)
    }

    private func makeSession(_ fixture: Fixture) -> ReaderSession {
        var configuration = ReaderSession.Configuration()
        configuration.notebookRebuildDelay = .milliseconds(10)
        configuration.installsFeatures = false
        return ReaderSession(book: fixture.book, store: fixture.store, configuration: configuration)
    }

    private func makeNotebook(_ fixture: Fixture) -> NotebookModel {
        NotebookModel(store: fixture.store, bookID: fixture.book.id, rebuildDelay: .milliseconds(10))
    }

    private func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func cleanUp(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.store.rootDirectory)
    }

    private func titles(_ outline: Outline) -> [String] { outline.nodes.map(\.title) }

    // MARK: Every window follows the same data

    @Test func aNoteSavedInOneWindowShowsInEveryWindow() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let first = makeSession(fixture), second = makeSession(fixture)
        first.open()
        second.open()
        let notebook = makeNotebook(fixture)
        await notebook.start()
        #expect(await waitUntil { first.notebook != nil && second.notebook != nil })
        #expect(notebook.phase == .ready)
        let chapter = try #require(first.outline.nodes.first { $0.title == "2 Vector Spaces" })
        #expect(first.notebook?.hasBadge(chapter.anchor) == false)

        let saved = try first.perform { try $0.notes.save(Note(bookID: fixture.book.id, target: .page(6), text: "hi")) }
        let note = try #require(saved)
        #expect(await waitUntil {
            first.notebook?.hasBadge(chapter.anchor) == true && second.notebook?.hasBadge(chapter.anchor) == true
                && notebook.notebook?.hasBadge(chapter.anchor) == true
        })
        #expect(second.notebook?.counts(for: chapter.anchor).pageNotes == 1)

        // Edited, then moved away by deleting: every window follows.
        var edited = note
        edited.text = "hello"
        _ = try second.perform { try $0.notes.save(edited) }
        let deepest = try #require(first.outline.deepestHeading(forPage: 6))
        #expect(await waitUntil {
            notebook.notebook?.section(for: deepest.anchor)?.pages.first?.note?.text == "hello"
                && first.notebook?.section(for: deepest.anchor)?.pages.first?.note?.text == "hello"
        })
        try await fixture.store.deleteNote(id: note.id, origin: nil)
        #expect(await waitUntil {
            first.notebook?.hasBadge(chapter.anchor) == false && second.notebook?.hasBadge(chapter.anchor) == false
                && notebook.notebook?.hasBadge(chapter.anchor) == false
        })
    }

    @Test func highlightsAndBookmarksReachEveryWindow() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        session.open()
        let notebook = makeNotebook(fixture)
        await notebook.start()
        #expect(await waitUntil { session.notebook != nil })
        let section = try #require(session.outline.deepestHeading(forPage: 9))

        let highlight = Highlight(bookID: fixture.book.id, pageIndex: 9, rects: [], color: .green, text: "marked")
        try fixture.store.highlights.save(highlight)
        try fixture.store.bookmarks.setBookmarked(true, bookID: fixture.book.id, pageIndex: 9)
        #expect(await waitUntil {
            session.notebook?.counts(for: section.anchor).highlights == 1
                && session.notebook?.counts(for: section.anchor).bookmarks == 1
                && notebook.notebook?.counts(for: section.anchor).highlights == 1
        })

        // Moved to another page (another section), then deleted.
        var moved = highlight
        moved.pageIndex = 1
        try fixture.store.highlights.save(moved)
        let other = try #require(session.outline.deepestHeading(forPage: 1))
        #expect(await waitUntil {
            session.notebook?.counts(for: section.anchor).highlights == 0
                && session.notebook?.counts(for: other.anchor).highlights == 1
                && notebook.notebook?.counts(for: other.anchor).highlights == 1
        })
        try fixture.store.highlights.deleteHighlight(id: highlight.id)
        try fixture.store.bookmarks.setBookmarked(false, bookID: fixture.book.id, pageIndex: 9)
        #expect(await waitUntil {
            session.notebook?.totalCounts.highlights == 0 && session.notebook?.totalCounts.bookmarks == 0
                && notebook.notebook?.totalCounts.highlights == 0
        })
    }

    @Test func aHeadingTheReaderAddsAppearsInEveryWindow() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let first = makeSession(fixture), second = makeSession(fixture)
        first.open()
        second.open()
        let notebook = makeNotebook(fixture)
        await notebook.start()
        #expect(await waitUntil { first.isOutlineLoaded && second.isOutlineLoaded })
        #expect(first.outline.nodes.count == 9)

        first.pdfReportedCurrentPage(2)
        #expect(first.headingPath.map(\.title) == ["1 Linear Systems", "1.1 Foundations"])
        let heading = UserHeading(bookID: fixture.book.id, title: "Worked example", pageIndex: 2, parent: nil)
        try first.perform { try $0.headings.save(heading) }
        #expect(await waitUntil {
            titles(first.outline).contains("Worked example") && titles(second.outline).contains("Worked example")
                && notebook.notebook?.sections.contains { $0.title == "Worked example" } == true
        })
        #expect(first.headingPath.last?.title == "Worked example", "the heading path follows the new outline")

        try second.perform { try $0.headings.deleteUserHeading(id: heading.id) }
        #expect(await waitUntil {
            !titles(first.outline).contains("Worked example") && !titles(second.outline).contains("Worked example")
                && notebook.notebook?.sections.contains { $0.title == "Worked example" } == false
        })
        #expect(first.headingPath.map(\.title) == ["1 Linear Systems", "1.1 Foundations"])
    }

    @Test func pagesWithInkAreListedInTheNotebookAndNeverBadge() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        session.open()
        let notebook = makeNotebook(fixture)
        await notebook.start()
        #expect(await waitUntil { session.notebook != nil })
        #expect(notebook.notebook?.inkedPageIndices == [])

        try await fixture.store.savePageInk(Data([1, 2, 3]), bookID: fixture.book.id, pageIndex: 7, origin: session.origin)
        #expect(await waitUntil { notebook.notebook?.inkedPageIndices == [7] })
        #expect(notebook.pageInkVersions[7] == 1)
        let section = try #require(session.outline.deepestHeading(forPage: 7))
        #expect(session.notebook?.hasBadge(section.anchor) == false)
        #expect(notebook.notebook?.hasBadge(section.anchor) == false)

        try await fixture.store.deletePageInk(bookID: fixture.book.id, pageIndex: 7, origin: session.origin)
        #expect(await waitUntil { notebook.notebook?.inkedPageIndices == [] })
    }

    @Test func aWindowOpenedLaterStartsFromTheCurrentData() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let first = makeSession(fixture)
        first.open()
        #expect(await waitUntil { first.notebook != nil })
        _ = try first.perform { try $0.notes.save(Note(bookID: fixture.book.id, target: .page(6), text: "hi")) }
        try first.perform {
            try $0.headings.save(UserHeading(bookID: fixture.book.id, title: "Mine", pageIndex: 6, parent: nil))
        }
        #expect(await waitUntil { first.notebook?.totalCounts.pageNotes == 1 && titles(first.outline).contains("Mine") })

        let second = makeSession(fixture)
        #expect(!second.isOutlineLoaded, "a window has no outline before its document has opened")
        #expect(second.notebook == nil)
        second.open()
        #expect(await waitUntil { second.notebook?.totalCounts.pageNotes == 1 })
        #expect(titles(second.outline) == titles(first.outline))
        let notebook = makeNotebook(fixture)
        await notebook.start()
        #expect(notebook.notebook?.totalCounts.pageNotes == 1)
        #expect(notebook.notebook?.sections.contains { $0.title == "Mine" } == true)
    }

    @Test func deletingTheBookEndsEveryWindowAndANewBookWithItsIDStartsAfresh() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        session.open()
        let notebook = makeNotebook(fixture)
        await notebook.start()
        #expect(await waitUntil { session.notebook != nil })
        _ = try session.perform { try $0.notes.save(Note(bookID: fixture.book.id, target: .page(6), text: "old")) }
        #expect(await waitUntil { session.notebook?.totalCounts.pageNotes == 1 })

        // A restore replaces the book under the same ID: windows on it close, and a window opened
        // afterwards shows the restored records only.
        let restored = BookArchive(book: fixture.book, notes: [Note(bookID: fixture.book.id, target: .page(1), text: "restored")],
                                   highlights: [], bookmarks: [], userHeadings: [])
        try fixture.store.books.replaceBook(restored, removing: [])
        #expect(session.closeReason == .bookDeleted)
        #expect(notebook.phase == .missing)
        #expect(notebook.notebook == nil)

        let reopened = makeSession(fixture)
        reopened.open()
        #expect(await waitUntil { reopened.notebook != nil })
        #expect(reopened.notebook?.totalCounts.pageNotes == 1)
        let fresh = makeNotebook(fixture)
        await fresh.start()
        #expect(fresh.phase == .ready)
        #expect(fresh.notebook?.totalCounts.pageNotes == 1)
    }

    @Test func aPDFLocatedWhileANotebookIsOpenGivesLaterWindowsItsOutline() async throws {
        let fixture = try makeFixture(withPDF: false)
        defer { cleanUp(fixture) }
        // Restored without its PDF: the Notebook opens with no outline.
        let notebook = makeNotebook(fixture)
        await notebook.start()
        #expect(notebook.phase == .ready)
        #expect(notebook.notebook?.sections.isEmpty == true)

        // The PDF is linked (the file appears and the book is saved).
        try addPDF(fixture)
        try fixture.store.books.save(fixture.book)
        let session = makeSession(fixture)
        session.open()
        #expect(await waitUntil { session.isOutlineLoaded })
        #expect(session.outline.nodes.count == 9)
    }

    // MARK: One index per book

    @Test func everyWindowOnABookSharesOneIndex() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let index = BookIndex.shared(for: fixture.book, in: fixture.store)
        #expect(BookIndex.shared(for: fixture.book, in: fixture.store) === index)

        // Another book, and the same book in another store, have their own.
        let second = Book(title: "Second", fingerprint: "index-\(UUID().uuidString)", fileName: "second.pdf",
                          pageCount: 3, fileSize: 1)
        try fixture.store.books.save(second)
        #expect(BookIndex.shared(for: second, in: fixture.store) !== index)
        let elsewhere = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: elsewhere.rootDirectory) }
        try elsewhere.books.save(fixture.book)
        #expect(BookIndex.shared(for: fixture.book, in: elsewhere) !== index)
    }

    @Test func aChangeIsReadAndBuiltOnceForEveryWindow() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let first = makeSession(fixture), second = makeSession(fixture)
        first.open()
        second.open()
        let notebook = makeNotebook(fixture)
        await notebook.start()
        #expect(await waitUntil { first.notebook != nil && second.notebook != nil })
        let index = BookIndex.shared(for: fixture.book, in: fixture.store)
        try await Task.sleep(for: .milliseconds(100))  // nothing left to build
        #expect(index.wholeBookReadCount == 1, "the book's records are read as a whole once, for all three windows")
        let builds = index.buildCount
        let notebookBuilds = notebook.buildCount

        _ = try first.perform { try $0.notes.save(Note(bookID: fixture.book.id, target: .page(6), text: "hi")) }
        #expect(await waitUntil {
            second.notebook?.totalCounts.pageNotes == 1 && notebook.notebook?.totalCounts.pageNotes == 1
        })
        try await Task.sleep(for: .milliseconds(100))
        #expect(index.buildCount == builds + 1, "one build, whatever the number of windows")
        #expect(notebook.buildCount == notebookBuilds + 1)
        #expect(index.wholeBookReadCount == 1, "a change re-reads only what it names")
    }

    @Test func aBurstOfChangesIsBuiltOnce() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        session.open()
        #expect(await waitUntil { session.notebook != nil })
        let index = BookIndex.shared(for: fixture.book, in: fixture.store)
        let builds = index.buildCount

        for page in 0..<8 {
            try fixture.store.highlights.save(Highlight(bookID: fixture.book.id, pageIndex: page, rects: [], color: .yellow,
                                                        text: "h\(page)"))
        }
        #expect(await waitUntil { session.notebook?.totalCounts.highlights == 8 })
        #expect(index.buildCount == builds + 1)
    }

    @Test func readersBuildNothingForInkUnlessANotebookIsOpen() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        session.open()
        #expect(await waitUntil { session.notebook != nil })
        let index = BookIndex.shared(for: fixture.book, in: fixture.store)
        let builds = index.buildCount

        try await fixture.store.savePageInk(Data([1, 2, 3]), bookID: fixture.book.id, pageIndex: 7, origin: session.origin)
        try await Task.sleep(for: .milliseconds(150))
        #expect(index.buildCount == builds, "drawing with no Notebook window open builds nothing")
        #expect(fixture.store.inkedPages.listingCount == 0)

        // A Notebook opened now lists the page. The reader has nothing new to show.
        let notebook = makeNotebook(fixture)
        await notebook.start()
        #expect(notebook.notebook?.inkedPageIndices == [7])
        #expect(fixture.store.inkedPages.listingCount == 1)
        #expect(session.notebook?.inkedPageIndices == [])

        // Once the Notebook has gone, ink builds nothing again.
        notebook.stop()
        let afterNotebook = index.buildCount
        try await fixture.store.savePageInk(Data([4, 5, 6]), bookID: fixture.book.id, pageIndex: 8, origin: session.origin)
        try await Task.sleep(for: .milliseconds(150))
        #expect(index.buildCount == afterNotebook)
    }

    @Test func anchorRepairsDoNotRebuildTheTree() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        // A heading note stored against a stale anchor (wrong outline path) for "2 Vector Spaces".
        let stale = HeadingAnchor(pdfPath: [7], pageIndex: 4, title: "2 Vector Spaces")
        let saved = try fixture.store.notes.save(Note(bookID: fixture.book.id, target: .heading(stale), text: "Chapter 2"))
        let note = try #require(saved)
        let session = makeSession(fixture)
        session.open()
        let notebook = makeNotebook(fixture)
        await notebook.start()
        #expect(await waitUntil { session.notebook != nil })
        let index = BookIndex.shared(for: fixture.book, in: fixture.store)
        let section = try #require(notebook.notebook?.sections.first { $0.title == "2 Vector Spaces" })
        #expect(try fixture.store.notes.note(id: note.id)?.target == .heading(section.anchor), "repaired by the Notebook")
        let builds = index.buildCount
        try await Task.sleep(for: .milliseconds(150))
        #expect(index.buildCount == builds)

        // The index's records followed the repair: the next tree needs no repair.
        try fixture.store.bookmarks.setBookmarked(true, bookID: fixture.book.id, pageIndex: 1)
        #expect(await waitUntil { index.buildCount == builds + 1 })
        #expect(index.notebook?.anchorRepairs.isEmpty == true)
        #expect(index.notebook?.section(for: section.anchor)?.note?.id == note.id)
    }
}
