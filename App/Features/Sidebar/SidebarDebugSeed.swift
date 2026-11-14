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

    /// `-seedSidebarHeadings`: when the book has no user headings, builds a reader's outline
    /// through `UserHeadingEditor` (as the add sheet does), for the hand-built outline
    /// screenshot on `no-outline.pdf`: "1 Getting Started" (p. 1) › "1.1 Setting Up" (p. 3),
    /// "1.2 First Steps" (p. 6); "2 Working with Data" (p. 10) › "2.1 Tables" (p. 12) ›
    /// "2.1.1 Sorting" (p. 13); "3 Reference" (p. 25).
    static let headingsArgument = "-seedSidebarHeadings"

    static func seedHeadingsIfRequested(session: ReaderSession) {
        guard ProcessInfo.processInfo.arguments.contains(headingsArgument),
              ((try? session.store.headings.userHeadings(bookID: session.book.id)) ?? []).isEmpty else { return }
        let bookID = session.book.id
        func heading(_ title: String, _ page: Int, under parent: UserHeading?, _ order: TimeInterval) -> UserHeading {
            UserHeading(bookID: bookID, title: title, pageIndex: page - 1, parent: parent?.anchor,
                        createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + order))
        }
        let one = heading("1 Getting Started", 1, under: nil, 1)
        let two = heading("2 Working with Data", 10, under: nil, 4)
        let tables = heading("2.1 Tables", 12, under: two, 5)
        let all = [one, heading("1.1 Setting Up", 3, under: one, 2), heading("1.2 First Steps", 6, under: one, 3),
                   two, tables, heading("2.1.1 Sorting", 13, under: tables, 6), heading("3 Reference", 25, under: nil, 7)]
        try? session.perform { store in
            for item in all where PageNumbering.isValid(item.pageIndex, pageCount: session.book.pageCount) {
                try store.headings.save(item)
            }
        }
    }

    static func seedIfRequested(session: ReaderSession) {
        seedHeadingsIfRequested(session: session)
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
