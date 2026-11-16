import PencilKit

/// Reconciling one page's ink between windows (design: "The same book in two windows stays
/// consistent"; a surface mid-stroke is never overwritten).
///
/// The three-way merge is `StrokeMerge`, the same implementation note ink uses. Page ink has no
/// bands, so strokes are compared with their full transform (`StrokeFingerprint`).
nonisolated enum PageInkMerge {
    static func merge(local: PKDrawing, remote: PKDrawing, base: PKDrawing?) -> PKDrawing {
        PKDrawing(strokes: merge(local: local.strokes, remote: remote.strokes, base: base?.strokes))
    }

    static func merge(local: [PKStroke], remote: [PKStroke], base: [PKStroke]?) -> [PKStroke] {
        StrokeMerge.merge(local: local, remote: remote, base: base, stroke: { $0 }, content: StrokeFingerprint.init)
    }

    /// Whether two drawings hold the same strokes (same identities and placed content) in the
    /// same order.
    static func sameStrokes(_ a: PKDrawing, _ b: PKDrawing) -> Bool {
        sameStrokes(a.strokes, b.strokes)
    }

    static func sameStrokes(_ a: [PKStroke], _ b: [PKStroke]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { StrokeFingerprint($0) == StrokeFingerprint($1) }
    }
}
