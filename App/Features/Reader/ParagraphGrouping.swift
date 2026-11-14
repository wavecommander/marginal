import CoreGraphics

/// Groups one page's text lines into paragraphs from their layout alone (design: "Select All
/// selects the paragraph"). Pure: page-space line rects in, paragraph line ranges out; it never
/// sees text beyond a line's trailing hyphen, other pages or the document.
///
/// Lines come in the page's text order (PDFKit's `selectionsByLine()` order). Consecutive lines
/// stay in one paragraph unless one of these separates them:
/// - **another column or block**: the lines do not overlap horizontally, or the next line is not
///   below the previous one (a paragraph never jumps columns or goes back up the page). Pieces of
///   one visual line (same height band, a gap under one line height) stay together;
/// - **a font-size change**: line heights differ by more than 30 % (headings, captions,
///   footnotes, running headers);
/// - **a vertical gap**: the line pitch is more than 1.35 times the page's typical pitch (the
///   lower quartile of same-column pitches, so the paragraph gaps themselves do not raise it);
/// - **a first-line indent**: the next line starts more than about two-thirds of a line height
///   to the right of the previous one (also centred or right-aligned lines: equations, titles),
///   unless the previous line ends with a hyphen;
/// - **an outdent**: the next line starts to the left of the previous one, except the return
///   from a paragraph's own indented first line (up to four line heights).
///
/// Lines outside `visibleBox` (text hidden by a crop box) and empty rects are paragraphs of
/// their own. Rotated text is handled by turning the layout so lines read left to right and
/// follow each other downwards; the rules above then apply unchanged. The first and last
/// paragraphs on the page are simply the first and last groups: a paragraph that continues from
/// the previous page or onto the next ends at the page edge.
nonisolated struct ParagraphGrouping: Sendable {
    nonisolated struct Line: Equatable, Sendable {
        /// The line's bounds in page space (PDFKit: points, y up).
        var rect: CGRect
        /// The line's text ends with a hyphen (a word continues on the next line).
        var endsWithHyphen = false

        init(rect: CGRect, endsWithHyphen: Bool = false) {
            self.rect = rect
            self.endsWithHyphen = endsWithHyphen
        }

        init(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, hyphen: Bool = false) {
            self.init(rect: CGRect(x: x, y: y, width: width, height: height), endsWithHyphen: hyphen)
        }
    }

    /// Contiguous ranges of line indices covering `lines` in order, one per paragraph.
    static func paragraphs(_ lines: [Line], visibleBox: CGRect? = nil) -> [Range<Int>] {
        guard !lines.isEmpty else { return [] }
        let isolated = lines.map { line in
            line.rect.isNull || line.rect.isEmpty || line.rect.width <= 0 || line.rect.height <= 0
                || (visibleBox.map { !$0.intersects(line.rect) } ?? false)
        }
        let rects = normalized(lines.map(\.rect), isolated: isolated)
        let pitch = typicalPitch(rects, isolated: isolated)
        var result: [Range<Int>] = []
        var start = 0
        // The visual line before `index` (pieces merged) and the index it began at.
        var previous = rects[0]
        var previousStart = 0
        for index in 1..<lines.count {
            let rect = rects[index]
            if !isolated[index], !isolated[index - 1], isSameVisualLine(rect, previous) {
                previous = previous.union(rect)
                continue
            }
            let breaks = isolated[index] || isolated[index - 1]
                || startsParagraph(rect, after: previous, previousIsFirst: previousStart == start,
                                   previousHyphenated: lines[index - 1].endsWithHyphen, pitch: pitch)
            if breaks {
                result.append(start..<index)
                start = index
            }
            previous = rect
            previousStart = index
        }
        result.append(start..<lines.count)
        return result
    }

    // MARK: Rules

    private static func startsParagraph(_ line: CGRect, after previous: CGRect, previousIsFirst: Bool,
                                        previousHyphenated: Bool, pitch: CGFloat) -> Bool {
        let height = min(line.height, previous.height)
        if max(line.height, previous.height) > 1.3 * height { return true }
        let overlap = min(line.maxX, previous.maxX) - max(line.minX, previous.minX)
        if overlap <= 0 { return true }
        // The next line must be below the previous one.
        if line.midY >= previous.midY - 0.5 * height { return true }
        if previous.midY - line.midY > 1.35 * pitch { return true }
        let indent = max(0.65 * height, 4)
        let dx = line.minX - previous.minX
        if dx > indent { return !previousHyphenated }
        if dx < -indent {
            // Back from this paragraph's own indented first line.
            return !(previousIsFirst && -dx <= 4 * height)
        }
        return false
    }

    /// Two pieces of one visual line (PDFKit can split a line at a font or spacing change).
    private static func isSameVisualLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let height = min(a.height, b.height)
        let verticalOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard verticalOverlap > 0.6 * height else { return false }
        let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        return gap < height
    }

    /// The lower quartile of the vertical distance between consecutive lines of one column, or
    /// a line and a fifth when there are none.
    private static func typicalPitch(_ rects: [CGRect], isolated: [Bool]) -> CGFloat {
        var pitches: [CGFloat] = []
        var heights: [CGFloat] = []
        for index in rects.indices where !isolated[index] {
            heights.append(rects[index].height)
            guard index > 0, !isolated[index - 1] else { continue }
            let a = rects[index - 1], b = rects[index]
            let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
            let small = min(a.height, b.height)
            guard overlap > 0, max(a.height, b.height) <= 1.3 * small else { continue }
            let pitch = a.midY - b.midY
            if pitch > 0.5 * small { pitches.append(pitch) }
        }
        if !pitches.isEmpty {
            return pitches.sorted()[pitches.count / 4]
        }
        let median = heights.sorted()[safe: heights.count / 2] ?? 12
        return 1.2 * median
    }

    // MARK: Orientation

    /// Turns the layout so the text reads left to right and lines follow each other downwards
    /// (decreasing y), whatever the page or text rotation.
    private static func normalized(_ rects: [CGRect], isolated: [Bool]) -> [CGRect] {
        let usable = rects.indices.filter { !isolated[$0] }
        let tall = usable.filter { rects[$0].height > 1.5 * rects[$0].width }.count
        let wide = usable.filter { rects[$0].width > 1.5 * rects[$0].height }.count
        // Vertical text: rotate the page a quarter turn clockwise, (x, y) -> (y, -x).
        var result = tall > wide
            ? rects.map { CGRect(x: $0.minY, y: -$0.maxX, width: $0.height, height: $0.width) }
            : rects
        // Lines going up the page: the text is upside down; turn it half a turn.
        var steps: [CGFloat] = []
        for (a, b) in zip(usable, usable.dropFirst()) {
            let r = result[a], s = result[b]
            let overlap = min(r.maxX, s.maxX) - max(r.minX, s.minX)
            if overlap > 0 { steps.append(s.midY - r.midY) }
        }
        let rising = steps.filter { $0 > 0 }.count
        if rising > steps.count - rising {
            result = result.map { CGRect(x: -$0.maxX, y: -$0.maxY, width: $0.width, height: $0.height) }
        }
        return result
    }
}

nonisolated private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
