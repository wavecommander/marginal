import Foundation

/// One thing the Notebook lists and exports: a note (on a heading or a page), a highlight, or a
/// page's ink.
public enum NotebookItemID: Hashable, Sendable {
    case note(UUID)
    case highlight(UUID)
    /// The ink on a page (zero-based page index).
    case pageInk(Int)
}

extension Notebook {
    /// Every item in the notebook, wherever it is filed (sections, front matter, unfiled).
    public var itemIDs: Set<NotebookItemID> {
        var ids = Set<NotebookItemID>()
        func add(_ page: NotebookPage) {
            if let note = page.note { ids.insert(.note(note.id)) }
            for highlight in page.highlights { ids.insert(.highlight(highlight.id)) }
            if page.hasInk { ids.insert(.pageInk(page.pageIndex)) }
        }
        var stack = sections
        while let section = stack.popLast() {
            if let note = section.note { ids.insert(.note(note.id)) }
            section.pages.forEach(add)
            stack.append(contentsOf: section.children)
        }
        frontMatter.forEach(add)
        orphanPages.forEach(add)
        for note in orphanNotes { ids.insert(.note(note.id)) }
        return ids
    }

    /// The notebook cut down to `items`: the same outline, with every note, highlight and page
    /// ink that is not in `items` removed, pages left with nothing removed, and counts recomputed
    /// (so `sectionsWithContent` and the exports show only headings that still hold something).
    /// Bookmarks stay on the pages that remain. `anchorRepairs` is empty: the result is for
    /// showing and exporting, not for repairing the store.
    public func selecting(_ items: Set<NotebookItemID>) -> Notebook {
        func keep(_ note: Note?) -> Note? {
            guard let note, items.contains(.note(note.id)) else { return nil }
            return note
        }
        func cut(_ page: NotebookPage) -> NotebookPage? {
            let cut = NotebookPage(pageIndex: page.pageIndex, note: keep(page.note),
                                   highlights: page.highlights.filter { items.contains(.highlight($0.id)) },
                                   isBookmarked: page.isBookmarked,
                                   hasInk: page.hasInk && items.contains(.pageInk(page.pageIndex)))
            return cut.hasContent ? cut : nil
        }
        func cut(_ section: NotebookSection) -> NotebookSection {
            let children = section.children.map(cut)
            let pages = section.pages.compactMap(cut)
            let note = keep(section.note)
            let own = pages.reduce(NotebookCounts(headingNotes: note == nil ? 0 : 1)) { $0 + $1.counts }
            return NotebookSection(
                anchor: section.anchor, title: section.title, level: section.level, startPage: section.startPage,
                pageRange: section.pageRange, isUserHeading: section.isUserHeading, note: note,
                noteMatch: note == nil ? nil : section.noteMatch, pages: pages, children: children,
                ownCounts: own, totalCounts: children.reduce(own) { $0 + $1.totalCounts }
            )
        }
        return Notebook(sections: sections.map(cut), frontMatter: frontMatter.compactMap(cut),
                        orphanNotes: orphanNotes.filter { items.contains(.note($0.id)) },
                        orphanPages: orphanPages.compactMap(cut), anchorRepairs: [])
    }
}
