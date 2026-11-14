import Foundation
import ReaderCore
import ReaderStore
import Testing
@testable import Marginal

/// The notes panel controller on a real session over `small.pdf` (12 pages; "1 Linear Systems"
/// p1 with 1.1 p2 and 1.2 p4; "2 Vector Spaces" p5 with 2.1 p6 and 2.2 p8; "3 Eigenvalues" p9
/// with 3.1 p10 and 3.2 p12; indices are one less): following the page, deferral while typing,
/// saving on switch, the level choice, the model cap, and the anchor repair (WP8).
@MainActor
struct NotesPanelControllerTests {
    struct Fixture {
        let store: LibraryStore
        let book: Book
    }

    private func makeFixture() throws -> Fixture {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/out/small.pdf")
        let store = try LibraryStore.ephemeral()
        let book = Book(title: "Small", fingerprint: "panel-\(UUID().uuidString)", fileName: "small.pdf",
                        pageCount: 12, fileSize: 1)
        try store.books.save(book)
        let url = store.documentURL(for: book)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: url)
        return Fixture(store: store, book: book)
    }

    private func makeSession(_ fixture: Fixture, tab: ReaderSession.NotesTab = .page) async -> ReaderSession {
        var configuration = ReaderSession.Configuration()
        configuration.installsFeatures = false
        configuration.notebookRebuildDelay = .milliseconds(10)
        configuration.openNotesTab = tab
        let session = ReaderSession(book: fixture.book, store: fixture.store, configuration: configuration)
        session.open()
        _ = await waitUntil { session.isOutlineLoaded }
        return session
    }

    private func makeController(_ session: ReaderSession) -> NotesPanelController {
        NotesPanelController(session: session) { [weak session] target in
            NotePageModel(session: session!, target: target, autosaveDelay: .milliseconds(40))
        }
    }

    private func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
        await NotePageTestSupport.waitUntil(timeout: timeout, condition)
    }

    private func heading(_ title: String, _ session: ReaderSession) throws -> OutlineNode {
        try #require(session.outline.nodes.first { $0.title == title })
    }

    // MARK: Page tab

    @Test func pageTabFollowsTheCurrentPageAndSavesOnSwitch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.store.rootDirectory) }
        let session = await makeSession(fixture)
        let controller = makeController(session)
        #expect(controller.model?.target == .page(0))
        let first = try #require(controller.model)
        await first.load()
        first.userDidEditText("Written on page 1")

        session.pdfReportedCurrentPage(6)
        #expect(await waitUntil { controller.model?.target == .page(6) })
        // The old note was flushed on the switch (no waiting for the debounce).
        #expect(await waitUntil { (try? fixture.store.notes.note(bookID: fixture.book.id, target: .page(0)))??.text == "Written on page 1" })
        // An untouched page is a placeholder, not a stored record.
        let second = try #require(controller.model)
        await second.load()
        #expect(second.saveState == .empty)
        #expect(try fixture.store.notes.note(bookID: fixture.book.id, target: .page(6)) == nil)
    }

    @Test func followingWaitsWhileTypingAndSwitchesWhenTypingEnds() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.store.rootDirectory) }
        let session = await makeSession(fixture)
        let controller = makeController(session)
        let typing = try #require(controller.model)
        await typing.load()
        typing.setEditingText(true)
        typing.userDidEditText("Mid-sentence")

        // The keyboard scrolled the PDF (or the reader jumped 1,000 pages): the note stays.
        session.pdfReportedCurrentPage(9)
        #expect(await waitUntil { controller.isSwitchDeferred })
        #expect(controller.model === typing)

        typing.setEditingText(false)
        #expect(await waitUntil { controller.model?.target == .page(9) })
        #expect(!controller.isSwitchDeferred)
        #expect(await waitUntil { (try? fixture.store.notes.note(bookID: fixture.book.id, target: .page(0)))??.text == "Mid-sentence" })
    }

    @Test func switchingTabsMidEditSwitchesAtOnceAndSaves() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.store.rootDirectory) }
        let session = await makeSession(fixture)
        session.pdfReportedCurrentPage(2)  // in 1.1 Foundations
        let controller = makeController(session)
        let page = try #require(controller.model)
        await page.load()
        page.setEditingText(true)
        page.userDidEditText("Page three")

        controller.selectTab(.section)
        #expect(controller.model?.target == .heading(try heading("1.1 Foundations", session).anchor))
        // The page model is no longer shown; nothing showed it in an editor, so flush it as the
        // editor would (the controller keeps it cached for going back).
        await page.flush()
        #expect(try fixture.store.notes.note(bookID: fixture.book.id, target: .page(2))?.text == "Page three")

        // Back to the page tab: the same model (undo stack and all).
        controller.selectTab(.page)
        #expect(controller.model === page)
    }

    // MARK: Section tab and the level picker

    @Test func levelChoiceStaysWithinTheHeadingAndFollowsAfterLeaving() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.store.rootDirectory) }
        let session = await makeSession(fixture, tab: .section)
        session.pdfReportedCurrentPage(2)
        let controller = makeController(session)
        let chapter = try heading("1 Linear Systems", session)
        #expect(controller.shownHeading?.title == "1.1 Foundations")

        controller.chooseLevel(chapter)
        #expect(controller.model?.target == .heading(chapter.anchor))
        for page in [1, 3, 0] {
            session.pdfReportedCurrentPage(page)
            try? await Task.sleep(for: .milliseconds(60))
            #expect(controller.shownHeading?.title == "1 Linear Systems", "page index \(page)")
        }
        session.pdfReportedCurrentPage(5)  // 2.1 Foundations: left chapter 1
        #expect(await waitUntil { controller.shownHeading?.title == "2.1 Foundations" })
        session.pdfReportedCurrentPage(2)  // back in chapter 1: following, not the old choice
        #expect(await waitUntil { controller.shownHeading?.title == "1.1 Foundations" })
    }

    @Test func thisPageIsInOpensTheSectionTabOnThatHeading() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.store.rootDirectory) }
        let session = await makeSession(fixture)
        session.pdfReportedCurrentPage(6)
        let controller = makeController(session)
        controller.openSectionNote(for: try heading("2 Vector Spaces", session))
        #expect(session.notesTab == .section)
        #expect(controller.shownHeading?.title == "2 Vector Spaces")

        // By anchor (search / Notebook requests): same as choosing the level.
        session.notesTab = .page
        #expect(controller.openSectionNote(forHeading: try heading("3 Eigenvalues", session).anchor))
        #expect(session.notesTab == .section)
        #expect(controller.shownHeading?.title == "3 Eigenvalues")
        #expect(controller.selection.pinnedAnchor == (try heading("3 Eigenvalues", session).anchor))
        #expect(!controller.openSectionNote(forHeading: HeadingAnchor(pdfPath: [42], pageIndex: nil, title: "Nowhere")))
        #expect(controller.shownHeading?.title == "3 Eigenvalues")
    }

    @Test func atMostAFewModelsStayAlive() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.store.rootDirectory) }
        let session = await makeSession(fixture)
        let controller = makeController(session)
        for page in 0..<12 {
            session.pdfReportedCurrentPage(page)
            #expect(await waitUntil { controller.model?.target == .page(page) })
            #expect(controller.liveTargets.count <= NotesPanelController.modelCapacity)
        }
        controller.selectTab(.section)
        #expect(controller.liveTargets.count <= NotesPanelController.modelCapacity)
        #expect(controller.liveTargets.contains(try #require(controller.model?.target)))
    }

    @Test func pageBeforeAnyHeadingOrNoOutlineHasNoSectionNote() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.store.rootDirectory) }
        var configuration = ReaderSession.Configuration()
        configuration.installsFeatures = false
        configuration.openNotesTab = .section
        // Not opened: no outline yet.
        let session = ReaderSession(book: fixture.book, store: fixture.store, configuration: configuration)
        let controller = makeController(session)
        #expect(controller.model == nil)
        #expect(!controller.didRepairAnchors, "the repair waits for the outline")
    }

    // MARK: Heading anchors

    @Test func staleHeadingNotesAreRepairedOncePerLoadBeforeTheyAreOpened() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.store.rootDirectory) }
        // "2 Vector Spaces" is the second top-level item, on page index 4; this anchor was
        // recorded with another path (an item since removed before it).
        let stale = HeadingAnchor(pdfPath: [7], pageIndex: 4, title: "2 Vector Spaces")
        let note = Note(bookID: fixture.book.id, target: .heading(stale), text: "chapter two")
        try fixture.store.notes.save(note)

        let session = await makeSession(fixture, tab: .section)
        session.pdfReportedCurrentPage(4)
        let controller = makeController(session)
        let chapter = try heading("2 Vector Spaces", session)
        #expect(controller.didRepairAnchors)
        #expect(controller.repairedAnchorCount == 1)
        #expect(try fixture.store.notes.note(id: note.id)?.target == .heading(chapter.anchor))
        // The section note opened on the repaired note, not on an empty placeholder.
        let model = try #require(controller.model)
        await model.load()
        #expect(model.text == "chapter two")

        // A second window on the book finds nothing left to repair.
        let other = await makeSession(fixture, tab: .section)
        let otherController = makeController(other)
        #expect(otherController.didRepairAnchors)
        #expect(otherController.repairedAnchorCount == 0)
    }

    // MARK: Other windows

    @Test func inkChangesFromAnyWindowBumpTheRenderingRevision() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.store.rootDirectory) }
        let session = await makeSession(fixture)
        let controller = makeController(session)
        let noteID = UUID()
        try await fixture.store.saveNoteInk(Data([1]), bookID: fixture.book.id, noteID: noteID, origin: ChangeOrigin())
        #expect(controller.inkRevisions[noteID] == 1)
        try await fixture.store.saveNoteInk(Data([2]), bookID: fixture.book.id, noteID: noteID, origin: session.origin)
        #expect(controller.inkRevisions[noteID] == 2)
    }
}
