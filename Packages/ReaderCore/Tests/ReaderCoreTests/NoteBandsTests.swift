import Foundation
import CoreGraphics
import Testing
@testable import ReaderCore

/// Stacks paragraph bands from y = 8 (the text container's top inset).
func layout(_ paragraphs: [(String, CGFloat)], top: CGFloat = 8) -> NoteBandLayout {
    var y = top
    var bands: [NoteParagraphBand] = []
    for (text, height) in paragraphs {
        bands.append(NoteParagraphBand(text: text, top: y, height: height))
        y += height
    }
    return NoteBandLayout(pageWidth: 320, paragraphs: bands, trailingTop: y)
}

/// Applies a relocation to a stroke stored band-local against `saved`; returns its new band and
/// its rect in note-page coordinates of `current`.
func move(_ pageRect: CGRect, from saved: NoteBandLayout, to current: NoteBandLayout) -> (NoteBandRef, CGRect) {
    let band = saved.band(for: pageRect)
    let local = saved.localRect(pageRect, in: band)
    let move = NoteBands.relocate(from: saved, to: current).move(for: band)!
    let newLocal = local.offsetBy(dx: 0, dy: move.localOffset)
    let newPage = current.pageRect(newLocal, in: move.destination)
    #expect(newPage.minY == pageRect.minY + move.deltaY)   // deltaY agrees with localOffset
    return (move.destination, newPage)
}

@Suite("NoteBands")
struct NoteBandsTests {
    let stroke = CGRect(x: 40, y: 30, width: 60, height: 10)   // over the second paragraph below

    @Test func paragraphsOfText() {
        #expect(NoteBandLayout.paragraphs(of: "") == [""])
        #expect(NoteBandLayout.paragraphs(of: "a\n") == ["a", ""])
        #expect(NoteBandLayout.paragraphs(of: "a\r\nb\rc\u{2029}d\u{2028}e") == ["a", "b", "c", "d\u{2028}e"])
    }

    @Test func paragraphGrowsAboveAMarkedBand() {
        let saved = layout([("Hello", 20), ("World", 20)])
        let current = layout([("Hello there, this paragraph now wraps onto three lines", 60), ("World", 20)])
        let relocation = NoteBands.relocate(from: saved, to: current)
        #expect(relocation.paragraphs[0].fate == .edited)
        #expect(relocation.paragraphs[0].deltaY == 0)
        #expect(relocation.paragraphs[1].fate == .unchanged)
        #expect(relocation.paragraphs[1].deltaY == 40)
        #expect(relocation.trailing.deltaY == 40)
        let (band, rect) = move(stroke, from: saved, to: current)
        #expect(band == .paragraph(1))
        #expect(rect == stroke.offsetBy(dx: 0, dy: 40))
    }

    @Test func rewrappingInsideAParagraphDoesNotMoveItsOwnStrokes() {
        let saved = layout([("Hello", 20), ("World", 20)])
        let current = layout([("Hello", 20), ("World, now much longer and wrapping", 40)])
        let (band, rect) = move(stroke, from: saved, to: current)
        #expect(band == .paragraph(1))
        #expect(rect == stroke)
    }

    @Test func paragraphIsDeleted() {
        let saved = layout([("A", 20), ("B", 20), ("C", 20)])   // A 8-28, B 28-48, C 48-68
        let current = layout([("A", 20), ("C", 20)])
        let relocation = NoteBands.relocate(from: saved, to: current)
        #expect(relocation.paragraphs[1] == NoteBandMove(source: .paragraph(1), destination: .paragraph(0),
                                                        localOffset: 20, deltaY: 0, fate: .deleted))
        #expect(relocation.paragraphs[2].destination == .paragraph(1))
        #expect(relocation.paragraphs[2].deltaY == -20)
        // B's strokes stay in place, now attached to A...
        let (band, rect) = move(stroke, from: saved, to: current)
        #expect(band == .paragraph(0))
        #expect(rect == stroke)
        // ...so when A later grows, they move with A.
        let grown = layout([("A, longer", 40), ("C", 20)])
        let local = current.localRect(rect, in: band)
        let next = NoteBands.relocate(from: current, to: grown).move(for: band)!
        #expect(next.destination == .paragraph(0))
        #expect(grown.pageRect(local.offsetBy(dx: 0, dy: next.localOffset), in: next.destination) == rect)
        let pushed = layout([("New first", 30), ("A", 20), ("C", 20)])
        let push = NoteBands.relocate(from: current, to: pushed).move(for: band)!
        #expect(push.destination == .paragraph(1) && push.deltaY == 30)
    }

    @Test func firstParagraphIsDeleted() {
        let saved = layout([("A", 20), ("B", 20)])
        let current = layout([("B", 20)])
        let move = NoteBands.relocate(from: saved, to: current).paragraphs[0]
        #expect(move == NoteBandMove(source: .paragraph(0), destination: .paragraph(0), localOffset: 0, deltaY: 0, fate: .deleted))
    }

    @Test func paragraphIsInserted() {
        let saved = layout([("A", 20), ("B", 20)])
        let current = layout([("A", 20), ("Inserted", 40), ("B", 20)])
        #expect(NoteBands.matchParagraphs(saved: ["A", "B"], current: ["A", "Inserted", "B"]) == [0, 2])
        let (band, rect) = move(stroke, from: saved, to: current)
        #expect(band == .paragraph(2))
        #expect(rect == stroke.offsetBy(dx: 0, dy: 40))
    }

    @Test func textIsEmptied() {
        let saved = layout([("A", 20), ("B", 20)])
        let sketch = CGRect(x: 10, y: 60, width: 100, height: 80)    // below the text
        // The editor still lays out one empty paragraph for empty text.
        let current = layout([("", 20)])
        let relocation = NoteBands.relocate(from: saved, to: current)
        #expect(relocation.paragraphs.map(\.fate) == [.deleted, .deleted])
        #expect(relocation.paragraphs.map(\.deltaY) == [0, 0])          // ink over the text stays put
        #expect(move(stroke, from: saved, to: current).1 == stroke)
        let (sketchBand, sketchRect) = move(sketch, from: saved, to: current)
        #expect(sketchBand == .trailing)
        #expect(sketchRect == sketch.offsetBy(dx: 0, dy: -20))          // the blank-space band follows the text end

        // A layout with no paragraph bands at all.
        let bare = NoteBandLayout(pageWidth: 320, paragraphs: [], trailingTop: 8)
        let bareMove = NoteBands.relocate(from: saved, to: bare).paragraphs[1]
        #expect(bareMove.destination == .trailing && bareMove.deltaY == 0 && bareMove.localOffset == 20)
        #expect(bare.band(for: stroke) == .trailing)
    }

    @Test func fontMetricChangeShiftsBands() {
        let saved = layout([("A", 20), ("B", 20), ("C", 20)])
        let current = layout([("A", 22), ("B", 22), ("C", 22)], top: 10)
        let relocation = NoteBands.relocate(from: saved, to: current)
        #expect(relocation.paragraphs.map(\.fate) == [.unchanged, .unchanged, .unchanged])
        #expect(relocation.paragraphs.map(\.deltaY) == [2, 4, 6])
        #expect(relocation.trailing.deltaY == 8)
    }

    @Test func strokeSpanningTwoBandsGoesToTheLargerOverlap() {
        let bands = layout([("A", 20), ("B", 20)])   // A [8,28), B [28,48)
        #expect(bands.band(for: CGRect(x: 0, y: 20, width: 50, height: 12)) == .paragraph(0))   // 8 vs 4
        #expect(bands.band(for: CGRect(x: 0, y: 24, width: 50, height: 12)) == .paragraph(1))   // 4 vs 8
        #expect(bands.band(for: CGRect(x: 0, y: 22, width: 50, height: 12)) == .paragraph(0))   // tie: upper
        #expect(bands.band(for: CGRect(x: 0, y: 0, width: 50, height: 100)) == .trailing)      // 20, 20, 52
    }

    @Test func strokeWhollyBelowTheText() {
        let bands = layout([("A", 20), ("B", 20)])   // trailing from 48
        #expect(bands.band(for: CGRect(x: 0, y: 48, width: 50, height: 5)) == .trailing)
        #expect(bands.band(for: CGRect(x: 0, y: 300, width: 50, height: 50)) == .trailing)
        #expect(bands.band(for: CGRect(x: 0, y: 40, width: 50, height: 30)) == .trailing)   // mostly below
    }

    @Test func degenerateStrokes() {
        var bands = layout([("A", 20), ("B", 20)])
        #expect(bands.band(for: CGRect(x: 0, y: 30, width: 50, height: 0)) == .paragraph(1))  // a flat line
        #expect(bands.band(for: CGRect(x: 0, y: 2, width: 5, height: 3)) == .paragraph(0))    // above the inset
        bands.paragraphs[1].top = 40                                                        // gap 28..40
        bands.paragraphs[1].height = 8
        #expect(bands.band(for: CGRect(x: 0, y: 30, width: 5, height: 0)) == .paragraph(0))   // nearer A
        #expect(bands.band(for: CGRect(x: 0, y: 37, width: 5, height: 0)) == .paragraph(1))   // nearer B
        #expect(bands.band(for: .null) == .trailing)
    }

    @Test func coordinateConversions() {
        let bands = layout([("A", 20), ("B", 20)])
        #expect(bands.localRect(stroke, in: .paragraph(1)) == CGRect(x: 40, y: 2, width: 60, height: 10))
        #expect(bands.pageRect(CGRect(x: 40, y: 2, width: 60, height: 10), in: .paragraph(1)) == stroke)
        #expect(bands.localRect(stroke, in: .trailing).minY == CGFloat(-18))
        #expect(bands.top(of: .paragraph(5)) == nil)
    }

    @Test func paragraphMatching() {
        #expect(NoteBands.matchParagraphs(saved: ["a", "b", "c"], current: ["a", "c"]) == [0, nil, 1])
        #expect(NoteBands.matchParagraphs(saved: ["a", "b", "c"], current: ["a", "B!", "c"]) == [0, 1, 2])
        #expect(NoteBands.matchParagraphs(saved: ["Hello world"], current: ["Hello world, and more", "New"]) == [0])
        #expect(NoteBands.matchParagraphs(saved: ["Old one", "keep"], current: ["New", "Brand", "keep"]) == [nil, 2])
        #expect(NoteBands.matchParagraphs(saved: ["Hello world"], current: ["Hello", " world"]) == [1])     // 6/11 beats 5/11
        #expect(NoteBands.matchParagraphs(saved: ["Hello world"], current: ["Hello ", "world"]) == [0])
        #expect(NoteBands.matchParagraphs(saved: ["", "x"], current: [""]) == [0, nil])
        #expect(NoteBands.matchParagraphs(saved: ["x", "x"], current: ["x"]) == [0, nil])
        #expect(NoteBands.matchParagraphs(saved: [], current: ["a"]) == [])
        #expect(NoteBands.matchParagraphs(saved: ["a"], current: []) == [nil])
        #expect(NoteBands.similarity("Hello", "Hello there") == 1)
        #expect(NoteBands.similarity("", "x") == 0)
    }

    @Test func layoutIsCodable() throws {
        let saved = layout([("A", 20.5), ("B", 20)])
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(NoteBandLayout.self, from: data) == saved)
    }
}
