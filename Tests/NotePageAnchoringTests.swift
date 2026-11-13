import Foundation
import PencilKit
import ReaderCore
import Testing
import UIKit
@testable import Marginal

/// Band layouts from real TextKit layout, and ink following the text (WP13).
@MainActor
struct NotePageAnchoringTests {
    typealias Support = NotePageTestSupport

    private func liveTextView(_ text: String) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        NotePageStyle.configure(textView)
        textView.frame = CGRect(x: 0, y: 0, width: NotePageStyle.pageWidth, height: 2000)
        textView.attributedText = NotePageStyle.attributedText(text)
        return textView
    }

    // MARK: Layout

    @Test func layoutHasOneTiledBandPerParagraph() {
        let text = "Why the determinant shows up\n(A − λI)v = 0 needs a nonzero v, so A − λI has to flatten some direction to zero. That means singular.\n\n- Degree of the polynomial = size of the matrix."
        let layout = NotePageTextLayout.bandLayout(of: liveTextView(text))
        let paragraphs = NoteBandLayout.paragraphs(of: text)
        #expect(layout.paragraphs.map(\.text) == paragraphs)
        #expect(layout.pageWidth == NotePageStyle.pageWidth)
        #expect(layout.paragraphs.first?.top == NotePageStyle.textInsets.top)
        for (upper, lower) in zip(layout.paragraphs, layout.paragraphs.dropFirst()) {
            #expect(upper.bottom == lower.top)  // tiled, ordered, no overlap
            #expect(upper.height > 0)
        }
        #expect(layout.trailingTop == layout.paragraphs.last?.bottom)
        // The long paragraph wraps to several lines; one-line paragraphs are one line + spacing.
        #expect(layout.paragraphs[1].height > 2 * NotePageStyle.lineHeight)
        #expect(layout.paragraphs[0].height == NotePageStyle.lineHeight + NotePageStyle.paragraphSpacing)
    }

    @Test func trailingNewlineAndEmptyTextGetBands() {
        let trailing = NotePageTextLayout.bandLayout(of: liveTextView("Alpha\n"))
        #expect(trailing.paragraphs.map(\.text) == ["Alpha", ""])
        #expect(trailing.paragraphs[1].top > trailing.paragraphs[0].top)
        #expect(trailing.paragraphs[1].height > 0)

        let empty = NotePageTextLayout.bandLayout(of: liveTextView(""))
        #expect(empty.paragraphs.map(\.text) == [""])
        #expect(empty.paragraphs[0].top == NotePageStyle.textInsets.top)
        #expect(empty.trailingTop == NotePageStyle.textInsets.top + NotePageStyle.lineHeight)
    }

    @Test func offscreenEngineMatchesLiveTextView() {
        let text = "One\nTwo is a longer paragraph that will need to wrap onto a second line at this width\n\nFour\n"
        let live = NotePageTextLayout.bandLayout(of: liveTextView(text))
        let engine = NotePageLayoutEngine().bandLayout(for: text)
        #expect(live == engine)
    }

    // MARK: Anchoring

    @Test func insertingAParagraphAboveMovesTheStrokeByTheInsertedHeight() {
        let engine = NotePageLayoutEngine()
        let before = "Alpha line\nBeta has the target word\nGamma"
        let layout0 = engine.bandLayout(for: before)
        var ink = NoteInk(layout: layout0)
        var baseline = CanvasBaseline()
        let drawn = Support.stroke(over: layout0.paragraphs[1])
        let changed = ink.applyCanvasDrawing(PKDrawing(strokes: [drawn]), baseline: &baseline)
        #expect(changed)
        #expect(ink.strokes.map(\.band) == [.paragraph(1)])
        let boundsBefore = ink.composedDrawing().strokes[0].renderBounds

        let after = "Inserted above\n" + before
        let layout1 = engine.bandLayout(for: after)
        let insertedHeight = layout1.paragraphs[1].top - layout1.paragraphs[0].top
        let moved = ink.relayout(to: layout1)
        #expect(moved)
        let boundsAfter = ink.composedDrawing().strokes[0].renderBounds
        #expect(ink.strokes.map(\.band) == [.paragraph(2)])
        #expect(abs((boundsAfter.minY - boundsBefore.minY) - insertedHeight) < 0.001)
        #expect(abs(boundsAfter.minX - boundsBefore.minX) < 0.001)
        #expect(insertedHeight == NotePageStyle.lineHeight + NotePageStyle.paragraphSpacing)
    }

    @Test func typingCharacterByCharacterAboveKeepsTheStrokeOnItsParagraph() {
        let engine = NotePageLayoutEngine()
        let original = "Beta has the target word\nGamma"
        var ink = NoteInk(layout: engine.bandLayout(for: original))
        var baseline = CanvasBaseline()
        _ = ink.applyCanvasDrawing(PKDrawing(strokes: [Support.stroke(over: ink.layout.paragraphs[0])]), baseline: &baseline)
        let start = ink.composedDrawing().strokes[0].renderBounds.minY
        // Typing "New⏎" at the start of the note, one keystroke at a time.
        for prefix in ["N", "Ne", "New", "New\n"] {
            ink.relayout(to: engine.bandLayout(for: prefix + original))
        }
        let moved = ink.composedDrawing().strokes[0].renderBounds.minY - start
        #expect(abs(moved - (NotePageStyle.lineHeight + NotePageStyle.paragraphSpacing)) < 0.001)
        #expect(ink.strokes[0].band == .paragraph(1))
    }

    @Test func deletedParagraphStrokesStayAndAttachToThePreviousParagraph() {
        let engine = NotePageLayoutEngine()
        let layout0 = engine.bandLayout(for: "One\nTwo\nThree")
        var ink = NoteInk(layout: layout0)
        var baseline = CanvasBaseline()
        let onTwo = Support.stroke(over: layout0.paragraphs[1])
        let onThree = Support.stroke(over: layout0.paragraphs[2], x: 30...90)
        _ = ink.applyCanvasDrawing(PKDrawing(strokes: [onTwo, onThree]), baseline: &baseline)
        let before = ink.composedDrawing().strokes.map(\.renderBounds)

        // Delete "Two".
        let layout1 = engine.bandLayout(for: "One\nThree")
        ink.relayout(to: layout1)
        let after = ink.composedDrawing().strokes.map(\.renderBounds)
        #expect(ink.strokes[0].band == .paragraph(0))  // attached to "One"
        #expect(abs(after[0].minY - before[0].minY) < 0.001)  // stays in place
        #expect(ink.strokes[1].band == .paragraph(1))  // "Three"
        let bandHeight = layout0.paragraphs[1].height
        #expect(abs((before[1].minY - after[1].minY) - bandHeight) < 0.001)  // moved up with "Three"

        // The orphaned stroke now follows "One" (its band was not re-derived from geometry).
        let layout2 = engine.bandLayout(for: "Zero\nOne\nThree")
        ink.relayout(to: layout2)
        let moved = ink.composedDrawing().strokes[0].renderBounds
        #expect(abs((moved.minY - after[0].minY) - (layout2.paragraphs[1].top - layout1.paragraphs[0].top)) < 0.001)
        #expect(ink.strokes[0].band == .paragraph(1))
    }

    @Test func emptyingTheTextKeepsEveryStroke() {
        let engine = NotePageLayoutEngine()
        let layout0 = engine.bandLayout(for: "One\nTwo")
        var ink = NoteInk(layout: layout0)
        var baseline = CanvasBaseline()
        let below = Support.stroke(from: CGPoint(x: 40, y: layout0.trailingTop + 80), to: CGPoint(x: 200, y: layout0.trailingTop + 90))
        _ = ink.applyCanvasDrawing(PKDrawing(strokes: [Support.stroke(over: layout0.paragraphs[1]), below]), baseline: &baseline)
        let before = ink.composedDrawing().strokes.map(\.renderBounds)
        #expect(ink.strokes.map(\.band) == [.paragraph(1), .trailing])

        let empty = engine.bandLayout(for: "")
        ink.relayout(to: empty)
        let after = ink.composedDrawing().strokes.map(\.renderBounds)
        #expect(ink.strokes.count == 2)
        #expect(abs(after[0].minY - before[0].minY) < 0.001)  // deleted paragraph: stays
        // The trailing band moves up with the end of the text.
        #expect(abs((before[1].minY - after[1].minY) - (layout0.trailingTop - empty.trailingTop)) < 0.001)
    }

    @Test func onlyNewOrEditedStrokesAreAnchoredByGeometry() {
        let engine = NotePageLayoutEngine()
        let layout0 = engine.bandLayout(for: "One\nTwo\nThree")
        var ink = NoteInk(layout: layout0)
        var baseline = CanvasBaseline()
        _ = ink.applyCanvasDrawing(PKDrawing(strokes: [Support.stroke(over: layout0.paragraphs[1])]), baseline: &baseline)
        // Delete "Two": the stroke now belongs to "One" although it lies over "Three"'s band.
        ink.relayout(to: engine.bandLayout(for: "One\nThree"))
        #expect(ink.strokes[0].band == .paragraph(0))

        // The canvas reports the unchanged stroke plus a new one: the old one keeps its band.
        var (drawing, displayBaseline) = ink.composedForDisplay()
        let fresh = Support.stroke(over: ink.layout.paragraphs[1], x: 150...220)
        drawing.strokes.append(fresh)
        let reported = ink.applyCanvasDrawing(drawing, baseline: &displayBaseline)
        #expect(reported)
        #expect(ink.strokes.map(\.band) == [.paragraph(0), .paragraph(1)])

        // A lasso move (transform change) re-anchors the moved stroke by geometry.
        var moved = drawing.strokes
        moved[0].transform = moved[0].transform.translatedBy(x: 5, y: 0)
        let lassoed = ink.applyCanvasDrawing(PKDrawing(strokes: moved), baseline: &displayBaseline)
        #expect(lassoed)
        #expect(ink.strokes[0].band == ink.layout.band(for: moved[0].renderBounds))

        // Erasing removes the stroke.
        let erased = ink.applyCanvasDrawing(PKDrawing(strokes: [moved[1]]), baseline: &displayBaseline)
        #expect(erased)
        #expect(ink.strokes.count == 1)
    }

    @Test func canvasHandsBackStrokesItWasGivenUnchanged() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        let engine = NotePageLayoutEngine()
        let layout = engine.bandLayout(for: "One\nTwo")
        var ink = NoteInk(layout: layout)
        var baseline = CanvasBaseline()
        _ = ink.applyCanvasDrawing(PKDrawing(strokes: [Support.stroke(over: layout.paragraphs[0]),
                                                      Support.stroke(over: layout.paragraphs[1], x: 10...300)]),
                                   baseline: &baseline)
        ink.relayout(to: engine.bandLayout(for: "Zero\nOne\nTwo"))
        let (drawing, displayBaseline) = ink.composedForDisplay()
        canvas.drawing = drawing
        var check = displayBaseline
        var copy = ink
        let changed = copy.applyCanvasDrawing(canvas.drawing, baseline: &check)
        #expect(!changed)
        #expect(canvas.drawing.strokes.map(StrokeFingerprint.init) == drawing.strokes.map(StrokeFingerprint.init))
    }

    @Test func spanningStrokeBelongsToTheBandItOverlapsMost() {
        let engine = NotePageLayoutEngine()
        let layout = engine.bandLayout(for: "One\nTwo\nThree")
        var ink = NoteInk(layout: layout)
        var baseline = CanvasBaseline()
        // From the middle of "One" to well into "Two": mostly over "Two".
        let spanning = Support.stroke(from: CGPoint(x: 20, y: layout.paragraphs[0].top + 18),
                                      to: CGPoint(x: 60, y: layout.paragraphs[1].bottom - 2))
        _ = ink.applyCanvasDrawing(PKDrawing(strokes: [spanning]), baseline: &baseline)
        #expect(ink.strokes[0].band == .paragraph(1))
    }
}
