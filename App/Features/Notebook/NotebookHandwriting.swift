import PDFKit
import PencilKit
import ReaderCore
import SwiftUI
import UIKit

// Ink navigation: a Notebook row for each page with page ink, showing the page with its
// ink, so whatever the Pencil put on a page (highlighter strokes and drawings alike) can be found
// and returned to (design: "Ink is navigable like highlights and bookmarks").

extension NotebookAccessibilityID {
    /// A page with ink: `notebook.handwriting.<1-based page>`.
    static func handwriting(_ displayPage: Int) -> String { "notebook.handwriting.\(displayPage)" }
}

/// Labels of a handwriting row.
nonisolated enum NotebookHandwriting {
    /// The row's VoiceOver label: "Handwriting, page N".
    static func accessibilityLabel(pageIndex: Int) -> String {
        "Handwriting, page \(PageNumbering.displayNumber(forPageIndex: pageIndex))"
    }
}

// MARK: - Drawing a book page

/// Draws a page of the book as the PDF draws it, in ink space, so ink drawn after it over the
/// same target lands where it was written. Thread-safe for a page of a document no other thread
/// uses (the preview renderer's private document, or the exporter's own).
nonisolated enum BookPageDrawing {
    /// Draws `page` so that ink space (its crop box, upright: `geometry`) fills `target` in a
    /// y-down `context` (UIKit orientation: `UIGraphicsImageRenderer`, the Notebook PDF writer).
    /// The page's content is drawn as vector (`CGContext.drawPDFPage`): text stays text in a PDF
    /// context. Annotations of the PDF are not drawn. Fills nothing: draw the paper first.
    static func draw(_ page: PDFPage, geometry: PageInkGeometry, in context: CGContext, target: CGRect) {
        let size = geometry.size
        guard let cgPage = page.pageRef, size.width > 0, size.height > 0, target.width > 0, target.height > 0 else { return }
        context.saveGState()
        context.clip(to: target)
        context.translateBy(x: target.minX, y: target.minY)
        context.scaleBy(x: target.width / size.width, y: target.height / size.height)
        // Ink space ← page space (y up, the PDF's own coordinates).
        context.concatenate(geometry.pageToInk)
        context.clip(to: geometry.cropBox)
        context.interpolationQuality = .high
        context.drawPDFPage(cgPage)
        context.restoreGState()
    }
}

// MARK: - Rendering previews off the main thread

/// Renders previews of inked pages (white paper, the page, its ink as stored) off the main thread
/// from a **private** `PDFDocument`, never the on-screen one. Requests are serialised; a request
/// whose task was cancelled before it started returns `nil` without rendering.
actor NotebookPageRenderer {
    nonisolated struct Preview: @unchecked Sendable {
        /// Immutable once made.
        let image: UIImage
        /// The page's size in ink space (points): its aspect ratio.
        let pageSize: CGSize
    }

    private let url: URL
    private var document: PDFDocument?
    /// Pages rendered (tests and diagnostics).
    private(set) var renderCount = 0

    init(url: URL) {
        self.url = url
    }

    /// The page with `inkData` drawn over it, `width` points wide at `scale` pixels per point,
    /// height from the page's aspect ratio. `nil` if the page does not exist, the data is not a
    /// readable drawing, or the task was cancelled first.
    func preview(pageIndex: Int, inkData: Data, width: CGFloat, scale: CGFloat) -> Preview? {
        guard !Task.isCancelled else { return nil }
        if document == nil { document = PDFDocument(url: url) }
        guard let page = document?.page(at: pageIndex), let drawing = try? PKDrawing(data: inkData) else { return nil }
        let geometry = PageInkGeometry(page: page)
        let pageSize = geometry.size
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let size = CGSize(width: width, height: (width * pageSize.height / pageSize.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        // 8-bit sRGB (4 bytes a pixel), not the wide-colour default (8): previews are cached.
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let target = CGRect(origin: .zero, size: size)
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(target)
            BookPageDrawing.draw(page, geometry: geometry, in: context.cgContext, target: target)
            PageInkRenderer.drawBitmap(drawing, geometry: geometry, in: context.cgContext, target: target,
                                       pixelsPerPoint: scale)
        }
        renderCount += 1
        return Preview(image: image, pageSize: pageSize)
    }

    /// Releases the private document (its page cache). The next request reopens it.
    func purge() {
        document = nil
    }
}

/// The handwriting rows' previews for one Notebook: rendered by a `NotebookPageRenderer`, kept in
/// a most-recently-used cache bounded by count **and** decoded bytes, purged on memory warnings.
///
/// - **Cancellation:** rows ask from a SwiftUI `.task(id:)`, cancelled when the row scrolls away.
///   A request first waits `startDelay`, so rows that only fly past during a fast scroll never
///   read ink or render.
/// - **Freshness:** entries are keyed by page, the page's ink version (`NotebookModel.
///   pageInkVersions`, bumped by every page-ink change from any window) and pixel width, so a
///   changed page renders again and stale entries simply age out.
/// - **Bounds:** at most `countLimit` previews and `costLimit` bytes; a 240-point preview of a
///   US Letter page at 2x is about 1 MB, so the default keeps roughly the last 30 rows.
@MainActor
final class NotebookPagePreviews {
    struct Key: Hashable {
        let pageIndex: Int
        let inkVersion: Int
        let pixelWidth: Int
    }

    struct Stats: Equatable {
        var requests = 0
        var cacheHits = 0
        var rendered = 0
        var cancelled = 0
        var purges = 0
    }

    static let defaultCountLimit = 48
    static let defaultCostLimit = 32 * 1024 * 1024

    let renderer: NotebookPageRenderer
    private let store: LibraryStore
    private let bookID: UUID
    private let startDelay: Duration
    private var cache: LRUCache<Key, UIImage>
    /// Page sizes seen so far (ink space), for placeholders of the right shape.
    private var pageSizes: [Int: CGSize] = [:]
    private var lastPageSize: CGSize?
    nonisolated(unsafe) private var memoryWarning: NSObjectProtocol?
    private(set) var stats = Stats()

    init(store: LibraryStore, bookID: UUID, countLimit: Int = NotebookPagePreviews.defaultCountLimit,
         costLimit: Int = NotebookPagePreviews.defaultCostLimit, startDelay: Duration = .milliseconds(120)) {
        self.store = store
        self.bookID = bookID
        self.startDelay = startDelay
        cache = LRUCache(countLimit: countLimit, costLimit: costLimit)
        let url = (try? store.books.book(id: bookID)).flatMap { $0 }.map { store.documentURL(for: $0) }
        renderer = NotebookPageRenderer(url: url ?? URL(fileURLWithPath: "/dev/null"))
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.purge() }
        }
    }

    deinit {
        if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) }
    }

    var cachedCount: Int { cache.count }
    var cachedCost: Int { cache.totalCost }

    /// The page's height over its width: known once a preview of it (or of any page of the book)
    /// was rendered; US Letter until then.
    func aspectRatio(forPage pageIndex: Int) -> CGFloat {
        let size = pageSizes[pageIndex] ?? lastPageSize ?? CGSize(width: 612, height: 792)
        return size.height / max(size.width, 1)
    }

    /// The cached preview, if any (no reading or rendering).
    func cachedImage(_ key: Key) -> UIImage? { cache.peek(key) }

    /// The page with its ink, `width` points wide at `scale`: from the cache, or read and rendered
    /// off the main thread. `nil` when the calling task was cancelled (the row scrolled away), or
    /// the page has no ink any more (its row goes with the next rebuild).
    func image(pageIndex: Int, inkVersion: Int, width: CGFloat, scale: CGFloat) async -> UIImage? {
        stats.requests += 1
        let key = Key(pageIndex: pageIndex, inkVersion: inkVersion, pixelWidth: Int((width * scale).rounded()))
        if let hit = cache.value(for: key) {
            stats.cacheHits += 1
            return hit
        }
        do {
            try await Task.sleep(for: startDelay)
        } catch {
            stats.cancelled += 1
            return nil
        }
        if let hit = cache.value(for: key) {
            stats.cacheHits += 1
            return hit
        }
        guard !Task.isCancelled,
              let data = try? await store.pageInk(bookID: bookID, pageIndex: pageIndex),
              !Task.isCancelled else {
            stats.cancelled += Task.isCancelled ? 1 : 0
            return nil
        }
        guard let preview = await renderer.preview(pageIndex: pageIndex, inkData: data, width: width, scale: scale) else {
            stats.cancelled += Task.isCancelled ? 1 : 0
            return nil
        }
        stats.rendered += 1
        pageSizes[pageIndex] = preview.pageSize
        lastPageSize = preview.pageSize
        cache.insert(preview.image, for: key, cost: ThumbnailLoader.cost(of: preview.image))
        // The work is done, so it is cached, but a row that went away is not updated.
        return Task.isCancelled ? nil : preview.image
    }

    /// Drops every cached preview and the renderer's document (memory warning, Notebook closed).
    func purge() {
        cache.removeAll()
        stats.purges += 1
        let renderer = renderer
        Task { await renderer.purge() }
    }
}

// MARK: - The row's content

/// The body of a handwriting row: a "Handwriting" caption and the page with its ink, always on
/// white paper with the ink as stored, in every appearance (the page is shown as the PDF draws
/// it, like the reader). The preview loads only while the row is on screen.
struct NotebookHandwritingPreview: View {
    let pageIndex: Int
    let model: NotebookModel

    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .body) private var baseWidth: CGFloat = 240
    @State private var image: UIImage?
    @State private var loadedKey: String?

    private var width: CGFloat { min(max(baseWidth, 200), 380).rounded() }

    var body: some View {
        let version = model.pageInkVersions[pageIndex] ?? 0
        let key = "\(pageIndex)-\(version)-\(Int(width * displayScale))"
        let height = (image.map { $0.size.height / max($0.size.width, 1) } ?? model.pagePreviews.aspectRatio(forPage: pageIndex)) * width
        VStack(alignment: .leading, spacing: 6) {
            Label("Handwriting", systemImage: "pencil.tip")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            ZStack {
                Color.white
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .environment(\.colorScheme, .light)
                }
            }
            .frame(width: width, height: height.rounded())
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color(uiColor: .separator), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        }
        .padding(.bottom, 4)
        .task(id: key) {
            guard loadedKey != key else { return }
            if let loaded = await model.pagePreviews.image(pageIndex: pageIndex, inkVersion: version, width: width,
                                                           scale: displayScale), !Task.isCancelled {
                image = loaded
                loadedKey = key
            }
        }
    }
}
