import Foundation
import PDFKit
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// S4 helpers: a store holding a copy of `scanned.pdf` (page 1 typed, pages 2 to 30 pictures of
/// text with no text layer; "The quiet heron measures tidewater." is the first body line of page
/// 17, zero-based index 16).
@MainActor
enum ScannedHighlightTestSupport {
    static let phrase = "The quiet heron measures tidewater."
    /// PDFKit's own Live Text line rect for the phrase (docs/SCANNED_BOOKS_FINDINGS.md).
    static let phraseRect = CGRect(x: 72, y: 693, width: 159, height: 12)
    static let phrasePage = 16
    static var scannedPDF: URL { PageInkTestSupport.fixture("scanned.pdf") }

    static func makeStore() throws -> (LibraryStore, Book) {
        try PageInkTestSupport.makeStore(pdf: scannedPDF, pageCount: 30)
    }

    /// A scanned-page highlight over the phrase, as the reader stores it.
    static func phraseHighlight(_ book: Book, color: HighlightColor = .yellow, text: String = phrase) -> Highlight {
        Highlight(bookID: book.id, pageIndex: phrasePage, rects: [phraseRect], color: color, text: text,
                  createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000), textSource: .liveText)
    }

    /// A selection as the bridge reports it, for a page part (the `PDFSelection` is an empty one:
    /// `HighlightEditing` reads it only when merging).
    static func selection(page: Int, rects: [CGRect], string: String) -> ReaderTextSelection {
        ReaderTextSelection(parts: [.init(pageIndex: page, lineRects: rects, string: string)], string: string,
                            selection: PDFSelection(document: PDFDocument()))
    }

    /// Fraction of a crop's pixels that are dark (text).
    static func darkFraction(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, !pixels.isEmpty else { return 0 }
        return Double(pixels.filter { $0 < 110 }.count) / Double(pixels.count)
    }
}

/// S4 · The highlight's text source is decided from the page **in the file** (never the on-screen
/// document, which gains PDFKit's Live Text): a scanned page tags `.liveText`, a typed page
/// keeps `nil`, a page not read yet is corrected right after saving.
@Suite(.serialized)
@MainActor
struct ScannedHighlightSourceTests {
    typealias Support = ScannedHighlightTestSupport

    @Test func theFileSaysWhichPagesHaveTextOfTheirOwn() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let probe = HighlightTextSourceProbe(documentURL: store.documentURL(for: book))
        #expect(probe.cachedLayer(forPage: 16) == nil)
        #expect(await probe.layer(forPage: 0) == .hasText)
        #expect(await probe.layer(forPage: 16) == .noText)
        #expect(await probe.layer(forPage: 29) == .noText)
        #expect(await probe.layer(forPage: 30) == nil)
        #expect(probe.cachedLayer(forPage: 16) == .noText)

        probe.prefetch([1, 2, 3])
        #expect(await PageInkTestSupport.waitUntil { probe.cachedLayer(forPage: 3) != nil })
        #expect(probe.cachedLayer(forPage: 1) == .noText)
        #expect(PageTextLayer.noText.highlightSource == .liveText)
        #expect(PageTextLayer.hasText.highlightSource == nil)
    }

    @Test func editingTagsScannedPagesAndLeavesTypedPagesAsBefore() throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let layers: [Int: PageTextLayer] = [0: .hasText, 16: .noText]
        let editing = HighlightEditing(store: store, bookID: book.id, textLayer: { layers[$0] }) { _ in nil }

        let scanned = try editing.apply(.yellow, to: Support.selection(page: 16, rects: [Support.phraseRect], string: Support.phrase))
        #expect(scanned.map(\.textSource) == [.liveText])
        let typed = try editing.apply(.green, to: Support.selection(page: 0, rects: [CGRect(x: 72, y: 600, width: 200, height: 20)],
                                                                    string: "The Scanned Fixture Book"))
        #expect(typed.map(\.textSource) == [nil])
        // A page not read yet: left as it was (the controller corrects it).
        let unknown = try editing.apply(.blue, to: Support.selection(page: 20, rects: [CGRect(x: 72, y: 600, width: 100, height: 12)],
                                                                     string: "unknown"))
        #expect(unknown.map(\.textSource) == [nil])

        // A merge on a scanned page records the source too, also for a highlight stored without
        // it (one made before scanned books existed).
        var old = Support.phraseHighlight(book, color: .pink)
        old.pageIndex = 18
        old.textSource = nil
        try store.highlights.save(old)
        let merged = try editing.apply(.green, to: Support.selection(page: 18, rects: [Support.phraseRect.insetBy(dx: 30, dy: 0)],
                                                                     string: "heron"))
        #expect(merged.count == 1)
        #expect(merged.first?.id == old.id)
        // No page to consult: 18 is not in `layers`, so nothing changes the source.
        #expect(merged.first?.textSource == nil)
        let tagging = HighlightEditing(store: store, bookID: book.id, textLayer: { _ in .noText }) { _ in nil }
        let remerged = try tagging.apply(.green, to: Support.selection(page: 18, rects: [Support.phraseRect.insetBy(dx: 30, dy: 0)],
                                                                       string: "heron"))
        #expect(remerged.first?.id == old.id)
        #expect(try store.highlights.highlight(id: old.id)?.textSource == .liveText)
        #expect(try store.highlights.highlights(bookID: book.id, pageIndex: 18).count == 1)
    }

    /// A real session on `scanned.pdf`: the controller has read the visible pages from the file
    /// before any selection exists, so a highlight on the scanned page is tagged at once; on
    /// the typed cover it is not. Then PDFKit's Live Text: once the on-screen page has gained
    /// text, a selection on it (the phrase) still records `.liveText`, because the file says so.
    @Test func aRealSessionTagsFromTheFileEvenAfterTheScreenGainsText() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let host = try await HighlightsTestSupport.host(book, store, pageIndex: Support.phrasePage)
        defer { Task { await host.close() } }
        let controller = HighlightsTestSupport.controller(host)
        #expect(await PageInkTestSupport.waitUntil { controller.textSources.cachedLayer(forPage: Support.phrasePage) != nil })
        #expect(controller.textSources.cachedLayer(forPage: Support.phrasePage) == .noText)

        // PDFKit reads the shown page a few seconds after it appears (up to 15 s on a cold start).
        let page = try #require(host.session.pdf.page(at: Support.phrasePage))
        let recognised = await PageInkTestSupport.waitUntil(timeout: 25) {
            (page.string ?? "").contains("heron")
        }
        if recognised {
            // The on-screen page now has text the file lacks; the file's answer is unchanged.
            #expect(page.numberOfCharacters > 0)
            #expect(controller.textSources.cachedLayer(forPage: Support.phrasePage) == .noText)
            let selection = try HighlightsTestSupport.select(Support.phrase, onPage: Support.phrasePage, in: host)
            let made = controller.highlight(selection, color: .green)
            #expect(made.count == 1)
            let stored = try #require(try store.highlights.highlights(bookID: book.id).first)
            #expect(stored.textSource == .liveText)
            #expect(stored.isOnScannedPage)
            #expect(stored.text.contains("heron"))
            #expect(abs(stored.rects[0].minY - Support.phraseRect.minY) < 3, "rects \(stored.rects)")
            #expect(controller.pendingSourceCorrection == nil, "the answer was cached: no correction needed")
            try store.highlights.deleteHighlight(id: stored.id)
        } else {
            // Seen once, when this suite ran beside other hosted-window suites: PDFKit had not read
            // the page after 25 s (alone it takes about 6 to 9 s). PDFKit gives no way to start or
            // await its reading, so this is reported, not failed.
            withKnownIssue("PDFKit did not add Live Text to page 17 within 25 s in this run", isIntermittent: true) {
                Issue.record("Live Text not ready; the tag is checked with a bridge-shaped selection instead")
            }
            let made = controller.highlight(Support.selection(page: Support.phrasePage, rects: [Support.phraseRect],
                                                              string: Support.phrase), color: .green)
            #expect(made.map(\.textSource) == [.liveText])
            try store.highlights.deleteHighlight(id: try #require(made.first).id)
        }
    }

    @Test func theTypedCoverKeepsTheTextLayerSource() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let host = try await HighlightsTestSupport.host(book, store, pageIndex: 0)
        defer { Task { await host.close() } }
        let controller = HighlightsTestSupport.controller(host)
        #expect(await PageInkTestSupport.waitUntil { controller.textSources.cachedLayer(forPage: 0) != nil })
        let selection = try HighlightsTestSupport.select("The Scanned Fixture Book", onPage: 0, in: host)
        let made = controller.highlight(selection, color: .yellow)
        #expect(made.count == 1)
        let stored = try #require(try store.highlights.highlights(bookID: book.id).first)
        #expect(stored.textSource == nil)
        #expect(!stored.isOnScannedPage)
        #expect(stored.text == "The Scanned Fixture Book")
    }

    /// A page whose answer was not prefetched (far from the screen): the highlight is saved at
    /// once without a source, then corrected off the main thread.
    @Test func aPageNotReadYetIsCorrectedAfterSaving() async throws {
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let host = try await HighlightsTestSupport.host(book, store, pageIndex: 1)
        defer { Task { await host.close() } }
        let controller = HighlightsTestSupport.controller(host)
        let far = 25
        #expect(controller.textSources.cachedLayer(forPage: far) == nil)
        let made = controller.highlight(Support.selection(page: far, rects: [Support.phraseRect], string: Support.phrase),
                                        color: .blue)
        let id = try #require(made.first?.id)
        #expect(made.first?.textSource == nil)
        let correction = try #require(controller.pendingSourceCorrection)
        await correction.value
        #expect(try store.highlights.highlight(id: id)?.textSource == .liveText)
        #expect(controller.textSources.cachedLayer(forPage: far) == .noText)
    }
}

/// S4 · The crop renderer: the page under a highlight's rects with a small margin, off the main
/// thread, at the scale asked for, from a private document; cached in memory and cancellable.
@Suite(.serialized)
@MainActor
struct ScannedHighlightCropTests {
    typealias Support = ScannedHighlightTestSupport

    @Test func cropsThePhraseAtTheExpectedSize() async throws {
        let renderer = HighlightCropRenderer(url: Support.scannedPDF)
        let crop = try #require(await renderer.crop(pageIndex: Support.phrasePage, rects: [Support.phraseRect], zoom: 1, scale: 2))
        let margin = HighlightCrop.margin
        let expected = CGSize(width: Support.phraseRect.width + 2 * margin, height: Support.phraseRect.height + 2 * margin)
        #expect(crop.pageSize == expected)
        #expect(crop.image.size == expected)
        #expect(crop.image.scale == 2)
        #expect(crop.image.cgImage?.width == Int(expected.width * 2))
        #expect(crop.image.cgImage?.height == Int(expected.height * 2))
        // Text, not blank paper: a good share of dark pixels.
        let dark = Support.darkFraction(crop.image)
        #expect(dark > 0.05 && dark < 0.7, "dark fraction \(dark)")
        try? crop.image.pngData()?.write(to: NotebookTestSupport.repoRoot.appendingPathComponent("build/scanned-highlight-crop.png"))

        let zoomed = try #require(await renderer.crop(pageIndex: Support.phrasePage, rects: [Support.phraseRect], zoom: 2, scale: 1))
        #expect(zoomed.image.size == CGSize(width: expected.width * 2, height: expected.height * 2))

        // A blank stretch of the same page (the right margin) is paper.
        let blank = try #require(await renderer.crop(pageIndex: Support.phrasePage,
                                                     rects: [CGRect(x: 560, y: 400, width: 30, height: 12)], zoom: 1, scale: 2))
        #expect(Support.darkFraction(blank.image) < 0.01)
        #expect(await renderer.renderCount == 3)

        // Nothing to show, or no such page.
        #expect(await renderer.crop(pageIndex: Support.phrasePage, rects: [], zoom: 1, scale: 2) == nil)
        #expect(await renderer.crop(pageIndex: 40, rects: [Support.phraseRect], zoom: 1, scale: 2) == nil)
    }

    @Test func theRegionIsClippedToThePage() {
        let box = CGRect(x: 0, y: 0, width: 612, height: 792)
        #expect(HighlightCrop.region(of: [CGRect(x: 1, y: 1, width: 10, height: 10)], cropBox: box)
                == CGRect(x: 0, y: 0, width: 15, height: 15))
        #expect(HighlightCrop.region(of: [Support.phraseRect, Support.phraseRect.offsetBy(dx: 0, dy: -24)])
                == CGRect(x: 68, y: 665, width: 167, height: 44))
        #expect(HighlightCrop.region(of: [.null, .zero]) == nil)
    }

    @Test func aCancelledRequestRendersNothing() async throws {
        let renderer = HighlightCropRenderer(url: Support.scannedPDF)
        let task = Task { await renderer.crop(pageIndex: Support.phrasePage, rects: [Support.phraseRect], zoom: 1, scale: 2) }
        task.cancel()
        #expect(await task.value == nil)
        #expect(await renderer.renderCount == 0)

        // Through the cache: a row that went away before its start delay renders nothing.
        let (store, book) = try Support.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let cache = HighlightCropCache(documentURL: store.documentURL(for: book), startDelay: .milliseconds(200))
        let highlight = Support.phraseHighlight(book)
        let row = Task { await cache.image(for: highlight, zoom: 1, scale: 2) }
        try await Task.sleep(for: .milliseconds(20))
        row.cancel()
        #expect(await row.value == nil)
        #expect(cache.stats.cancelled == 1)
        #expect(cache.stats.rendered == 0)
        #expect(await cache.renderer.renderCount == 0)

        // Asked again: rendered once, then from memory.
        let image = try #require(await cache.image(for: highlight, zoom: 1, scale: 2))
        #expect(image.size.width == Support.phraseRect.width + 2 * HighlightCrop.margin)
        #expect(await cache.image(for: highlight, zoom: 1, scale: 2) === image)
        #expect(cache.stats.rendered == 1)
        #expect(cache.stats.cacheHits == 1)
        // A recolour keeps the crop; a merge into larger rects renders again.
        var recoloured = highlight
        recoloured.color = .pink
        #expect(cache.cachedImage(for: recoloured, zoom: 1, scale: 2) === image)
        var merged = highlight
        merged.rects.append(Support.phraseRect.offsetBy(dx: 0, dy: -24))
        #expect(cache.cachedImage(for: merged, zoom: 1, scale: 2) == nil)
        cache.purge()
        #expect(cache.cachedCount == 0)
        // Nothing is ever written next to the book.
        let files = BackupTestSupport.files(in: store.bookDirectoryURL(bookID: book.id))
        #expect(files.keys.sorted() == [book.fileName])
    }

    @Test func spokenTextIsTheCaptionOrSaysWhatItIs() throws {
        let book = Book(title: "B", fingerprint: "f", fileName: "b.pdf", pageCount: 30, fileSize: 1)
        let captioned = ScannedHighlightTestSupport.phraseHighlight(book)
        #expect(HighlightCropLabels.spokenText(captioned) == Support.phrase)
        let blank = ScannedHighlightTestSupport.phraseHighlight(book, text: "  ")
        #expect(HighlightCropLabels.spokenText(blank) == "Highlight on a scanned page, page 17")
        var typed = captioned
        typed.textSource = nil
        #expect(HighlightCropLabels.spokenText(typed) == Support.phrase)
    }
}
