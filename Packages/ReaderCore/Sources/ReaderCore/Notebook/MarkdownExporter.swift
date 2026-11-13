import Foundation

/// Renders a `Notebook` as Markdown. Output is a pure function of its inputs (byte-for-byte
/// stable), so it can be compared against golden files.
///
/// ## Format
/// Blocks are separated by exactly one blank line; there is no trailing whitespace on any line;
/// the output ends with a single `"\n"`. Line endings are `"\n"`.
/// 1. `# <book title>` (normalised with `OutlineText.normalizedTitle`).
/// 2. If `frontMatter` has exportable pages: `## Front matter`, then its page blocks.
/// 3. Every section of `Notebook.sectionsWithContent`, depth first in outline order:
///    a heading line of `level + 1` hashes (capped at 6) and the title (`## 5 Eigenvalues`,
///    `### 5.2 The Characteristic Equation`); then the heading's note block, if any; then the
///    page blocks of its own pages; then its child sections.
/// 4. If there are orphans with content: `## Unfiled notes`, then for each orphan heading note
///    `### <recorded anchor title>` (or `### Untitled heading` for user headings) and its note
///    block, then the orphan page blocks.
///
/// A **page block** is emitted for a page with a note or highlights (bookmark-only pages are
/// skipped): the line `**Page N**` (1-based), then the note block if any, then one quote block
/// per highlight in reading order: `> <text> (p. N)`, where the text has all whitespace collapsed
/// to single spaces.
///
/// A **note block** is the note's text with line endings normalised to `"\n"`, trailing
/// whitespace removed from each line, and leading and trailing blank lines removed; then, if
/// `imagePath` returns a path, an image line `![Handwritten note](path)` (the path wrapped in
/// `<…>` when it contains spaces or parentheses). A note with no text and no image yields
/// `_Handwritten note_`.
public enum MarkdownExporter {
    /// Exports the notebook.
    /// - Parameters:
    ///   - notebook: from `NotebookBuilder.build`.
    ///   - bookTitle: the book's display title.
    ///   - imagePath: called exactly once per exported note, in output order; returns the image's
    ///     path relative to the Markdown file (e.g. `"images/<noteID>.png"`) or `nil` for no image.
    ///     WP9 returns a path for notes with `hasInk` and renders those images.
    public static func export(_ notebook: Notebook, bookTitle: String,
                              imagePath: (Note) -> String? = { _ in nil }) -> String {
        var blocks: [String] = ["# \(OutlineText.normalizedTitle(bookTitle))"]

        func noteBlocks(_ note: Note) -> [String] {
            var result: [String] = []
            let text = cleanedNoteText(note.text)
            if !text.isEmpty { result.append(text) }
            if let path = imagePath(note) {
                result.append("![Handwritten note](\(markdownDestination(path)))")
            }
            if result.isEmpty { result.append("_Handwritten note_") }
            return result
        }

        func pageBlocks(_ page: NotebookPage) -> [String] {
            guard page.note != nil || !page.highlights.isEmpty else { return [] }
            var result = ["**Page \(PageNumbering.displayNumber(forPageIndex: page.pageIndex))**"]
            if let note = page.note { result += noteBlocks(note) }
            for highlight in page.highlights {
                let text = OutlineText.normalizedTitle(highlight.text)
                result.append("> \(text) (\(PageNumbering.label(forPageIndex: highlight.pageIndex)))")
            }
            return result
        }

        let front = notebook.frontMatter.flatMap(pageBlocks)
        if !front.isEmpty {
            blocks.append("## Front matter")
            blocks += front
        }

        func emit(_ section: NotebookSection) {
            blocks.append(String(repeating: "#", count: min(6, section.level + 1)) + " " + section.title)
            if let note = section.note { blocks += noteBlocks(note) }
            for page in section.pages { blocks += pageBlocks(page) }
            for child in section.children { emit(child) }
        }
        for section in notebook.sectionsWithContent { emit(section) }

        var unfiled: [String] = []
        for note in notebook.orphanNotes {
            let title = note.target.headingAnchor?.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled heading"
            unfiled.append("### \(title)")
            unfiled += noteBlocks(note)
        }
        unfiled += notebook.orphanPages.flatMap(pageBlocks)
        if !unfiled.isEmpty {
            blocks.append("## Unfiled notes")
            blocks += unfiled
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func cleanedNoteText(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = unified.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var line = Substring(line)
            while let last = line.last, last.isWhitespace { line = line.dropLast() }
            return String(line)
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func markdownDestination(_ path: String) -> String {
        path.contains(where: { $0 == " " || $0 == "(" || $0 == ")" }) ? "<\(path)>" : path
    }
}
