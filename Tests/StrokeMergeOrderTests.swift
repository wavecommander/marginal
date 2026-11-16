import Foundation
import PencilKit
import ReaderCore
import Testing
import UIKit
@testable import Marginal

/// Page ink (`PageInkMerge`) and note ink (`NoteInk.merge`) share one three-way merge
/// (`StrokeMerge`). These tests pin the stroke order it produces, which is the z-order: the
/// remote (stored) order first, then the strokes only the local side has, on top.
@MainActor
struct StrokeMergeOrderTests {
    private func line(_ y: CGFloat) -> PKStroke {
        PageInkTestSupport.stroke(from: CGPoint(x: 50, y: y), to: CGPoint(x: 300, y: y + 4))
    }

    private func ids(_ strokes: [PKStroke]) -> [StrokeIdentity] { strokes.map(StrokeIdentity.init) }

    /// The same strokes as note ink: each in the trailing band of `layout`.
    private func noteInk(_ strokes: [PKStroke], layout: NoteBandLayout) -> NoteInk {
        NoteInk(layout: layout, strokes: strokes.map { NoteInkStroke(band: .trailing, local: $0) })
    }

    private var layout: NoteBandLayout { NotePageLayoutEngine().bandLayout(for: "One\nTwo") }

    /// Base [a, b]. The other side reordered them and added r; this side added l1 then l2.
    private struct Scenario {
        let a, b, r, l1, l2: PKStroke
        var base: [PKStroke] { [a, b] }
        var local: [PKStroke] { [a, b, l1, l2] }
        var remote: [PKStroke] { [b, a, r] }
        var expected: [PKStroke] { [b, a, r, l1, l2] }
    }

    private func scenario() -> Scenario {
        Scenario(a: line(10), b: line(20), r: line(30), l1: line(40), l2: line(50))
    }

    @Test func pageInkKeepsTheStoredOrderWithLocalAdditionsOnTop() throws {
        let s = scenario()
        let merged = PageInkMerge.merge(local: PKDrawing(strokes: s.local), remote: PKDrawing(strokes: s.remote),
                                        base: PKDrawing(strokes: s.base))
        #expect(ids(merged.strokes) == ids(s.expected))
        // No local change: exactly the stored drawing, in its order.
        #expect(ids(PageInkMerge.merge(local: s.base, remote: s.remote, base: s.base)) == ids(s.remote))
        // No base: the union, remote order first.
        #expect(ids(PageInkMerge.merge(local: [s.l1, s.a], remote: [s.a, s.r], base: nil)) == ids([s.a, s.r, s.l1]))
        // Saved and read back, the merged drawing is unchanged.
        let decoded = try PKDrawing(data: merged.dataRepresentation())
        #expect(PageInkMerge.sameStrokes(decoded, merged))
    }

    @Test func noteInkKeepsTheStoredOrderWithLocalAdditionsOnTop() throws {
        let s = scenario()
        let layout = layout
        let merged = NoteInk.merge(local: noteInk(s.local, layout: layout), remote: noteInk(s.remote, layout: layout),
                                   base: noteInk(s.base, layout: layout))
        #expect(ids(merged.strokes.map(\.local)) == ids(s.expected))
        let unchanged = NoteInk.merge(local: noteInk(s.base, layout: layout), remote: noteInk(s.remote, layout: layout),
                                      base: noteInk(s.base, layout: layout))
        #expect(ids(unchanged.strokes.map(\.local)) == ids(s.remote))
        let union = NoteInk.merge(local: noteInk([s.l1, s.a], layout: layout), remote: noteInk([s.a, s.r], layout: layout),
                                  base: nil)
        #expect(ids(union.strokes.map(\.local)) == ids([s.a, s.r, s.l1]))
        let decoded = try NoteInkArchive.decode(try NoteInkArchive.encode(merged), fallbackLayout: layout)
        #expect(decoded.isEquivalent(to: merged))
    }

    @Test func pageAndNoteInkMergeAlike() {
        let s = scenario()
        let layout = layout
        // Edits too: b recoloured remotely, a moved locally, r erased locally after a first merge.
        var bRecoloured = s.b
        bRecoloured.ink = PKInk(.pen, color: .systemOrange)
        var aMoved = s.a
        aMoved.transform = CGAffineTransform(translationX: 7, y: 0)
        let local = [aMoved, s.b, s.l1], remote = [s.r, bRecoloured, s.a], base = [s.a, s.b]
        let page = PageInkMerge.merge(local: local, remote: remote, base: base)
        let note = NoteInk.merge(local: noteInk(local, layout: layout), remote: noteInk(remote, layout: layout),
                                 base: noteInk(base, layout: layout))
        #expect(ids(page) == ids([s.r, bRecoloured, aMoved, s.l1]))
        #expect(ids(note.strokes.map(\.local)) == ids(page))
        #expect(page.map(StrokeFingerprint.init) == note.strokes.map { StrokeFingerprint($0.local) })
    }
}
