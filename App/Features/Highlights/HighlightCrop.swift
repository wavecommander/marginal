import Foundation
import PDFKit
import ReaderCore
import SwiftUI
import UIKit

// S4 · The crop of a scanned-page highlight: the image of the page under its rects, with a small
// margin, shown wherever highlights are listed ("Highlights on this page", the Notebook) and in
// the Markdown ZIP and Notebook PDF exports (design: "Scanned books" ▸ Highlights on scanned
// pages, "Shown as the page itself"). It is rendered on demand from the PDF page, off the main
// thread, and kept only in memory: never stored on disk as data.

/// Geometry of a highlight crop.
nonisolated enum HighlightCrop {
    /// The margin around the highlight's rects, in page points.
    static let margin: CGFloat = 4
    /// Largest number of pixels either side of a rendered crop.
    static let maximumPixels: CGFloat = 4096

    /// The part of the page a crop shows, in page space: the union of `rects` outset by
    /// `margin`, clipped to `cropBox` when given. `nil` when there is nothing to show.
    static func region(of rects: [CGRect], cropBox: CGRect? = nil) -> CGRect? {
        let union = rects.filter { !$0.isNull && !$0.isEmpty }.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return nil }
        var region = union.insetBy(dx: -margin, dy: -margin)
        if let cropBox {
            region = region.intersection(cropBox.standardized)
        }
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        return region
    }

    /// The size of the crop the reader sees (upright, points of the page) for a page that is not
    /// rotated a quarter turn; good enough to reserve space before the crop is rendered.
    static func estimatedSize(of rects: [CGRect]) -> CGSize? {
        region(of: rects)?.size
    }

    /// The zoom (view points per page point) at which a crop of `width` page points fits
    /// `maxWidth`, never more than `maxZoom`.
    static func zoom(regionWidth width: CGFloat, maxWidth: CGFloat, maxZoom: CGFloat = 1.5) -> CGFloat {
        guard width > 0 else { return 1 }
        return max(0.1, min(maxZoom, maxWidth / width))
    }
}

/// Renders crops from a **private** `PDFDocument` (never the on-screen one, which PDFKit has
/// changed by adding Live Text), off the main thread. Requests are serialised; a request whose
/// task was cancelled before it started returns `nil` without rendering. The page is drawn as the
/// PDF draws it, on white, light in every appearance (as every export image is).
actor HighlightCropRenderer {
    nonisolated struct Crop: @unchecked Sendable {
        /// Immutable once made.
        let image: UIImage
        /// The region shown, upright (ink space), in page points.
        let pageSize: CGSize
    }

    private let url: URL
    private var document: PDFDocument?
    /// Crops rendered (tests and diagnostics).
    private(set) var renderCount = 0

    init(url: URL) {
        self.url = url
    }

    /// The page under `rects` (page space) with `HighlightCrop.margin` around them, drawn at
    /// `zoom` points per page point and `scale` pixels per point. `nil` if the page does not
    /// exist, the rects are empty, or the task was cancelled first.
    func crop(pageIndex: Int, rects: [CGRect], zoom: CGFloat, scale: CGFloat) -> Crop? {
        guard !Task.isCancelled else { return nil }
        if document == nil { document = PDFDocument(url: url) }
        guard let page = document?.page(at: pageIndex) else { return nil }
        let geometry = PageInkGeometry(page: page)
        guard let region = HighlightCrop.region(of: rects, cropBox: geometry.cropBox) else { return nil }
        // Upright, y down: the page as the reader sees it (rotated pages included).
        let upright = region.applying(geometry.pageToInk).standardized
        var zoom = max(zoom, 0.01)
        let scale = max(scale, 1)
        let largest = max(upright.width, upright.height) * zoom * scale
        if largest > HighlightCrop.maximumPixels { zoom *= HighlightCrop.maximumPixels / largest }
        let size = CGSize(width: max(1, (upright.width * zoom).rounded(.up)),
                          height: max(1, (upright.height * zoom).rounded(.up)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        // 8-bit sRGB (4 bytes a pixel), not the wide-colour default: crops are cached.
        format.preferredRange = .standard
        let pageSize = geometry.size
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            let target = CGRect(x: -upright.minX * zoom, y: -upright.minY * zoom,
                                width: pageSize.width * zoom, height: pageSize.height * zoom)
            BookPageDrawing.draw(page, geometry: geometry, in: cg, target: target)
        }
        renderCount += 1
        return Crop(image: image, pageSize: upright.size)
    }

    /// Releases the private document (its page cache). The next request reopens it.
    func purge() {
        document = nil
    }
}

/// The crops of one book for one list (a reader window's notes panel, or a Notebook): rendered by
/// a `HighlightCropRenderer`, kept in a most-recently-used cache bounded by count and decoded
/// bytes, and purged on memory warnings. Nothing is written to disk.
///
/// - **Cancellation:** rows ask from a SwiftUI `.task(id:)`, cancelled when the row goes away. A
///   request first waits `startDelay`, so rows that only fly past during a fast scroll render
///   nothing.
/// - **Freshness:** entries are keyed by the highlight's page and rects and the pixel size, so a
///   highlight merged into a larger one renders again; a recolour reuses the crop (the crop
///   shows the page, not the colour).
@MainActor
final class HighlightCropCache {
    struct Key: Hashable {
        let pageIndex: Int
        let rects: String
        let pixelWidth: Int

        init(highlight: Highlight, zoom: CGFloat, scale: CGFloat) {
            pageIndex = highlight.pageIndex
            rects = highlight.rects.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" }.joined(separator: ";")
            let width = HighlightCrop.estimatedSize(of: highlight.rects)?.width ?? 0
            pixelWidth = Int((width * zoom * scale).rounded())
        }
    }

    struct Stats: Equatable {
        var requests = 0
        var cacheHits = 0
        var rendered = 0
        var cancelled = 0
        var purges = 0
    }

    static let defaultCountLimit = 64
    static let defaultCostLimit = 16 * 1024 * 1024

    let renderer: HighlightCropRenderer
    private let startDelay: Duration
    private var cache: LRUCache<Key, UIImage>
    nonisolated(unsafe) private var memoryWarning: NSObjectProtocol?
    private(set) var stats = Stats()

    init(documentURL: URL, countLimit: Int = HighlightCropCache.defaultCountLimit,
         costLimit: Int = HighlightCropCache.defaultCostLimit, startDelay: Duration = .milliseconds(80)) {
        renderer = HighlightCropRenderer(url: documentURL)
        self.startDelay = startDelay
        cache = LRUCache(countLimit: countLimit, costLimit: costLimit)
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

    /// The cached crop, if any (no rendering).
    func cachedImage(for highlight: Highlight, zoom: CGFloat, scale: CGFloat) -> UIImage? {
        cache.peek(Key(highlight: highlight, zoom: zoom, scale: scale))
    }

    /// The crop of `highlight`'s page at `zoom` and `scale`: from the cache, or rendered off the
    /// main thread. `nil` when the calling task was cancelled, or the page cannot be drawn (the
    /// PDF is missing, the page is outside the book).
    func image(for highlight: Highlight, zoom: CGFloat, scale: CGFloat) async -> UIImage? {
        stats.requests += 1
        let key = Key(highlight: highlight, zoom: zoom, scale: scale)
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
        guard let crop = await renderer.crop(pageIndex: highlight.pageIndex, rects: highlight.rects,
                                             zoom: zoom, scale: scale) else {
            stats.cancelled += Task.isCancelled ? 1 : 0
            return nil
        }
        stats.rendered += 1
        cache.insert(crop.image, for: key, cost: ThumbnailLoader.cost(of: crop.image))
        // The work is done, so it is cached, but a row that went away is not updated.
        return Task.isCancelled ? nil : crop.image
    }

    /// Drops every cached crop and the renderer's document (memory warning, list closed).
    func purge() {
        cache.removeAll()
        stats.purges += 1
        let renderer = renderer
        Task { await renderer.purge() }
    }
}

// MARK: - Labels

/// What lists and VoiceOver say for a scanned-page highlight.
nonisolated enum HighlightCropLabels {
    /// The caption shown with the crop, or `nil` when the highlight has no text.
    static func caption(_ highlight: Highlight) -> String? {
        highlight.presentation.caption
    }

    /// "Highlight on a scanned page, page N": the words for a crop with no caption.
    static func uncaptioned(pageIndex: Int) -> String {
        "\(HighlightPresentation.uncaptionedCropLabel), page \(PageNumbering.displayNumber(forPageIndex: pageIndex))"
    }

    /// The text VoiceOver reads for a highlight's content: its caption, or "Highlight on a
    /// scanned page, page N" for a scanned-page highlight without one.
    static func spokenText(_ highlight: Highlight) -> String {
        switch highlight.presentation {
        case .text(let text): text
        case .crop(let caption): caption ?? uncaptioned(pageIndex: highlight.pageIndex)
        }
    }
}

// MARK: - The view

/// A scanned-page highlight's crop in a list: the page itself, on white in every appearance (a
/// page is shown as the PDF draws it, like the reader), with a thin border. It loads only while
/// on screen and holds its size while loading. Hidden from VoiceOver: the row it is in carries
/// the label.
struct HighlightCropView: View {
    let highlight: Highlight
    let crops: HighlightCropCache?
    /// The widest the crop is shown, in points.
    var maxWidth: CGFloat = 320
    /// Zoom (points per page point) at most.
    var maxZoom: CGFloat = 1.5

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadedKey: String?

    var body: some View {
        let estimated = HighlightCrop.estimatedSize(of: highlight.rects) ?? CGSize(width: 200, height: 20)
        let zoom = HighlightCrop.zoom(regionWidth: estimated.width, maxWidth: maxWidth, maxZoom: maxZoom)
        let size = image.map { $0.size } ?? CGSize(width: estimated.width * zoom, height: estimated.height * zoom)
        let key = "\(highlight.pageIndex)-\(highlight.rects)-\(zoom)-\(displayScale)"
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .environment(\.colorScheme, .light)
            }
        }
        .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
        .frame(maxWidth: size.width.rounded(.up), alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(Color(uiColor: .separator), lineWidth: 0.75))
        .accessibilityHidden(true)
        .task(id: key) {
            guard loadedKey != key, let crops else { return }
            if let loaded = await crops.image(for: highlight, zoom: zoom, scale: displayScale), !Task.isCancelled {
                image = loaded
                loadedKey = key
            }
        }
    }
}
