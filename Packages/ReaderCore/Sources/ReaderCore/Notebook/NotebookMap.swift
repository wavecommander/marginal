import Foundation

/// The Notebook's map of the whole book (design: "Notebook map"): the book as a strip divided
/// into its top-level headings, with a mark at the page of every item the Notebook shows for the
/// current type filter and search. Positions are fractions of the book (0 at the start of the
/// first page, 1 at the end of the last), so the view only scales them to its width.
public struct NotebookMap: Hashable, Sendable {
    /// A top-level heading's pages (or the front matter before the first heading).
    public struct Segment: Hashable, Sendable, Identifiable {
        public let id: String
        /// The heading's title ("" for front matter or a book without headings).
        public let title: String
        /// A short label drawn under the segment when it is wide enough: the title's leading
        /// number ("5" for "5 Eigenvalues and Eigenvectors"), or `nil`.
        public let shortLabel: String?
        public let pages: ClosedRange<Int>
    }

    public enum Kind: Hashable, Sendable {
        case sectionNote
        case pageNote
        case highlight(HighlightColor)
        case handwriting

        public var title: String {
            switch self {
            case .sectionNote: "Section note"
            case .pageNote: "Page note"
            case .highlight: "Highlight"
            case .handwriting: "Handwriting"
            }
        }
    }

    /// One item: where it is, what it is, and the feed row it stands for.
    public struct Mark: Hashable, Sendable, Identifiable {
        /// The feed row's ID (`NotebookFeedRow.id`).
        public let id: String
        public let pageIndex: Int
        public let kind: Kind
        /// The deepest heading it is filed under ("Front matter", "Unfiled" outside headings).
        public let sectionTitle: String
    }

    public let pageCount: Int
    public let segments: [Segment]
    /// In book order.
    public let marks: [Mark]

    /// Builds the map from the book's Notebook and the feed rows for the whole book (scope
    /// `.all`) with the current type filter and search.
    public init(notebook: Notebook, rows: [NotebookFeedRow], pageCount: Int) {
        let pageCount = max(pageCount, 1)
        self.pageCount = pageCount
        let last = pageCount - 1

        var segments: [Segment] = []
        let starts = notebook.sections.compactMap { section -> (NotebookSection, Int)? in
            guard let start = section.pageRange?.lowerBound ?? section.startPage else { return nil }
            return (section, min(max(start, 0), last))
        }
        if let first = starts.first?.1, first > 0 {
            segments.append(Segment(id: "front", title: "Front matter", shortLabel: nil, pages: 0...(first - 1)))
        }
        for (index, (section, start)) in starts.enumerated() {
            let nextStart = index + 1 < starts.count ? starts[index + 1].1 : pageCount
            let end = max(start, min(section.pageRange?.upperBound ?? nextStart - 1, nextStart - 1, last))
            // Headings that share a page with the next one get no segment of their own.
            guard start <= end, segments.last.map({ $0.pages.upperBound < start }) ?? true else { continue }
            segments.append(Segment(id: section.anchor.rawValue, title: section.title,
                                    shortLabel: Self.shortLabel(section.title), pages: start...end))
        }
        if segments.isEmpty {
            segments = [Segment(id: "book", title: "", shortLabel: nil, pages: 0...last)]
        }
        self.segments = segments

        var marks: [Mark] = []
        var currentTitle = ""
        for row in rows {
            switch row.kind {
            case .header(let header):
                currentTitle = header.title
            case .headingNote(let note, let heading):
                let page = heading.startPage ?? note.target.headingAnchor?.pageIndex ?? 0
                marks.append(Mark(id: row.id, pageIndex: min(page, last), kind: .sectionNote, sectionTitle: heading.title))
            case .unfiledHeadingNote(let note, let title):
                let page = note.target.headingAnchor?.pageIndex ?? 0
                marks.append(Mark(id: row.id, pageIndex: min(page, last), kind: .sectionNote, sectionTitle: title))
            case .pageNote(_, let page):
                marks.append(Mark(id: row.id, pageIndex: min(page, last), kind: .pageNote, sectionTitle: currentTitle))
            case .highlight(let highlight, _):
                marks.append(Mark(id: row.id, pageIndex: min(highlight.pageIndex, last),
                                  kind: .highlight(highlight.color), sectionTitle: currentTitle))
            case .handwriting(let page):
                marks.append(Mark(id: row.id, pageIndex: min(page, last), kind: .handwriting, sectionTitle: currentTitle))
            }
        }
        self.marks = marks
    }

    /// Where `range` starts and ends along the book (0...1).
    public func span(of range: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(range.lowerBound) / Double(pageCount)...Double(range.upperBound + 1) / Double(pageCount)
    }

    /// The middle of a page along the book (0...1).
    public func position(ofPage pageIndex: Int) -> Double {
        (Double(pageIndex) + 0.5) / Double(pageCount)
    }

    /// The mark nearest `fraction` along the book (ties: the earlier one), or `nil` if there are none.
    public func nearestMark(to fraction: Double) -> Mark? {
        marks.min { abs(position(ofPage: $0.pageIndex) - fraction) < abs(position(ofPage: $1.pageIndex) - fraction) }
    }

    /// The segment containing `pageIndex`.
    public func segment(containing pageIndex: Int) -> Segment? {
        segments.first { $0.pages.contains(pageIndex) }
    }

    /// The segment with the most marks (the first of equals), for a one-line summary.
    public var busiestSegment: Segment? {
        let counts = segments.map { segment in marks.filter { segment.pages.contains($0.pageIndex) }.count }
        guard let best = counts.max(), best > 0, let index = counts.firstIndex(of: best) else { return nil }
        return segments[index]
    }

    /// The pages the given feed rows cover, from the first to the last (a header counts at its
    /// heading's start page), for the box that shows what the feed has on screen.
    public static func pageRange(ofRows rowIDs: Set<String>, in rows: [NotebookFeedRow]) -> ClosedRange<Int>? {
        let pages = rows.filter { rowIDs.contains($0.id) }.compactMap(\.targetPage)
        guard let low = pages.min(), let high = pages.max() else { return nil }
        return low...high
    }

    /// "5" for "5 Eigenvalues and Eigenvectors", "A.2" for "A.2 Proofs"; `nil` when the title
    /// does not start with a token that has a digit in it.
    static func shortLabel(_ title: String) -> String? {
        guard let token = title.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
              token.count <= 6, token.contains(where: \.isNumber) else { return nil }
        return String(token).trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
    }
}
