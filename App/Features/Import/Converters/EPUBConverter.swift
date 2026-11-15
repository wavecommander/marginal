import CoreGraphics
import Foundation
import ImageIO
import ReaderCore
import UIKit

// EPUB → PDF. Each spine item is laid out in the off-screen web renderer and printed to its own
// PDF in a private folder inside the staging directory; one CoreGraphics pass then joins the
// chapters into the output and writes the outline (from the book's table of contents) and the
// links. See docs/FORMAT_IMPORT_PLAN.md, "Web converter".
//
// Decisions the plan left open:
// - Non-linear spine items (`linear="no"`: pop-up notes, answer keys, sometimes the cover) are
//   printed after the linear ones, in spine order, so the reading flow is not interrupted but
//   their text and the links into them still work.
// - A spine item listed twice is printed once. Spine items that are not documents or images
//   (audio, say) are skipped.
// - A table-of-contents entry whose target is not in the spine, or whose title is empty, is
//   dropped and its children move up to its place. An entry with no link of its own (a group
//   heading) goes to its first child's page.
// - Text sizes (CSS px; the print path draws 1 px as 1 pt on the 6 × 9 in page):
//   small 9.5, medium 11, large 13. A trade paperback sets body text at 10–12 pt.
// - A chapter longer than 24 pages is printed in segments of about 16 pages, cut between
//   top-level blocks (at a heading when one is near), so no single print holds the main thread
//   for long. Each segment's last page ends early, like a section break: a few extra pages in a
//   book with long chapters (+2 for a 268-page chapter).
// - Forced page breaks before a chapter's (or segment's) first content and after its last are
//   ignored, empty trailing elements are hidden and the trailing bottom margin is dropped: each
//   printed an empty page (one per chapter in Project Gutenberg books). See
//   `WebPDFRenderer.suppressEdgeBreaksJS`. Breaks between pieces of content are kept.

/// Turns a reflowable, DRM-free EPUB 2 or 3 into a PDF.
nonisolated struct EPUBConverter: DocumentConverter {
    var version: Int { 1 }
    var formats: Set<ImportFormat> { [.epub] }
    /// Seconds a chapter may take to load (with its fonts and images) before the conversion fails.
    var chapterTimeout: TimeInterval = 60
    /// Filled in as the conversion runs, for tests and diagnostics.
    var diagnostics: EPUBConversionDiagnostics?
    /// Receives the renderer's step-by-step trace, for diagnostics.
    var trace: (@Sendable (String) -> Void)?

    func convert(_ input: ConversionInput, progress: @escaping @Sendable (Double) -> Void) async throws -> ConvertedDocument {
        let workspace = input.directory.appendingPathComponent(".epub-chapters-\(UUID().uuidString)", isDirectory: true)
        var cover: URL?
        do {
            try Task.checkCancellation()
            let book = try await Self.prepare(input, workspace: workspace)
            cover = book.cover
            progress(0.02)
            let printed = try await EPUBChapterPrinter.printChapters(
                of: book, textSize: input.options.textSize, workspace: workspace, timeout: chapterTimeout,
                diagnostics: diagnostics, trace: trace, progress: { progress(0.02 + 0.86 * $0) })
            try Task.checkCancellation()
            let pageCount = try await Self.assemble(book, printed: printed, output: input.outputURL,
                                                    diagnostics: diagnostics, progress: { progress(0.88 + 0.12 * $0) })
            await Self.remove([workspace])
            progress(1)
            return ConvertedDocument(pdf: input.outputURL, pageCount: pageCount, title: book.title, coverImage: book.cover)
        } catch {
            await Self.remove([workspace, input.outputURL] + (cover.map { [$0] } ?? []))
            throw Self.conversionError(for: error)
        }
    }

    static func conversionError(for error: any Error) -> any Error {
        switch error {
        case is CancellationError, is ConversionError: error
        case let error as WebRenderError: ConversionError.failed(reason: "The book could not be laid out: \(error.reason).")
        case let error as EPUBError: ConversionError.failed(reason: describe(error))
        default: ConversionError.failed(reason: "The book could not be converted (\(error.localizedDescription)).")
        }
    }

    static func describe(_ error: EPUBError) -> String {
        switch error {
        case .missingContainer: "The EPUB has no META-INF/container.xml."
        case let .malformedXML(path): "\(path) in the EPUB is not well-formed XML."
        case .noPackageDocument: "The EPUB's container.xml names no package document."
        case let .missingPackageDocument(path): "The EPUB's package document (\(path)) is missing."
        case let .invalidPackageDocument(path): "The EPUB's package document (\(path)) has no manifest or spine."
        case let .archive(zipError): "The EPUB archive could not be read (\(zipError))."
        }
    }

    @concurrent
    static func remove(_ urls: [URL]) async {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Prepare

    /// Parses the package, checks it can be converted, plans the chapters, extracts the cover
    /// and creates the workspace. Off the main thread.
    @concurrent
    static func prepare(_ input: ConversionInput, workspace: URL) async throws -> EPUBBookPlan {
        let package: EPUBPackage
        do {
            package = try EPUBParser.parse(fileAt: input.original)
        } catch let error as EPUBError {
            throw ConversionError.failed(reason: describe(error))
        }
        if package.protection.isProtected { throw ConversionError.protected }
        if package.isFixedLayout {
            throw ConversionError.unsupported(reason: "Fixed-layout EPUBs (picture books, comics, some textbooks) can't be converted yet.")
        }
        let chapters = plannedChapters(package)
        guard !chapters.isEmpty else {
            throw ConversionError.failed(reason: "The EPUB's reading order lists no chapters that can be shown.")
        }
        try Task.checkCancellation()
        let resources: EPUBArchiveResources
        do {
            resources = try EPUBArchiveResources(url: input.original, package: package)
        } catch {
            throw ConversionError.failed(reason: "The EPUB archive could not be read (\(error)).")
        }
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        } catch {
            throw ConversionError.failed(reason: "There is no room to convert the book (\(error.localizedDescription)).")
        }
        let title = package.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = package.metadata.creators.isEmpty ? nil : package.metadata.creators.joined(separator: ", ")
        let cover = extractCover(package, from: input.original, into: input.directory)
        return EPUBBookPlan(package: package, chapters: chapters, resources: resources,
                            title: (title?.isEmpty ?? true) ? nil : title, author: author, cover: cover)
    }

    /// Linear spine items in order, then the non-linear ones; each path once; documents and
    /// images only.
    static func plannedChapters(_ package: EPUBPackage) -> [EPUBChapter] {
        var seen = Set<String>()
        var linear: [EPUBChapter] = []
        var auxiliary: [EPUBChapter] = []
        for item in package.spine {
            guard let manifest = package.manifestItem(id: item.idref), seen.insert(manifest.path).inserted else { continue }
            let declared = manifest.mediaType.trimmingCharacters(in: .whitespaces).lowercased()
            let mediaType = declared.isEmpty ? (WebResourcePath.mimeType(forPath: manifest.path) ?? "") : declared
            guard isRenderable(mediaType) else { continue }
            let chapter = EPUBChapter(path: manifest.path, mediaType: mediaType, isLinear: item.isLinear)
            if item.isLinear { linear.append(chapter) } else { auxiliary.append(chapter) }
        }
        return linear + auxiliary
    }

    static func isRenderable(_ mediaType: String) -> Bool {
        ["application/xhtml+xml", "text/html", "image/svg+xml", "application/xml", "text/xml"].contains(mediaType)
            || mediaType.hasPrefix("image/")
    }

    /// Copies the cover image into `directory` when ImageIO can decode it.
    static func extractCover(_ package: EPUBPackage, from original: URL, into directory: URL) -> URL? {
        guard let path = package.coverImagePath,
              let archive = try? ZIPArchive(url: original),
              let data = try? archive.data(at: path, maxSize: 64 << 20),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                              kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) != nil
        else { return nil }
        var ext = (path as NSString).pathExtension.lowercased()
        if ext.isEmpty || ext.count > 5 { ext = "img" }
        let url = directory.appendingPathComponent("epub-cover.\(ext)", isDirectory: false)
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    // MARK: Assemble

    /// Finds the table-of-contents targets and the links in the printed chapters, then joins the
    /// chapters into `output`. Off the main thread.
    @concurrent
    static func assemble(_ book: EPUBBookPlan, printed: [EPUBPrintedChapter], output: URL,
                         diagnostics: EPUBConversionDiagnostics?, progress: @Sendable (Double) -> Void) async throws -> Int {
        let total = printed.reduce(0) { $0 + $1.pageCount }
        guard total > 0 else { throw ConversionError.failed(reason: "The book's chapters printed no pages.") }
        var locator = WebTargetLocator(printed: printed)
        let outline = locator.outline(from: book.package.navigation)
        try Task.checkCancellation()
        let links = locator.links()
        diagnostics?.record(outline: locator.outlineStatistics, links: locator.linkStatistics)
        progress(0.2)
        try Task.checkCancellation()
        let parts = printed.filter { $0.pageCount > 0 }.map(\.pdf)
        return try WebPDFJoiner.join(parts: parts, to: output, outline: outline, links: links,
                                     info: WebPDFDocumentInfo(title: book.title, author: book.author),
                                     progress: { progress(0.2 + 0.8 * $0) })
    }
}

/// One spine item to print.
nonisolated struct EPUBChapter: Sendable, Equatable {
    var path: String
    var mediaType: String
    var isLinear: Bool
}

/// Everything the printing and joining steps need, read once from the package.
nonisolated struct EPUBBookPlan: Sendable {
    var package: EPUBPackage
    var chapters: [EPUBChapter]
    var resources: EPUBArchiveResources
    var title: String?
    var author: String?
    var cover: URL?
}

/// A chapter (or one segment of a long chapter) after printing; `path` is the spine item's.
typealias EPUBPrintedChapter = WebPrintedPart

// MARK: - Printing

/// The app's additions to the book's own CSS.
nonisolated enum EPUBStyle {
    /// Page margins on the 6 × 9 in page, in points.
    static let margins = UIEdgeInsets(top: 40, left: 36, bottom: 40, right: 36)
    /// Chapters longer than `splitAbove` pages are printed in segments of about
    /// `pagesPerSegment` pages, which keeps each print's main-thread stall near 100 ms at the
    /// measured 2–5 ms a page (see `WebPDFRenderer.planSegments`).
    static let pagesPerSegment = 16
    static let splitAbove = 24

    static func baseFontSize(_ size: ConversionTextSize) -> Double {
        switch size {
        case .small: 9.5
        case .medium: 11
        case .large: 13
        }
    }

    /// Sets the base text size on the root (the book's relative sizes scale from it), scales
    /// images to fit the page, keeps headings with what follows, and hides audio and video.
    /// It sets no colours and no writing direction.
    static func styleSheet(textSize: ConversionTextSize, printableHeight: CGFloat) -> String {
        let size = baseFontSize(textSize)
        let maxHeight = Int(printableHeight.rounded(.down)) - 8
        return """
            :root { color-scheme: only light; }
            html { font-size: \(size)px; line-height: 1.4; -webkit-text-size-adjust: none; text-size-adjust: none; \
            margin: 0; padding: 0; }
            body { overflow-wrap: break-word; widows: 2; orphans: 2; }
            img, svg, video, canvas, object, embed { max-width: 100% !important; max-height: \(maxHeight)px !important; \
            object-fit: contain; break-inside: avoid; page-break-inside: avoid; }
            img { height: auto; }
            pre { white-space: pre-wrap; }
            table { max-width: 100%; }
            h1, h2, h3, h4, h5, h6 { break-after: avoid; page-break-after: avoid; break-inside: avoid; }
            audio, video { display: none !important; }
            """
    }
}

@MainActor
enum EPUBChapterPrinter {
    /// Loads and prints each chapter in order into `workspace`. Fails naming the chapter when one
    /// cannot be loaded. Always tears the web view down.
    static func printChapters(of book: EPUBBookPlan, textSize: ConversionTextSize, workspace: URL,
                              timeout: TimeInterval, diagnostics: EPUBConversionDiagnostics?,
                              trace: (@Sendable (String) -> Void)? = nil, progress: @Sendable (Double) -> Void) async throws -> [EPUBPrintedChapter] {
        let page = ConversionOptions.reflowPageSize
        var configuration = WebPDFRenderer.Configuration(pageSize: page, margins: EPUBStyle.margins)
        configuration.styleSheet = EPUBStyle.styleSheet(textSize: textSize, printableHeight: configuration.printableRect.height)
        configuration.loadTimeout = timeout
        configuration.trace = trace
        let renderer = WebPDFRenderer(provider: book.resources, configuration: configuration)
        defer { renderer.tearDown() }
        try await renderer.start()
        var printed: [EPUBPrintedChapter] = []
        for (index, chapter) in book.chapters.enumerated() {
            try Task.checkCancellation()
            let name = "Chapter \(index + 1) (\(chapter.path))"
            let started = Date()
            do {
                let report = try await renderer.load(path: chapter.path)
                if report.hasParserError, chapter.mediaType == "application/xhtml+xml" {
                    book.resources.serveAsHTML(chapter.path)
                    try await renderer.load(path: chapter.path)
                }
                let parts = try await renderer.printSegments(path: chapter.path, into: workspace,
                                                             prefix: String(format: "chapter-%04d", index))
                for part in parts {
                    printed.append(part)
                    diagnostics?.record(chapter: EPUBConversionDiagnostics.Chapter(
                        path: chapter.path, part: part.part, parts: part.parts, pageCount: part.pageCount,
                        seconds: Date().timeIntervalSince(started), print: part.report, reloadedAsHTML: report.hasParserError,
                        anchors: part.layout.anchors.count, links: part.layout.links.count))
                }
            } catch let error as WebRenderError {
                throw ConversionError.failed(reason: "\(name) could not be converted: \(error.reason).")
            } catch let error as CancellationError {
                throw error
            } catch let error as ConversionError {
                throw error
            } catch {
                throw ConversionError.failed(reason: "\(name) could not be converted (\(error.localizedDescription)).")
            }
            progress(Double(index + 1) / Double(book.chapters.count))
        }
        diagnostics?.record(requests: renderer.schemeHandler.records)
        return printed
    }
}

// MARK: - Targets and links

/// The EPUB's table of contents, resolved against the printed chapters.
nonisolated extension WebTargetLocator {
    mutating func outline(from points: [EPUBNavigationPoint]) -> [WebPDFOutlineItem] {
        // Resolve in chapter order so each chapter's PDF is opened once.
        var keys: [Key] = []
        func collect(_ points: [EPUBNavigationPoint]) {
            for point in points {
                if let path = point.path, let chapter = chapterByPath[path] { keys.append(Key(chapter: chapter, fragment: point.fragment)) }
                collect(point.children)
            }
        }
        collect(points)
        for key in keys.sorted(by: { $0.chapter < $1.chapter }) { _ = resolve(key) }
        return build(points)
    }

    private mutating func build(_ points: [EPUBNavigationPoint]) -> [WebPDFOutlineItem] {
        var items: [WebPDFOutlineItem] = []
        for point in points {
            let children = build(point.children)
            let title = point.title.trimmingCharacters(in: .whitespacesAndNewlines)
            var page: Int?
            if let path = point.path {
                guard let chapter = chapterByPath[path] else {
                    outlineStatistics.dropped += 1
                    items += children
                    continue
                }
                switch resolve(Key(chapter: chapter, fragment: point.fragment)) {
                case let .exact(found):
                    page = found
                    outlineStatistics.exact += 1
                case let .estimated(found):
                    page = found
                    outlineStatistics.estimated += 1
                case .missing:
                    page = startPage(chapter)
                    outlineStatistics.missingFragment += 1
                }
            } else {
                page = children.first?.pageIndex
            }
            guard !title.isEmpty, let page else {
                outlineStatistics.dropped += 1
                items += children
                continue
            }
            items.append(WebPDFOutlineItem(title: title, pageIndex: page, children: children))
        }
        return items
    }
}

// MARK: - Diagnostics

/// What a conversion measured: per-chapter print times, how the outline and links were placed,
/// and which resources were requested. Thread-safe.
nonisolated final class EPUBConversionDiagnostics: @unchecked Sendable {
    struct Chapter: Sendable {
        var path: String
        /// Segment of the chapter, and how many segments it was printed in.
        var part: Int
        var parts: Int
        var pageCount: Int
        var seconds: TimeInterval
        var print: WebPrintReport
        var reloadedAsHTML: Bool
        var anchors: Int
        var links: Int
    }

    typealias Outline = WebOutlineStatistics
    typealias Links = WebLinkStatistics

    private let lock = NSLock()
    private var storedChapters: [Chapter] = []
    private var storedOutline = Outline()
    private var storedLinks = Links()
    private var storedRequests: [WebResourceRequestRecord] = []

    init() {}

    var chapters: [Chapter] { lock.withLock { storedChapters } }
    var outline: Outline { lock.withLock { storedOutline } }
    var links: Links { lock.withLock { storedLinks } }
    var requests: [WebResourceRequestRecord] { lock.withLock { storedRequests } }
    /// The longest the main thread was held by printing, over all chapters.
    var longestMainThreadSlice: TimeInterval { chapters.map(\.print.longestMainThreadSlice).max() ?? 0 }

    func record(chapter: Chapter) { lock.withLock { storedChapters.append(chapter) } }
    func record(outline: Outline, links: Links) { lock.withLock { storedOutline = outline; storedLinks = links } }
    func record(requests: [WebResourceRequestRecord]) { lock.withLock { storedRequests = requests } }
}
