import Foundation
import PencilKit
import ReaderBackup
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// No stale write lands after a restore (B3, item 5): a restore replaces a book under the same
/// ID, its open reader session and note editor see `.bookDeleted`, and any later save from them
/// (`suspend()`, `flush()`, a debounce, a page leaving the screen, a delete, an anchor repair)
/// changes nothing on disk or in the store. Also the flush that runs before the commit, and the
/// write gate that keeps an in-flight ink save from straddling the commit.
@MainActor
struct BackupStaleWriteTests {
    typealias Support = BackupTestSupport

    private let geometry = PageInkGeometry(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)

    struct Fixture {
        let store: LibraryStore
        let book: Book
        let backup: URL
        let note: Note
        let pageInk: Data
        let scratch: URL
    }

    /// A book (small.pdf) with a page note and page ink on page 2, backed up to a file.
    private func makeFixture() async throws -> Fixture {
        let scratch = try Support.scratch("BackupStale")
        let store = try LibraryStore.ephemeral()
        let book = try #require(try await ImportService(store: store).importPDF(at: Support.small).book)
        let note = Note(bookID: book.id, target: .page(3), text: "original text", createdAt: Date(timeIntervalSinceReferenceDate: 790_000_000))
        try store.notes.save(note)
        let ink = PKDrawing(strokes: [PageInkTestSupport.stroke(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 300, y: 60))])
            .dataRepresentation()
        try await store.savePageInk(ink, bookID: book.id, pageIndex: 2, origin: nil)
        let backup = try await Support.makeService(store, scratch: scratch).backUpToFile(includePDFs: false).url
        return Fixture(store: store, book: book, backup: backup, note: note, pageInk: ink, scratch: scratch)
    }

    private func cleanUp(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.scratch)
        try? FileManager.default.removeItem(at: fixture.store.rootDirectory)
    }

    private func makeSession(_ fixture: Fixture) -> ReaderSession {
        var configuration = ReaderSession.Configuration()
        configuration.installsFeatures = false
        configuration.lastReadSaveDelay = .seconds(60)
        return ReaderSession(book: fixture.book, store: fixture.store, configuration: configuration)
    }

    private func makeSurface(_ session: ReaderSession, page: Int = 2) async -> PageInkSurface {
        let context = PageInkContext(store: session.store, bookID: session.book.id, origin: session.origin,
                                     saveToken: session.saveToken)
        let surface = PageInkSurface(pageIndex: page, geometry: geometry, overlay: nil, context: context,
                                     markup: session.markup, saveDelay: .seconds(60))
        surface.startLoading()
        surface.register()
        #expect(await Support.waitUntil { surface.loadState == .ready })
        return surface
    }

    private func draw(on surface: PageInkSurface, y: CGFloat) {
        var drawing = surface.canvas.drawing
        drawing.strokes.append(PageInkTestSupport.stroke(from: CGPoint(x: 50, y: y), to: CGPoint(x: 400, y: y + 5)))
        surface.canvas.drawing = drawing
        surface.canvasViewDrawingDidChange(surface.canvas)
    }

    /// Restores the fixture's book over itself (same ID). `flushEditors` overrides the
    /// pre-commit flush (nil: the real one, every live editor on the store).
    private func restore(_ fixture: Fixture, flushEditors: (@MainActor () async -> Void)? = nil) async throws {
        let service = BackupService(store: fixture.store, temporaryRoot: fixture.scratch.appendingPathComponent("tmp"),
                                    defaults: UserDefaults(suiteName: UUID().uuidString)!, flushEditors: flushEditors)
        let session = try await service.openBackup(at: fixture.backup)
        defer { session.close() }
        let summary = try await service.restore([fixture.book.id], from: session, restorePDFs: true)
        #expect(summary.restored.map(\.id) == [fixture.book.id])
    }

    // MARK: Late saves after the restore

    @Test func lateSavesFromTheClosedEditorsChangeNothing() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let store = fixture.store
        let session = makeSession(fixture)
        let surface = await makeSurface(session)
        let model = NotePageModel(session: session, target: .page(3), autosaveDelay: .seconds(60))
        await model.load()
        #expect(model.text == "original text")

        // Unsaved work on screen: page ink, note text and note ink, a new reading position.
        draw(on: surface, y: 200)
        #expect(surface.isDirty)
        model.userDidEditText("typed on screen, not saved")
        NotePageTestSupport.draw(NotePageTestSupport.stroke(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 200, y: 32)), on: model)
        #expect(model.hasUnsavedChanges)
        session.pdfReportedCurrentPage(9)

        // Restore without the pre-commit flush, to prove the guards alone stop the late writes.
        try await restore(fixture, flushEditors: {})
        #expect(session.closeReason == .bookDeleted)
        #expect(session.saveToken.isRevoked && model.saveToken.isRevoked)
        let restored = try #require(try Support.archive(store, fixture.book.id))
        let restoredFiles = Support.files(in: store.bookDirectoryURL(bookID: fixture.book.id))

        // Every way the closing windows would save.
        await session.suspend()
        await model.flush()
        await surface.flushPendingMarkup()
        surface.finish()
        try await model.deleteNote()
        model.userDidEditText("still typing after the restore")
        await model.flush()
        await PageInkQueue.shared.drain(bookID: fixture.book.id)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(try Support.archive(store, fixture.book.id) == restored)
        #expect(Support.files(in: store.bookDirectoryURL(bookID: fixture.book.id)) == restoredFiles)
        #expect(try store.notes.note(id: fixture.note.id)?.text == "original text")
        #expect(try await store.noteInk(bookID: fixture.book.id, noteID: fixture.note.id) == nil)
        #expect(try await store.pageInk(bookID: fixture.book.id, pageIndex: 2) == fixture.pageInk)
        #expect(try store.books.book(id: fixture.book.id)?.lastReadPageIndex == fixture.book.lastReadPageIndex)
    }

    @Test func aNoteModelMadeAfterTheSessionClosedSavesNothing() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        try await restore(fixture, flushEditors: {})
        #expect(session.saveToken.isRevoked)
        // The closing window's notes panel switches to another page's note after the restore.
        let late = NotePageModel(session: session, target: .page(5), autosaveDelay: .milliseconds(20))
        await late.load()
        late.userDidEditText("a note on page 6 from a dead window")
        try? await Task.sleep(for: .milliseconds(150))
        await late.flush()
        #expect(try fixture.store.notes.note(bookID: fixture.book.id, target: .page(5)) == nil)
    }

    @Test func aClosedSessionNeverRepairsHeadingAnchors() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let session = makeSession(fixture)
        try await restore(fixture, flushEditors: {})
        session.open()
        #expect(await Support.waitUntil { session.isOutlineLoaded })
        let controller = session.notesPanel
        controller.refresh(explicit: true)
        #expect(!controller.didRepairAnchors)

        // A window opened on the restored book does run it.
        let fresh = makeSession(fixture)
        fresh.open()
        #expect(await Support.waitUntil { fresh.isOutlineLoaded })
        let freshController = fresh.notesPanel
        freshController.refresh(explicit: true)
        #expect(freshController.didRepairAnchors)
    }

    // MARK: The flush before the commit

    @Test func pendingEditsAreSavedBeforeTheCommitThenReplaced() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let store = fixture.store
        let session = makeSession(fixture)
        let surface = await makeSurface(session)
        let model = NotePageModel(session: session, target: .page(3), autosaveDelay: .seconds(60))
        await model.load()
        draw(on: surface, y: 300)
        model.userDidEditText("saved by the flush, then replaced")
        let log = TestLog()
        let origin = session.origin
        let token = store.hub.observe { event in
            switch event.change {
            case .noteSaved where event.isFrom(origin): log.append("note")
            case .pageInkChanged where event.isFrom(origin): log.append("ink")
            case .bookDeleted: log.append("deleted")
            default: break
            }
        }

        try await restore(fixture)  // the real flush: every live editor on this store
        token.cancel()
        let order = log.entries
        #expect(order.contains("note") && order.contains("ink"))
        #expect(order.last == "deleted")
        #expect((order.firstIndex(of: "deleted") ?? -1) > (order.firstIndex(of: "note") ?? Int.max))
        #expect(try store.notes.note(id: fixture.note.id)?.text == "original text")
        #expect(try await store.pageInk(bookID: fixture.book.id, pageIndex: 2) == fixture.pageInk)
        await session.suspend()
        await model.flush()
        #expect(try store.notes.note(id: fixture.note.id)?.text == "original text")
        #expect(try await store.pageInk(bookID: fixture.book.id, pageIndex: 2) == fixture.pageInk)
        #expect(OpenEditorRegistry.shared.sessions(of: store).contains { $0 === session })
        #expect(OpenEditorRegistry.shared.noteModels(of: store).contains { $0 === model })
    }

    // MARK: The gate

    @Test func theGateHoldsSavesAroundACommit() async throws {
        let gate = BookWriteGate()
        let bookID = UUID()
        let token = BookSaveToken(bookID: bookID)
        let inFlight = TestLatch()
        let log = TestLog()

        // A save already past the gate when the pause begins: the pause waits for it.
        let first = Task { @MainActor in
            await gate.performSave(bookID: bookID, token: token) {
                log.append("first started")
                await inFlight.wait()
                log.append("first finished")
            }
        }
        #expect(await Support.waitUntil { inFlight.arrivals == 1 })
        let pausing = Task { @MainActor () -> BookWriteGate.Pause in
            let pause = await gate.pause([bookID])
            log.append("paused")
            return pause
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!log.contains("paused"))
        #expect(gate.isPaused(bookID))
        inFlight.open()
        let pause = await pausing.value
        _ = await first.value
        #expect(log.entries == ["first started", "first finished", "paused"])
        #expect(gate.inFlightCount(bookID) == 0)

        // A save arriving during the pause waits, then sees the revoked token and does nothing.
        let second = Task { @MainActor in
            await gate.performSave(bookID: bookID, token: token) { log.append("second ran") }
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!log.contains("second ran"))
        token.revoke()  // the commit posted `.bookDeleted`
        gate.resume(pause)
        #expect(await second.value == nil)
        #expect(!log.contains("second ran"))

        // Other books are never held, and after the pause saves run again.
        let other = await gate.performSave(bookID: UUID(), token: nil) { 42 }
        #expect(other == 42)
        #expect(!gate.isPaused(bookID))
        let fresh = await gate.performSave(bookID: bookID, token: BookSaveToken(bookID: bookID)) { "ran" }
        #expect(fresh == "ran")
    }
}
