import ReaderCore

/// The bookmark toggle used by the reader toolbar, the "Add/Remove Bookmark" command (⌘D) and
/// the sidebar. Every write goes through `session.perform`, so the change is attributed to this
/// window and every window on the book (toolbar, menu title, Bookmarks tab, Pages flags)
/// updates through `session.revisions.bookmarks`.
@MainActor
enum BookmarkActions {
    /// Whether the session's current page is bookmarked.
    static func isBookmarked(session: ReaderSession) -> Bool {
        // The shell reads this from the toolbar and the menu bar for every reader window, so it
        // is the earliest WP5 code each session reaches: install the "Add as Heading" selection
        // item here too (idempotent). See `SidebarHeadingActions.install(on:)`.
        SidebarHeadingActions.install(on: session)
        return isBookmarked(page: session.currentPageIndex, session: session)
    }

    /// Adds or removes the bookmark on the session's current page.
    static func toggle(session: ReaderSession) {
        let page = session.currentPageIndex
        setBookmarked(!isBookmarked(page: page, session: session), page: page, session: session)
    }

    /// Whether a zero-based page is bookmarked.
    static func isBookmarked(page: Int, session: ReaderSession) -> Bool {
        (try? session.store.bookmarks.isBookmarked(bookID: session.book.id, pageIndex: page)) ?? false
    }

    /// Adds or removes the bookmark on a zero-based page.
    static func setBookmarked(_ bookmarked: Bool, page: Int, session: ReaderSession) {
        guard PageNumbering.isValid(page, pageCount: session.pageCount) || !bookmarked else { return }
        try? session.perform {
            try $0.bookmarks.setBookmarked(bookmarked, bookID: session.book.id, pageIndex: page)
        }
    }
}
