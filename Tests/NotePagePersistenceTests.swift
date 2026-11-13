import Foundation
import PencilKit
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// Saving, loading, relocation on load, emptying, undo, and two windows on one note (WP13).
@MainActor
struct NotePagePersistenceTests {
    typealias Support = NotePageTestSupport

    private func makeModel(_ store: LibraryStore, _ book: Book, target: NoteTarget = .page(3),
                           origin: ChangeOrigin = ChangeOrigin(label: "test")) -> NotePageModel {
        NotePageModel(store: store, bookID: book.id, target: target, origin: origin, autosaveDelay: .milliseconds(40))
    }

    // MARK: Archive

    @Test func archiveRoundTripsInkAndLayoutLosslessly() throws {
        let engine = NotePageLayoutEngine()
        let layout = engine.bandLayout(for: "One\nTwo\nThree")
        var ink = NoteInk(layout: layout)
        var baseline = CanvasBaseline()
        let strokes = [Support.stroke(over: layout.paragraphs[0]),
                       Support.stroke(over: layout.paragraphs[2], x: 50...250),
                       Support.stroke(from: CGPoint(x: 30, y: layout.trailingTop + 60), to: CGPoint(x: 280, y: layout.trailingTop + 140),
                                      ink: .marker, width: 12)]
        _ = ink.applyCanvasDrawing(PKDrawing(strokes: strokes), baseline: &baseline)

        let data = try NoteInkArchive.encode(ink)
        let decoded = try NoteInkArchive.decode(data, fallbackLayout: engine.bandLayout(for: ""))
        #expect(decoded.layout == ink.layout)
        #expect(decoded.strokes.map(\.band) == ink.strokes.map(\.band))
        #expect(decoded.strokes.map { StrokeFingerprint($0.local) } == ink.strokes.map { StrokeFingerprint($0.local) })
        #expect(decoded.isEquivalent(to: ink))
        #expect(decoded.composedDrawing() == ink.composedDrawing() || decoded.composedDrawing().strokes.count == 3)
        // Re-encoding what was decoded gives the same ink again.
        let again = try NoteInkArchive.decode(try NoteInkArchive.encode(decoded), fallbackLayout: layout)
        #expect(again.isEquivalent(to: ink))
        // The payload carries PencilKit vector data.
        #expect(try PropertyListSerialization.propertyList(from: data, format: nil) is [String: Any])
    }

    @Test func plainPencilKitDataIsAcceptedByGeometry() throws {
        let layout = NotePageLayoutEngine().bandLayout(for: "One\nTwo")
        let drawing = PKDrawing(strokes: [Support.stroke(over: layout.paragraphs[1])])
        let ink = try NoteInkArchive.decode(drawing.dataRepresentation(), fallbackLayout: layout)
        #expect(ink.strokes.map(\.band) == [.paragraph(1)])
        #expect(ink.composedDrawing().strokes[0].renderBounds.minY == drawing.strokes[0].renderBounds.minY)
        #expect(throws: NoteInkArchive.DecodingFailure.self) {
            _ = try NoteInkArchive.decode(Data("nonsense".utf8), fallbackLayout: layout)
        }
    }

    // MARK: Store round trip

    @Test func textAndInkPersistThroughTheStore() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = makeModel(store, book)
        await model.load()
        #expect(model.saveState == .empty)
        model.userDidEditText("First paragraph\nSecond has a word")
        let layout = model.ink.layout
        Support.draw(Support.stroke(over: layout.paragraphs[1]), on: model)
        #expect(model.saveState == .edited)
        await model.flush()
        #expect(model.saveState == .saved)

        let stored = try #require(try store.notes.note(bookID: book.id, target: .page(3)))
        #expect(stored.text == "First paragraph\nSecond has a word")
        #expect(stored.hasInk)
        #expect(stored.bandLayout == model.ink.layout)
        let data = try #require(try await store.noteInk(bookID: book.id, noteID: stored.id))
        let decoded = try NoteInkArchive.decode(data, fallbackLayout: layout)
        #expect(decoded.layout == stored.bandLayout)
        #expect(decoded.isEquivalent(to: model.ink))

        let reopened = makeModel(store, book)
        await reopened.load()
        #expect(reopened.text == model.text)
        #expect(reopened.strokeCount == 1)
        #expect(reopened.noteID == stored.id)
        #expect(Support.pageStrokes(reopened).map(\.renderBounds) == Support.pageStrokes(model).map(\.renderBounds))
    }

    @Test func autosaveIsDebounced() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = makeModel(store, book)
        await model.load()
        model.userDidEditText("Hello")
        #expect(try store.notes.note(bookID: book.id, target: .page(3)) == nil)
        #expect(await Support.waitUntil { model.saveState == .saved })
        #expect(try store.notes.note(bookID: book.id, target: .page(3))?.text == "Hello")
    }

    @Test func relocatesOnLoadWhenTheComputedLayoutDiffers() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let text = "Alpha\nBeta line with ink\nGamma"
        let current = NotePageLayoutEngine.shared.bandLayout(for: text)
        // A layout saved on a system with other font metrics: same paragraphs, different tops.
        var saved = current
        for index in saved.paragraphs.indices {
            saved.paragraphs[index].top = 10 + CGFloat(index) * 30
            saved.paragraphs[index].height = 30
        }
        saved.trailingTop = 100
        let local = Support.stroke(from: CGPoint(x: 20, y: 12), to: CGPoint(x: 120, y: 12))  // band-local
        let ink = NoteInk(layout: saved, strokes: [NoteInkStroke(band: .paragraph(1), local: local)])
        let note = Note(bookID: book.id, target: .page(3), text: text, hasInk: true, bandLayout: saved)
        try store.notes.save(note)
        try await store.saveNoteInk(try NoteInkArchive.encode(ink), bookID: book.id, noteID: note.id, origin: nil)

        let model = makeModel(store, book)
        await model.load()
        let bounds = try #require(Support.pageStrokes(model).first).renderBounds
        let expected = local.renderBounds.offsetBy(dx: 0, dy: current.paragraphs[1].top)
        #expect(abs(bounds.minY - expected.minY) < 0.001)
        #expect(model.ink.layout == current)

        // The read-only renderer relocates the same way.
        let snapshot = NotePageRenderer.snapshot(note: note, inkData: try await store.noteInk(bookID: book.id, noteID: note.id))
        #expect(abs(snapshot.drawing.strokes[0].renderBounds.minY - expected.minY) < 0.001)
    }

    @Test func emptiedNoteIsDeletedAndInkOnlyNoteIsKept() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = makeModel(store, book)
        await model.load()
        model.userDidEditText("Something")
        Support.draw(Support.stroke(from: CGPoint(x: 20, y: 200), to: CGPoint(x: 200, y: 220)), on: model)
        await model.flush()
        let id = try #require(model.noteID)

        // Text emptied, ink kept: the note stays.
        model.userDidEditText("")
        await model.flush()
        let inkOnly = try #require(try store.notes.note(bookID: book.id, target: .page(3)))
        #expect(inkOnly.text == "" && inkOnly.hasInk)
        #expect(try await store.noteInk(bookID: book.id, noteID: id) != nil)

        // Ink erased too: record and ink file are gone.
        model.applyUserDrawing(PKDrawing())
        await model.flush()
        #expect(try store.notes.note(bookID: book.id, target: .page(3)) == nil)
        #expect(try await store.noteInk(bookID: book.id, noteID: id) == nil)
        #expect(model.saveState == .empty)
        #expect(!model.isStored)

        // Whitespace only is empty as well.
        model.userDidEditText("  \n ")
        await model.flush()
        #expect(try store.notes.note(bookID: book.id, target: .page(3)) == nil)
    }

    @Test func textOnlyNoteRemovesTheInkFileWhenTheLastStrokeGoes() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = makeModel(store, book)
        await model.load()
        model.userDidEditText("Keep me")
        Support.draw(Support.stroke(over: model.ink.layout.paragraphs[0]), on: model)
        await model.flush()
        let id = try #require(model.noteID)
        model.applyUserDrawing(PKDrawing())
        await model.flush()
        let stored = try #require(try store.notes.note(bookID: book.id, target: .page(3)))
        #expect(!stored.hasInk && stored.bandLayout == nil)
        #expect(try await store.noteInk(bookID: book.id, noteID: id) == nil)
    }

    // MARK: Undo

    @Test func inkUndoSurvivesTextMovingTheStrokes() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = makeModel(store, book)
        await model.load()
        model.userDidEditText("One\nTwo")
        model.undoManager.groupsByEvent = false
        model.undoManager.beginUndoGrouping()
        Support.draw(Support.stroke(over: model.ink.layout.paragraphs[1]), on: model)
        model.undoManager.endUndoGrouping()
        let drawnAt = Support.pageStrokes(model)[0].renderBounds
        model.userDidEditText("Zero\nOne\nTwo")
        let movedAt = Support.pageStrokes(model)[0].renderBounds
        #expect(movedAt.minY > drawnAt.minY)

        model.undoManager.undo()
        #expect(model.strokeCount == 0)
        model.undoManager.redo()
        #expect(model.strokeCount == 1)
        // Redo puts the stroke back on its paragraph where that paragraph is now.
        #expect(abs(Support.pageStrokes(model)[0].renderBounds.minY - movedAt.minY) < 0.001)
    }

    // MARK: Two windows

    @Test func twoModelsOnOneNoteReconcile() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let windowA = makeModel(store, book, origin: ChangeOrigin(label: "A"))
        let windowB = makeModel(store, book, origin: ChangeOrigin(label: "B"))
        await windowA.load()
        await windowB.load()

        // A writes; idle B reloads text and ink.
        windowA.userDidEditText("Shared note\nSecond line")
        Support.draw(Support.stroke(over: windowA.ink.layout.paragraphs[0]), on: windowA)
        await windowA.flush()
        #expect(await Support.waitUntil { windowB.text == "Shared note\nSecond line" && windowB.strokeCount == 1 })
        #expect(windowB.noteID == windowA.noteID)

        // B is mid-stroke when A adds a stroke: B is not overwritten; both strokes survive.
        _ = windowB.displayInk()
        windowB.strokeDidBegin()
        Support.draw(Support.stroke(over: windowA.ink.layout.paragraphs[1], x: 30...200), on: windowA)
        await windowA.flush()
        try await Task.sleep(for: .milliseconds(150))
        #expect(windowB.strokeCount == 1)  // deferred
        Support.draw(Support.stroke(from: CGPoint(x: 40, y: 300), to: CGPoint(x: 220, y: 310)), on: windowB)
        windowB.strokeDidEnd()
        await windowB.flush()
        #expect(windowB.strokeCount == 3)
        #expect(await Support.waitUntil { windowA.strokeCount == 3 })

        // Erase in A (B unchanged): the erase reaches B.
        var drawing = windowA.displayInk()
        drawing.strokes.removeFirst()
        windowA.applyUserDrawing(drawing)
        await windowA.flush()
        #expect(await Support.waitUntil { windowB.strokeCount == 2 })

        // Text: last writer wins. Both edit; B saves first, then A: A's text is kept everywhere.
        windowA.userDidEditText("A's version")
        windowB.userDidEditText("B's version")
        await windowB.flush()
        await windowA.flush()
        #expect(try store.notes.note(bookID: book.id, target: .page(3))?.text == "A's version")
        #expect(await Support.waitUntil { windowB.text == "A's version" })
        #expect(windowA.strokeCount == 2 && windowB.strokeCount == 2)
    }

    @Test func secondWindowCreatingTheSameNoteAdoptsTheStoredID() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let windowA = makeModel(store, book, origin: ChangeOrigin(label: "A"))
        let windowB = makeModel(store, book, origin: ChangeOrigin(label: "B"))
        await windowA.load()
        await windowB.load()
        // Both start writing on an empty target; B draws while A types.
        _ = windowB.displayInk()
        windowB.strokeDidBegin()
        windowA.userDidEditText("From A")
        await windowA.flush()
        Support.draw(Support.stroke(from: CGPoint(x: 20, y: 120), to: CGPoint(x: 200, y: 130)), on: windowB)
        windowB.strokeDidEnd()
        await windowB.flush()
        let stored = try #require(try store.notes.note(bookID: book.id, target: .page(3)))
        #expect(windowB.noteID == stored.id && windowA.noteID == stored.id)
        #expect(stored.hasInk)
        #expect(await Support.waitUntil { windowA.strokeCount == 1 })
        #expect(windowB.text == "From A")
        #expect(try store.notes.notes(bookID: book.id).count == 1)
    }
}
