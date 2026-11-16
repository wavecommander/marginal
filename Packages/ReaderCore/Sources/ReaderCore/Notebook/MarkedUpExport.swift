import Foundation

/// One entry of an exported PDF's outline (the bookmarks a PDF viewer lists): a title, the
/// 1-based page of the exported file it opens, and its children in order.
public struct ExportOutlineItem: Hashable, Sendable {
    public var title: String
    /// 1-based page number in the exported file.
    public var pageNumber: Int
    public var children: [ExportOutlineItem]

    public init(title: String, pageNumber: Int, children: [ExportOutlineItem] = []) {
        self.title = title
        self.pageNumber = pageNumber
        self.children = children
    }

    /// This item and every descendant, in pre-order (for tests and counts).
    public var flattened: [ExportOutlineItem] { [self] + children.flatMap(\.flattened) }
}

/// A part of the Notebook as the Notebook's PDF drawing lays it out: where each one starts is
/// recorded while the notes are written, so the export's outline can open it.
public enum NotebookExportPart: Hashable, Sendable {
    /// The title block at the top of the first page.
    case title
    /// "Front matter": pages with notes before the first heading.
    case frontMatter
    /// A heading's header (its current anchor).
    case section(HeadingAnchor)
    /// "Unfiled notes".
    case unfiled
}

/// The pure parts of exporting a book as a marked-up PDF (design: "Export" ▸ Marked-up PDF):
/// the file name, the export's outline (the book's own, then the notes appendix), and the page
/// mapping. The PDF itself is written by the app.
///
/// **Pages.** The export holds every page of the book, in order, so book page index `i` is page
/// `i + 1` of the export; the notes appendix, when included, starts on page `pageCount + 1`.
public enum MarkedUpExport {
    /// Title of the notes appendix (its first page's heading and its outline entry).
    public static let appendixTitle = "Notes"

    /// `"<Title> (Marked Up).pdf"`, or `"<Title> (Marked Up with Notes).pdf"` when the notes
    /// appendix is included. Characters that are unsafe in file names are replaced
    /// (`ExportFileName.cleanedTitle`); a blank title gives `"Book"`.
    public static func fileName(forBookTitle title: String, includesNotes: Bool) -> String {
        let base = ExportFileName.cleanedTitle(title) ?? "Book"
        return includesNotes ? "\(base) (Marked Up with Notes).pdf" : "\(base) (Marked Up).pdf"
    }

    /// 1-based page of the export for a book page index.
    public static func exportPageNumber(forBookPageIndex pageIndex: Int) -> Int { pageIndex + 1 }

    /// 1-based page of the export the notes appendix starts on.
    public static func appendixFirstPageNumber(bookPageCount: Int) -> Int { max(0, bookPageCount) + 1 }

    /// The book's outline as the export carries it: every heading of the merged outline (the
    /// PDF's own and the reader's own, exactly as Contents shows them: design, "The reader's own
    /// headings" ▸ everywhere a heading matters, exports included), in display order and nesting,
    /// each opening its page.
    ///
    /// A heading opens its own page; one without a page of its own (a PDF outline item with no
    /// destination) opens its start page (its first descendant's page), else its parent's page,
    /// else the first page. A PDF outline entry always needs a destination, so none is dropped.
    /// Headings jump to the top of their page (the app's own outline keeps no position on the
    /// page).
    public static func bookOutline(_ outline: Outline) -> [ExportOutlineItem] {
        func items(_ nodes: [OutlineNode], parentPage: Int) -> [ExportOutlineItem] {
            nodes.map { node in
                let page = node.pageIndex ?? node.startPage ?? parentPage
                return ExportOutlineItem(title: node.title, pageNumber: exportPageNumber(forBookPageIndex: page),
                                         children: items(node.children, parentPage: page))
            }
        }
        return items(outline.roots, parentPage: 0)
    }

    /// The notes appendix's outline entry: `appendixTitle` opening the appendix's first page, with
    /// "Front matter", every heading with notes in its subtree (nested as in the book's outline)
    /// and "Unfiled notes" under it, each opening the page its header was drawn on (`starts`, as
    /// the Notebook drawing recorded them; a part not recorded opens its parent's page). `nil`
    /// when the appendix has no first page.
    ///
    /// - Parameter notebook: the appendix's Notebook (notes only).
    public static func appendixOutline(_ notebook: Notebook, starts: [NotebookExportPart: Int]) -> ExportOutlineItem? {
        guard let first = starts[.title] else { return nil }
        var children: [ExportOutlineItem] = []
        if notebook.frontMatter.contains(where: \.hasContent) {
            children.append(ExportOutlineItem(title: "Front matter", pageNumber: starts[.frontMatter] ?? first))
        }
        func items(_ sections: [NotebookSection], parentPage: Int) -> [ExportOutlineItem] {
            sections.map { section in
                let page = starts[.section(section.anchor)] ?? parentPage
                return ExportOutlineItem(title: section.title, pageNumber: page,
                                         children: items(section.children, parentPage: page))
            }
        }
        children += items(notebook.sectionsWithContent, parentPage: first)
        if !notebook.orphanNotes.isEmpty || notebook.orphanPages.contains(where: \.hasContent) {
            children.append(ExportOutlineItem(title: "Unfiled notes", pageNumber: starts[.unfiled] ?? first))
        }
        return ExportOutlineItem(title: appendixTitle, pageNumber: first, children: children)
    }

    /// The export's whole outline: the book's, then the appendix's entry when there is one.
    public static func outline(book: [ExportOutlineItem], appendix: ExportOutlineItem?) -> [ExportOutlineItem] {
        book + (appendix.map { [$0] } ?? [])
    }
}

/// File names of exports made from a book's title.
public enum ExportFileName {
    /// The title with characters that are unsafe in file names replaced by spaces, runs of white
    /// space collapsed, leading dots removed and at most `maxLength` characters; `nil` when
    /// nothing is left.
    public static func cleanedTitle(_ title: String, maxLength: Int = 80) -> String? {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var cleaned = String(String.UnicodeScalarView(title.unicodeScalars.map { unsafe.contains($0) ? " " : $0 }))
        cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }
}
