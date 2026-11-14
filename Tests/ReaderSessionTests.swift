import Foundation
import PencilKit
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// Session logic that needs no on-screen PDF view: outline loading, heading-path tracking, the
/// debounced last-read save, change filtering, deletion, and markup undo routing.
@MainActor
struct ReaderSessionTests {
    // MARK: Fixture

    struct Fixture {
        let store: LibraryStore
        let book: Book
    }

    /// A store with one book: a copy of the generated `small.pdf` fixture (12 pages; "1 Linear
    /// Systems" p1 with 1.1 p2 and 1.2 p4; "2 Vector Spaces" p5 with 2.1 p6 and 2.2 p8;
    /// "3 Eigenvalues" p9 with 3.1 p10 and 3.2 p12). `scripts/test.sh` generates it first.
    private func makeFixture() throws -> Fixture {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/out/small.pdf")
        let store = try LibraryStore.ephemeral()
        let book = Book(title: "Small", fingerprint: "test-\(UUID().uuidString)", fileName: "small.pdf",
                        pageCount: 12, fileSize: 1)
        try store.books.save(book)
        let url = store.documentURL(for: book)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: url)
        return Fixture(store: store, book: book)
    }

    private func makeSession(_ fixture: Fixture, configure: (inout ReaderSession.Configuration) -> Void = { _ in })
        -> ReaderSession {
        var configuration = ReaderSession.Configuration()
        configuration.lastReadSaveDelay = .milliseconds(150)
        configuration.notebookRebuildDelay = .milliseconds(10)
        configure(&configuration)
        return ReaderSession(book: fixture.book, store: fixture.store, configuration: configuration)
    }

    private func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func cleanUp(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.store.rootDirectory)
    }

    // MARK: Outline and heading path

    @Test func outlineLoadsOffMainAndHeadingPathFollowsPage() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        session.open()
        #expect(await waitUntil { session.isOutlineLoaded })
        #expect(session.loadState == .ready)
        #expect(session.pageCount == 12)
        #expect(session.outline.nodes.count == 9)
        #expect(session.outline.nodes.prefix(4).map(\.title) == ["1 Linear Systems", "1.1 Foundations", "1.2 Exercises", "2 Vector Spaces"])
        #expect(session.headingPath.map(\.title) == ["1 Linear Systems"])  // page index 0

        session.pdfReportedCurrentPage(6)  // page 7
        #expect(session.headingPath.map(\.title) == ["2 Vector Spaces", "2.1 Foundations"])
        #expect(session.deepestHeading?.title == "2.1 Foundations")

        #expect(session.jump(toDisplayNumber: 4))
        #expect(session.currentPageIndex == 3)
        #expect(session.deepestHeading?.title == "1.2 Exercises")
        #expect(!session.jump(toDisplayNumber: 13))
        #expect(!session.jump(toPage: -1))
        #expect(session.currentPageIndex == 3)

        let gamma = try #require(session.outline.nodes.first { $0.title == "3 Eigenvalues" })
        #expect(session.jump(toHeading: gamma.anchor))
        #expect(session.currentPageIndex == 8)
    }

    @Test func notebookIsBuiltAndFollowsNotes() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        session.open()
        #expect(await waitUntil { session.notebook != nil })
        let beta = try #require(session.outline.nodes.first { $0.title == "2 Vector Spaces" })
        #expect(session.notebook?.hasBadge(beta.anchor) == false)
        try session.perform { try $0.notes.save(Note(bookID: fixture.book.id, target: .page(6), text: "hi")) }
        #expect(await waitUntil { session.notebook?.hasBadge(beta.anchor) == true })
    }

    // MARK: Last-read save

    @Test func lastReadSaveIsDebouncedAndAttributed() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        var saves: [StoreChangeEvent] = []
        let token = fixture.store.hub.observe { event in
            if case .bookSaved = event.change { saves.append(event) }
        }
        for page in [3, 4, 5, 6, 7] { session.pdfReportedCurrentPage(page) }
        #expect(saves.isEmpty)
        #expect(await waitUntil { !saves.isEmpty })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(saves.count == 1)
        #expect(saves.first?.isFrom(session.origin) == true)
        #expect(try fixture.store.books.book(id: fixture.book.id)?.lastReadPageIndex == 7)

        // suspend() flushes immediately.
        session.pdfReportedCurrentPage(10)
        await session.suspend()
        #expect(saves.count == 2)
        #expect(try fixture.store.books.book(id: fixture.book.id)?.lastReadPageIndex == 10)
        _ = token
    }

    @Test func startPagePriority() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        var stored = fixture.book
        stored.lastReadPageIndex = 9
        let restored = ReaderSession.RestorableState(pageIndex: 4, isContentsVisible: false, isNotesVisible: false,
                                                     notesTab: .section, notesPanelWidth: 500)
        let fromBook = ReaderSession(book: stored, store: fixture.store)
        #expect(fromBook.currentPageIndex == 9)
        var configuration = ReaderSession.Configuration()
        configuration.restoredState = restored
        let fromScene = ReaderSession(book: stored, store: fixture.store, configuration: configuration)
        #expect(fromScene.currentPageIndex == 4)
        #expect(!fromScene.isContentsVisible && !fromScene.isNotesVisible)
        #expect(fromScene.notesTab == .section && fromScene.notesPanelWidth == 500)
        #expect(fromScene.mode == .reading)
        configuration.initialPageIndex = 11
        configuration.startInMarkup = true
        configuration.openNotesTab = .page
        let fromLaunch = ReaderSession(book: stored, store: fixture.store, configuration: configuration)
        #expect(fromLaunch.currentPageIndex == 11)
        #expect(fromLaunch.isMarkupMode)
        #expect(fromLaunch.isNotesVisible && fromLaunch.notesTab == .page)
        #expect(fromLaunch.restorableState.pageIndex == 11)
    }

    // MARK: Change filtering

    @Test func revisionsFilterBookAndOrigin() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        let other = Book(title: "Other", fingerprint: "other", fileName: "o.pdf", pageCount: 5, fileSize: 1)
        try fixture.store.books.save(other)
        let otherWindow = ChangeOrigin(label: "other window")

        // Another book: ignored.
        try fixture.store.perform(as: otherWindow) {
            try fixture.store.bookmarks.setBookmarked(true, bookID: other.id, pageIndex: 1)
        }
        #expect(session.revisions.bookmarks == 0)

        // This book, another window: both counters.
        try fixture.store.perform(as: otherWindow) {
            try fixture.store.bookmarks.setBookmarked(true, bookID: fixture.book.id, pageIndex: 1)
        }
        #expect(session.revisions.bookmarks == 1)
        #expect(session.externalRevisions.bookmarks == 1)

        // This book, this session: only `revisions`.
        try session.perform { try $0.bookmarks.setBookmarked(true, bookID: fixture.book.id, pageIndex: 2) }
        #expect(session.revisions.bookmarks == 2)
        #expect(session.externalRevisions.bookmarks == 1)

        // Imperative observation: own events excluded unless asked for.
        var seen: [StoreChange] = []
        var seenAll: [StoreChange] = []
        let token = session.observeBookChanges { seen.append($0.change) }
        let tokenAll = session.observeBookChanges(includeOwn: true) { seenAll.append($0.change) }
        try session.perform { try $0.bookmarks.setBookmarked(false, bookID: fixture.book.id, pageIndex: 2) }
        try fixture.store.perform(as: otherWindow) {
            try fixture.store.bookmarks.setBookmarked(false, bookID: fixture.book.id, pageIndex: 1)
            try fixture.store.bookmarks.setBookmarked(false, bookID: other.id, pageIndex: 1)
        }
        #expect(seen == [.bookmarksChanged(bookID: fixture.book.id, pageIndex: 1)])
        #expect(seenAll.count == 2)
        _ = (token, tokenAll)
    }

    @Test func userHeadingChangeRebuildsOutline() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        session.open()
        #expect(await waitUntil { session.isOutlineLoaded })
        session.pdfReportedCurrentPage(2)
        #expect(session.deepestHeading?.title == "1.1 Foundations")
        let alpha = try #require(session.outline.nodes.first { $0.title == "1 Linear Systems" })
        let heading = UserHeading(bookID: fixture.book.id, title: "Mine", pageIndex: 2, parent: alpha.anchor)
        try fixture.store.perform(as: ChangeOrigin()) { try fixture.store.headings.save(heading) }
        #expect(await waitUntil { session.deepestHeading?.title == "Mine" })
        #expect(session.headingPath.map(\.title) == ["1 Linear Systems", "Mine"])
    }

    @Test func deletingTheBookClosesTheSessionAndNeverResurrectsIt() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        session.setMode(.markup)
        session.pdfReportedCurrentPage(5)  // schedules a save
        try await fixture.store.deleteBook(id: fixture.book.id, origin: ChangeOrigin(label: "library"))
        #expect(session.closeReason == .bookDeleted)
        #expect(session.mode == .reading)
        try? await Task.sleep(for: .milliseconds(300))
        await session.suspend()
        #expect(try fixture.store.books.book(id: fixture.book.id) == nil)
    }

    @Test func windowPathDropsDeletedBook() {
        let a = UUID(), b = UUID()
        let path: [WindowRoute] = [.notebook(bookID: a), .reader(bookID: b), .reader(bookID: a)]
        #expect(WindowContext.path(path, removingBook: a) == [.reader(bookID: b)])
        let context = WindowContext(kind: .library, path: path)
        context.bookWasDeleted(b)
        #expect(context.path == [.notebook(bookID: a), .reader(bookID: a)])
    }

    // MARK: Section history

    /// Owner's acceptance rule: Back/Forward return to the exact page left in each section.
    @Test func sectionHistoryReturnsToThePageLeftAndIsRestored() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        session.open()
        #expect(await waitUntil { session.isOutlineLoaded })
        #expect(!session.canGoBack && !session.canGoForward)

        // Scrolling and paging are not jumps.
        session.pdfReportedCurrentPage(2)
        session.goToNextPage()
        session.goToPreviousPage()
        #expect(!session.canGoBack)

        #expect(session.jump(toPage: 5))          // A = 2.1 (p6)
        session.pdfReportedCurrentPage(6)         // scroll within A to p7
        #expect(session.jump(toPage: 9))          // B = 3.1 (p10)
        session.pdfReportedCurrentPage(10)        // scroll within B to p11
        #expect(session.canGoBack && !session.canGoForward)
        #expect(session.history.backList.map(\.place.menuTitle) == ["2.1 Foundations · p. 7", "1.1 Foundations · p. 3"])

        session.goBack()
        #expect(session.currentPageIndex == 6)    // the scrolled-to page in A, not its start
        session.goForward()
        #expect(session.currentPageIndex == 10)   // the page left in B
        session.goBack()
        #expect(session.canGoForward)

        // A jump within the same section adds nothing; a new jump drops forward entries.
        #expect(session.jump(toPage: 5))
        #expect(session.canGoForward)
        #expect(session.jump(toDisplayNumber: 12))  // 3.2
        #expect(!session.canGoForward)

        // Restoration carries the trail.
        var configuration = ReaderSession.Configuration()
        configuration.restoredState = session.restorableState
        configuration.installsFeatures = false
        let restored = ReaderSession(book: fixture.book, store: fixture.store, configuration: configuration)
        #expect(restored.history == session.history)
        #expect(restored.currentPageIndex == 11)
    }

    @Test func notesForARequestedHeading() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture) { $0.installsFeatures = false }
        let anchor = HeadingAnchor(userHeadingID: UUID())
        session.isNotesVisible = false
        session.showNotes(.section, heading: anchor)
        #expect(session.isNotesVisible && session.notesTab == .section)
        #expect(session.requestedSectionHeading == anchor)
        #expect(session.takeRequestedSectionHeading() == anchor)
        #expect(session.requestedSectionHeading == nil)
        session.showNotes(.page, heading: anchor)  // a heading only applies to the Section tab
        #expect(session.requestedSectionHeading == nil && session.notesTab == .page)
    }

    // MARK: Markup

    @Test func markupRoutesUndoToLastActiveSurfaceAndFlushes() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture) { $0.inkAnyInput = true }
        let page = FakeSurface(id: "page-1")
        let note = FakeSurface(id: "note-1")
        session.markup.register(page)
        session.markup.register(note)
        #expect(page.canvasView.drawingPolicy == .anyInput)
        #expect(page.modes == [false] && note.modes == [false])
        session.setMode(.markup)
        #expect(page.modes == [false, true])

        page.recordUndoable()
        session.markup.surfaceDidBeginStroke(page)
        session.markup.surfaceDidEndStroke(page)
        note.recordUndoable()
        session.markup.surfaceDidBeginStroke(note)
        session.markup.surfaceDidEndStroke(note)
        #expect(session.markup.activeSurfaceID == "note-1")
        #expect(session.markup.canUndo)
        session.markup.undo()
        #expect(note.undone == 1 && page.undone == 0)
        #expect(session.markup.canRedo)

        session.markup.unregister(note)
        #expect(session.markup.activeSurfaceID == "page-1")
        session.markup.undo()
        #expect(page.undone == 1)

        session.finishMarkup()
        #expect(page.modes.last == false)
        #expect(await waitUntil { page.flushes >= 1 })
        #expect(note.flushes == 0)  // unregistered
    }
}

@MainActor
private final class FakeSurface: MarkupSurface {
    let markupSurfaceID: String
    let canvasView = PKCanvasView()
    let undo = UndoManager()
    var modes: [Bool] = []
    var flushes = 0
    var undone = 0

    init(id: String) {
        markupSurfaceID = id
        undo.groupsByEvent = false
    }

    var markupUndoManager: UndoManager? { undo }
    func markupModeDidChange(_ isMarkup: Bool) { modes.append(isMarkup) }
    func flushPendingMarkup() async { flushes += 1 }

    func recordUndoable() {
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { target in
            target.undone += 1
            target.undo.registerUndo(withTarget: target) { _ in }
        }
        undo.endUndoGrouping()
    }
}
