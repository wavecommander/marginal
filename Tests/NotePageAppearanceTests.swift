import Foundation
import PencilKit
import ReaderCore
import Testing
import UIKit
@testable import TactileTexts

/// Design rule "The notes pane follows the system appearance": the note page (editor and
/// read-only views) follows light and dark, live, with PencilKit's own light/dark ink rendering;
/// switching never changes the stored strokes; exports stay light.
@MainActor
@Suite(.serialized)
struct NotePageAppearanceTests {
    typealias Support = NotePageTestSupport

    static let black = UIColor.black
    static let darkBlue = UIColor(red: 0.05, green: 0.15, blue: 0.5, alpha: 1)

    // MARK: Pixels

    struct RGBA: CustomStringConvertible {
        var r, g, b, a: Int
        var luminance: Double { 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b) }
        var description: String { "rgba(\(r),\(g),\(b),\(a))" }
    }

    /// The pixel at `point` (image points) of `image`.
    static func pixel(_ image: UIImage, at point: CGPoint) -> RGBA {
        guard let cg = image.cgImage else { return RGBA(r: -1, g: -1, b: -1, a: -1) }
        let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
        return RGBA(r: Int(data[0]), g: Int(data[1]), b: Int(data[2]), a: Int(data[3]))
    }

    /// The darkest and lightest luminance in a rectangle of `image` (image points), sampled.
    static func luminanceRange(_ image: UIImage, in rect: CGRect) -> ClosedRange<Double> {
        var low = 255.0, high = 0.0
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                let value = pixel(image, at: CGPoint(x: x, y: y)).luminance
                low = min(low, value)
                high = max(high, value)
                x += 1
            }
            y += 1
        }
        return low...max(low, high)
    }

    static func snapshot(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    static func makeWindow(size: CGSize, style: UIUserInterfaceStyle) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = style
        window.isHidden = false
        return window
    }

    static func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    private func components(_ color: UIColor) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a]
    }

    // MARK: PencilKit's own conversion

    /// The renderer's ink image is PencilKit's rendering for the appearance: black ink shows
    /// light on dark paper and stays black in light; the strokes themselves are unchanged.
    @Test func inkImageUsesPencilKitsAppearanceRendering() {
        let strokes = [Support.stroke(from: CGPoint(x: 10, y: 40), to: CGPoint(x: 300, y: 40), width: 8, color: Self.black),
                       Support.stroke(from: CGPoint(x: 10, y: 80), to: CGPoint(x: 300, y: 80), width: 8, color: Self.darkBlue)]
        let drawing = PKDrawing(strokes: strokes)
        let before = drawing.dataRepresentation()
        let snapshot = NotePageSnapshot(text: "", layout: NotePageLayoutEngine.shared.bandLayout(for: ""),
                                        drawing: drawing, size: CGSize(width: 320, height: 120), inkUnreadable: false)
        let light = NotePageRenderer.inkImage(snapshot, scale: 2, traits: UITraitCollection(userInterfaceStyle: .light))
        let dark = NotePageRenderer.inkImage(snapshot, scale: 2, traits: UITraitCollection(userInterfaceStyle: .dark))
        #expect(Self.pixel(light, at: CGPoint(x: 150, y: 40)).luminance < 10)
        #expect(Self.pixel(dark, at: CGPoint(x: 150, y: 40)).luminance > 240)
        let blueLight = Self.pixel(light, at: CGPoint(x: 150, y: 80))
        let blueDark = Self.pixel(dark, at: CGPoint(x: 150, y: 80))
        #expect(blueLight.luminance < 50)
        #expect(blueDark.luminance > 140 && blueDark.b > blueDark.r)  // still blue, now light
        #expect(drawing.dataRepresentation() == before)
        #expect(components(drawing.strokes[0].ink.color) == [0, 0, 0, 1])
    }

    // MARK: Editor

    /// The editor in a window: light paper, dark text and black ink in Light Mode; dark paper,
    /// light text, light ink in Dark Mode; switching live both ways. The stored note (text, ink
    /// bytes, modification date) is identical afterwards and the model has nothing to save.
    @Test func editorFollowsAppearanceLiveWithoutChangingStoredInk() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }

        // A stored note with text and black and dark blue ink in the writing space.
        let text = "Dark mode note"
        let seed = NotePageModel(store: store, bookID: book.id, target: .page(2), origin: ChangeOrigin(),
                                 autosaveDelay: .milliseconds(20))
        await seed.load()
        seed.userDidEditText(text)
        let top = seed.ink.layout.trailingTop
        Support.draw(Support.stroke(from: CGPoint(x: 30, y: top + 60), to: CGPoint(x: 290, y: top + 60), width: 8,
                                    color: Self.black), on: seed)
        Support.draw(Support.stroke(from: CGPoint(x: 30, y: top + 100), to: CGPoint(x: 290, y: top + 100), width: 8,
                                    color: Self.darkBlue), on: seed)
        await seed.flush()
        let record = try #require(try store.notes.note(bookID: book.id, target: .page(2)))
        let storedInk = try #require(try await store.noteInk(bookID: book.id, noteID: record.id))

        let window = try Self.makeWindow(size: CGSize(width: 330, height: 600), style: .light)
        defer { window.isHidden = true }
        let model = NotePageModel(store: store, bookID: book.id, target: .page(2), origin: ChangeOrigin(),
                                  autosaveDelay: .milliseconds(20))
        let editor = NotePageEditorView(session: nil)
        editor.frame = window.bounds
        window.addSubview(editor)
        editor.model = model
        #expect(await Support.waitUntil { model.isLoaded && model.strokeCount == 2 })
        editor.layoutIfNeeded()
        let canvasBefore = editor.canvasView.drawing.dataRepresentation()

        func point(_ page: CGPoint) -> CGPoint { editor.canvasView.convert(page, to: window) }
        let inkPoint = point(CGPoint(x: 160, y: top + 60))
        let bluePoint = point(CGPoint(x: 160, y: top + 100))
        let paperPoint = point(CGPoint(x: 160, y: top + 160))
        let textRect = CGRect(origin: point(CGPoint(x: NotePageStyle.textInsets.left, y: NotePageStyle.textInsets.top)),
                              size: CGSize(width: 90, height: NotePageStyle.lineHeight))

        func check(_ style: UIUserInterfaceStyle) async {
            window.overrideUserInterfaceStyle = style
            await Self.settle()
            let image = Self.snapshot(window)
            let paper = Self.pixel(image, at: paperPoint)
            let ink = Self.pixel(image, at: inkPoint)
            let blue = Self.pixel(image, at: bluePoint)
            let textRange = Self.luminanceRange(image, in: textRect)
            let textColor = (editor.textView.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)?
                .resolvedColor(with: editor.textView.traitCollection)
            if style == .dark {
                #expect(paper.luminance < 40, "dark paper, got \(paper)")
                #expect(ink.luminance > 200, "black ink shows light on dark paper, got \(ink)")
                #expect(blue.luminance > 120 && blue.b > blue.r, "dark blue shows light blue, got \(blue)")
                #expect(textRange.upperBound > 180, "light text, got \(textRange)")
                #expect(textColor.map { components($0)[0] > 0.9 } == true)
            } else {
                #expect(paper.luminance > 250, "white paper, got \(paper)")
                #expect(ink.luminance < 20, "black ink, got \(ink)")
                #expect(blue.luminance < 60, "dark blue, got \(blue)")
                #expect(textRange.lowerBound < 60, "dark text, got \(textRange)")
                #expect(textColor.map { components($0)[0] < 0.1 } == true)
            }
            #expect(editor.canvasView.traitCollection.userInterfaceStyle == style)
        }
        await check(.light)
        await check(.dark)
        await check(.light)
        await check(.dark)

        // Nothing about the note changed: the canvas's drawing, the model, the store.
        #expect(editor.canvasView.drawing.dataRepresentation() == canvasBefore)
        #expect(!model.hasUnsavedChanges)
        await editor.flushPendingMarkup()
        await model.flush()
        let after = try #require(try store.notes.note(bookID: book.id, target: .page(2)))
        #expect(after.modifiedAt == record.modifiedAt)
        #expect(after.text == text)
        #expect(try await store.noteInk(bookID: book.id, noteID: record.id) == storedInk)
        let colors = Support.pageStrokes(model).map { components($0.ink.color) }
        #expect(colors.first == [0, 0, 0, 1])
        editor.removeFromSuperview()
    }

    /// The placeholder of an empty note follows the appearance too.
    @Test func placeholderFollowsAppearance() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let window = try Self.makeWindow(size: CGSize(width: 330, height: 400), style: .dark)
        defer { window.isHidden = true }
        let model = NotePageModel(store: store, bookID: book.id, target: .page(0), origin: ChangeOrigin())
        let editor = NotePageEditorView(session: nil)
        editor.frame = window.bounds
        window.addSubview(editor)
        editor.model = model
        #expect(await Support.waitUntil { model.isLoaded })
        editor.layoutIfNeeded()
        await Self.settle()
        let origin = editor.canvasView.convert(CGPoint(x: NotePageStyle.textInsets.left, y: NotePageStyle.textInsets.top),
                                              to: window)
        let rect = CGRect(origin: origin, size: CGSize(width: 80, height: NotePageStyle.lineHeight))
        let dark = Self.luminanceRange(Self.snapshot(window), in: rect)
        #expect(dark.lowerBound < 40 && dark.upperBound > 70, "grey placeholder on dark paper, got \(dark)")
        window.overrideUserInterfaceStyle = .light
        await Self.settle()
        let light = Self.luminanceRange(Self.snapshot(window), in: rect)
        #expect(light.upperBound > 250 && light.lowerBound < 230, "grey placeholder on white paper, got \(light)")
        editor.removeFromSuperview()
    }

    // MARK: Read-only view

    /// The Notebook: the read-only view re-renders on a live
    /// switch (its ink image is keyed by appearance), on the matching paper.
    @Test func readOnlyViewFollowsAppearanceLive() async throws {
        let stroke = Support.stroke(from: CGPoint(x: 20, y: 80), to: CGPoint(x: 300, y: 80), width: 8, color: Self.black)
        let snapshot = NotePageSnapshot(text: "Read only", layout: NotePageLayoutEngine.shared.bandLayout(for: "Read only"),
                                        drawing: PKDrawing(strokes: [stroke]), size: CGSize(width: 320, height: 120),
                                        inkUnreadable: false)
        let window = try Self.makeWindow(size: CGSize(width: 320, height: 120), style: .light)
        defer { window.isHidden = true }
        let view = NotePageReadOnlyUIView(frame: window.bounds)
        view.snapshot = snapshot
        window.addSubview(view)
        await Self.settle()
        var image = Self.snapshot(window)
        #expect(Self.pixel(image, at: CGPoint(x: 160, y: 80)).luminance < 20)
        #expect(Self.pixel(image, at: CGPoint(x: 160, y: 110)).luminance > 250)
        #expect(view.renderedStyle == .light)

        window.overrideUserInterfaceStyle = .dark
        await Self.settle()
        image = Self.snapshot(window)
        let ink = Self.pixel(image, at: CGPoint(x: 160, y: 80))
        let paper = Self.pixel(image, at: CGPoint(x: 160, y: 110))
        #expect(ink.luminance > 200, "light ink on dark paper, got \(ink)")
        #expect(paper.luminance < 40, "dark paper, got \(paper)")
        #expect(Self.luminanceRange(image, in: CGRect(x: 14, y: 14, width: 60, height: 22)).upperBound > 180)
        #expect(view.renderedStyle == .dark)

        window.overrideUserInterfaceStyle = .light
        await Self.settle()
        image = Self.snapshot(window)
        #expect(Self.pixel(image, at: CGPoint(x: 160, y: 80)).luminance < 20)
        #expect(view.renderedStyle == .light)
        #expect(components(snapshot.drawing.strokes[0].ink.color) == [0, 0, 0, 1])
        view.removeFromSuperview()
    }

    // MARK: Exports

    /// The export renderers share code with the on-screen view, so check they stay light when
    /// called while the app is in Dark Mode (dark trait collection current, and from inside a
    /// dark view's drawing): white paper, dark text, the stored ink colours, in PNG and PDF.
    @Test func exportsStayLightInDarkMode() throws {
        let text = "Exported"
        let layout = NotePageLayoutEngine.shared.bandLayout(for: text)
        let top = layout.trailingTop
        let strokes = [Support.stroke(from: CGPoint(x: 20, y: top + 30), to: CGPoint(x: 300, y: top + 30), width: 8,
                                      color: Self.black),
                       Support.stroke(from: CGPoint(x: 20, y: top + 70), to: CGPoint(x: 300, y: top + 70), ink: .pencil,
                                      width: 10, color: Self.black)]
        var ink = NoteInk(layout: layout)
        var baseline = CanvasBaseline()
        _ = ink.applyCanvasDrawing(PKDrawing(strokes: strokes), baseline: &baseline)
        let data = try NoteInkArchive.encode(ink)
        let note = Note(bookID: UUID(), target: .page(0), text: text, hasInk: true, bandLayout: layout)
        let snapshot = NotePageRenderer.snapshot(note: note, inkData: data)

        // PNG (Markdown export), with a dark trait collection current.
        var png: Data?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            png = NotePageRenderer.pngData(note: note, inkData: data)
        }
        let image = try #require(png.flatMap { UIImage(data: $0, scale: 3) })
        #expect(Self.pixel(image, at: CGPoint(x: 160, y: top + 30)).luminance < 20)
        #expect(Self.pixel(image, at: CGPoint(x: 160, y: top + 70)).luminance < 140)  // textured pencil, dark
        #expect(Self.pixel(image, at: CGPoint(x: 160, y: top + 50)).luminance > 250)
        #expect(Self.pixel(image, at: CGPoint(x: 316, y: 4)).luminance > 250)
        #expect(Self.luminanceRange(image, in: CGRect(x: 14, y: 14, width: 60, height: 22)).lowerBound < 60)

        // PDF (Notebook export): vector pen, image-fallback pencil, glyphs, rasterised to check.
        let bounds = CGRect(x: 0, y: 0, width: 320, height: snapshot.size.height)
        var pdf = Data()
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            pdf = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
                context.beginPage()
                NotePageRenderer.draw(snapshot, in: context.cgContext)
            }
        }
        let provider = try #require(CGDataProvider(data: pdf as CFData))
        let page = try #require(CGPDFDocument(provider)?.page(at: 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let raster = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(bounds)
            context.cgContext.translateBy(x: 0, y: bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            context.cgContext.drawPDFPage(page)
        }
        #expect(Self.pixel(raster, at: CGPoint(x: 160, y: top + 30)).luminance < 20)
        #expect(Self.pixel(raster, at: CGPoint(x: 160, y: top + 70)).luminance < 140)
        #expect(Self.luminanceRange(raster, in: CGRect(x: 14, y: 14, width: 60, height: 22)).lowerBound < 60)

        // The on-screen look of Dark Mode is only ever asked for explicitly.
        let dark = NotePageRenderer.image(snapshot, scale: 2, appearance: .dark)
        #expect(Self.pixel(dark, at: CGPoint(x: 160, y: top + 30)).luminance > 200)
        #expect(Self.pixel(dark, at: CGPoint(x: 160, y: top + 50)).luminance < 40)
    }
}
