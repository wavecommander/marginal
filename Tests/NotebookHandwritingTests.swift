import Foundation
import PDFKit
import PencilKit
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// WP14 · Ink navigation in the Notebook: handwriting rows in the feed and the filter, live
/// updates from page-ink changes, previews (off the main thread, light paper, bounded cache), and
/// the exports.
@MainActor
struct NotebookHandwritingTests {
    typealias Support = NotebookTestSupport

    /// The debug seed on a real copy of `no-outline.pdf`, with page ink on pp. 2, 18 and 25.
    static func seededWithPageInk() async throws -> (LibraryStore, Book, NotebookModel) {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("no-outline.pdf"), pageCount: 40)
        try await NotebookDebugSeed.seed(store: store, book: book)
        try await NotebookDebugSeed.seedPageInk(store: store, bookID: book.id)
        let model = await Support.startedModel(store, book)
        return (store, book, model)
    }

    static func describe(_ row: NotebookFeedRow) -> String {
        switch row.kind {
        case .header(let header): "# \(header.title)"
        case .headingNote: "section"
        case .pageNote(_, let page): "note p\(page + 1)"
        case .highlight(let highlight, _): "\(highlight.color.rawValue) p\(highlight.pageIndex + 1)"
        case .handwriting(let page): "ink p\(page + 1)"
        case .unfiledHeadingNote: "unfiled"
        }
    }

    // MARK: Feed

    @Test func handwritingRowsSitUnderTheirSectionAfterThePagesOtherItems() async throws {
        let (store, _, model) = try await Self.seededWithPageInk()
        defer { Support.cleanUp(store) }
        let notebook = try #require(model.notebook)
        #expect(notebook.inkedPageIndices == [1, 17, 24])
        let rows = NotebookFeed.rows(for: notebook, filter: NotebookFilter()).map(Self.describe)
        // Front matter: p. 1's note, then p. 2's ink (p. 2 has nothing else).
        #expect(Array(rows.prefix(3)) == ["# Front matter", "note p1", "ink p2"])
        // 5.1: its note, p. 17's note, p. 18's ink (alone on its page), p. 19's highlight.
        let s51 = try #require(rows.firstIndex(of: "# 5.1 Invariant Directions"))
        #expect(Array(rows[s51...].prefix(5)) == ["# 5.1 Invariant Directions", "section", "note p17", "ink p18", "yellow p19"])
        // 5.2: p. 25 has a note, two highlights and ink: each its own row, ink last.
        let s52 = try #require(rows.firstIndex(of: "# 5.2 The Characteristic Equation"))
        #expect(Array(rows[(s52 + 1)...]) == ["section", "note p23", "note p25", "yellow p25", "green p25", "ink p25",
                                              "note p28", "blue p29"])
        // The row opens the reader at its page.
        let ink = try #require(NotebookFeed.rows(for: notebook, filter: NotebookFilter()).first { Self.describe($0) == "ink p18" })
        #expect(ink.targetPage == 17)
        #expect(ink.note == nil)
        #expect(NotebookHandwriting.accessibilityLabel(pageIndex: 17) == "Handwriting, page 18")
        #expect(NotebookAccessibilityID.handwriting(18) == "notebook.handwriting.18")
    }

    @Test func handwritingFilterSearchAndCounts() async throws {
        let (store, _, model) = try await Self.seededWithPageInk()
        defer { Support.cleanUp(store) }
        let notebook = try #require(model.notebook)
        let handwriting = NotebookFeed.rows(for: notebook, filter: NotebookFilter(type: .handwriting)).map(Self.describe)
        #expect(handwriting == ["# Front matter", "ink p2", "# 5 Eigenvalues and Eigenvectors", "# 5.1 Invariant Directions",
                                "ink p18", "# 5.2 The Characteristic Equation", "ink p25"])
        #expect(NotebookTypeFilter.handwriting.title == "Handwriting")
        // Other types leave handwriting out.
        for type in [NotebookTypeFilter.sectionNotes, .pageNotes, .highlights] {
            #expect(!NotebookFeed.rows(for: notebook, filter: NotebookFilter(type: type)).contains {
                if case .handwriting = $0.kind { true } else { false }
            })
        }
        // Handwriting has no text: a search hides it.
        #expect(NotebookFeed.rows(for: notebook, filter: NotebookFilter(type: .handwriting, query: "eigen")).isEmpty)
        #expect(!NotebookFeed.rows(for: notebook, filter: NotebookFilter(query: "determinant")).map(Self.describe)
            .contains { $0.hasPrefix("ink") })
        // Counts in the heading column include inked pages (WP9's were [16, 1, 2, 2, 11, 3, 7]).
        let entries = NotebookFeed.scopeEntries(for: notebook)
        #expect(entries.map(\.count) == [19, 2, 2, 2, 13, 4, 8])
        #expect(NotebookFeed.itemCount(notebook) == 19)
        // A scope holding only ink is listed: 5.1 with the ink alone.
        let s51 = try #require(entries.first { $0.title == "5.1 Invariant Directions" })
        #expect(NotebookFeed.rows(for: notebook, filter: NotebookFilter(scope: s51.scope, type: .handwriting))
            .map(Self.describe) == ["# 5.1 Invariant Directions", "ink p18"])
    }

    // MARK: Live updates

    @Test func inkAddedOrErasedInAnyWindowUpdatesTheNotebook() async throws {
        let (store, book, model) = try await Self.seededWithPageInk()
        defer { Support.cleanUp(store) }
        let otherWindow = ChangeOrigin(label: "reader window")
        let listings = store.inkedPages.listingCount
        func inkRows() -> [String] {
            model.notebook.map { NotebookFeed.rows(for: $0, filter: NotebookFilter(type: .handwriting)) }?
                .filter { !$0.isHeader }.map(Self.describe) ?? []
        }
        #expect(inkRows() == ["ink p2", "ink p18", "ink p25"])

        // Ink on p. 34, under the until-then empty "6 Orthogonality".
        var before = model.buildCount
        let drawing = PKDrawing(strokes: [PageInkTestSupport.stroke(from: CGPoint(x: 80, y: 80), to: CGPoint(x: 300, y: 90))])
        try await store.savePageInk(drawing.dataRepresentation(), bookID: book.id, pageIndex: 33, origin: otherWindow)
        #expect(model.pageInkVersions[33] == 1)
        #expect(await PageInkTestSupport.waitUntil { model.buildCount > before })
        #expect(inkRows() == ["ink p2", "ink p18", "ink p25", "ink p34"])
        #expect(Support.titles(NotebookFeed.rows(for: try #require(model.notebook), filter: NotebookFilter()))
            .contains("6 Orthogonality"))

        // Erasing all of p. 18's ink removes its row (and 5.1 keeps its note rows).
        before = model.buildCount
        try await store.deletePageInk(bookID: book.id, pageIndex: 17, origin: otherWindow)
        #expect(await PageInkTestSupport.waitUntil { model.buildCount > before })
        #expect(inkRows() == ["ink p2", "ink p25", "ink p34"])
        #expect(store.inkedPages.listingCount == listings + 2)

        // Redrawing a page that keeps its ink re-renders its preview (new version) but keeps the row.
        try await store.savePageInk(drawing.dataRepresentation(), bookID: book.id, pageIndex: 24, origin: otherWindow)
        #expect(model.pageInkVersions[24] == 1)
        #expect(await PageInkTestSupport.waitUntil { model.buildCount > before + 1 })
        #expect(inkRows() == ["ink p2", "ink p25", "ink p34"])
    }

    // MARK: Previews

    /// A pen stroke's pixels in a preview: dark ink stays dark on white paper whatever the
    /// appearance (PencilKit would draw black ink light in Dark Mode), rendered off the main thread.
    @Test func previewIsTheWhitePageWithTheInkAsStored() async throws {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("small.pdf"), pageCount: 12)
        defer { Support.cleanUp(store) }
        let black = PageInkTestSupport.stroke(from: CGPoint(x: 100, y: 400), to: CGPoint(x: 500, y: 400), width: 12, color: .black)
        try await store.savePageInk(PKDrawing(strokes: [black]).dataRepresentation(), bookID: book.id, pageIndex: 2, origin: nil)
        let previews = NotebookPagePreviews(store: store, bookID: book.id, startDelay: .zero)
        let image = try #require(await previews.image(pageIndex: 2, inkVersion: 0, width: 240, scale: 2))
        let page = try #require(PDFDocument(url: store.documentURL(for: book))?.page(at: 2))
        let geometry = PageInkGeometry(page: page)
        #expect(image.size.width == 240)
        #expect(abs(image.size.height - (240 * geometry.size.height / geometry.size.width).rounded()) <= 1)
        let scale = 240 / geometry.size.width
        // On the stroke: dark. Top-left corner: white paper.
        let onStroke = try #require(Self.pixel(image, at: CGPoint(x: 300 * scale, y: 400 * scale)))
        #expect(onStroke.r < 0.25 && onStroke.g < 0.25 && onStroke.b < 0.25, "\(onStroke)")
        let corner = try #require(Self.pixel(image, at: CGPoint(x: 3, y: 3)))
        #expect(corner.r > 0.95 && corner.g > 0.95 && corner.b > 0.95, "\(corner)")
        #expect(previews.cachedCount == 1)
        // The ink's bitmap is light-appearance even when the caller's appearance is dark.
        let size = CGSize(width: 240, height: image.size.height)
        var dark: UIImage?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            dark = UIGraphicsImageRenderer(size: size).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                PageInkRenderer.drawBitmap(PKDrawing(strokes: [black]), geometry: geometry, in: context.cgContext,
                                           target: CGRect(origin: .zero, size: size), pixelsPerPoint: 2)
            }
        }
        let darkImage = try #require(dark)
        let darkStroke = try #require(Self.pixel(darkImage, at: CGPoint(x: 300 * scale, y: 400 * scale)))
        #expect(darkStroke.r < 0.25 && darkStroke.g < 0.25 && darkStroke.b < 0.25, "\(darkStroke)")
        // A second request is a cache hit; a new ink version renders again.
        _ = await previews.image(pageIndex: 2, inkVersion: 0, width: 240, scale: 2)
        _ = await previews.image(pageIndex: 2, inkVersion: 1, width: 240, scale: 2)
        #expect(previews.stats.cacheHits == 1)
        #expect(previews.stats.rendered == 2)
        #expect(await previews.renderer.renderCount == 2)
        // A page without ink any more yields nothing.
        try await store.deletePageInk(bookID: book.id, pageIndex: 2, origin: nil)
        #expect(await previews.image(pageIndex: 2, inkVersion: 2, width: 240, scale: 2) == nil)
        // Save it for looking at.
        try? image.pngData()?.write(to: Support.repoRoot.appendingPathComponent("build/notebook-handwriting-preview.png"))
    }

    @Test func aRowThatScrollsAwayBeforeItsDelayRendersNothing() async throws {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("small.pdf"), pageCount: 12)
        defer { Support.cleanUp(store) }
        let drawing = PKDrawing(strokes: [PageInkTestSupport.stroke(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 100))])
        try await store.savePageInk(drawing.dataRepresentation(), bookID: book.id, pageIndex: 1, origin: nil)
        let previews = NotebookPagePreviews(store: store, bookID: book.id, startDelay: .milliseconds(200))
        let task = Task { await previews.image(pageIndex: 1, inkVersion: 0, width: 240, scale: 2) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        #expect(await task.value == nil)
        #expect(previews.stats.cancelled == 1)
        #expect(await previews.renderer.renderCount == 0)
    }

    /// `large.pdf` (1,500 pages) with ink on 300 pages: building, and previews for every inked
    /// page through the cache, which stays within its bounds. Numbers go to `build/wp14-metrics.txt`.
    @Test func largeBookWithThreeHundredInkedPagesStaysBounded() async throws {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("large.pdf"), pageCount: 1500)
        defer { Support.cleanUp(store) }
        let inkedPages = Array(stride(from: 3, to: 1500, by: 5).prefix(300))
        for page in inkedPages {
            var strokes: [PKStroke] = []
            for index in 0..<6 {
                let y = 120 + CGFloat(index) * 80
                let ink: PKInk.InkType = index == 0 ? .marker : .pen
                let width: CGFloat = index == 0 ? 14 : 3
                strokes.append(PageInkTestSupport.stroke(from: CGPoint(x: 80, y: y), to: CGPoint(x: 480, y: y + 10),
                                                         ink: ink, width: width))
            }
            try await store.inkStore.savePageInk(PKDrawing(strokes: strokes).dataRepresentation(), bookID: book.id, pageIndex: page)
        }
        let clock = ContinuousClock()
        let buildStart = clock.now
        let model = await Support.startedModel(store, book) { _ in
            await ReaderDocumentLoader.outlineEntries(at: PageInkTestSupport.fixture("large.pdf"))
        }
        let buildTime = clock.now - buildStart
        let notebook = try #require(model.notebook)
        #expect(notebook.totalCounts.inkedPages == 300)
        #expect(store.inkedPages.listingCount == 1)
        let rows = NotebookFeed.rows(for: notebook, filter: NotebookFilter(type: .handwriting))
        #expect(rows.filter { !$0.isHeader }.count == 300)

        // A rebuild after one change lists once more, on top of the cached list.
        let rebuildStart = clock.now
        let before = model.buildCount
        try await store.deletePageInk(bookID: book.id, pageIndex: inkedPages[0], origin: ChangeOrigin())
        #expect(await PageInkTestSupport.waitUntil { model.buildCount > before })
        let rebuildTime = clock.now - rebuildStart   // includes the 20 ms debounce
        #expect(store.inkedPages.listingCount == 2)
        #expect(model.notebook?.totalCounts.inkedPages == 299)

        let previews = NotebookPagePreviews(store: store, bookID: book.id, startDelay: .zero)
        var maxCount = 0, maxCost = 0
        var slowest = Duration.zero
        let renderStart = clock.now
        for page in inkedPages.dropFirst() {
            let start = clock.now
            _ = await previews.image(pageIndex: page, inkVersion: 0, width: 240, scale: 2)
            slowest = max(slowest, clock.now - start)
            maxCount = max(maxCount, previews.cachedCount)
            maxCost = max(maxCost, previews.cachedCost)
        }
        let renderTime = clock.now - renderStart
        #expect(previews.stats.rendered == 299)
        #expect(maxCount <= NotebookPagePreviews.defaultCountLimit)
        #expect(maxCost <= NotebookPagePreviews.defaultCostLimit)
        previews.purge()
        #expect(previews.cachedCount == 0)

        let metrics = """
        WP14 metrics (large.pdf, 1,500 pages, ink on 300 pages, 6 strokes each, simulator)
        first build (outline + records + 1 listing + tree): \(buildTime)
        rebuild after one page-ink change (incl. 20 ms debounce): \(rebuildTime)
        directory listings: \(store.inkedPages.listingCount)
        previews: 299 rendered at 240 pt x 2 in \(renderTime) (mean \(renderTime / 299), slowest \(slowest))
        cache high-water: \(maxCount) images, \(maxCost / 1024) KB (limits \(NotebookPagePreviews.defaultCountLimit), \(NotebookPagePreviews.defaultCostLimit / 1024) KB)
        """
        try? metrics.write(to: Support.repoRoot.appendingPathComponent("build/wp14-metrics.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Exports

    @Test func markdownNamesEveryInkedPage() async throws {
        let (store, book, model) = try await Self.seededWithPageInk()
        defer { Support.cleanUp(store) }
        let (text, images) = NotebookExporter.markdown(for: try #require(model.notebook), bookTitle: book.title)
        for page in [2, 18, 25] { #expect(text.contains("_Handwriting on page \(page)_"), "page \(page)") }
        #expect(images.count == 1)   // the inked note only: page ink is named, not pictured
        #expect(text.contains("> The eigenvalues of a triangular matrix are the entries on its main diagonal. (p. 29)"))
        // p. 25's block: note, highlights, then the handwriting line.
        let block = try #require(text.components(separatedBy: "**Page 25**").last)
        let handwriting = try #require(block.range(of: "_Handwriting on page 25_"))
        let highlight = try #require(block.range(of: "an n × n matrix has at most n distinct eigenvalues"))
        #expect(highlight.lowerBound < handwriting.lowerBound)
    }

    @Test func pdfDrawsEachInkedPageWithItsInkAsVector() async throws {
        let (store, book, model) = try await Self.seededWithPageInk()
        defer { Support.cleanUp(store) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookHandwritingTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await NotebookExporter.export(.pdf, notebook: try #require(model.notebook), book: book,
                                                       store: store, root: root)
        let document = try #require(PDFDocument(url: result.fileURL))
        let text = try #require(document.string).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(text.contains("3 pages of handwriting"))
        #expect(text.contains("Handwriting"))

        // The book page is drawn as the PDF draws it: its text is in the export.
        let source = try #require(PDFDocument(url: store.documentURL(for: book))?.page(at: 17)?.string)
        let phrase = source.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        #expect(!phrase.isEmpty && text.contains(phrase), "book page text '\(phrase)' in the export")

        // The page carrying p. 18's preview: pen strokes as paths (curves), the book page as a form.
        func collapsed(_ index: Int) -> String {
            (document.page(at: index)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let found = (0..<document.pageCount).first { collapsed($0).contains(phrase) }
        let pageIndex = try #require(found)
        let data = try Data(contentsOf: result.fileURL)
        let counts = NotebookPDFInspector.operatorCounts(data, page: pageIndex + 1)
        #expect((counts["c"] ?? 0) > 100, "curve operators: \(counts)")
        // The book page's own text is drawn as text (inline, not as an image).
        #expect(((counts["Tj"] ?? 0) + (counts["TJ"] ?? 0)) > 20, "the book page: \(counts)")
        #expect((counts["Do"] ?? 0) == 0 && (counts["BI"] ?? 0) == 0, "no images for pen ink or the page: \(counts)")
        if let page = document.page(at: pageIndex) {
            let image = page.thumbnail(of: CGSize(width: 1200, height: 1600), for: .mediaBox)
            try? image.pngData()?.write(to: Support.repoRoot.appendingPathComponent("build/notebook-export-handwriting.png"))
        }
    }

    // MARK: Helpers

    static func pixel(_ image: UIImage, at point: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let cgImage = image.cgImage else { return nil }
        let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        return (CGFloat(bytes[0]) / 255, CGFloat(bytes[1]) / 255, CGFloat(bytes[2]) / 255)
    }
}
