import Foundation
import PencilKit
import ReaderCore

// MARK: - Anchored strokes

/// One stroke of a note's ink, anchored to a band of the note's band layout.
///
/// `local` is the PencilKit stroke in **band-local coordinates** (see `NoteBands`): its rendered
/// note-page position is `local` translated down by `layout.top(of: band)`. `uid` is an
/// in-memory identity (not persisted) used to recognise the stroke when the canvas hands its
/// drawing back.
nonisolated struct NoteInkStroke: Sendable {
    var uid: UUID
    var band: NoteBandRef
    var local: PKStroke

    init(uid: UUID = UUID(), band: NoteBandRef, local: PKStroke) {
        self.uid = uid
        self.band = band
        self.local = local
    }
}

/// A note's ink: strokes anchored to bands of `layout`, in z-order (first is drawn first).
///
/// **Anchoring rules (design: "Ink follows the text it annotates"):**
/// - A stroke's band is decided only when the stroke is new or edited (drawn, moved or resized
///   by the lasso, recoloured, split or masked by the eraser): `layout.band(for: renderBounds)`.
/// - After every text change the editor calls `relayout(to:)`, which moves every stroke with its
///   band (`NoteBands.relocate`): a deleted paragraph's strokes stay in place, attached to the
///   paragraph before it.
/// - `composedDrawing()` is what the canvas shows: each stroke translated to its band's top.
nonisolated struct NoteInk: Sendable {
    /// The layout `strokes`' band references point into.
    var layout: NoteBandLayout
    /// Strokes in z-order.
    var strokes: [NoteInkStroke]

    init(layout: NoteBandLayout, strokes: [NoteInkStroke] = []) {
        self.layout = layout
        self.strokes = strokes
    }

    var isEmpty: Bool { strokes.isEmpty }

    /// The stroke as drawn on the note page under the current layout.
    func pageStroke(_ stroke: NoteInkStroke) -> PKStroke {
        stroke.local.translatedVertically(by: layout.top(of: stroke.band) ?? 0)
    }

    /// The drawing in note-page coordinates.
    func composedDrawing() -> PKDrawing {
        PKDrawing(strokes: strokes.map(pageStroke))
    }

    /// Bottom of the lowest stroke in note-page coordinates (0 without ink).
    var pageBottom: CGFloat {
        strokes.reduce(0) { max($0, pageStroke($1).renderBounds.maxY) }
    }

    /// Moves every stroke from `layout` to `newLayout` (`NoteBands.relocate`) and adopts it.
    /// - Returns: `true` if any stroke's position on the page changed.
    @discardableResult
    mutating func relayout(to newLayout: NoteBandLayout) -> Bool {
        guard newLayout != layout else { return false }
        let relocation = NoteBands.relocate(from: layout, to: newLayout)
        var moved = false
        for index in strokes.indices {
            let stroke = strokes[index]
            if let move = relocation.move(for: stroke.band) {
                if move.localOffset != 0 {
                    strokes[index].local = stroke.local.translatedVertically(by: move.localOffset)
                }
                strokes[index].band = move.destination
                if move.deltaY != 0 { moved = true }
            } else {
                // A band reference outside the old layout (only from damaged data): keep the
                // stroke's page position and anchor it by geometry.
                let page = stroke.local.translatedVertically(by: layout.top(of: stroke.band) ?? 0)
                let band = newLayout.band(for: page.renderBounds)
                strokes[index].band = band
                strokes[index].local = page.translatedVertically(by: -(newLayout.top(of: band) ?? 0))
                moved = true
            }
        }
        layout = newLayout
        return moved
    }

    /// A copy moved to `newLayout`.
    func relaid(to newLayout: NoteBandLayout) -> NoteInk {
        var copy = self
        copy.relayout(to: newLayout)
        return copy
    }

    /// Adopts the drawing the canvas reports after a user change.
    ///
    /// Strokes whose fingerprint matches a stroke the canvas was last given (`baseline`) keep
    /// their band and band-local stroke; every other stroke is new or edited and is anchored by
    /// geometry in the current layout. Strokes missing from the canvas were erased or replaced.
    /// The canvas's order becomes the z-order. `baseline` is updated to the canvas's strokes.
    /// - Returns: `true` if the ink changed.
    mutating func applyCanvasDrawing(_ drawing: PKDrawing, baseline: inout CanvasBaseline) -> Bool {
        var pool = baseline.entries
        var byUID: [UUID: NoteInkStroke] = [:]
        for stroke in strokes { byUID[stroke.uid] = stroke }
        var result: [NoteInkStroke] = []
        var next = CanvasBaseline()
        var changed = false
        for pageStroke in drawing.strokes {
            let fingerprint = StrokeFingerprint(pageStroke)
            if var candidates = pool[fingerprint], !candidates.isEmpty {
                let uid = candidates.removeFirst()
                pool[fingerprint] = candidates
                if let existing = byUID.removeValue(forKey: uid) {
                    result.append(existing)
                    next.add(fingerprint, uid)
                    continue
                }
            }
            let band = layout.band(for: pageStroke.renderBounds)
            let local = pageStroke.translatedVertically(by: -(layout.top(of: band) ?? 0))
            let stroke = NoteInkStroke(band: band, local: local)
            result.append(stroke)
            next.add(fingerprint, stroke.uid)
            changed = true
        }
        if result.count != strokes.count || zip(result, strokes).contains(where: { $0.uid != $1.uid }) {
            changed = true
        }
        strokes = result
        baseline = next
        return changed
    }

    /// The composed drawing plus the baseline that recognises its strokes when the canvas hands
    /// them back.
    func composedForDisplay() -> (drawing: PKDrawing, baseline: CanvasBaseline) {
        var baseline = CanvasBaseline()
        var pageStrokes: [PKStroke] = []
        pageStrokes.reserveCapacity(strokes.count)
        for stroke in strokes {
            let page = pageStroke(stroke)
            pageStrokes.append(page)
            baseline.add(StrokeFingerprint(page), stroke.uid)
        }
        return (PKDrawing(strokes: pageStrokes), baseline)
    }

    /// Whether two inks hold the same strokes (same band-local content, bands and order) against
    /// equal layouts.
    func isEquivalent(to other: NoteInk) -> Bool {
        guard layout == other.layout, strokes.count == other.strokes.count else { return false }
        return zip(strokes, other.strokes).allSatisfy {
            $0.band == $1.band && StrokeFingerprint($0.local) == StrokeFingerprint($1.local)
        }
    }

    // MARK: Merge

    /// Three-way merge of two edits of the same note's ink (multi-window reconcile, and the
    /// union of a backup merge when `base` is `nil`).
    ///
    /// `remote` is relocated into `local.layout` first. The rule and the stroke order are
    /// `StrokeMerge`'s, shared with page ink: the remote order first, local-only strokes on top.
    /// Strokes are compared by `StrokeContent` of the band-local stroke, so a move caused by
    /// relocation alone is not an edit. A stroke taken from `remote` gets a new `uid`.
    static func merge(local: NoteInk, remote: NoteInk, base: NoteInk?) -> NoteInk {
        let remote = remote.relaid(to: local.layout)
        let strokes = StrokeMerge.merge(
            local: local.strokes, remote: remote.strokes, base: base?.strokes,
            stroke: \.local,
            content: { StrokeContent($0.local) },
            adoptRemote: { NoteInkStroke(band: $0.band, local: $0.local) })
        return NoteInk(layout: local.layout, strokes: strokes)
    }
}

/// Fingerprints of the strokes last handed to the canvas, mapped to the strokes' `uid`s.
nonisolated struct CanvasBaseline: Sendable {
    fileprivate(set) var entries: [StrokeFingerprint: [UUID]] = [:]

    init() {}

    fileprivate mutating func add(_ fingerprint: StrokeFingerprint, _ uid: UUID) {
        entries[fingerprint, default: []].append(uid)
    }

    var count: Int { entries.values.reduce(0) { $0 + $1.count } }
}

// MARK: - Stroke keys

/// Quantises a coordinate so values that went through PencilKit unchanged compare equal.
nonisolated private func quantise(_ value: CGFloat) -> Int64 {
    guard value.isFinite else { return Int64.min }
    return Int64((value * 4096).rounded())
}

/// Content fingerprint of a stroke as placed (ink, colour, path, transform, mask): equal for a
/// stroke the canvas hands back unchanged, different after any edit (move, resize, recolour,
/// erase).
nonisolated struct StrokeFingerprint: Hashable, Sendable {
    let identity: StrokeIdentity
    let content: StrokeContent
    let ty: Int64

    init(_ stroke: PKStroke) {
        identity = StrokeIdentity(stroke)
        content = StrokeContent(stroke)
        ty = quantise(stroke.transform.ty)
    }
}

/// Identity of a stroke that survives moves, recolouring and relocation: when it was made, its
/// random seed, and its path in path coordinates.
nonisolated struct StrokeIdentity: Hashable, Sendable {
    let created: Int64
    let pointCount: Int
    let randomSeed: UInt32
    let first: [Int64]
    let last: [Int64]

    init(_ stroke: PKStroke) {
        let path = stroke.path
        created = Int64((path.creationDate.timeIntervalSinceReferenceDate * 1_000_000).rounded())
        pointCount = path.count
        randomSeed = stroke.randomSeed
        if let firstPoint = path.first, let lastPoint = path.last {
            first = [quantise(firstPoint.location.x), quantise(firstPoint.location.y)]
            last = [quantise(lastPoint.location.x), quantise(lastPoint.location.y)]
        } else {
            first = []
            last = []
        }
    }
}

/// Everything about a stroke's appearance except its vertical translation (`transform.ty`, which
/// relocation changes): used to tell an edited stroke from an unchanged one when merging.
nonisolated struct StrokeContent: Hashable, Sendable {
    let identity: StrokeIdentity
    let inkType: String
    let color: [Int64]
    let transform: [Int64]
    let mask: [Int64]

    init(_ stroke: PKStroke) {
        identity = StrokeIdentity(stroke)
        inkType = stroke.ink.inkType.rawValue
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        if stroke.ink.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            color = [red, green, blue, alpha].map { Int64(($0 * 1000).rounded()) }
        } else {
            color = []
        }
        let t = stroke.transform
        transform = [t.a, t.b, t.c, t.d, t.tx].map(quantise)
        if let bounds = stroke.mask?.bounds {
            mask = [bounds.minX, bounds.minY, bounds.width, bounds.height].map(quantise)
        } else {
            mask = []
        }
    }
}

nonisolated struct StrokeKey: Hashable, Sendable {
    let identity: StrokeIdentity
    let occurrence: Int
}

extension PKStroke {
    /// The stroke moved down by `dy` (applied after its own transform).
    nonisolated func translatedVertically(by dy: CGFloat) -> PKStroke {
        guard dy != 0 else { return self }
        var copy = self
        copy.transform = transform.concatenating(CGAffineTransform(translationX: 0, y: dy))
        return copy
    }
}
