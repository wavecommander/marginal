#if DEBUG
import Foundation
import ReaderCore

/// DEBUG-only seeding for sidebar screenshots and UI tests (read from the process arguments here,
/// so the shell's `LaunchOptions` is untouched).
///
/// `-seedSidebar`: when a window's sidebar model starts and its book has no notes, adds through
/// the session (`session.perform`), on zero-based pages clamped to the book:
/// page notes on 120, 235, 311 and 404; highlights on 312 and 420; bookmarks on 311, 450 and 1199.
/// On `large.pdf` that badges chapters 2–5 and, at page 312, the current section "4.1.3 Summary".
@MainActor
enum SidebarDebugSeed {
    static let argument = "-seedSidebar"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func seedIfRequested(session: ReaderSession) {
        guard isRequested else { return }
        let bookID = session.book.id
        guard ((try? session.store.notes.noteCount(bookID: bookID)) ?? 0) == 0 else { return }
        let last = max(0, session.book.pageCount - 1)
        func page(_ index: Int) -> Int { min(index, last) }
        try? session.perform { store in
            for (index, text) in [(120, "Row reduction recap"), (235, "Kernel and image"),
                                  (311, "Cofactor expansion"), (404, "Why eigenvectors")] {
                _ = try store.notes.save(Note(bookID: bookID, target: .page(page(index)), text: text))
            }
            for (index, color) in [(312, HighlightColor.yellow), (420, .green)] {
                try store.highlights.save(Highlight(bookID: bookID, pageIndex: page(index), rects: [], color: color,
                                                    text: "Seeded highlight"))
            }
            for index in [311, 450, 1199] {
                try store.bookmarks.setBookmarked(true, bookID: bookID, pageIndex: page(index))
            }
        }
    }
}
#endif
