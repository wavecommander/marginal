import Foundation

/// Item counts for a heading, a bucket or the whole book.
public struct NotebookCounts: Hashable, Sendable {
    /// Notes attached to headings.
    public var headingNotes: Int = 0
    /// Notes attached to pages.
    public var pageNotes: Int = 0
    /// Highlights.
    public var highlights: Int = 0
    /// Bookmarked pages (never badge).
    public var bookmarks: Int = 0
    /// Pages with page ink (Pencil highlighter strokes and drawings alike). Listed in the
    /// Notebook, never a Contents badge (owner decision, 14 November 2026).
    public var inkedPages: Int = 0

    public init(headingNotes: Int = 0, pageNotes: Int = 0, highlights: Int = 0, bookmarks: Int = 0,
                inkedPages: Int = 0) {
        self.headingNotes = headingNotes
        self.pageNotes = pageNotes
        self.highlights = highlights
        self.bookmarks = bookmarks
        self.inkedPages = inkedPages
    }

    /// `headingNotes + pageNotes`.
    public var notes: Int { headingNotes + pageNotes }
    /// The Contents badge rule: any note or highlight (bookmarks and page ink do not badge).
    public var hasBadge: Bool { notes + highlights > 0 }
    /// What the Notebook lists and counts: notes, highlights and pages with ink.
    public var items: Int { notes + highlights + inkedPages }
    /// Whether the Notebook shows anything here (`items > 0`).
    public var hasContent: Bool { items > 0 }
    /// No items of any kind.
    public var isEmpty: Bool { notes + highlights + bookmarks + inkedPages == 0 }

    static func + (a: Self, b: Self) -> Self {
        Self(headingNotes: a.headingNotes + b.headingNotes, pageNotes: a.pageNotes + b.pageNotes,
             highlights: a.highlights + b.highlights, bookmarks: a.bookmarks + b.bookmarks,
             inkedPages: a.inkedPages + b.inkedPages)
    }
}

/// Everything on one page: its note, highlights (reading order), bookmark flag and whether it
/// has page ink. Only pages with at least one item appear in a notebook.
public struct NotebookPage: Hashable, Sendable, Identifiable {
    /// Zero-based page index (also the `id`).
    public let pageIndex: Int
    public let note: Note?
    /// Sorted by `Highlight.readingOrder`.
    public let highlights: [Highlight]
    public let isBookmarked: Bool
    /// The page has ink (`InkStore.inkedPageIndices`): the Notebook lists it as its own entry.
    public let hasInk: Bool

    public var id: Int { pageIndex }
    /// Whether the Notebook and its exports show this page: a note, a highlight or ink
    /// (bookmark-only pages are not shown).
    public var hasContent: Bool { note != nil || !highlights.isEmpty || hasInk }
    var counts: NotebookCounts {
        NotebookCounts(pageNotes: note == nil ? 0 : 1, highlights: highlights.count, bookmarks: isBookmarked ? 1 : 0,
                       inkedPages: hasInk ? 1 : 0)
    }
}

/// One heading of the outline with its items. The section tree mirrors the outline exactly
/// (every heading, including empty ones, in display order).
public struct NotebookSection: Hashable, Sendable, Identifiable {
    /// The heading's current anchor (also the `id`).
    public let anchor: HeadingAnchor
    public let title: String
    /// 1-based outline level.
    public let level: Int
    /// `OutlineNode.startPage` (where "open in reader" jumps).
    public let startPage: Int?
    /// `OutlineNode.pageRange`.
    public let pageRange: ClosedRange<Int>?
    /// `true` for headings the reader added.
    public let isUserHeading: Bool
    /// The heading's own note, if any.
    public let note: Note?
    /// How the note's stored anchor matched this heading (`nil` when there is no note). A
    /// non-exact match means the stored anchor is stale; see `Notebook.anchorRepairs`.
    public let noteMatch: AnchorMatchQuality?
    /// Pages whose deepest heading is this one and that have items, ascending.
    public let pages: [NotebookPage]
    public let children: [NotebookSection]
    /// The heading's own note plus the items on `pages`.
    public let ownCounts: NotebookCounts
    /// `ownCounts` plus every descendant's `ownCounts`.
    public let totalCounts: NotebookCounts

    public var id: HeadingAnchor { anchor }
    /// `children`, or `nil` when empty (for `OutlineGroup`).
    public var childrenIfAny: [NotebookSection]? { children.isEmpty ? nil : children }
}

/// The per-book tree the Notebook screen, the Contents badges and the Markdown export render.
/// Built by `NotebookBuilder.build`.
public struct Notebook: Sendable {
    /// Top-level sections, mirroring `Outline.roots`.
    public let sections: [NotebookSection]
    /// Pages with items that no heading contains (before the first heading, or every page when
    /// the outline is empty or has no ranges), ascending. Shown as "Front matter".
    public let frontMatter: [NotebookPage]
    /// Heading notes whose anchor resolves to no heading, or lost the heading to a stronger
    /// match (see `Outline.resolveAll`). Kept, never dropped. Sorted by the anchor's recorded
    /// title, then `createdAt`, then `id`.
    public let orphanNotes: [Note]
    /// Pages with items whose page index is outside the book (`< 0` or `>= pageCount`), and
    /// page notes that lost a duplicate-target conflict. Ascending by page.
    public let orphanPages: [NotebookPage]
    /// Rolled-up counts per heading (every heading has an entry).
    public let countsByAnchor: [HeadingAnchor: NotebookCounts]
    /// Anchors of every heading whose rolled-up counts have a badge (`NotebookCounts.hasBadge`).
    public let badgedAnchors: Set<HeadingAnchor>
    /// Heading notes whose stored target is stale: `(noteID, current target)`. The caller may
    /// apply them with `RecordStore.retarget` so later lookups by the current anchor are exact.
    public let anchorRepairs: [(noteID: UUID, target: NoteTarget)]
    /// Counts of `frontMatter`.
    public let frontMatterCounts: NotebookCounts
    /// Counts of everything, orphans included.
    public let totalCounts: NotebookCounts

    private let sectionsByAnchor: [HeadingAnchor: NotebookSection]

    init(sections: [NotebookSection], frontMatter: [NotebookPage], orphanNotes: [Note], orphanPages: [NotebookPage],
         anchorRepairs: [(noteID: UUID, target: NoteTarget)]) {
        self.sections = sections
        self.frontMatter = frontMatter
        self.orphanNotes = orphanNotes
        self.orphanPages = orphanPages
        self.anchorRepairs = anchorRepairs
        var counts: [HeadingAnchor: NotebookCounts] = [:]
        var byAnchor: [HeadingAnchor: NotebookSection] = [:]
        var stack = sections
        while let section = stack.popLast() {
            counts[section.anchor] = section.totalCounts
            byAnchor[section.anchor] = section
            stack.append(contentsOf: section.children)
        }
        countsByAnchor = counts
        badgedAnchors = Set(counts.filter { $0.value.hasBadge }.keys)
        sectionsByAnchor = byAnchor
        frontMatterCounts = frontMatter.reduce(NotebookCounts()) { $0 + $1.counts }
        let orphanCounts = orphanPages.reduce(NotebookCounts(headingNotes: orphanNotes.count)) { $0 + $1.counts }
        totalCounts = sections.reduce(frontMatterCounts + orphanCounts) { $0 + $1.totalCounts }
    }

    /// Rolled-up counts for a heading (zero for an unknown anchor).
    public func counts(for anchor: HeadingAnchor) -> NotebookCounts { countsByAnchor[anchor] ?? NotebookCounts() }
    /// Whether the heading shows a note badge in Contents. O(1).
    public func hasBadge(_ anchor: HeadingAnchor) -> Bool { badgedAnchors.contains(anchor) }
    /// The section for a heading's current anchor. O(1).
    public func section(for anchor: HeadingAnchor) -> NotebookSection? { sectionsByAnchor[anchor] }

    /// `sections` pruned to headings with any note, highlight or inked page in their subtree
    /// (`NotebookCounts.hasContent`), recursively; what the Notebook feed and the export show.
    public var sectionsWithContent: [NotebookSection] { Self.prune(sections) }

    /// Pages with ink, ascending, wherever they are filed (sections, front matter, orphans).
    public var inkedPageIndices: [Int] {
        var pages: [Int] = []
        var stack = sections
        while let section = stack.popLast() {
            pages += section.pages.lazy.filter(\.hasInk).map(\.pageIndex)
            stack.append(contentsOf: section.children)
        }
        pages += (frontMatter + orphanPages).lazy.filter(\.hasInk).map(\.pageIndex)
        return pages.sorted()
    }

    static func prune(_ sections: [NotebookSection]) -> [NotebookSection] {
        sections.compactMap { section in
            guard section.totalCounts.hasContent else { return nil }
            return NotebookSection(
                anchor: section.anchor, title: section.title, level: section.level, startPage: section.startPage,
                pageRange: section.pageRange, isUserHeading: section.isUserHeading, note: section.note,
                noteMatch: section.noteMatch, pages: section.pages, children: prune(section.children),
                ownCounts: section.ownCounts, totalCounts: section.totalCounts
            )
        }
    }
}

/// Builds a `Notebook` from a book's outline and items.
public enum NotebookBuilder {
    /// Groups a book's items along its outline. Pure and `Sendable`-safe; run it off the main
    /// thread for large books. All inputs must belong to one book (not checked).
    ///
    /// **Rules:**
    /// - *Page items* (page notes, highlights, bookmarks, page ink) on page `p` are filed once, under
    ///   `outline.deepestHeading(forPage: p)`; with no such heading they go to `frontMatter`;
    ///   pages outside `0..<outline.pageCount` go to `orphanPages`.
    /// - *Heading notes* are matched with `outline.resolveAll` (one note per heading; the
    ///   strongest match wins). A resolved note becomes its section's `note`; the others go to
    ///   `orphanNotes`. Non-exact matches are listed in `anchorRepairs`.
    /// - If two page notes share a page (a store invariant was broken), the one with the latest
    ///   `modifiedAt` (then greatest `id.uuidString`) is kept and the other goes to `orphanPages`.
    /// - *Page ink*: each page in `inkedPages` is one entry (`NotebookPage.hasInk`), counted once
    ///   in `NotebookCounts.inkedPages` however many strokes it holds. A page with a note,
    ///   highlights and ink is one `NotebookPage` carrying all three. Duplicates are ignored.
    /// - Counts: a section's `ownCounts` are its note plus its own pages' items; `totalCounts`
    ///   add all descendants. A heading has a badge when `totalCounts.hasBadge` (its own note,
    ///   or any note or highlight on a page it contains, through any descendant); page ink never
    ///   badges, but it does make a heading appear in `sectionsWithContent` (`hasContent`).
    /// - Parameter inkedPages: zero-based pages with page ink (`InkStore.inkedPageIndices`).
    public static func build(outline: Outline, notes: [Note], highlights: [Highlight],
                             bookmarks: [Bookmark] = [], inkedPages: [Int] = []) -> Notebook {
        // Page items.
        var pageNotes: [Int: Note] = [:]
        var duplicateNotes: [Note] = []
        var headingNotes: [Note] = []
        for note in notes {
            switch note.target {
            case .heading:
                headingNotes.append(note)
            case .page(let page):
                if let existing = pageNotes[page] {
                    let keepNew = (note.modifiedAt, note.id.uuidString) > (existing.modifiedAt, existing.id.uuidString)
                    pageNotes[page] = keepNew ? note : existing
                    duplicateNotes.append(keepNew ? existing : note)
                } else {
                    pageNotes[page] = note
                }
            }
        }
        var highlightsByPage: [Int: [Highlight]] = [:]
        for highlight in highlights { highlightsByPage[highlight.pageIndex, default: []].append(highlight) }
        let bookmarked = Set(bookmarks.map(\.pageIndex))
        let inked = Set(inkedPages)

        let pagesWithItems = Set(pageNotes.keys).union(highlightsByPage.keys).union(bookmarked).union(inked).sorted()
        var pagesByOwner: [HeadingAnchor: [NotebookPage]] = [:]
        var frontMatter: [NotebookPage] = []
        var orphanPages: [NotebookPage] = []
        for page in pagesWithItems {
            let item = NotebookPage(pageIndex: page, note: pageNotes[page],
                                    highlights: (highlightsByPage[page] ?? []).sorted(by: Highlight.readingOrder),
                                    isBookmarked: bookmarked.contains(page), hasInk: inked.contains(page))
            if !PageNumbering.isValid(page, pageCount: outline.pageCount) {
                orphanPages.append(item)
            } else if let owner = outline.deepestHeading(forPage: page) {
                pagesByOwner[owner.anchor, default: []].append(item)
            } else {
                frontMatter.append(item)
            }
        }
        for note in duplicateNotes {
            orphanPages.append(NotebookPage(pageIndex: note.target.pageIndex ?? 0, note: note, highlights: [], isBookmarked: false,
                                           hasInk: false))
        }
        orphanPages.sort { ($0.pageIndex, $0.note?.id.uuidString ?? "") < ($1.pageIndex, $1.note?.id.uuidString ?? "") }

        // Heading notes.
        let notesByAnchor = Dictionary(headingNotes.map { ($0.target.headingAnchor!, $0) }, uniquingKeysWith: { a, _ in a })
        let matches = outline.resolveAll(notesByAnchor.keys)
        var noteForNode: [HeadingAnchor: (note: Note, quality: AnchorMatchQuality)] = [:]
        var repairs: [(noteID: UUID, target: NoteTarget)] = []
        var claimed = Set<UUID>()
        for (stored, match) in matches {
            let note = notesByAnchor[stored]!
            noteForNode[match.node.anchor] = (note, match.quality)
            claimed.insert(note.id)
            if !match.isExact { repairs.append((note.id, .heading(match.node.anchor))) }
        }
        repairs.sort { $0.noteID.uuidString < $1.noteID.uuidString }
        let orphanNotes = headingNotes.filter { !claimed.contains($0.id) }.sorted { a, b in
            let ta = a.target.headingAnchor?.title ?? "", tb = b.target.headingAnchor?.title ?? ""
            if ta != tb { return ta < tb }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }

        func makeSection(_ node: OutlineNode) -> NotebookSection {
            let children = node.children.map(makeSection)
            let pages = pagesByOwner[node.anchor] ?? []
            let own = noteForNode[node.anchor]
            let ownCounts = pages.reduce(NotebookCounts(headingNotes: own == nil ? 0 : 1)) { $0 + $1.counts }
            let total = children.reduce(ownCounts) { $0 + $1.totalCounts }
            return NotebookSection(
                anchor: node.anchor, title: node.title, level: node.level, startPage: node.startPage,
                pageRange: node.pageRange, isUserHeading: node.isUserHeading, note: own?.note,
                noteMatch: own?.quality, pages: pages, children: children, ownCounts: ownCounts, totalCounts: total
            )
        }

        return Notebook(sections: outline.roots.map(makeSection), frontMatter: frontMatter, orphanNotes: orphanNotes,
                        orphanPages: orphanPages, anchorRepairs: repairs)
    }
}
