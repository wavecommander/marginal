import CoreGraphics
import Foundation
import ReaderCore

/// Pure rules of highlights (no PDFKit): text normalisation, the overlap test behind the merge
/// rule, and hit-testing. All rects are in PDFKit page space (`Highlight.rects`).
nonisolated enum HighlightGeometry {
    /// Tap tolerance around a highlight's line rects, in page points.
    static let hitTolerance: CGFloat = 4

    /// The selected text as stored: every run of whitespace (spaces, tabs, line breaks, the
    /// non-breaking space) becomes one space, and the ends are trimmed. A hyphen at a line end is
    /// kept as it is (it cannot be told apart from a real hyphen).
    static func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// Whether two line rects lie on the same line and share some horizontal extent: their
    /// vertical overlap is at least half the shorter height, and their horizontal overlap is
    /// more than half a point (rects that merely touch end to end do not overlap).
    static func linesOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        guard !a.isNull, !b.isNull, !a.isEmpty, !b.isEmpty else { return false }
        let vertical = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let horizontal = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return vertical >= 0.5 * min(a.height, b.height) && horizontal > 0.5
    }

    /// Whether any line of `a` overlaps any line of `b` (see `linesOverlap`).
    static func overlaps(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        a.contains { lineA in b.contains { linesOverlap(lineA, $0) } }
    }

    /// The highlight under `point` (page space), allowing `tolerance` points around each line
    /// rect. When several match (a highlight inside another's tolerance band), the one whose rect
    /// actually contains the point wins, then the smallest, then the newest.
    static func hitTest(_ point: CGPoint, in highlights: [Highlight],
                        tolerance: CGFloat = hitTolerance) -> Highlight? {
        struct Candidate { var highlight: Highlight; var inside: Bool; var area: CGFloat }
        var candidates: [Candidate] = []
        for highlight in highlights {
            var inside = false
            var near = false
            for rect in highlight.rects where !rect.isNull && !rect.isEmpty {
                if rect.contains(point) { inside = true }
                if rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) { near = true }
            }
            guard near else { continue }
            let area = highlight.rects.reduce(0) { $0 + $1.width * $1.height }
            candidates.append(Candidate(highlight: highlight, inside: inside, area: area))
        }
        return candidates.min { a, b in
            if a.inside != b.inside { return a.inside }
            if a.area != b.area { return a.area < b.area }
            return a.highlight.createdAt > b.highlight.createdAt
        }?.highlight
    }

    /// Fallback merge of line rects when the page's text cannot be consulted: rects on the same
    /// line (see `linesOverlap`, touching ends included) are unioned; lines are returned top to
    /// bottom, then left to right.
    static func mergedLines(_ rects: [CGRect]) -> [CGRect] {
        var lines: [CGRect] = []
        for rect in rects where !rect.isNull && !rect.isEmpty {
            var merged = rect
            var changed = true
            while changed {
                changed = false
                if let index = lines.firstIndex(where: { sameLine($0, merged) }) {
                    merged = merged.union(lines.remove(at: index))
                    changed = true
                }
            }
            lines.append(merged)
        }
        return lines.sorted { $0.maxY != $1.maxY ? $0.maxY > $1.maxY : $0.minX < $1.minX }
    }

    private static func sameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let vertical = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let horizontal = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return vertical >= 0.5 * min(a.height, b.height) && horizontal >= -0.5
    }

    /// Union of rects (`.null` for none).
    static func union(_ rects: [CGRect]) -> CGRect {
        rects.reduce(CGRect.null) { $0.union($1) }
    }
}
