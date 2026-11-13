import Foundation
import ReaderCore

// Result values, the search over notes and highlights, and grouping by heading.

/// One row of the result list: a text hit, a note or a highlight.
nonisolated struct SearchResult: Hashable, Sendable, Identifiable {
    enum Kind: Int, Hashable, Sendable {
        /// Text in the book's pages.
        case text
        case note
        case highlight
    }

    var id: String
    var kind: Kind
    /// Zero-based page (a heading note's heading start page).
    var pageIndex: Int
    /// Rects in page space (text hits and highlights); empty for notes.
    var rects: [CGRect]
    var snippet: SearchSnippet
    /// For notes: what the note is attached to.
    var noteTarget: NoteTarget?

    init(hit: SearchHit) {
        id = hit.id
        kind = .text
        pageIndex = hit.pageIndex
        rects = hit.rects
        snippet = hit.snippet
    }

    init(id: String, kind: Kind, pageIndex: Int, rects: [CGRect] = [], snippet: SearchSnippet,
         noteTarget: NoteTarget? = nil) {
        self.id = id
        self.kind = kind
        self.pageIndex = pageIndex
        self.rects = rects
        self.snippet = snippet
        self.noteTarget = noteTarget
    }

    /// Order inside a group: page, then heading note, text, highlight, page note, then top to
    /// bottom on the page.
    fileprivate var sortRank: Int {
        switch kind {
        case .text: 1
        case .highlight: 2
        case .note: noteTarget?.headingAnchor != nil ? 0 : 3
        }
    }

    fileprivate var top: CGFloat {
        rects.map(\.maxY).max() ?? 0
    }
}

/// A heading's (or page range's) hits.
nonisolated struct SearchGroup: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case heading(level: Int)
        /// Pages before the first heading.
        case frontMatter
        /// A book without an outline: a fixed range of pages.
        case pageRange
    }

    var id: String
    var kind: Kind
    var title: String
    /// First page of the heading or range (zero-based), for the header's "p. N".
    var startPage: Int?
    var results: [SearchResult]
}

nonisolated enum SearchGrouping {
    /// Pages per group in a book without an outline.
    static let pagesPerRange = 50

    static let frontMatterTitle = "Front Matter"

    /// Groups `results` by the deepest heading containing their page, in outline order, with a
    /// front-matter group first for pages before the first heading. A heading note belongs to its
    /// own heading. A book without an outline (empty `outline`) is grouped by `pagesPerRange`
    /// pages ("pp. 1–50", "pp. 51–100", …), which keeps a 1,500-page book's results
    /// navigable where a flat list would not be. Empty groups are omitted.
    static func group(_ results: [SearchResult], outline: Outline, pageCount: Int) -> [SearchGroup] {
        guard !results.isEmpty else { return [] }
        let sorted = results.sorted(by: order)
        if outline.isEmpty {
            return byPageRange(sorted, pageCount: pageCount)
        }
        var indexByAnchor: [HeadingAnchor: Int] = [:]
        for (index, node) in outline.nodes.enumerated() { indexByAnchor[node.anchor] = index }

        var buckets: [Int: [SearchResult]] = [:]  // -1 = front matter
        for result in sorted {
            var bucket = -1
            if let anchor = result.noteTarget?.headingAnchor, let index = indexByAnchor[anchor] {
                bucket = index
            } else if let node = outline.deepestHeading(forPage: result.pageIndex),
                      let index = indexByAnchor[node.anchor] {
                bucket = index
            }
            buckets[bucket, default: []].append(result)
        }
        var groups: [SearchGroup] = []
        if let front = buckets[-1] {
            groups.append(SearchGroup(id: "front", kind: .frontMatter, title: frontMatterTitle, startPage: nil,
                                      results: front))
        }
        for index in buckets.keys.filter({ $0 >= 0 }).sorted() {
            let node = outline.nodes[index]
            groups.append(SearchGroup(id: "heading-\(node.anchor.rawValue)", kind: .heading(level: node.level),
                                      title: node.title, startPage: node.startPage, results: buckets[index] ?? []))
        }
        return groups
    }

    private static func byPageRange(_ sorted: [SearchResult], pageCount: Int) -> [SearchGroup] {
        var buckets: [Int: [SearchResult]] = [:]
        for result in sorted { buckets[result.pageIndex / pagesPerRange, default: []].append(result) }
        return buckets.keys.sorted().map { bucket in
            let first = bucket * pagesPerRange
            var last = first + pagesPerRange - 1
            if pageCount > 0 { last = min(last, pageCount - 1) }
            return SearchGroup(id: "range-\(bucket)", kind: .pageRange,
                               title: PageNumbering.label(forPageRange: first...max(first, last)),
                               startPage: first, results: buckets[bucket] ?? [])
        }
    }

    private static func order(_ a: SearchResult, _ b: SearchResult) -> Bool {
        if a.pageIndex != b.pageIndex { return a.pageIndex < b.pageIndex }
        if a.sortRank != b.sortRank { return a.sortRank < b.sortRank }
        if a.top != b.top { return a.top > b.top }
        return a.id < b.id
    }
}

/// Searches note text and highlight text from the store.
@MainActor
enum AnnotationSearch {
    static func results(query: String, bookID: UUID, store: LibraryStore, outline: Outline) -> [SearchResult] {
        var matcher = SearchTextMatcher()
        let needle = matcher.foldQuery(query)
        guard !needle.isEmpty else { return [] }
        var out: [SearchResult] = []

        for note in (try? store.notes.notes(bookID: bookID)) ?? [] {
            let page: Int
            switch note.target {
            case .page(let index):
                page = index
            case .heading(let anchor):
                // A heading that no longer resolves cannot be shown in context: skip it.
                guard let start = outline.resolve(anchor)?.node.startPage else { continue }
                page = start
            }
            let folded = matcher.fold(note.text)
            guard let range = SearchTextMatcher.matches(of: needle, in: folded).first else { continue }
            let snippet = SearchTextMatcher.snippet(in: note.text as NSString, around: range)
            // A heading note's target is stored as found, but grouped under the resolved node.
            var target = note.target
            if case .heading(let anchor) = note.target, let node = outline.resolve(anchor)?.node {
                target = .heading(node.anchor)
            }
            out.append(SearchResult(id: "note-\(note.id.uuidString)", kind: .note, pageIndex: page,
                                    snippet: snippet, noteTarget: target))
        }

        for highlight in (try? store.highlights.highlights(bookID: bookID)) ?? [] {
            let folded = matcher.fold(highlight.text)
            guard let range = SearchTextMatcher.matches(of: needle, in: folded).first else { continue }
            let snippet = SearchTextMatcher.snippet(in: highlight.text as NSString, around: range)
            out.append(SearchResult(id: "highlight-\(highlight.id.uuidString)", kind: .highlight,
                                    pageIndex: highlight.pageIndex, rects: highlight.rects, snippet: snippet))
        }
        return out
    }
}
