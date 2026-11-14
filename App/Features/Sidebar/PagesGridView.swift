import PDFKit
import ReaderCore
import SwiftUI

/// The Pages tab: a lazy grid of thumbnails for the whole book. Only cells on (or near) screen
/// exist; each loads its thumbnail through the window's `ThumbnailLoader` in a task that is
/// cancelled when the cell scrolls away. The current page is marked and scrolled into view when
/// the tab opens; bookmarked, noted and highlighted pages are flagged (ink is not: owner decision, ink
/// navigation lives in the Notebook). Tapping jumps.
struct PagesGridView: View {
    let session: ReaderSession
    let model: ContentsSidebarModel
    let actions: SidebarActions

    @ScaledMetric(relativeTo: .caption) private var minimumCellWidth: CGFloat = 96

    var body: some View {
        let aspect = session.sidebarPageAspect
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumCellWidth, maximum: 180), spacing: 12)],
                          spacing: 14) {
                    ForEach(0..<session.pageCount, id: \.self) { index in
                        PageThumbnailCell(pageIndex: index, aspect: aspect, session: session, model: model,
                                          actions: actions)
                            .id(index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier(SidebarAccessibilityID.pagesGrid)
            .onAppear {
                model.start()
                let current = session.currentPageIndex
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(current, anchor: .center)
                }
                #if DEBUG
                SidebarDebugStats.runAutoScroll(scrollTo: { proxy.scrollTo($0, anchor: .top) },
                                                pageCount: session.pageCount)
                #endif
            }
            #if DEBUG
            .overlay(alignment: .bottom) {
                if SidebarDebugStats.isEnabled { SidebarDebugStatsView(model: model) }
            }
            #endif
        }
    }
}

private struct PageThumbnailCell: View {
    let pageIndex: Int
    let aspect: CGFloat
    let session: ReaderSession
    let model: ContentsSidebarModel
    let actions: SidebarActions

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    init(pageIndex: Int, aspect: CGFloat, session: ReaderSession, model: ContentsSidebarModel, actions: SidebarActions) {
        self.pageIndex = pageIndex
        self.aspect = aspect
        self.session = session
        self.model = model
        self.actions = actions
        _image = State(initialValue: model.thumbnails.cachedImage(forPage: pageIndex))
    }

    var body: some View {
        let number = PageNumbering.displayNumber(forPageIndex: pageIndex)
        let isCurrent = session.currentPageIndex == pageIndex
        let isBookmarked = model.bookmarkedPages.contains(pageIndex)
        let marks = model.pageMarks[pageIndex] ?? []

        Button { session.jump(toPage: pageIndex) } label: {
            VStack(spacing: 5) {
                thumbnail
                    .overlay(alignment: .topTrailing) {
                        if isBookmarked {
                            Image(systemName: "bookmark.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(4)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        flags(marks: marks)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isCurrent ? Color.accentColor : Color(uiColor: .separator),
                                          lineWidth: isCurrent ? 3 : 0.5)
                    }
                Text(verbatim: "\(number)")
                    .font(.caption)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(number)")
        .accessibilityValue(accessibilityValue(isCurrent: isCurrent, isBookmarked: isBookmarked, marks: marks))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier(SidebarAccessibilityID.page(number))
        .contextMenu {
            Button { session.jump(toPage: pageIndex) } label: { Label("Go to Page \(number)", systemImage: "arrow.right.circle") }
            Button { actions.addHeading(pageIndex) } label: { Label("Add Heading at Page \(number)", systemImage: "plus") }
            Button {
                BookmarkActions.setBookmarked(!isBookmarked, page: pageIndex, session: session)
            } label: {
                Label(isBookmarked ? "Remove Bookmark" : "Bookmark Page",
                      systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
            }
        }
        .task(id: pageIndex) {
            guard image == nil else { return }
            let size = CGSize(width: PageThumbnailCellMetrics.renderWidth,
                              height: PageThumbnailCellMetrics.renderWidth / aspect)
            if let loaded = await model.thumbnails.image(forPage: pageIndex, size: size, scale: displayScale) {
                image = loaded
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(Color.white)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
    }

    @ViewBuilder
    private func flags(marks: ContentsSidebarModel.PageMarks) -> some View {
        if !marks.isEmpty {
            HStack(spacing: 3) {
                if marks.contains(.note) { Image(systemName: "note.text") }
                if marks.contains(.highlight) { Image(systemName: "highlighter") }
            }
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor))
            .padding(4)
        }
    }

    private func accessibilityValue(isCurrent: Bool, isBookmarked: Bool, marks: ContentsSidebarModel.PageMarks) -> String {
        var parts: [String] = []
        if isCurrent { parts.append("current page") }
        if isBookmarked { parts.append("bookmarked") }
        if marks.contains(.note) { parts.append("has a note") }
        if marks.contains(.highlight) { parts.append("has highlights") }
        return parts.joined(separator: ", ")
    }
}

/// A small page thumbnail from the shared loader (Bookmarks list).
struct SidebarPageThumbnail: View {
    let pageIndex: Int
    let model: ContentsSidebarModel
    let aspect: CGFloat
    let width: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    init(pageIndex: Int, model: ContentsSidebarModel, aspect: CGFloat, width: CGFloat) {
        self.pageIndex = pageIndex
        self.model = model
        self.aspect = aspect
        self.width = width
        _image = State(initialValue: model.thumbnails.cachedImage(forPage: pageIndex))
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: width, height: width / aspect)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: pageIndex) {
            guard image == nil else { return }
            let size = CGSize(width: PageThumbnailCellMetrics.renderWidth,
                              height: PageThumbnailCellMetrics.renderWidth / aspect)
            if let loaded = await model.thumbnails.image(forPage: pageIndex, size: size, scale: displayScale) {
                image = loaded
            }
        }
    }
}

enum PageThumbnailCellMetrics {
    /// Thumbnails are rendered at one size (points) everywhere, so the Pages grid and the
    /// Bookmarks list share cached images.
    static let renderWidth: CGFloat = 120
}

extension ReaderSession {
    /// Width / height of the first page (0.77 before the document opens). Every thumbnail cell
    /// uses it, so all cells have one height and scrolling to a far page needs no measuring.
    var sidebarPageAspect: CGFloat {
        guard let bounds = document?.page(at: 0)?.bounds(for: .cropBox), bounds.height > 0 else { return 0.77 }
        return min(max(bounds.width / bounds.height, 0.4), 2)
    }
}
