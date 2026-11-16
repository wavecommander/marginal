import Foundation
import PencilKit
import ReaderCore
import SwiftUI
import Testing
import UIKit
@testable import TactileTexts

/// `NotePageRenderer`: sizes, PNG, vector PDF, read-only view, and the editor view itself.
@MainActor
struct NotePageRendererTests {
    typealias Support = NotePageTestSupport

    private func note(text: String, strokes: [PKStroke], layout: NoteBandLayout) throws -> (Note, Data?) {
        var ink = NoteInk(layout: layout)
        var baseline = CanvasBaseline()
        _ = ink.applyCanvasDrawing(PKDrawing(strokes: strokes), baseline: &baseline)
        let data = strokes.isEmpty ? nil : try NoteInkArchive.encode(ink)
        let note = Note(bookID: UUID(), target: .page(0), text: text, hasInk: !strokes.isEmpty,
                        bandLayout: strokes.isEmpty ? nil : layout)
        return (note, data)
    }

    @Test func sizesFollowTextAndInk() throws {
        let text = "One\nTwo"
        let layout = NotePageLayoutEngine.shared.bandLayout(for: text)
        let (plain, _) = try note(text: text, strokes: [], layout: layout)
        let plainSize = NotePageRenderer.pageSize(note: plain, inkData: nil)
        #expect(plainSize.width == NotePageStyle.pageWidth)
        #expect(plainSize.height == ceil(layout.trailingTop + NotePageStyle.textInsets.bottom))

        let low = Support.stroke(from: CGPoint(x: 20, y: 400), to: CGPoint(x: 200, y: 420))
        let (inked, data) = try note(text: text, strokes: [low], layout: layout)
        let size = NotePageRenderer.pageSize(note: inked, inkData: data)
        #expect(size.width == NotePageStyle.pageWidth)
        #expect(size.height == ceil(low.renderBounds.maxY + NotePageStyle.renderBottomMargin))
    }

    /// Ink written in a widened notes pane lies to the right of the default page: the read-only
    /// page grows to hold it, so the Notebook and the exports show all of it.
    @Test func thePageGrowsToHoldInkWrittenBeyondTheDefaultWidth() throws {
        let text = "One\nTwo"
        let layout = NotePageLayoutEngine.shared.bandLayout(for: text)
        let far = Support.stroke(from: CGPoint(x: 420, y: 30), to: CGPoint(x: 600, y: 40))
        let (inked, data) = try note(text: text, strokes: [far], layout: layout)
        let snapshot = NotePageRenderer.snapshot(note: inked, inkData: data)
        #expect(snapshot.size.width == ceil(far.renderBounds.maxX))
        #expect(snapshot.size.width > NotePageStyle.pageWidth)
        #expect(snapshot.layout == layout, "the text is still wrapped at the default width")

        // The PNG covers the whole page, and the stroke's far end is in it (not white paper).
        let png = try #require(NotePageRenderer.pngData(snapshot, scale: 1))
        let image = try #require(UIImage(data: png)?.cgImage)
        #expect(CGFloat(image.width) == snapshot.size.width)
        let pixel = try #require(Self.pixel(of: image, x: 590, y: 39))
        #expect(pixel.blue > pixel.red + 40, "the stroke's blue ink, found at x 590: \(pixel)")
    }

    /// The colour of one pixel of `image` (origin top-left).
    private static func pixel(of image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int)? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    /// A note whose ink was last laid out at the default width, opened in a widened editor: its
    /// ink is brought to the wide layout at once, so it sits on its paragraph and a new stroke is
    /// filed under the paragraph it is drawn on.
    @Test func aNoteOpenedInAWidenedEditorIsLaidOutAtThatWidth() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = NotePageModel(store: store, bookID: book.id, target: .page(0), origin: ChangeOrigin(),
                                  autosaveDelay: .milliseconds(40))
        await model.load()
        let long = "A paragraph long enough to wrap onto several lines of the note page at its default width"
        model.userDidEditText(long + "\nSecond")
        let narrow = model.ink.layout
        #expect(narrow.pageWidth == NotePageStyle.pageWidth)
        Support.draw(Support.stroke(over: narrow.paragraphs[1]), on: model)

        let editor = NotePageEditorView(session: nil)
        editor.frame = CGRect(x: 0, y: 0, width: 700, height: 700)
        editor.isMarkupStandalone = true
        editor.pageWidth = 640
        editor.model = model
        editor.layoutIfNeeded()

        let wide = try #require(editor.liveBandLayout(for: model.text))
        #expect(wide.pageWidth == 640)
        #expect(wide.paragraphs[1].top < narrow.paragraphs[1].top, "fewer lines above on the wider page")
        #expect(model.ink.layout == wide)
        let shown = try #require(editor.canvasView.drawing.strokes.first).renderBounds
        #expect(shown.midY > wide.paragraphs[1].top && shown.midY < wide.paragraphs[1].bottom,
                "the stroke is shown on its paragraph")
        await editor.flushPendingMarkup()
    }

    @Test func pngIsTheNoteAtThreeTimesScale() throws {
        let layout = NotePageLayoutEngine.shared.bandLayout(for: "Hello")
        let (note, data) = try note(text: "Hello", strokes: [Support.stroke(over: layout.paragraphs[0])], layout: layout)
        let snapshot = NotePageRenderer.snapshot(note: note, inkData: data)
        let png = try #require(NotePageRenderer.pngData(note: note, inkData: data))
        let image = try #require(UIImage(data: png))
        #expect(image.size.width * image.scale == snapshot.size.width * 3)
        #expect(image.size.height * image.scale == snapshot.size.height * 3)
        let widePNG = try #require(NotePageRenderer.pngData(note: note, inkData: data, scale: 2, width: 640))
        let wide = try #require(UIImage(data: widePNG))
        #expect(wide.size.width * wide.scale == 1280)
    }

    private func pdf(_ snapshot: NotePageSnapshot) -> Data {
        let bounds = CGRect(origin: .zero, size: CGSize(width: 400, height: 600))
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            NotePageRenderer.draw(snapshot, in: context.cgContext, at: CGPoint(x: 20, y: 20))
        }
    }

    @Test func pdfDrawsPenInkAsVectorPaths() throws {
        let layout = NotePageLayoutEngine.shared.bandLayout(for: "Vector ink")
        let strokes = [Support.stroke(over: layout.paragraphs[0]),
                       Support.stroke(from: CGPoint(x: 30, y: 120), to: CGPoint(x: 250, y: 160), ink: .marker, width: 14),
                       Support.stroke(from: CGPoint(x: 30, y: 200), to: CGPoint(x: 250, y: 210), ink: .monoline, width: 2)]
        let (note, data) = try note(text: "Vector ink", strokes: strokes, layout: layout)
        let counts = Support.pdfOperatorCounts(pdf(NotePageRenderer.snapshot(note: note, inkData: data)))
        #expect((counts["f"] ?? 0) + (counts["f*"] ?? 0) >= 3)
        #expect((counts["c"] ?? 0) > 0)
        #expect((counts["Do"] ?? 0) == 0 && (counts["BI"] ?? 0) == 0)
        #expect((counts["Tj"] ?? 0) + (counts["TJ"] ?? 0) > 0)  // text as glyphs
        for stroke in strokes { #expect(NotePageRenderer.export(for: stroke) == .vector) }
    }

    @Test func pdfFallsBackToAnImageForTexturedInk() throws {
        let layout = NotePageLayoutEngine.shared.bandLayout(for: "Pencil")
        let pencil = Support.stroke(from: CGPoint(x: 30, y: 80), to: CGPoint(x: 250, y: 90), ink: .pencil, width: 4)
        let (note, data) = try note(text: "Pencil", strokes: [pencil], layout: layout)
        let counts = Support.pdfOperatorCounts(pdf(NotePageRenderer.snapshot(note: note, inkData: data)))
        #expect((counts["Do"] ?? 0) + (counts["BI"] ?? 0) >= 1)
        #expect(NotePageRenderer.export(for: pencil) == .image)
        #expect(NotePageRenderer.export(for: Support.stroke(from: .zero, to: CGPoint(x: 9, y: 9), ink: .crayon)) == .image)
        #expect(NotePageRenderer.export(for: Support.stroke(from: .zero, to: CGPoint(x: 9, y: 9), ink: .watercolor)) == .image)
        #expect(NotePageRenderer.export(for: Support.stroke(from: .zero, to: CGPoint(x: 9, y: 9), ink: .fountainPen)) == .image)
    }

    @Test func vectorOutlineCoversTheStroke() throws {
        let stroke = Support.stroke(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 210, y: 50), width: 6)
        let outline = try #require(NotePageRenderer.outline(of: stroke))
        #expect(outline.contains(CGPoint(x: 110, y: 50)))
        #expect(outline.contains(CGPoint(x: 110, y: 52)))
        #expect(!outline.contains(CGPoint(x: 110, y: 58)))
        let moved = stroke.translatedVertically(by: 100)
        #expect(try #require(NotePageRenderer.outline(of: moved)).contains(CGPoint(x: 110, y: 150)))
    }

    @Test func readOnlyViewRendersOffScreenAtItsWidth() throws {
        let layout = NotePageLayoutEngine.shared.bandLayout(for: "Read only")
        let (note, data) = try note(text: "Read only", strokes: [Support.stroke(over: layout.paragraphs[0])], layout: layout)
        let snapshot = NotePageRenderer.snapshot(note: note, inkData: data)
        let host = UIHostingController(rootView: NotePageReadOnlyView(snapshot: snapshot).frame(width: 160))
        let size = host.sizeThatFits(in: CGSize(width: 160, height: 10_000))
        #expect(abs(size.height - snapshot.size.height / 2) < 1)

        let view = NotePageReadOnlyUIView(frame: CGRect(x: 0, y: 0, width: 640, height: snapshot.size.height * 2))
        view.snapshot = snapshot
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in view.layer.render(in: context.cgContext) }
        #expect(image.size.width == 640)
    }

    // MARK: Editor view

    @Test func editorMovesInkWhenTextIsInsertedAbove() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = NotePageModel(store: store, bookID: book.id, target: .page(0), origin: ChangeOrigin(),
                                  autosaveDelay: .milliseconds(40))
        let editor = NotePageEditorView(session: nil)
        editor.frame = CGRect(x: 0, y: 0, width: 330, height: 700)
        editor.isMarkupStandalone = true
        editor.model = model
        #expect(await Support.waitUntil { model.isLoaded })
        editor.layoutIfNeeded()

        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        editor.textView.insertText("Alpha\nBeta word here")
        #expect(model.text == "Alpha\nBeta word here")
        let layout = try #require(editor.liveBandLayout(for: model.text))
        var drawing = editor.canvasView.drawing
        drawing.strokes.append(Support.stroke(over: layout.paragraphs[1]))
        editor.canvasView.drawing = drawing  // reported through canvasViewDrawingDidChange
        #expect(await Support.waitUntil { model.strokeCount == 1 })
        let before = editor.canvasView.drawing.strokes[0].renderBounds

        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        editor.textView.insertText("Inserted\n")
        let after = editor.canvasView.drawing.strokes[0].renderBounds
        let newLayout = try #require(editor.liveBandLayout(for: model.text))
        let inserted = newLayout.paragraphs[1].top - newLayout.paragraphs[0].top
        #expect(abs((after.minY - before.minY) - inserted) < 0.001)

        // Zoom never changes line breaks.
        editor.zoom = 1.8
        #expect(abs(editor.zoom - 1.8) < 0.0001)
        #expect(editor.liveBandLayout(for: model.text) == newLayout)
        editor.zoom = 5
        #expect(editor.zoom == NotePageStyle.zoomRange.upperBound)

        await editor.flushPendingMarkup()
        #expect(try store.notes.note(bookID: book.id, target: .page(0))?.text == "Inserted\nAlpha\nBeta word here")
    }

    /// TSOFT-226: a wider page re-wraps the text at the same size, and ink moves with its
    /// paragraph; the default width restores the line breaks and the ink.
    @Test func editorPageWidthRewrapsTextAndMovesInkWithItsParagraph() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = NotePageModel(store: store, bookID: book.id, target: .page(0), origin: ChangeOrigin(),
                                  autosaveDelay: .milliseconds(40))
        let editor = NotePageEditorView(session: nil)
        editor.frame = CGRect(x: 0, y: 0, width: 700, height: 700)
        editor.isMarkupStandalone = true
        editor.model = model
        #expect(await Support.waitUntil { model.isLoaded })
        editor.layoutIfNeeded()

        let long = "A paragraph long enough to wrap onto several lines of the note page at its default width"
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        editor.textView.insertText(long + "\nSecond")
        let narrow = try #require(editor.liveBandLayout(for: model.text))
        #expect(narrow.pageWidth == NotePageStyle.pageWidth)
        var drawing = editor.canvasView.drawing
        drawing.strokes.append(Support.stroke(over: narrow.paragraphs[1]))
        editor.canvasView.drawing = drawing
        #expect(await Support.waitUntil { model.strokeCount == 1 })
        let before = editor.canvasView.drawing.strokes[0].renderBounds

        editor.pageWidth = 640
        #expect(editor.pageWidth == 640)
        #expect(editor.textView.frame.width == 640)
        #expect(abs(editor.zoom - 1) < 0.0001, "a wider page is not a zoom")
        let wide = try #require(editor.liveBandLayout(for: model.text))
        #expect(wide.pageWidth == 640)
        #expect(wide.paragraphs[0].height < narrow.paragraphs[0].height, "fewer lines on the wider page")
        let moved = wide.paragraphs[1].top - narrow.paragraphs[1].top
        #expect(moved < 0)
        let wideStroke = editor.canvasView.drawing.strokes[0].renderBounds
        #expect(abs((wideStroke.minY - before.minY) - moved) < 0.001, "the stroke moved with its paragraph")
        #expect(abs(wideStroke.minX - before.minX) < 0.001)

        editor.pageWidth = 100  // never narrower than the default page
        #expect(editor.pageWidth == NotePageStyle.pageWidth)
        #expect(editor.liveBandLayout(for: model.text) == narrow)
        let back = editor.canvasView.drawing.strokes[0].renderBounds
        #expect(abs(back.minY - before.minY) < 0.001)

        await editor.flushPendingMarkup()
    }

    @Test func editorRoutesTouchesByMode() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = NotePageModel(store: store, bookID: book.id, target: .page(0), origin: ChangeOrigin())
        let editor = NotePageEditorView(session: nil)
        editor.frame = CGRect(x: 0, y: 0, width: 330, height: 700)
        editor.model = model
        #expect(await Support.waitUntil { model.isLoaded })
        #expect(!editor.canvasView.isUserInteractionEnabled)  // reading: the text view gets everything
        #expect(editor.textView.isEditable)
        editor.isMarkupStandalone = true
        #expect(editor.canvasView.isUserInteractionEnabled)
        #expect(editor.canvasView.drawingGestureRecognizer.isEnabled)
        editor.isMarkupStandalone = false
        #expect(!editor.canvasView.isUserInteractionEnabled)
        #expect(!editor.canvasView.drawingGestureRecognizer.isEnabled)
    }

    @Test func defaultZoomFollowsDynamicType() {
        #expect(NotePageStyle.defaultZoom(for: UIContentSizeCategory.large) == 1)
        #expect(NotePageStyle.defaultZoom(for: UIContentSizeCategory.extraSmall) == 1)
        #expect(NotePageStyle.defaultZoom(for: UIContentSizeCategory.accessibilityExtraExtraExtraLarge) == 2)
        #expect(NotePageStyle.defaultZoom(for: UIContentSizeCategory.extraExtraLarge) > 1)
        #expect(NotePageZoom.zoom(base: 1, panelWidth: 660) == 2)
        #expect(abs(NotePageZoom.zoom(base: 1, panelWidth: 462) - 1.4) < 0.0001)
    }
}
