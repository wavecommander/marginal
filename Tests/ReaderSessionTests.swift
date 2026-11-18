import Foundation
import PDFKit
import PencilKit
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import TactileTexts

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
        _ = try session.perform { try $0.notes.save(Note(bookID: fixture.book.id, target: .page(6), text: "hi")) }
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

    /// A reader woken under the top screen and never shown (its PDF view never positioned) has
    /// not been read: it saves no position.
    @Test func aReaderNeverShownSavesNoPosition() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture) { $0.initialPageIndex = 5 }
        session.open()
        #expect(await waitUntil { session.loadState == .ready })
        #expect(session.pdf.isAwaitingFirstPosition)
        await session.suspend()
        #expect(try fixture.store.books.book(id: fixture.book.id)?.lastReadPageIndex == fixture.book.lastReadPageIndex)
    }

    @Test func notesPanelComesBackAsItWasLeft() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let suite = "ReaderSessionTests.notes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var configuration = ReaderSession.Configuration()
        configuration.notesPanelStore = ReaderNotesPanelStore(defaults: defaults)

        let first = ReaderSession(book: fixture.book, store: fixture.store, configuration: configuration)
        #expect(!first.isNotesVisible, "a first open starts with the panel closed")
        first.showNotes(.section)
        first.saveNotesPanelState()
        let reopened = ReaderSession(book: fixture.book, store: fixture.store, configuration: configuration)
        #expect(reopened.isNotesVisible && reopened.notesTab == .section)

        reopened.toggleNotes()
        reopened.saveNotesPanelState()
        let again = ReaderSession(book: fixture.book, store: fixture.store, configuration: configuration)
        #expect(!again.isNotesVisible && again.notesTab == .section, "closed stays closed")
    }

    @Test func startPagePriority() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let suite = "ReaderSessionTests.position.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let positions = ReaderPositionStore(defaults: defaults)
        var stored = fixture.book
        stored.lastReadPageIndex = 9
        let restored = ReaderSession.RestorableState(isContentsVisible: false, isNotesVisible: false,
                                                     notesTab: .section, notesPanelWidth: 500)
        var configuration = ReaderSession.Configuration()
        configuration.positionStore = positions
        let fromBook = ReaderSession(book: stored, store: fixture.store, configuration: configuration)
        #expect(fromBook.currentPageIndex == 9)
        #expect(fromBook.startPosition == nil)
        #expect(!fromBook.isNotesVisible)  // a first open starts with the notes panel closed

        // Scene state brings the panels back; the page is the book's latest position.
        configuration.restoredState = restored
        let fromScene = ReaderSession(book: stored, store: fixture.store, configuration: configuration)
        #expect(fromScene.currentPageIndex == 9)
        #expect(!fromScene.isContentsVisible && !fromScene.isNotesVisible)
        #expect(fromScene.notesTab == .section && fromScene.notesPanelWidth == 500)
        #expect(fromScene.mode == .reading)

        // The exact place and zoom, when they belong to the stored last-read page.
        let exact = ReaderPosition(pageIndex: 9, anchor: ReadingAnchor(pageIndex: 8, point: CGPoint(x: 20, y: 300)),
                                   scale: 1.5, isFitWidth: false)
        positions.setPosition(exact, for: stored.id)
        #expect(ReaderSession(book: stored, store: fixture.store, configuration: configuration).startPosition == exact)
        var moved = stored
        moved.lastReadPageIndex = 3  // e.g. a restore or a merge moved the stored page
        let stale = ReaderSession(book: moved, store: fixture.store, configuration: configuration)
        #expect(stale.currentPageIndex == 3 && stale.startPosition == nil)

        // A waking reader resumes its own place and zoom, whatever the book's latest position.
        let own = ReaderPosition(pageIndex: 4, anchor: ReadingAnchor(pageIndex: 4, point: CGPoint(x: 0, y: 120)),
                                 scale: 1, isFitWidth: true)
        configuration.resumePosition = own
        let resumed = ReaderSession(book: stored, store: fixture.store, configuration: configuration)
        #expect(resumed.currentPageIndex == 4 && resumed.startPosition == own)
        configuration.resumePosition = ReaderPosition(pageIndex: 40, anchor: own.anchor, scale: 1, isFitWidth: true)
        #expect(ReaderSession(book: stored, store: fixture.store, configuration: configuration).startPosition == exact,
                "a place outside the book is ignored")
        configuration.resumePosition = own

        configuration.initialPageIndex = 11
        configuration.startInMarkup = true
        configuration.openNotesTab = .page
        let fromLaunch = ReaderSession(book: stored, store: fixture.store, configuration: configuration)
        #expect(fromLaunch.currentPageIndex == 11)
        #expect(fromLaunch.startPosition == nil)
        #expect(fromLaunch.isMarkupMode)
        #expect(fromLaunch.isNotesVisible && fromLaunch.notesTab == .page)
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

    /// Sleeping readers: the top screen and the one under it stay awake; a reader being shown is
    /// placed at the top, or just under it while the back swipe reveals it.
    @Test func readerSleepRule() {
        #expect(WindowContext.readerStaysAwake(pathIndex: 3, pathCount: 4))
        #expect(WindowContext.readerStaysAwake(pathIndex: 2, pathCount: 4))
        #expect(!WindowContext.readerStaysAwake(pathIndex: 1, pathCount: 4))
        #expect(!WindowContext.readerStaysAwake(pathIndex: 0, pathCount: 4))
        let a = UUID(), b = UUID()
        let path: [WindowRoute] = [.reader(bookID: a), .notebook(bookID: a), .reader(bookID: a), .notebook(bookID: b)]
        #expect(WindowContext.pathIndex(ofShownReader: a, in: Array(path.prefix(3))) == 2)
        #expect(WindowContext.pathIndex(ofShownReader: a, in: path) == 2)
        #expect(WindowContext.pathIndex(ofShownReader: a, in: Array(path.prefix(2))) == 0)
        #expect(WindowContext.pathIndex(ofShownReader: b, in: path) == nil)
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

        // Restoration carries the trail, and opens at the book's latest position (here the
        // stored last-read page: this session has no on-screen view, so it saved none).
        var configuration = ReaderSession.Configuration()
        configuration.restoredState = session.restorableState
        configuration.installsFeatures = false
        var book = try #require(try fixture.store.books.book(id: fixture.book.id))
        book.lastReadPageIndex = 7
        let restored = ReaderSession(book: book, store: fixture.store, configuration: configuration)
        #expect(restored.history == session.history)
        #expect(restored.currentPageIndex == 7)
    }

    // MARK: Section history in a real PDF view

    /// A session on `links.pdf` (`small.pdf`'s pages and outline plus links: on page 7, "start
    /// of 2.1" at y 120 → page 6 and "3.2 Exercises" at y 200 → page 12; on page 3, "middle of
    /// page 7" at y 400 → page 7 y 450), hosted in a window, positioned and with its outline.
    private func makeLinkedHost(configure: (inout ReaderSession.Configuration) -> Void = { _ in }) async throws
        -> PageInkTestSupport.Host {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("links.pdf"), pageCount: 12)
        let host = PageInkTestSupport.Host(book: book, store: store) {
            $0.installsFeatures = false
            configure(&$0)
        }
        #expect(await waitUntil { host.session.isOutlineLoaded && host.session.pdf.hasPositionedInitially })
        await settle()
        return host
    }

    /// Lets PDFKit and the history move's alignment finish.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// Scrolls as the reader's finger does (no jump), so page-space `y` of zero-based `page` is
    /// at the top of the view.
    private func scroll(_ session: ReaderSession, toPage page: Int, y: CGFloat) async throws {
        let view = session.pdf.view
        let scrollView = try #require(session.pdf.scrollView)
        let pdfPage = try #require(session.pdf.page(at: page))
        let content = scrollView.convert(view.convert(CGPoint(x: 0, y: y), from: pdfPage), from: view)
        scrollView.contentOffset.y = content.y - scrollView.adjustedContentInset.top
        await settle()
    }

    /// The current page (and so the page pill) follows a scroll while it is in progress: each
    /// scroll step that moves the place on screen is reported at once, without waiting for
    /// PDFKit's page notification at the end of the scroll.
    @Test func currentPageFollowsAScrollInProgress() async throws {
        let host = try await makeLinkedHost()
        let session = host.session
        let scrollView = try #require(session.pdf.scrollView)
        #expect(session.currentPageIndex == 0)
        var seen: [Int] = []
        // Small steps on the same run-loop turn, as a drag's frames are: no notification can land.
        for _ in 0..<400 {
            scrollView.contentOffset.y += 20
            if seen.last != session.currentPageIndex { seen.append(session.currentPageIndex) }
            if session.currentPageIndex >= 3 { break }
        }
        #expect(seen.count >= 3, "pages seen mid-scroll: \(seen)")
        #expect(session.currentPageIndex >= 3)
    }

    /// Follows the link whose box starts at page-space `y` on zero-based `page` as PDFKit does
    /// on a tap: it performs the link's action on the view (a plain destination as a go-to).
    private func followLink(_ session: ReaderSession, onPage page: Int, y: CGFloat) async throws {
        let link = try #require(session.pdf.annotations(onPageAt: page).first {
            $0.bounds.minY == y && ($0.action != nil || $0.destination != nil)
        })
        let action = try #require(link.action ?? link.destination.map { PDFActionGoTo(destination: $0) })
        session.pdf.view.perform(action)
        await settle()
    }

    /// The same page point at the top of the view (≤ 1 pt in page space).
    private func expectSamePlace(_ actual: ReadingAnchor?, _ expected: ReadingAnchor?, _ context: String,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        let same = actual.map { a in expected.map { a.pageIndex == $0.pageIndex && abs(a.point.y - $0.point.y) <= 1 } ?? false } ?? false
        #expect(same, "\(context): at \(String(describing: actual)), left at \(String(describing: expected))",
                sourceLocation: sourceLocation)
    }

    /// TSOFT-214, the owner's sequence: jump A → B, Back, Forward, read on in B, follow a link
    /// to C, Back: back in B at the exact place the link was followed from.
    @Test func backAfterFollowingALinkReturnsToTheExactPlaceItWasFollowedFrom() async throws {
        let host = try await makeLinkedHost()
        let session = host.session
        #expect(session.jump(toPage: 5))                    // A "1 Linear Systems" p1 → B "2.1" p6
        await settle()
        session.goBack()
        await settle()
        #expect(session.currentPageIndex == 0)
        session.goForward()
        await settle()
        #expect(session.currentPageIndex == 5)

        try await scroll(session, toPage: 6, y: 450)        // read on to p7; its "3.2" link is below
        let left = session.pdf.readingAnchor
        let leftPage = session.currentPageIndex
        #expect(left?.pageIndex == 6)
        try await followLink(session, onPage: 6, y: 200)    // → C "3.2 Exercises" p12
        #expect(session.currentPageIndex == 11)
        #expect(session.history.backList.count == 2)          // the link recorded the place it left
        #expect(session.history.backList.first?.place.anchor == left)
        #expect(session.history.backList.last?.place.title == "1 Linear Systems")

        session.goBack()
        await settle()
        expectSamePlace(session.pdf.readingAnchor, left, "Back after the link")
        #expect(session.currentPageIndex == leftPage)
        #expect(session.canGoForward)
        session.goForward()
        await settle()
        #expect(session.currentPageIndex == 11)
        await host.close()
    }

    /// TSOFT-220: the page a named page action link (`/S /Named`) goes to, recorded as a jump.
    @Test func namedPageActionTargets() {
        let target = ReaderPDFController.namedActionTarget
        #expect(target(.nextPage, 2, 12) == 3)
        #expect(target(.previousPage, 2, 12) == 1)
        #expect(target(.firstPage, 2, 12) == 0)
        #expect(target(.lastPage, 2, 12) == 11)
        // No move, no jump: at either end, or already on the page.
        #expect(target(.nextPage, 11, 12) == nil)
        #expect(target(.previousPage, 0, 12) == nil)
        #expect(target(.firstPage, 0, 12) == nil)
        #expect(target(.lastPage, 11, 12) == nil)
        // Not page actions (PDFKit's own visitation history, find, print, zoom).
        for name in [PDFActionNamedName.goBack, .goForward, .goToPage, .find, .print, .zoomIn, .zoomOut, .none] {
            #expect(target(name, 2, 12) == nil)
        }
        #expect(target(.nextPage, 0, 0) == nil)
        #expect(target(.nextPage, 12, 12) == nil)
    }

    /// `ReaderPDFController.selection(_:containsViewPoint:in:)` matches points inside the selected
    /// text's lines and rejects points elsewhere on the page or outside any page.
    @Test func selectionContainsViewPointChecksSelectedLineBounds() async throws {
        let host = try await makeLinkedHost()
        let pdfView = host.session.pdf.view
        let page = try #require(host.session.pdf.page(at: 0))
        let selection = try #require(page.selection(for: NSRange(location: 0, length: 5)))
        let line = try #require(selection.selectionsByLine().first)
        let lineBounds = line.bounds(for: page)
        let insideView = pdfView.convert(CGPoint(x: lineBounds.midX, y: lineBounds.midY), from: page)
        let blankOnPage = pdfView.convert(CGPoint(x: lineBounds.maxX + 80, y: lineBounds.minY - 80), from: page)
        let outsidePage = CGPoint(x: -20, y: -20)

        #expect(ReaderPDFController.selection(selection, containsViewPoint: insideView, in: pdfView))
        #expect(!ReaderPDFController.selection(selection, containsViewPoint: blankOnPage, in: pdfView))
        #expect(!ReaderPDFController.selection(selection, containsViewPoint: outsidePage, in: pdfView))
        await host.close()
    }

    /// A link followed from mid-page records that exact place; a link that lands in the section
    /// the reader is already in adds no entry (design), so Back then leaves the section.
    @Test func linksFromMidPageAndWithinTheSectionFollowTheRules() async throws {
        let host = try await makeLinkedHost()
        let session = host.session
        #expect(session.jump(toPage: 2))                    // → "1.1 Foundations" p3
        await settle()
        try await scroll(session, toPage: 2, y: 600)        // its link (y 400) is mid-view
        let leftInA = session.pdf.readingAnchor
        try await followLink(session, onPage: 2, y: 400)    // → p7 y 450, in "2.1 Foundations"
        #expect(session.deepestHeading?.title == "2.1 Foundations")
        #expect(session.history.entries.count == 3)

        try await scroll(session, toPage: 6, y: 700)
        try await followLink(session, onPage: 6, y: 120)    // → p6, the start of 2.1: same section
        #expect(session.currentPageIndex == 5)
        #expect(session.history.entries.count == 3)
        #expect(!session.canGoForward)
        let beforeBack = session.pdf.readingAnchor

        session.goBack()
        await settle()
        expectSamePlace(session.pdf.readingAnchor, leftInA, "Back to where the mid-page link was followed")
        session.goForward()
        await settle()
        expectSamePlace(session.pdf.readingAnchor, beforeBack, "Forward to the place Back was pressed")
        await host.close()
    }

    /// Several Backs, scrolling in between, then a new jump: the forward entries go and Back
    /// returns to the exact place the jump was made; the press-and-hold lists go straight to an
    /// entry's exact place; a restored window keeps the exact places.
    @Test func historyListsNewJumpsAndRestorationKeepExactPlaces() async throws {
        let host = try await makeLinkedHost()
        let session = host.session
        try await scroll(session, toPage: 0, y: 300)
        let inA = session.pdf.readingAnchor
        #expect(session.jump(toPage: 5))                    // → B "2.1"
        await settle()
        try await scroll(session, toPage: 5, y: 380)
        let inB = session.pdf.readingAnchor
        #expect(session.jump(toPage: 11))                   // → C "3.2"
        await settle()
        session.goBack()
        await settle()
        expectSamePlace(session.pdf.readingAnchor, inB, "Back to B")
        session.goBack()
        await settle()
        expectSamePlace(session.pdf.readingAnchor, inA, "Back to A")
        try await scroll(session, toPage: 1, y: 500)        // read on into "1.1"
        let jumpedFrom = session.pdf.readingAnchor
        #expect(session.jump(toPage: 9))                    // → "3.1": B and C are dropped
        await settle()
        #expect(!session.canGoForward)
        #expect(session.history.entries.count == 2)
        session.goBack()
        await settle()
        expectSamePlace(session.pdf.readingAnchor, jumpedFrom, "Back to where the new jump was made")

        // Press-and-hold list: straight to an entry.
        try await scroll(session, toPage: 2, y: 200)
        let leftAgain = session.pdf.readingAnchor
        let forward = try #require(session.history.forwardList.first)
        session.goToHistoryEntry(at: forward.index)
        await settle()
        #expect(session.currentPageIndex == 9)
        try await scroll(session, toPage: 9, y: 250)
        let inD = session.pdf.readingAnchor
        session.goToHistoryEntry(at: try #require(session.history.backList.first).index)
        await settle()
        expectSamePlace(session.pdf.readingAnchor, leftAgain, "Back list entry")

        // A restored window: the same trail, and Forward goes to the exact place left.
        let saved = session.restorableState
        await host.close()
        let restored = try await makeLinkedHost { $0.restoredState = saved }
        #expect(restored.session.history == session.history)
        restored.session.goForward()
        await settle()
        expectSamePlace(restored.session.pdf.readingAnchor, inD, "Forward in the restored window")
        await restored.close()
    }

    /// Sleeping readers: a reader that loads the book (woken, or another window's) opens at the
    /// exact place and zoom any reader on it last left, kept when the reader stops moving.
    @Test func aNewReaderOpensAtTheBooksLatestExactPositionAndZoom() async throws {
        let suite = "ReaderSessionTests.latest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let positions = ReaderPositionStore(defaults: defaults)
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("links.pdf"), pageCount: 12)
        func host() async -> PageInkTestSupport.Host {
            let fresh = (try? store.books.book(id: book.id)) ?? book
            let host = PageInkTestSupport.Host(book: fresh, store: store) {
                $0.installsFeatures = false
                $0.positionStore = positions
            }
            _ = await waitUntil { host.session.pdf.hasPositionedInitially }
            await settle()
            return host
        }

        let first = await host()
        first.session.zoomIn()
        await settle()
        try await scroll(first.session, toPage: 6, y: 420)
        let left = try #require(first.session.pdf.readingAnchor)
        let scale = first.session.pdf.scale
        // Saved once the reader has stood still, without leaving.
        #expect(await waitUntil { positions.position(for: book.id)?.anchor == left })
        #expect(try store.books.book(id: book.id)?.lastReadPageIndex == first.session.currentPageIndex)

        let second = await host()
        expectSamePlace(second.session.pdf.readingAnchor, left, "a new reader opens where the last one was left")
        #expect(abs(second.session.pdf.scale - scale) < 0.001, "and at its zoom")
        #expect(!second.session.isFitWidth)
        await second.close()
        await first.close()
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

    @Test func maximizingHidesThePanesWithoutChangingThemAndLeavesTheMode() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture) { $0.installsFeatures = false }
        session.isNotesVisible = true
        session.setMode(.markup)
        session.setMaximized(true)
        #expect(session.isMaximized && session.isMarkupMode, "markup carries on")
        #expect(!session.isContentsShown && !session.isNotesShown)
        #expect(session.isContentsVisible && session.isNotesVisible, "the panes' own state is kept")
        #expect(session.restorableState.isContentsVisible && session.restorableState.isNotesVisible)
        session.setMaximized(false)
        #expect(session.isContentsShown && session.isNotesShown && session.isMarkupMode)

        // The narrow Contents overlay is closed, not kept.
        session.isNarrowLayout = true
        session.isContentsOverlayVisible = true
        session.setMaximized(true)
        #expect(!session.isContentsOverlayVisible)
        session.setMaximized(false)
        #expect(!session.isContentsShown)
    }

    @Test func askingForAPaneOrSearchEndsAMaximizedPage() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture) { $0.installsFeatures = false }
        session.isContentsVisible = false

        session.setMaximized(true)
        session.toggleNotes()
        #expect(!session.isMaximized && session.isNotesShown, "Show Notes shows them")

        session.setMaximized(true)
        session.toggleNotes()
        #expect(!session.isMaximized && session.isNotesShown, "hidden by maximize is not shown: it stays on")

        session.setMaximized(true)
        session.toggleContents()
        #expect(!session.isMaximized && session.isContentsShown)

        session.setMaximized(true)
        session.showNotes(.section)
        #expect(!session.isMaximized && session.notesTab == .section)

        session.setMaximized(true)
        session.showSearch()
        #expect(!session.isMaximized && session.isSearchVisible)

        session.isSearchVisible = false
        session.setMaximized(true)
        session.requestAddHeading()
        #expect(!session.isMaximized && session.isContentsShown)
    }

    @Test func aReaderCanStartMaximized() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture) {
            $0.installsFeatures = false
            $0.startMaximized = true
        }
        #expect(session.isMaximized)
    }

    @Test func addHeadingRequestCarriesPageAndTitleAndShowsContents() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture) { $0.installsFeatures = false }
        session.pdfReportedCurrentPage(4)
        session.isContentsVisible = false
        session.requestAddHeading()
        #expect(session.pendingAddHeadingRequest?.pageIndex == 4)
        #expect(session.pendingAddHeadingRequest?.suggestedTitle == nil)
        #expect(session.isContentsVisible)
        session.isNarrowLayout = true
        session.requestAddHeading(atPage: 7, suggestedTitle: "  Eigenvalues \n")
        #expect(session.isContentsOverlayVisible)
        let request = session.takeAddHeadingRequest()
        #expect(request?.pageIndex == 7 && request?.suggestedTitle == "Eigenvalues")
        #expect(session.pendingAddHeadingRequest == nil)
        session.requestAddHeading(atPage: 999)  // out of range: the current page
        #expect(session.pendingAddHeadingRequest?.pageIndex == 4)
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

    /// The markup responder's undo manager (`MarkupRoutingUndoManager`, what the tool picker's
    /// Undo/Redo buttons and ⌘Z use) follows the surface last drawn on, acts on it, and tells a
    /// listener of its own notifications the state it will find (canUndo true after a stroke,
    /// false once everything is undone), with itself as the object.
    @Test func routingUndoManagerActsOnTheRoutedSurfaceAndNotifiesAsItself() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture) { $0.installsFeatures = false }
        let markup: ReaderMarkupController = session.markup
        let proxy = try #require(markup.responderView.undoManager)
        #expect(proxy === markup.routingUndoManager)
        let page = CountingSurface(id: "page-1")
        let note = CountingSurface(id: "note-1")
        markup.register(page)
        markup.register(note)
        session.setMode(.markup)

        // A listener of the proxy (object: the proxy), as the tool picker is: what it reads in
        // each notification, read as the notification is posted.
        var heard: [(name: Notification.Name, undo: Bool, redo: Bool)] = []
        let names: [Notification.Name] = [.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                                          .NSUndoManagerDidRedoChange]
        let tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: proxy, queue: nil) { notification in
                let posted = notification.name
                MainActor.assumeIsolated { heard.append((posted, proxy.canUndo, proxy.canRedo)) }
            }
        }
        defer { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
        #expect(!proxy.canUndo && !proxy.canRedo)

        // Two strokes on the page.
        page.stroke(markup)
        page.stroke(markup)
        #expect(proxy.canUndo && !proxy.canRedo)
        #expect(await waitUntil { heard.last?.undo == true }, "a listener hears canUndo after a stroke")

        // Undo through the proxy acts on the page.
        let before = heard.count
        proxy.undo()
        #expect(page.value == 1 && proxy.canUndo && proxy.canRedo)
        #expect(heard.dropFirst(before).contains { $0.name == .NSUndoManagerDidUndoChange })
        proxy.undo()
        #expect(page.value == 0 && !proxy.canUndo && proxy.canRedo)
        #expect(await waitUntil { heard.last.map { !$0.undo && $0.redo } == true },
                "a listener hears canUndo false once everything is undone")

        // Redo through the proxy.
        proxy.redo()
        #expect(page.value == 1 && proxy.canUndo && proxy.canRedo)
        #expect(heard.contains { $0.name == .NSUndoManagerDidRedoChange })
        proxy.redo()
        #expect(page.value == 2 && !proxy.canRedo)

        // A stroke on the note routes the proxy to the note at once, and the listener is told.
        note.stroke(markup)
        #expect(await waitUntil { heard.last.map { $0.undo && !$0.redo } == true })
        proxy.undo()
        #expect(note.value == 0 && page.value == 2)
        #expect(await waitUntil { heard.last.map { !$0.undo && $0.redo } == true })

        // The note leaves: the proxy falls back to the page (canUndo, nothing to redo).
        markup.unregister(note)
        #expect(proxy.canUndo && !proxy.canRedo)
        #expect(await waitUntil { heard.last.map { $0.undo && !$0.redo } == true })
    }
}

/// A surface whose strokes add one to `value`, with symmetric undo and redo (as PencilKit's).
@MainActor
private final class CountingSurface: MarkupSurface {
    let markupSurfaceID: String
    let canvasView = PKCanvasView()
    let undo = UndoManager()
    private(set) var value = 0

    init(id: String) {
        markupSurfaceID = id
        undo.groupsByEvent = false
    }

    var markupUndoManager: UndoManager? { undo }
    func markupModeDidChange(_ isMarkup: Bool) {}
    func flushPendingMarkup() async {}

    /// A stroke as a canvas reports it: begin, the undo step registered, end.
    func stroke(_ markup: ReaderMarkupController) {
        markup.surfaceDidBeginStroke(self)
        undo.beginUndoGrouping()
        set(value + 1)
        undo.endUndoGrouping()
        markup.surfaceDidEndStroke(self)
    }

    private func set(_ newValue: Int) {
        let old = value
        value = newValue
        undo.registerUndo(withTarget: self) { target in target.set(old) }
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
