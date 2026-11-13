import ReaderCore

/// PLACEHOLDER owned by WP5: the bookmark toggle used by the reader toolbar and the
/// "Add/Remove Bookmark" command. Keep the type name and the two signatures; the bodies may
/// change. The toolbar re-reads `isBookmarked` when `session.revisions.bookmarks` or the
/// current page changes.
@MainActor
enum BookmarkActions {
    /// Whether the session's current page is bookmarked.
    static func isBookmarked(session: ReaderSession) -> Bool {
        (try? session.store.bookmarks.isBookmarked(bookID: session.book.id,
                                                   pageIndex: session.currentPageIndex)) ?? false
    }

    /// Adds or removes the bookmark on the session's current page.
    static func toggle(session: ReaderSession) {
        let bookmarked = isBookmarked(session: session)
        try? session.perform {
            try $0.bookmarks.setBookmarked(!bookmarked, bookID: session.book.id,
                                           pageIndex: session.currentPageIndex)
        }
    }
}
