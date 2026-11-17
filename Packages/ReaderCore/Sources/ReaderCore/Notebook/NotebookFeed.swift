import Foundation

// The pure part of the Notebook screen: which rows the feed shows for a filter, and the entries of
// the heading filter column. No UI types; unit-tested in `NotebookFeedTests`.

/// The type filter (the segmented control above the feed, as in the mockup).
public enum NotebookTypeFilter: String, CaseIterable, Sendable, Codable {
    case all
    /// Notes attached to headings (including unfiled heading notes).
    case sectionNotes
    /// Notes attached to pages.
    case pageNotes
    case highlights
    /// Pages with page ink (Pencil highlighter strokes and drawings alike).
    case handwriting

    public var title: String {
        switch self {
        case .all: "All"
        case .sectionNotes: "Section Notes"
        case .pageNotes: "Page Notes"
        case .highlights: "Highlights"
        case .handwriting: "Handwriting"
        }
    }

    public var allowsSectionNotes: Bool { self == .all || self == .sectionNotes }
    public var allowsPageNotes: Bool { self == .all || self == .pageNotes }
    public var allowsHighlights: Bool { self == .all || self == .highlights }
    public var allowsHandwriting: Bool { self == .all || self == .handwriting }
}

/// What part of the book the feed shows (the heading filter column).
public enum NotebookScope: Hashable, Sendable {
    /// The whole book: front matter, every heading with content, unfiled notes.
    case all
    /// Pages before the first heading.
    case frontMatter
    /// Notes whose heading or page no longer exists in the book.
    case unfiled
    /// One heading and everything under it.
    case section(HeadingAnchor)

    /// Stable string for scene storage.
    public var storageKey: String {
        switch self {
        case .all: "all"
        case .frontMatter: "front"
        case .unfiled: "unfiled"
        case .section(let anchor): "section:" + anchor.rawValue
        }
    }

    public init?(storageKey: String) {
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
public struct NotebookFilter: Hashable, Sendable {
    public var scope: NotebookScope = .all
    public var type: NotebookTypeFilter = .all
    /// Search text; blank shows everything. Matches note text and highlight text,
    /// case- and diacritic-insensitively (`localizedStandardContains`). Handwriting has no text,
    /// so a search hides it.
    public var query: String = ""

    public init(scope: NotebookScope = .all, type: NotebookTypeFilter = .all, query: String = "") {
        self.scope = scope
        self.type = type
        self.query = query
    }

    public var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isSearching: Bool { !trimmedQuery.isEmpty }
}

/// A heading (or a pseudo-heading such as "Front matter") as shown in the feed.
public struct NotebookHeader: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case section(HeadingAnchor)
        case frontMatter
        case unfiled
    }

    public let kind: Kind
    public let title: String
    /// 1-based outline level (front matter and unfiled are level 1).
    public let level: Int
    public let pageRange: ClosedRange<Int>?
    /// Where tapping the header opens the reader (`nil`: not openable).
    public let startPage: Int?

    public init(kind: Kind, title: String, level: Int, pageRange: ClosedRange<Int>?, startPage: Int?) {
        self.kind = kind
        self.title = title
        self.level = level
        self.pageRange = pageRange
        self.startPage = startPage
    }

    /// "pp. 291–376" (empty without a range).
    public var pageRangeLabel: String { pageRange.map(PageNumbering.label(forPageRange:)) ?? "" }
}

/// A heading of the feed and the rows under it up to the next heading (`NotebookFeed.sections`).
public struct NotebookFeedSection: Identifiable, Hashable, Sendable {
    public let header: NotebookFeedRow?
    public let rows: [NotebookFeedRow]

    public var id: String { header?.id ?? "lead:" + (rows.first?.id ?? "") }
}

/// One row of the feed.
public struct NotebookFeedRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case header(NotebookHeader)
        /// A heading's own note. `heading` is the heading it belongs to.
        case headingNote(Note, heading: NotebookHeader)
        /// A heading note whose heading is gone; `title` is the title recorded in its anchor.
        case unfiledHeadingNote(Note, title: String)
        case pageNote(Note, pageIndex: Int)
        /// `indexOnPage`: position among the page's highlights in reading order.
        case highlight(Highlight, indexOnPage: Int)
        /// A page with page ink, shown as a preview of the page with its ink
        /// (`NotebookHandwritingPreview`).
        case handwriting(pageIndex: Int)
    }

    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// The page the reader opens at for this row, or `nil` when it cannot be opened.
    public var targetPage: Int? {
        switch kind {
        case .header(let header): header.startPage
        case .headingNote(_, let heading): heading.startPage
        case .unfiledHeadingNote(let note, _): note.target.headingAnchor?.pageIndex
        case .pageNote(_, let page): page
        case .highlight(let highlight, _): highlight.pageIndex
        case .handwriting(let page): page
        }
    }

    /// The note shown by this row, if any.
    public var note: Note? {
        switch kind {
        case .headingNote(let note, _), .unfiledHeadingNote(let note, _), .pageNote(let note, _): note
        case .header, .highlight, .handwriting: nil
        }
    }

    public var isHeader: Bool { if case .header = kind { true } else { false } }

    /// The item this row shows (what selecting the row selects); `nil` for a header.
    public var itemID: NotebookItemID? {
        switch kind {
        case .header: nil
        case .headingNote(let note, _), .unfiledHeadingNote(let note, _), .pageNote(let note, _): .note(note.id)
        case .highlight(let highlight, _): .highlight(highlight.id)
        case .handwriting(let page): .pageInk(page)
        }
    }
}

/// How much of a row is selected for export: an item row is `.none` or `.all`; a header is
/// `.some` when only part of what the feed shows under it is selected.
public enum NotebookRowSelection: Hashable, Sendable {
    case none, some, all

    public var accessibilityValue: String {
        switch self {
        case .none: "Not selected"
        case .some: "Partly selected"
        case .all: "Selected"
        }
    }
}

/// One entry of the heading filter column.
public struct NotebookScopeEntry: Identifiable, Hashable, Sendable {
    public let scope: NotebookScope
    public let title: String
    /// 1 for top level (and "Whole book", front matter, unfiled), deeper for nested headings.
    public let level: Int
    /// Notes, highlights and inked pages in the scope.
    public let count: Int

    public init(scope: NotebookScope, title: String, level: Int, count: Int) {
        self.scope = scope
        self.title = title
        self.level = level
        self.count = count
    }

    public var id: String { scope.storageKey }
}

/// Builds feed rows and filter entries from a `Notebook`.
public enum NotebookFeed {
    /// The feed for `filter`, in outline order: front matter; then every heading with content,
    /// depth first, each as its header, its own note, then its pages (each page's note, then its
    /// highlights in reading order, then its handwriting), then its children; then unfiled notes.
    /// A header is shown only when something under it passes the filter. Bookmark-only pages are
    /// not shown. A page's note, highlights and ink are separate rows.
    public static func rows(for notebook: Notebook, filter: NotebookFilter) -> [NotebookFeedRow] {
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
            if page.hasInk, type.allowsHandwriting, query.isEmpty {
                rows.append(NotebookFeedRow(id: "ink:\(page.pageIndex)", kind: .handwriting(pageIndex: page.pageIndex)))
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
    /// notes, highlights and inked pages (`NotebookCounts.items`).
    public static func scopeEntries(for notebook: Notebook) -> [NotebookScopeEntry] {
        func count(_ counts: NotebookCounts) -> Int { counts.items }
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

    /// Notes, highlights and inked pages in the whole book.
    public static func itemCount(_ notebook: Notebook) -> Int {
        notebook.totalCounts.items
    }

    /// Whether `scope` still exists in `notebook` (a heading may lose its content or be deleted).
    public static func contains(_ scope: NotebookScope, in notebook: Notebook) -> Bool {
        scopeEntries(for: notebook).contains { $0.scope == scope }
    }

    // MARK: Selection

    /// The items of `rows`, in feed order.
    public static func items(in rows: [NotebookFeedRow]) -> [NotebookItemID] { rows.compactMap(\.itemID) }

    /// `rows` split at every header: each section is a header and the rows up to the next header
    /// (of any level), for a feed whose headings stay pinned while their rows scroll beneath.
    /// Rows before the first header, if any, form a section without one.
    public static func sections(_ rows: [NotebookFeedRow]) -> [NotebookFeedSection] {
        var sections: [NotebookFeedSection] = []
        var header: NotebookFeedRow?
        var current: [NotebookFeedRow] = []
        func close() {
            if header != nil || !current.isEmpty { sections.append(NotebookFeedSection(header: header, rows: current)) }
        }
        for row in rows {
            if row.isHeader {
                close()
                header = row
                current = []
            } else {
                current.append(row)
            }
        }
        close()
        return sections
    }

    /// For every header row of `rows` (by row `id`), the items the feed shows under it: its own
    /// and those under its subheadings, down to the next header of the same or a higher level.
    public static func itemsByHeader(_ rows: [NotebookFeedRow]) -> [String: [NotebookItemID]] {
        var result: [String: [NotebookItemID]] = [:]
        var open: [(id: String, level: Int)] = []
        for row in rows {
            if case .header(let header) = row.kind {
                while let last = open.last, last.level >= header.level { open.removeLast() }
                open.append((row.id, header.level))
                result[row.id] = []
            } else if let item = row.itemID {
                for header in open { result[header.id, default: []].append(item) }
            }
        }
        return result
    }

    /// The selection state of `items` (a header's, or one row's) in `selection`.
    public static func selectionState(of items: [NotebookItemID], in selection: Set<NotebookItemID>) -> NotebookRowSelection {
        let selected = items.count { selection.contains($0) }
        return selected == 0 ? .none : (selected == items.count ? .all : .some)
    }

    // MARK: Helpers

    public static func header(for section: NotebookSection) -> NotebookHeader {
        NotebookHeader(kind: .section(section.anchor), title: section.title, level: section.level,
                       pageRange: section.pageRange, startPage: section.startPage)
    }

    /// "Front matter" opens the reader at the first page with an item there.
    public static func frontMatterHeader(_ notebook: Notebook) -> NotebookHeader {
        NotebookHeader(kind: .frontMatter, title: "Front matter", level: 1, pageRange: nil,
                       startPage: notebook.frontMatter.first?.pageIndex)
    }

    public static let unfiledHeader = NotebookHeader(kind: .unfiled, title: "Unfiled notes", level: 1, pageRange: nil, startPage: nil)

    public static func unfiledTitle(_ note: Note) -> String {
        guard let title = note.target.headingAnchor?.title, !title.isEmpty else { return "Untitled heading" }
        return title
    }

    public static func unfiledCount(_ notebook: Notebook) -> Int {
        notebook.orphanNotes.count + notebook.orphanPages.reduce(0) {
            $0 + ($1.note == nil ? 0 : 1) + $1.highlights.count + ($1.hasInk ? 1 : 0)
        }
    }

    public static func findSection(_ anchor: HeadingAnchor, in sections: [NotebookSection]) -> NotebookSection? {
        for section in sections {
            if section.anchor == anchor { return section }
            if let found = findSection(anchor, in: section.children) { return found }
        }
        return nil
    }

    /// "Chapter" for a top-level heading's note, "Section" below (the mockup's labels).
    public static func headingNoteLabel(level: Int) -> String { level <= 1 ? "Chapter" : "Section" }
}
