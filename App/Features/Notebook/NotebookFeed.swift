import Foundation
import ReaderCore

// The pure part of the Notebook screen: which rows the feed shows for a filter, and the entries of
// the heading filter column. No UI types; unit-tested in `Tests/NotebookFeedTests.swift`.

/// The type filter (the segmented control above the feed, as in the mockup).
nonisolated enum NotebookTypeFilter: String, CaseIterable, Sendable, Codable {
    case all
    /// Notes attached to headings (including unfiled heading notes).
    case sectionNotes
    /// Notes attached to pages.
    case pageNotes
    case highlights

    var title: String {
        switch self {
        case .all: "All"
        case .sectionNotes: "Section Notes"
        case .pageNotes: "Page Notes"
        case .highlights: "Highlights"
        }
    }

    var allowsSectionNotes: Bool { self == .all || self == .sectionNotes }
    var allowsPageNotes: Bool { self == .all || self == .pageNotes }
    var allowsHighlights: Bool { self == .all || self == .highlights }
}

/// What part of the book the feed shows (the heading filter column).
nonisolated enum NotebookScope: Hashable, Sendable {
    /// The whole book: front matter, every heading with content, unfiled notes.
    case all
    /// Pages before the first heading.
    case frontMatter
    /// Notes whose heading or page no longer exists in the book.
    case unfiled
    /// One heading and everything under it.
    case section(HeadingAnchor)

    /// Stable string for scene storage.
    var storageKey: String {
        switch self {
        case .all: "all"
        case .frontMatter: "front"
        case .unfiled: "unfiled"
        case .section(let anchor): "section:" + anchor.rawValue
        }
    }

    init?(storageKey: String) {
        switch storageKey {
        case "all": self = .all
        case "front": self = .frontMatter
        case "unfiled": self = .unfiled
        default:
            guard storageKey.hasPrefix("section:"),
                  let anchor = HeadingAnchor(rawValue: String(storageKey.dropFirst("section:".count))) else { return nil }
            self = .section(anchor)
        }
    }
}

/// The feed's filter: scope, type and search text (per window).
nonisolated struct NotebookFilter: Hashable, Sendable {
    var scope: NotebookScope = .all
    var type: NotebookTypeFilter = .all
    /// Search text; blank shows everything. Matches note text and highlight text,
    /// case- and diacritic-insensitively (`localizedStandardContains`).
    var query: String = ""

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearching: Bool { !trimmedQuery.isEmpty }
}

/// A heading (or a pseudo-heading such as "Front matter") as shown in the feed.
nonisolated struct NotebookHeader: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case section(HeadingAnchor)
        case frontMatter
        case unfiled
    }

    let kind: Kind
    let title: String
    /// 1-based outline level (front matter and unfiled are level 1).
    let level: Int
    let pageRange: ClosedRange<Int>?
    /// Where tapping the header opens the reader (`nil`: not openable).
    let startPage: Int?

    /// "pp. 291–376" (empty without a range).
    var pageRangeLabel: String { pageRange.map(PageNumbering.label(forPageRange:)) ?? "" }
}

/// One row of the feed.
nonisolated struct NotebookFeedRow: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case header(NotebookHeader)
        /// A heading's own note. `heading` is the heading it belongs to.
        case headingNote(Note, heading: NotebookHeader)
        /// A heading note whose heading is gone; `title` is the title recorded in its anchor.
        case unfiledHeadingNote(Note, title: String)
        case pageNote(Note, pageIndex: Int)
        /// `indexOnPage`: position among the page's highlights in reading order.
        case highlight(Highlight, indexOnPage: Int)
    }

    let id: String
    let kind: Kind

    /// The page the reader opens at for this row, or `nil` when it cannot be opened.
    var targetPage: Int? {
        switch kind {
        case .header(let header): header.startPage
        case .headingNote(_, let heading): heading.startPage
        case .unfiledHeadingNote(let note, _): note.target.headingAnchor?.pageIndex
        case .pageNote(_, let page): page
        case .highlight(let highlight, _): highlight.pageIndex
        }
    }

    /// The note shown by this row, if any.
    var note: Note? {
        switch kind {
        case .headingNote(let note, _), .unfiledHeadingNote(let note, _), .pageNote(let note, _): note
        case .header, .highlight: nil
        }
    }

    var isHeader: Bool { if case .header = kind { true } else { false } }
}

/// One entry of the heading filter column.
nonisolated struct NotebookScopeEntry: Identifiable, Hashable, Sendable {
    let scope: NotebookScope
    let title: String
    /// 1 for top level (and "Whole book", front matter, unfiled), deeper for nested headings.
    let level: Int
    /// Notes plus highlights in the scope.
    let count: Int

    var id: String { scope.storageKey }
}

/// Builds feed rows and filter entries from a `Notebook`.
nonisolated enum NotebookFeed {
    /// The feed for `filter`, in outline order: front matter; then every heading with content,
    /// depth first, each as its header, its own note, then its pages (each page's note, then its
    /// highlights in reading order), then its children; then unfiled notes. A header is shown
    /// only when something under it passes the filter. Bookmark-only pages are not shown.
    static func rows(for notebook: Notebook, filter: NotebookFilter) -> [NotebookFeedRow] {
        let query = filter.trimmedQuery
        let type = filter.type
        func matches(_ text: String) -> Bool { query.isEmpty || text.localizedStandardContains(query) }

        func pageRows(_ page: NotebookPage) -> [NotebookFeedRow] {
            var rows: [NotebookFeedRow] = []
            if let note = page.note, type.allowsPageNotes, matches(note.text) {
                rows.append(NotebookFeedRow(id: "note:" + note.id.uuidString, kind: .pageNote(note, pageIndex: page.pageIndex)))
            }
            if type.allowsHighlights {
                for (index, highlight) in page.highlights.enumerated() where matches(highlight.text) {
                    rows.append(NotebookFeedRow(id: "highlight:" + highlight.id.uuidString,
                                                kind: .highlight(highlight, indexOnPage: index)))
                }
            }
            return rows
        }

        func sectionRows(_ section: NotebookSection) -> [NotebookFeedRow] {
            let header = Self.header(for: section)
            var own: [NotebookFeedRow] = []
            if let note = section.note, type.allowsSectionNotes, matches(note.text) {
                own.append(NotebookFeedRow(id: "note:" + note.id.uuidString, kind: .headingNote(note, heading: header)))
            }
            for page in section.pages { own += pageRows(page) }
            let children = section.children.flatMap(sectionRows)
            guard !own.isEmpty || !children.isEmpty else { return [] }
            return [NotebookFeedRow(id: "header:" + section.anchor.rawValue, kind: .header(header))] + own + children
        }

        func frontRows() -> [NotebookFeedRow] {
            let rows = notebook.frontMatter.flatMap(pageRows)
            guard !rows.isEmpty else { return [] }
            return [NotebookFeedRow(id: "header:front", kind: .header(frontMatterHeader(notebook)))] + rows
        }

        func unfiledRows() -> [NotebookFeedRow] {
            var rows: [NotebookFeedRow] = []
            if type.allowsSectionNotes {
                for note in notebook.orphanNotes where matches(note.text) {
                    rows.append(NotebookFeedRow(id: "note:" + note.id.uuidString,
                                                kind: .unfiledHeadingNote(note, title: unfiledTitle(note))))
                }
            }
            rows += notebook.orphanPages.flatMap(pageRows)
            guard !rows.isEmpty else { return [] }
            return [NotebookFeedRow(id: "header:unfiled", kind: .header(unfiledHeader))] + rows
        }

        switch filter.scope {
        case .all:
            return frontRows() + notebook.sectionsWithContent.flatMap(sectionRows) + unfiledRows()
        case .frontMatter:
            return frontRows()
        case .unfiled:
            return unfiledRows()
        case .section(let anchor):
            guard let section = findSection(anchor, in: notebook.sectionsWithContent) else { return [] }
            return sectionRows(section)
        }
    }

    /// The heading filter column: "Whole book", front matter (if it has content), every heading
    /// with content in outline order (indented by level), and unfiled notes (if any). Counts are
    /// notes plus highlights.
    static func scopeEntries(for notebook: Notebook) -> [NotebookScopeEntry] {
        func count(_ counts: NotebookCounts) -> Int { counts.notes + counts.highlights }
        var entries = [NotebookScopeEntry(scope: .all, title: "Whole book", level: 1, count: count(notebook.totalCounts))]
        let front = count(notebook.frontMatterCounts)
        if front > 0 {
            entries.append(NotebookScopeEntry(scope: .frontMatter, title: "Front matter", level: 1, count: front))
        }
        func visit(_ section: NotebookSection) {
            entries.append(NotebookScopeEntry(scope: .section(section.anchor), title: section.title,
                                              level: section.level, count: count(section.totalCounts)))
            section.children.forEach(visit)
        }
        notebook.sectionsWithContent.forEach(visit)
        let unfiled = unfiledCount(notebook)
        if unfiled > 0 {
            entries.append(NotebookScopeEntry(scope: .unfiled, title: "Unfiled notes", level: 1, count: unfiled))
        }
        return entries
    }

    /// Notes plus highlights in the whole book.
    static func itemCount(_ notebook: Notebook) -> Int {
        notebook.totalCounts.notes + notebook.totalCounts.highlights
    }

    /// Whether `scope` still exists in `notebook` (a heading may lose its content or be deleted).
    static func contains(_ scope: NotebookScope, in notebook: Notebook) -> Bool {
        scopeEntries(for: notebook).contains { $0.scope == scope }
    }

    // MARK: Helpers

    static func header(for section: NotebookSection) -> NotebookHeader {
        NotebookHeader(kind: .section(section.anchor), title: section.title, level: section.level,
                       pageRange: section.pageRange, startPage: section.startPage)
    }

    /// "Front matter" opens the reader at the first page with an item there.
    static func frontMatterHeader(_ notebook: Notebook) -> NotebookHeader {
        NotebookHeader(kind: .frontMatter, title: "Front matter", level: 1, pageRange: nil,
                       startPage: notebook.frontMatter.first?.pageIndex)
    }

    static let unfiledHeader = NotebookHeader(kind: .unfiled, title: "Unfiled notes", level: 1, pageRange: nil, startPage: nil)

    static func unfiledTitle(_ note: Note) -> String {
        guard let title = note.target.headingAnchor?.title, !title.isEmpty else { return "Untitled heading" }
        return title
    }

    static func unfiledCount(_ notebook: Notebook) -> Int {
        notebook.orphanNotes.count + notebook.orphanPages.reduce(0) { $0 + ($1.note == nil ? 0 : 1) + $1.highlights.count }
    }

    static func findSection(_ anchor: HeadingAnchor, in sections: [NotebookSection]) -> NotebookSection? {
        for section in sections {
            if section.anchor == anchor { return section }
            if let found = findSection(anchor, in: section.children) { return found }
        }
        return nil
    }

    /// "Chapter" for a top-level heading's note, "Section" below (the mockup's labels).
    static func headingNoteLabel(level: Int) -> String { level <= 1 ? "Chapter" : "Section" }
}
