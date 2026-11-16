import Foundation
import PencilKit
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// Page ink saving and loading through an ephemeral `LibraryStore`: round trip, empty drawings,
/// debounce and flush, stale loads, leaving the screen mid-save, and the two-window reconcile
/// rule. Surfaces are driven the way the canvas drives them (drawing set, delegate told).
@MainActor
struct PageInkPersistenceTests {
    private let geometry = PageInkGeometry(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)

    private func makeSurface(_ store: LibraryStore, _ book: Book, page: Int = 2, origin: ChangeOrigin,
                             saveDelay: Duration = .seconds(60)) -> PageInkSurface {
        let context = PageInkContext(store: store, bookID: book.id, origin: origin)
        let surface = PageInkSurface(pageIndex: page, geometry: geometry, overlay: nil, context: context,
                                     markup: nil, saveDelay: saveDelay)
        surface.markupModeDidChange(true)
        surface.startLoading()
        return surface
    }

    private func loaded(_ surface: PageInkSurface) async -> Bool {
        await PageInkTestSupport.waitUntil { surface.loadState == .ready }
    }

    /// A user change: the canvas's drawing becomes `drawing` and the delegate is told.
    private func userSets(_ surface: PageInkSurface, _ drawing: PKDrawing) {
        surface.canvas.drawing = drawing
        surface.canvasViewDrawingDidChange(surface.canvas)
    }

    private func userDraws(_ surface: PageInkSurface, _ stroke: PKStroke) {
        var drawing = surface.canvas.drawing
        drawing.strokes.append(stroke)
        userSets(surface, drawing)
    }

    private func stored(_ store: LibraryStore, _ book: Book, page: Int = 2) async throws -> PKDrawing? {
        guard let data = try await store.pageInk(bookID: book.id, pageIndex: page) else { return nil }
        return try PKDrawing(data: data)
    }

    private func line(_ y: CGFloat, color: UIColor = .systemBlue) -> PKStroke {
        PageInkTestSupport.stroke(from: CGPoint(x: 50, y: y), to: CGPoint(x: 300, y: y + 4), color: color)
    }

    private func identities(_ drawing: PKDrawing?) -> [StrokeIdentity] {
        (drawing?.strokes ?? []).map(StrokeIdentity.init)
    }

    // MARK: Round trip and empty drawings

    @Test func drawingRoundTripsThroughTheStore() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let a = makeSurface(store, book, origin: ChangeOrigin())
        #expect(await loaded(a))
        #expect(a.strokeCount == 0)
        let s1 = line(100), s2 = line(200, color: .systemRed)
        userDraws(a, s1)
        userDraws(a, s2)
        await a.flushPendingMarkup()
        let data = try #require(try await stored(store, book))
        #expect(identities(data) == identities(PKDrawing(strokes: [s1, s2])))
        #expect(try await store.inkedPageIndices(bookID: book.id) == [2])
        a.finish()

        let b = makeSurface(store, book, origin: ChangeOrigin())
        #expect(await loaded(b))
        #expect(b.strokeCount == 2)
        #expect(PageInkMerge.sameStrokes(b.canvas.drawing, data))
    }

    @Test func erasingTheLastStrokeDeletesTheFile() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let a = makeSurface(store, book, origin: ChangeOrigin())
        #expect(await loaded(a))
        userDraws(a, line(100))
        await a.flushPendingMarkup()
        #expect(try await stored(store, book) != nil)
        userSets(a, PKDrawing())
        await a.flushPendingMarkup()
        #expect(try await store.pageInk(bookID: book.id, pageIndex: 2) == nil)
        #expect(try await store.inkedPageIndices(bookID: book.id).isEmpty)
    }

    @Test func aDrawingEmptiedBeforeItsFirstSaveIsNeverStored() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        var events = 0
        let observation = store.hub.observe { event in
            if case .pageInkChanged = event.change { events += 1 }
        }
        defer { observation.cancel() }
        let a = makeSurface(store, book, origin: ChangeOrigin())
        #expect(await loaded(a))
        userDraws(a, line(100))
        userSets(a, PKDrawing())
        await a.flushPendingMarkup()
        #expect(try await store.pageInk(bookID: book.id, pageIndex: 2) == nil)
        #expect(events == 0, "nothing written, nothing announced")
    }

    // MARK: Debounce and flush

    @Test func savesAreDebouncedAndCoalesced() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        var writes = 0
        let observation = store.hub.observe { event in
            if case .pageInkChanged = event.change { writes += 1 }
        }
        defer { observation.cancel() }
        let a = makeSurface(store, book, origin: ChangeOrigin(), saveDelay: .milliseconds(400))
        #expect(await loaded(a))
        userDraws(a, line(100))
        await PageInkTestSupport.pause(0.15)
        userDraws(a, line(150))
        await PageInkTestSupport.pause(0.15)
        userDraws(a, line(200))
        #expect(a.isDirty)
        await PageInkTestSupport.pause(0.2)
        #expect(try await store.pageInk(bookID: book.id, pageIndex: 2) == nil, "not before the delay")
        #expect(await PageInkTestSupport.waitUntil(timeout: 3) { writes == 1 })
        #expect(try await stored(store, book)?.strokes.count == 3)
        await PageInkTestSupport.pause(0.6)
        #expect(writes == 1, "three changes, one write")
        #expect(!a.isDirty)
    }

    @Test func flushWritesAtOnce() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let a = makeSurface(store, book, origin: ChangeOrigin(), saveDelay: .seconds(60))
        #expect(await loaded(a))
        userDraws(a, line(100))
        await a.flushPendingMarkup()
        #expect(try await stored(store, book)?.strokes.count == 1)
        // Safe to repeat, and with nothing pending.
        await a.flushPendingMarkup()
        await a.flushPendingMarkup()
        #expect(try await stored(store, book)?.strokes.count == 1)
    }

    @Test func aStrokeIsNotSavedWhileTheToolIsInUse() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let a = makeSurface(store, book, origin: ChangeOrigin(), saveDelay: .milliseconds(150))
        #expect(await loaded(a))
        userDraws(a, line(100))
        a.canvasViewDidBeginUsingTool(a.canvas)  // the next stroke is in progress
        await PageInkTestSupport.pause(0.5)
        #expect(try await store.pageInk(bookID: book.id, pageIndex: 2) == nil, "the debounce waits for the stroke")
        userDraws(a, line(150))
        a.canvasViewDidEndUsingTool(a.canvas)
        #expect(await PageInkTestSupport.waitUntil(timeout: 3) {
            (try? PKDrawing(data: (a.base.data ?? Data())))?.strokes.count == 2
        })
        #expect(try await stored(store, book)?.strokes.count == 2)
    }

    // MARK: Leaving the screen

    @Test func aStaleLoadIsIgnored() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let data = PKDrawing(strokes: [line(100)]).dataRepresentation()
        try await store.savePageInk(data, bookID: book.id, pageIndex: 2, origin: nil)
        let a = makeSurface(store, book, origin: ChangeOrigin())
        a.finish()  // the page left before its load came back
        await PageInkQueue.shared.drain(bookID: book.id)
        await PageInkTestSupport.pause(0.2)
        #expect(a.loadState == .loading)
        #expect(a.strokeCount == 0, "a finished surface is never given a drawing")
    }

    @Test func leavingTheScreenSavesAndTheNextLoadSeesIt() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let a = makeSurface(store, book, origin: ChangeOrigin(), saveDelay: .seconds(60))
        #expect(await loaded(a))
        userDraws(a, line(100))
        // The page leaves (scroll away / jump 1,000 pages) and comes straight back: the save
        // and the new load share the page's queue, so the load sees the save.
        a.finish()
        let b = makeSurface(store, book, origin: ChangeOrigin())
        #expect(await loaded(b))
        #expect(b.strokeCount == 1)
        #expect(try await stored(store, book)?.strokes.count == 1)
    }

    /// The page leaves the screen between the Pencil lifting and PencilKit committing the stroke
    /// (a jump or a fling straight after writing): the stroke is saved when it is committed.
    @Test func aStrokeCommittedAfterThePageLeftIsSaved() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let a = makeSurface(store, book, origin: ChangeOrigin())
        #expect(await loaded(a))
        a.canvasViewDidBeginUsingTool(a.canvas)
        a.canvasViewDidEndUsingTool(a.canvas)   // the Pencil lifted; the stroke is not committed yet
        a.finish()                              // the page leaves the screen
        #expect(!a.isFinished, "the surface waits for the stroke")
        userDraws(a, line(100))                 // PencilKit commits the stroke
        await PageInkQueue.shared.drain(bookID: book.id)
        #expect(a.isFinished)
        #expect(try await stored(store, book)?.strokes.count == 1)
    }

    /// The same, when PencilKit puts the stroke in the drawing without ever reporting the change:
    /// the wait times out and whatever the canvas holds by then is saved.
    @Test func aStrokeNeverReportedAfterThePageLeftIsSavedWhenTheWaitEnds() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let a = makeSurface(store, book, origin: ChangeOrigin())
        #expect(await loaded(a))
        a.canvasViewDidBeginUsingTool(a.canvas)
        a.canvasViewDidEndUsingTool(a.canvas)
        a.finish()
        a.canvas.drawing = PKDrawing(strokes: [line(100)])  // no delegate call
        await PageInkQueue.shared.drain(bookID: book.id)
        #expect(a.isFinished)
        #expect(try await stored(store, book)?.strokes.count == 1)
    }

    /// The page comes back before the stroke is committed: its new surface loads after the old
    /// one's save, so it shows the stroke.
    @Test func aPageThatReturnsBeforeTheStrokeIsCommittedShowsIt() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let origin = ChangeOrigin()
        let a = makeSurface(store, book, origin: origin)
        #expect(await loaded(a))
        a.canvasViewDidBeginUsingTool(a.canvas)
        a.canvasViewDidEndUsingTool(a.canvas)
        a.finish()
        let b = makeSurface(store, book, origin: origin)  // the page is displayed again
        userDraws(a, line(100))
        #expect(await loaded(b))
        #expect(b.strokeCount == 1)
        #expect(a.isFinished)
        b.finish()
    }

    /// A page that leaves with nothing pending is finished at once, as before.
    @Test func aPageWithNoStrokePendingFinishesAtOnce() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let a = makeSurface(store, book, origin: ChangeOrigin())
        #expect(await loaded(a))
        userDraws(a, line(100))
        a.finish()
        #expect(a.isFinished)
        await PageInkQueue.shared.drain(bookID: book.id)
        #expect(try await stored(store, book)?.strokes.count == 1)
    }

    @Test func manyPagesLeftMidSaveAreAllWritten() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let origin = ChangeOrigin()
        var surfaces: [PageInkSurface] = []
        for page in 0..<12 {
            let surface = makeSurface(store, book, page: page, origin: origin)
            surfaces.append(surface)
        }
        for surface in surfaces { #expect(await loaded(surface)) }
        for surface in surfaces { userDraws(surface, line(CGFloat(100 + surface.pageIndex))) }
        for surface in surfaces { surface.finish() }
        surfaces.removeAll()
        await PageInkQueue.shared.drain(bookID: book.id)
        #expect(try await store.inkedPageIndices(bookID: book.id) == Array(0..<12))
    }

    // MARK: Two windows

    @Test func anotherWindowsStrokesMergeWithUnsavedLocalStrokes() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let a = makeSurface(store, book, origin: ChangeOrigin())
        let b = makeSurface(store, book, origin: ChangeOrigin())
        #expect(await loaded(a))
        #expect(await loaded(b))
        let s1 = line(100), s2 = line(300, color: .systemGreen)
        userDraws(b, s2)                 // unsaved in window B
        userDraws(a, s1)
        await a.flushPendingMarkup()     // window A stores s1
        b.remoteDidChange()              // B hears about it
        #expect(await PageInkTestSupport.waitUntil { b.strokeCount == 2 })
        #expect(Set(identities(b.canvas.drawing)) == Set(identities(PKDrawing(strokes: [s1, s2]))))
        #expect(b.isDirty, "B still has to store its own stroke")
        await b.flushPendingMarkup()
        #expect(Set(identities(try await stored(store, book))) == Set(identities(PKDrawing(strokes: [s1, s2]))))
        a.remoteDidChange()
        #expect(await PageInkTestSupport.waitUntil { a.strokeCount == 2 })
        #expect(!a.isDirty)
    }

    @Test func aStrokeInProgressIsNeverOverwritten() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let a = makeSurface(store, book, origin: ChangeOrigin())
        let b = makeSurface(store, book, origin: ChangeOrigin())
        #expect(await loaded(a))
        #expect(await loaded(b))
        let s1 = line(100), s2 = line(300)
        b.canvasViewDidBeginUsingTool(b.canvas)   // B is mid-stroke
        userDraws(a, s1)
        await a.flushPendingMarkup()
        b.remoteDidChange()
        await PageInkTestSupport.pause(0.3)
        #expect(b.strokeCount == 0, "nothing applied mid-stroke")
        // The stroke ends and PencilKit commits it.
        b.canvas.drawing = PKDrawing(strokes: [s2])
        b.canvasViewDidEndUsingTool(b.canvas)
        b.canvasViewDrawingDidChange(b.canvas)
        #expect(await PageInkTestSupport.waitUntil { b.strokeCount == 2 })
        await b.flushPendingMarkup()
        #expect(try await stored(store, book)?.strokes.count == 2)
    }

    @Test func concurrentSavesFromTwoWindowsKeepBothStrokes() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let a = makeSurface(store, book, origin: ChangeOrigin())
        let b = makeSurface(store, book, origin: ChangeOrigin())
        #expect(await loaded(a))
        #expect(await loaded(b))
        userDraws(a, line(100))
        userDraws(b, line(300))
        // Both save without hearing of each other first.
        async let flushA: Void = a.flushPendingMarkup()
        async let flushB: Void = b.flushPendingMarkup()
        _ = await (flushA, flushB)
        #expect(try await stored(store, book)?.strokes.count == 2, "the second save merged the first")
    }

    @Test func anEraseInOneWindowRemovesTheStrokeUnlessTheOtherEditedIt() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let s1 = line(100), s2 = line(200)
        try await store.savePageInk(PKDrawing(strokes: [s1, s2]).dataRepresentation(), bookID: book.id, pageIndex: 2, origin: nil)
        let a = makeSurface(store, book, origin: ChangeOrigin())
        let b = makeSurface(store, book, origin: ChangeOrigin())
        #expect(await loaded(a))
        #expect(await loaded(b))
        // B moves s2 (lasso) without saving; A erases both strokes and saves.
        var moved = s2
        moved.transform = CGAffineTransform(translationX: 0, y: 40)
        userSets(b, PKDrawing(strokes: [s1, moved]))
        userSets(a, PKDrawing())
        await a.flushPendingMarkup()
        b.remoteDidChange()
        // s1 was unchanged in B: the erase wins. s2 was edited in B: the edit wins.
        #expect(await PageInkTestSupport.waitUntil { b.strokeCount == 1 })
        #expect(StrokeFingerprint(b.canvas.drawing.strokes[0]) == StrokeFingerprint(moved))
        await b.flushPendingMarkup()
        #expect(try await stored(store, book)?.strokes.count == 1)
    }

    // MARK: Merge rule

    @Test func mergeRule() {
        let a = line(10), b = line(20), c = line(30), d = line(40)
        var bMoved = b
        bMoved.transform = CGAffineTransform(translationX: 5, y: 0)
        var cRecoloured = c
        cRecoloured.ink = PKInk(.pen, color: .systemOrange)
        // base [a, b, c]; local: added d, moved b, erased c; remote: erased a, recoloured c.
        let merged = PageInkMerge.merge(local: [a, bMoved, d], remote: [b, cRecoloured], base: [a, b, c])
        let fingerprints = merged.map(StrokeFingerprint.init)
        #expect(!fingerprints.contains(StrokeFingerprint(a)), "erased remotely, unchanged locally")
        #expect(fingerprints.contains(StrokeFingerprint(bMoved)), "edited locally")
        #expect(fingerprints.contains(StrokeFingerprint(cRecoloured)), "edited remotely beats a local erase")
        #expect(fingerprints.contains(StrokeFingerprint(d)), "added locally")
        #expect(merged.count == 3)
        // No base: union.
        #expect(PageInkMerge.merge(local: [a], remote: [b], base: nil).count == 2)
    }

    @Test func strokeIdentityAndContentSurviveEncoding() throws {
        let strokes = (0..<20).map { line(CGFloat(13.37 * Double($0) + 0.123)) }
        let drawing = PKDrawing(strokes: strokes)
        let decoded = try PKDrawing(data: drawing.dataRepresentation())
        #expect(decoded.strokes.map(StrokeIdentity.init) == strokes.map(StrokeIdentity.init))
        #expect(PageInkMerge.sameStrokes(decoded, drawing))
    }

    // MARK: Cost of encoding (measured, reported)

    @Test func encodingCostIsMeasured() async throws {
        // 400 strokes of 120 points: a heavily marked-up page.
        func heavyDrawing() -> PKDrawing {
            var strokes: [PKStroke] = []
            for index in 0..<400 {
                let points = (0..<120).map { step -> PKStrokePoint in
                    let t = CGFloat(step)
                    return PKStrokePoint(location: CGPoint(x: 20 + t * 4, y: 20 + CGFloat(index) * 1.8 + sin(t / 5) * 3),
                                         timeOffset: Double(step) * 0.008, size: CGSize(width: 3, height: 3),
                                         opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                strokes.append(PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date())))
            }
            return PKDrawing(strokes: strokes)
        }
        let clock = ContinuousClock()
        // On the main actor (what a naive save would block drawing for).
        let first = heavyDrawing()
        var data = Data()
        let encode = clock.measure { data = first.dataRepresentation() }
        var decoded = PKDrawing()
        let decode = try clock.measure { decoded = try PKDrawing(data: data) }
        // The save path: the main actor only hands the drawing over and is free meanwhile.
        let second = heavyDrawing()
        var mainBusy = Duration.zero
        let total = await clock.measure {
            let start = clock.now
            let task = Task.detached { await PageInkPersistence.encode(second) }
            mainBusy = clock.now - start
            _ = await task.value
        }
        print("PageInk encode 400 strokes × 120 points: \(data.count) bytes; on main: encode \(encode), decode \(decode); off-main encode \(total) total, main actor busy \(mainBusy)")
        #expect(decoded.strokes.count == 400)
        #expect(mainBusy < .milliseconds(5))
    }
}
