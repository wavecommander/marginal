import Foundation
import CoreGraphics

// MARK: - Coordinate conventions
//
// *Note-page coordinates*: origin at the top-left of the note page, x to the right, y downward,
// in logical points at 100% zoom (the fixed ~320 pt wide page, before any zoom transform). This
// is the coordinate space of the note's text view and of the canvas laid over it.
//
// *Band-local coordinates*: x is the same as note-page x; y is measured from the top of the band
// (`localY = pageY - band.top`). A stroke stored band-local moves with its band.
//
// A stroke's band is decided once, when it is created or edited (moved by the lasso, erased in
// part, recoloured), from its bounds in note-page coordinates (`NoteBandLayout.band(for:)`).
// Unchanged strokes keep their band through text edits; only `NoteBands.relocate` moves them.
// Re-deriving every stroke's band from geometry after a text edit would break the rule that a
// deleted paragraph's strokes stay attached to the paragraph before it.

/// Which band of a layout a stroke belongs to.
public enum NoteBandRef: Hashable, Sendable, Codable {
    /// The paragraph band at this index of `NoteBandLayout.paragraphs`.
    case paragraph(Int)
    /// The blank space after the text: from `NoteBandLayout.trailingTop` downward, unbounded.
    case trailing
}

/// One paragraph's band: the vertical strip of the note page its line fragments occupy.
public struct NoteParagraphBand: Hashable, Sendable, Codable {
    /// The paragraph's text without its terminating newline (an element of
    /// `NoteBandLayout.paragraphs(of:)`). This is the paragraph's identity for matching across
    /// edits; no editor-maintained IDs are needed.
    public var text: String
    /// Top of the band in note-page coordinates.
    public var top: CGFloat
    /// Height of the band (the paragraph's line fragments plus its paragraph spacing).
    public var height: CGFloat

    public init(text: String, top: CGFloat, height: CGFloat) {
        self.text = text
        self.top = top
        self.height = height
    }

    /// `top + height`.
    public var bottom: CGFloat { top + height }
}

/// The band layout of a note page: one band per paragraph, top to bottom, plus the trailing
/// blank band. Saved with the note (`Note.bandLayout`) whenever its ink is saved, so stored ink
/// can be placed against the current text later.
///
/// **Construction rule (WP13):** `paragraphs[i]` describes the i-th element of
/// `paragraphs(of: text)`, in order, with `top`/`height` from the text layout (TextKit's
/// paragraph rects). Bands should be ordered and non-overlapping. `trailingTop` is where the
/// blank space after the text begins, normally `paragraphs.last!.bottom` (or the text
/// container's top inset when there are no paragraphs).
public struct NoteBandLayout: Hashable, Sendable, Codable {
    /// Logical width of the note page the layout was made at (for sanity checks; ink x is never
    /// rescaled).
    public var pageWidth: CGFloat
    /// Paragraph bands, top to bottom.
    public var paragraphs: [NoteParagraphBand]
    /// Top of the trailing blank band.
    public var trailingTop: CGFloat

    public init(pageWidth: CGFloat, paragraphs: [NoteParagraphBand], trailingTop: CGFloat) {
        self.pageWidth = pageWidth
        self.paragraphs = paragraphs
        self.trailingTop = trailingTop
    }

    /// Splits note text into paragraphs the way TextKit does for plain text: on `"\n"`, `"\r\n"`,
    /// `"\r"` and U+2029. Always returns at least one element: `""` → `[""]`, `"a\n"` → `["a", ""]`
    /// (TextKit lays out an extra empty line fragment after a final newline). U+2028 (line
    /// separator) does not end a paragraph.
    public static func paragraphs(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            if character == "\n" || character == "\r\n" || character == "\r" || character == "\u{2029}" {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }

    /// The top of a band in note-page coordinates, or `nil` for a paragraph index out of range.
    public func top(of band: NoteBandRef) -> CGFloat? {
        switch band {
        case .trailing: return trailingTop
        case .paragraph(let index): return paragraphs.indices.contains(index) ? paragraphs[index].top : nil
        }
    }

    /// The band a stroke belongs to, from its bounds in note-page coordinates.
    ///
    /// **Rule:**
    /// 1. No paragraphs, or `bounds.minY >= trailingTop` (wholly below the text) → `.trailing`.
    /// 2. Otherwise the band with the largest vertical overlap with `bounds`, the trailing band
    ///    counting as `[trailingTop, +∞)`. Ties go to the upper band.
    /// 3. If no band overlaps (a zero-height stroke, or one lying in a gap between bands or
    ///    above the first band): the band containing `bounds.midY` (half-open `[top, bottom)`),
    ///    else the band nearest to `midY`, ties to the upper band.
    public func band(for bounds: CGRect) -> NoteBandRef {
        guard !paragraphs.isEmpty, !bounds.isNull else { return .trailing }
        if bounds.minY >= trailingTop { return .trailing }

        var best: NoteBandRef?
        var bestOverlap: CGFloat = 0
        func consider(_ ref: NoteBandRef, top: CGFloat, bottom: CGFloat) {
            let overlap = min(bounds.maxY, bottom) - max(bounds.minY, top)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = ref
            }
        }
        for (index, band) in paragraphs.enumerated() {
            consider(.paragraph(index), top: band.top, bottom: band.bottom)
        }
        consider(.trailing, top: trailingTop, bottom: .greatestFiniteMagnitude)
        if let best { return best }

        let y = bounds.midY
        if y >= trailingTop { return .trailing }
        var nearest: NoteBandRef = .trailing
        var nearestDistance = trailingTop - y
        for (index, band) in paragraphs.enumerated() {
            if y >= band.top && y < band.bottom { return .paragraph(index) }
            let distance = y < band.top ? band.top - y : y - band.bottom
            if distance < nearestDistance || (distance == nearestDistance && nearest == .trailing) {
                nearestDistance = distance
                nearest = .paragraph(index)
            }
        }
        return nearest
    }

    /// Converts a rect from note-page to band-local coordinates (`y - top(of: band)`).
    /// An out-of-range paragraph index leaves the rect unchanged.
    public func localRect(_ pageRect: CGRect, in band: NoteBandRef) -> CGRect {
        pageRect.offsetBy(dx: 0, dy: -(top(of: band) ?? 0))
    }

    /// Converts a rect from band-local to note-page coordinates (`y + top(of: band)`).
    /// An out-of-range paragraph index leaves the rect unchanged.
    public func pageRect(_ localRect: CGRect, in band: NoteBandRef) -> CGRect {
        localRect.offsetBy(dx: 0, dy: top(of: band) ?? 0)
    }
}

/// Where one band of the saved layout goes in the current layout.
public struct NoteBandMove: Hashable, Sendable {
    /// What happened to the saved band's paragraph.
    public enum Fate: Hashable, Sendable {
        /// The paragraph still exists with identical text.
        case unchanged
        /// The paragraph still exists but its text was edited (see `NoteBands.matchParagraphs`).
        case edited
        /// The paragraph was deleted; its strokes now belong to `destination`, the band of the
        /// nearest earlier surviving paragraph (or the first/trailing band if none survives).
        case deleted
        /// The trailing blank band (always maps to the current trailing band).
        case trailing
    }

    /// The band in the saved layout.
    public let source: NoteBandRef
    /// The band in the current layout the strokes now belong to.
    public let destination: NoteBandRef
    /// Add to a stroke's band-local y (relative to `source` in the saved layout) to get its
    /// band-local y relative to `destination` in the current layout. `0` unless `.deleted`.
    public let localOffset: CGFloat
    /// Add to a stroke's note-page y as laid out by the saved layout to get its note-page y in
    /// the current layout. Equals `current.top(destination) + localOffset - saved.top(source)`.
    public let deltaY: CGFloat
    public let fate: Fate
}

/// The result of `NoteBands.relocate`: one move per saved band.
public struct NoteBandRelocation: Hashable, Sendable {
    /// `paragraphs[i]` is the move for saved paragraph band `i`.
    public let paragraphs: [NoteBandMove]
    /// The move for the saved trailing band.
    public let trailing: NoteBandMove

    /// The move for a saved band reference; `nil` for a paragraph index out of range.
    public func move(for source: NoteBandRef) -> NoteBandMove? {
        switch source {
        case .trailing: return trailing
        case .paragraph(let index): return paragraphs.indices.contains(index) ? paragraphs[index] : nil
        }
    }
}

/// Pure geometry behind "ink follows the text it annotates".
///
/// WP13's loop: keep each stroke as (band ref, band-local stroke) against the last layout.
/// After every text change compute the new layout, call `relocate(from: last, to: new)`, move
/// every stroke to `move.destination` translated by `(0, move.localOffset)`, and draw it at
/// `new.pageRect(local, in: destination)`. New or edited strokes get `band(for:)` of the current
/// layout. Saving stores the strokes with the layout they reference (`Note.bandLayout`); on load,
/// relocate from the saved layout to the freshly computed one (this absorbs font-metric changes:
/// identical text, different tops).
public enum NoteBands {
    /// Maps each saved paragraph band to its place in the current layout.
    ///
    /// **Rules** (from the design's "Ink follows the text it annotates"):
    /// - Paragraphs are matched with `matchParagraphs(saved:current:)`.
    /// - A matched paragraph's strokes move with it: `deltaY = current.top - saved.top`, local
    ///   coordinates unchanged. Re-wrapping inside the paragraph does not move them.
    /// - A deleted paragraph's strokes stay where they were relative to the nearest earlier
    ///   saved paragraph that survived, and from now on belong to that paragraph's current band
    ///   (`localOffset = saved.top(deleted) - saved.top(survivor)`). If no earlier paragraph
    ///   survived they keep their note-page position (`deltaY = 0`) and belong to the first
    ///   current paragraph band, or to the trailing band when the current layout has no
    ///   paragraphs.
    /// - The trailing band moves with the end of the text:
    ///   `deltaY = current.trailingTop - saved.trailingTop`.
    public static func relocate(from saved: NoteBandLayout, to current: NoteBandLayout) -> NoteBandRelocation {
        let matches = matchParagraphs(saved: saved.paragraphs.map(\.text), current: current.paragraphs.map(\.text))
        var moves: [NoteBandMove] = []
        moves.reserveCapacity(saved.paragraphs.count)
        var lastSurvivor: (saved: Int, current: Int)?
        for (index, band) in saved.paragraphs.enumerated() {
            let source = NoteBandRef.paragraph(index)
            if let match = matches[index] {
                let fate: NoteBandMove.Fate = band.text == current.paragraphs[match].text ? .unchanged : .edited
                moves.append(NoteBandMove(source: source, destination: .paragraph(match), localOffset: 0,
                                          deltaY: current.paragraphs[match].top - band.top, fate: fate))
                lastSurvivor = (index, match)
            } else if let survivor = lastSurvivor {
                let offset = band.top - saved.paragraphs[survivor.saved].top
                let delta = current.paragraphs[survivor.current].top - saved.paragraphs[survivor.saved].top
                moves.append(NoteBandMove(source: source, destination: .paragraph(survivor.current),
                                          localOffset: offset, deltaY: delta, fate: .deleted))
            } else if let first = current.paragraphs.first {
                moves.append(NoteBandMove(source: source, destination: .paragraph(0),
                                          localOffset: band.top - first.top, deltaY: 0, fate: .deleted))
            } else {
                moves.append(NoteBandMove(source: source, destination: .trailing,
                                          localOffset: band.top - current.trailingTop, deltaY: 0, fate: .deleted))
            }
        }
        let trailing = NoteBandMove(source: .trailing, destination: .trailing, localOffset: 0,
                                    deltaY: current.trailingTop - saved.trailingTop, fate: .trailing)
        return NoteBandRelocation(paragraphs: moves, trailing: trailing)
    }

    /// Paragraph identity across an edit. Returns, for each saved paragraph, the index of the
    /// current paragraph it became, or `nil` if it was deleted. Matched indices strictly
    /// increase (order is preserved).
    ///
    /// **Algorithm:**
    /// 1. *Anchors*: a longest common subsequence of paragraphs with identical text. Among equal
    ///    length solutions the one matching earlier saved paragraphs to earlier current ones is
    ///    taken (deterministic).
    /// 2. *Gaps*: between consecutive anchors (and before the first / after the last) the
    ///    unmatched saved paragraphs `S` and current paragraphs `C` are paired:
    ///    - `|S| == |C|`: pairwise in order (paragraphs edited in place; the common case of typing
    ///      inside one paragraph).
    ///    - otherwise: an order-preserving pairing maximising the summed `similarity`, using only
    ///      pairs with similarity > 0; ties prefer earlier pairs. Unpaired saved paragraphs are
    ///      deleted; unpaired current ones are inserted.
    ///
    /// `similarity(s, c)` = (length of the common prefix + length of the common suffix of the
    /// rest, in characters) / length of `s`; `0` when `s` is empty. So a paragraph that grew
    /// while a neighbour was inserted or deleted stays matched, and a paragraph split in two
    /// stays matched to the half that kept more of its text (ties: the first half).
    public static func matchParagraphs(saved: [String], current: [String]) -> [Int?] {
        let s = saved, c = current
        var result = [Int?](repeating: nil, count: s.count)
        guard !s.isEmpty, !c.isEmpty else { return result }

        // 1. LCS on equal text. Fill a suffix table so the forward walk prefers early matches.
        let m = s.count, n = c.count
        var table = [Int](repeating: 0, count: (m + 1) * (n + 1))
        func at(_ i: Int, _ j: Int) -> Int { i * (n + 1) + j }
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                table[at(i, j)] = s[i] == c[j]
                    ? table[at(i + 1, j + 1)] + 1
                    : max(table[at(i + 1, j)], table[at(i, j + 1)])
            }
        }
        var anchors: [(Int, Int)] = []
        var i = 0, j = 0
        while i < m && j < n {
            if s[i] == c[j] && table[at(i, j)] == table[at(i + 1, j + 1)] + 1 {
                anchors.append((i, j)); i += 1; j += 1
            } else if table[at(i + 1, j)] >= table[at(i, j + 1)] {
                i += 1
            } else {
                j += 1
            }
        }
        for (a, b) in anchors { result[a] = b }

        // 2. Gaps.
        var previous = (-1, -1)
        for anchor in anchors + [(m, n)] {
            let savedGap = Array((previous.0 + 1)..<anchor.0)
            let currentGap = Array((previous.1 + 1)..<anchor.1)
            if !savedGap.isEmpty && !currentGap.isEmpty {
                if savedGap.count == currentGap.count {
                    for (a, b) in zip(savedGap, currentGap) { result[a] = b }
                } else {
                    for (a, b) in alignBySimilarity(savedGap.map { s[$0] }, currentGap.map { c[$0] }) {
                        result[savedGap[a]] = currentGap[b]
                    }
                }
            }
            previous = anchor
        }
        return result
    }

    /// Fraction of `saved` preserved at its ends in `current`; see `matchParagraphs`.
    public static func similarity(_ saved: String, _ current: String) -> Double {
        let a = Array(saved), b = Array(current)
        guard !a.isEmpty else { return 0 }
        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix && suffix < b.count - prefix
                && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return Double(prefix + suffix) / Double(a.count)
    }

    /// Order-preserving pairing maximising summed similarity (pairs with similarity > 0 only).
    private static func alignBySimilarity(_ s: [String], _ c: [String]) -> [(Int, Int)] {
        let m = s.count, n = c.count
        var score = [Double](repeating: 0, count: (m + 1) * (n + 1))
        func at(_ i: Int, _ j: Int) -> Int { i * (n + 1) + j }
        var sim = [Double](repeating: 0, count: m * n)
        for i in 0..<m { for j in 0..<n { sim[i * n + j] = similarity(s[i], c[j]) } }
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                let pair = sim[i * n + j]
                let take = pair > 0 ? score[at(i + 1, j + 1)] + pair : -1
                score[at(i, j)] = max(take, score[at(i + 1, j)], score[at(i, j + 1)])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < m && j < n {
            let pair = sim[i * n + j]
            if pair > 0 && score[at(i, j)] == score[at(i + 1, j + 1)] + pair {
                pairs.append((i, j)); i += 1; j += 1
            } else if score[at(i + 1, j)] >= score[at(i, j + 1)] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
