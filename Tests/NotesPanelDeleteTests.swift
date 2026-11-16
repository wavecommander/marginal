import Foundation
import ReaderCore
import ReaderStore
import Testing
@testable import TactileTexts

/// Deleting a note from the notes panel (design: "Deleting a note"): `NotePageModel.deleteNote()`
/// and `NotesPanelController.delete(_:)` (the header's Delete Note).
@MainActor
struct NotesPanelDeleteTests {
    typealias Support = NotePageTestSupport

    private func makeModel(_ store: LibraryStore, _ book: Book, target: NoteTarget = .page(3),
                           origin: ChangeOrigin = ChangeOrigin(label: "panel")) -> NotePageModel {
        NotePageModel(store: store, bookID: book.id, target: target, origin: origin, autosaveDelay: .milliseconds(60))
    }

    @Test func aPendingAutosaveCannotRecreateADeletedNote() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = makeModel(store, book)
        await model.load()
        model.userDidEditText("First")
        await model.flush()
        #expect(try store.notes.note(bookID: book.id, target: .page(3))?.text == "First")

        model.userDidEditText("First, and more")  // autosave pending
        try await model.deleteNote()
        try? await Task.sleep(for: .milliseconds(250))  // well past the autosave delay
        #expect(try store.notes.note(bookID: book.id, target: .page(3)) == nil, "the note stays deleted")
        #expect(model.text == "")
        #expect(model.saveState == .empty)
        #expect(!model.isStored)
        await model.flush()
        #expect(try store.notes.note(bookID: book.id, target: .page(3)) == nil)

        // The placeholder takes a new note.
        model.userDidEditText("A new note")
        await model.flush()
        #expect(try store.notes.note(bookID: book.id, target: .page(3))?.text == "A new note")
    }

    @Test func deletingAnInkedNoteRemovesItsInk() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = makeModel(store, book)
        await model.load()
        model.userDidEditText("Marked")
        let layout = NotePageLayoutEngine.shared.bandLayout(for: "Marked")
        Support.draw(Support.stroke(over: layout.paragraphs[0]), on: model)
        await model.flush()
        let noteID = try #require(try store.notes.note(bookID: book.id, target: .page(3))?.id)
        #expect(try await store.noteInk(bookID: book.id, noteID: noteID) != nil)

        var removed = false
        let token = store.hub.observe { event in
            if case .noteRemoved(_, .page(3), noteID) = event.change { removed = true }
        }
        try await model.deleteNote()
        #expect(removed, "other windows hear about it")
        #expect(try store.notes.note(id: noteID) == nil)
        #expect(try await store.noteInk(bookID: book.id, noteID: noteID) == nil)
        #expect(!model.hasInk)
        #expect(model.undoManager.canUndo == false)
        _ = token
    }

    @Test func deletingANoteNeverSavedClearsIt() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = makeModel(store, book)
        await model.load()
        model.userDidEditText("Unsaved")
        Support.draw(Support.stroke(from: CGPoint(x: 20, y: 200), to: CGPoint(x: 200, y: 210)), on: model)
        var events = 0
        let token = store.hub.observe { _ in events += 1 }
        try await model.deleteNote()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.text == "" && !model.hasInk)
        #expect(try store.notes.note(bookID: book.id, target: .page(3)) == nil)
        #expect(events == 0, "nothing was stored, nothing to announce")
        _ = token
    }

    @Test func otherWindowsModelsDropTheDeletedNote() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let here = makeModel(store, book, origin: ChangeOrigin(label: "window 1"))
        let there = makeModel(store, book, origin: ChangeOrigin(label: "window 2"))
        await here.load()
        here.userDidEditText("Shared")
        await here.flush()
        await there.load()
        #expect(there.text == "Shared")
        try await here.deleteNote()
        #expect(await Support.waitUntil { there.text == "" && there.saveState == .empty })
    }

    @Test func controllerDeletesTheShownNoteThroughItsModel() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        var configuration = ReaderSession.Configuration()
        configuration.installsFeatures = false
        let session = ReaderSession(book: book, store: store, configuration: configuration)
        let controller = NotesPanelController(session: session) { [weak session] target in
            NotePageModel(session: session!, target: target, autosaveDelay: .milliseconds(60))
        }
        // The open page note with unsaved edits: deleted through its model, nothing re-created.
        let open = try #require(controller.model)
        await open.load()
        open.userDidEditText("Typing")
        #expect(await controller.delete(open))
        try? await Task.sleep(for: .milliseconds(250))
        #expect(try store.notes.note(bookID: book.id, target: open.target) == nil)
        #expect(open.text == "")
        #expect(NotesPanelController.isEmpty(open))
    }
}
