import ReaderCore
import SwiftUI

/// The Bookmarks tab: bookmarked pages in page order with the section each is in and a small
/// thumbnail. Tap jumps; swipe or the context menu removes. Updates from any window through
/// `session.revisions.bookmarks` (the model reloads).
struct BookmarksListView: View {
    let session: ReaderSession
    let model: ContentsSidebarModel

    @ScaledMetric(relativeTo: .body) private var thumbnailWidth: CGFloat = 34

    var body: some View {
        Group {
            if model.bookmarks.isEmpty {
                EmptyBookmarksView(session: session)
            } else {
                let aspect = session.sidebarPageAspect
                List {
                    ForEach(model.bookmarks) { bookmark in
                        BookmarkRow(bookmark: bookmark, session: session, model: model, aspect: aspect,
                                    thumbnailWidth: thumbnailWidth)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { remove(bookmark) } label: {
                                    Label("Remove", systemImage: "bookmark.slash")
                                }
                            }
                            .contextMenu {
                                Button { session.jump(toPage: bookmark.pageIndex) } label: {
                                    Label("Go to Page", systemImage: "arrow.right.circle")
                                }
                                Button(role: .destructive) { remove(bookmark) } label: {
                                    Label("Remove Bookmark", systemImage: "bookmark.slash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier(SidebarAccessibilityID.bookmarksList)
            }
        }
        .onAppear {
            model.start()
            model.reloadBookmarks()
        }
    }

    private func remove(_ bookmark: Bookmark) {
        BookmarkActions.setBookmarked(false, page: bookmark.pageIndex, session: session)
    }
}

private struct BookmarkRow: View {
    let bookmark: Bookmark
    let session: ReaderSession
    let model: ContentsSidebarModel
    let aspect: CGFloat
    let thumbnailWidth: CGFloat

    var body: some View {
        let number = PageNumbering.displayNumber(forPageIndex: bookmark.pageIndex)
        let section = session.outline.deepestHeading(forPage: bookmark.pageIndex)
        let isCurrent = session.currentPageIndex == bookmark.pageIndex
        Button { session.jump(toPage: bookmark.pageIndex) } label: {
            HStack(spacing: 12) {
                SidebarPageThumbnail(pageIndex: bookmark.pageIndex, model: model, aspect: aspect, width: thumbnailWidth)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Page \(number)")
                        .font(.body)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    if let section {
                        HStack(spacing: 4) {
                            Text(section.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if section.isUserHeading { ReaderHeadingMark() }
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "bookmark.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(number)")
        .accessibilityValue([section.map { $0.isUserHeading ? "\($0.title), your heading" : $0.title },
                             isCurrent ? "current page" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Remove Bookmark") {
            BookmarkActions.setBookmarked(false, page: bookmark.pageIndex, session: session)
        }
        .accessibilityIdentifier(SidebarAccessibilityID.bookmark(number))
    }
}

private struct EmptyBookmarksView: View {
    let session: ReaderSession

    var body: some View {
        let number = PageNumbering.displayNumber(forPageIndex: session.currentPageIndex)
        ContentUnavailableView {
            Label("No Bookmarks", systemImage: "bookmark")
        } description: {
            Text("Pages you bookmark appear here.")
        } actions: {
            Button("Bookmark Page \(number)") { BookmarkActions.toggle(session: session) }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SidebarAccessibilityID.emptyBookmarks)
    }
}
