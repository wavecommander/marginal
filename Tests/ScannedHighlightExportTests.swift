import Foundation
import PDFKit
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import TactileTexts

/// S4 · Scanned-page highlights in the Notebook and its three exports: the text-only Markdown
/// (S1's caption form, and the ZIP is offered), the Markdown ZIP (the crop under `highlights/`,
/// linked above the caption) and the PDF (the crop drawn, with its caption). Notebook search
/// finds the highlight by its stored text; counts are unchanged.
@Suite(.serialized)
@MainActor
struct ScannedHighlightExportTests {
    typealias Support = ScannedHighlightTestSupport

    /// `scanned.pdf` with a captioned scanned-page highlight on page 17, an uncaptioned one on
    /// page 21 and a text-layer highlight on the typed cover.
    private func seeded() async throws -> (LibraryStore, Book, NotebookModel, captioned: Highlight, blank: Highlight) {
        let (store, book) = try Support.makeStore()
        let captioned = Support.phraseHighlight(book)
        var blank = Support.phraseHighlight(book, color: .blue, text: "")
        blank.pageIndex = 20
        blank.rects = [CGRect(x: 72, y: 600, width: 300, height: 12), CGRect(x: 72, y: 586, width: 280, height: 12)]
        try store.highlights.save(captioned)
        try store.highlights.save(blank)
        try store.highlights.save(Highlight(bookID: book.id, pageIndex: 0, rects: [CGRect(x: 72, y: 600, width: 200, height: 20)],
                                            color: .green, text: "The Scanned Fixture Book"))
        let model = await NotebookTestSupport.startedModel(store, book)
        return (store, book, model, captioned, blank)
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ScannedHighlightExport-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func notebookCountsAndSearchUseTheStoredText() async throws {
        let (store, _, model, captioned, blank) = try await seeded()
        defer { NotebookTestSupport.cleanUp(store) }
        let notebook = try #require(model.notebook)
        #expect(notebook.totalCounts.highlights == 3)
        func highlightIDs(_ query: String) -> [UUID] {
            var filter = NotebookFilter()
            filter.query = query
            return NotebookFeed.rows(for: notebook, filter: filter).compactMap {
                if case .highlight(let highlight, _) = $0.kind { highlight.id } else { nil }
            }
        }
        #expect(highlightIDs("heron") == [captioned.id])
        // Found by what is stored, not by what the row shows for a crop without a caption.
        #expect(!highlightIDs("scanned page").contains(blank.id))
        #expect(highlightIDs("").count == 3)
    }

    @Test func textOnlyMarkdownCarriesTheCaptionAndOffersTheZip() async throws {
        let (store, book, model, _, _) = try await seeded()
        defer { NotebookTestSupport.cleanUp(store) }
        let notebook = try #require(model.notebook)
        #expect(NotebookExporter.hasImages(notebook), "the reader is told images are not included and offered the ZIP")
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await NotebookExporter.export(.markdown, notebook: notebook, book: book, store: store, root: root)
        let text = try String(contentsOf: result.fileURL, encoding: .utf8)
        #expect(text.contains("> The quiet heron measures tidewater. (p. 17)"))
        #expect(text.contains("> _Highlight on a scanned page_ (p. 21)"))
        #expect(text.contains("> The Scanned Fixture Book (p. 1)"))
        #expect(!text.contains("!["), "no image links in the text-only file")
        #expect(result.fileURL.pathExtension == "md")
    }

    @Test func markdownZipHoldsTheCropsUnderHighlightsAndLinksThem() async throws {
        let (store, book, model, _, _) = try await seeded()
        defer { NotebookTestSupport.cleanUp(store) }
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await NotebookExporter.export(.markdownZip, notebook: try #require(model.notebook), book: book,
                                                       store: store, root: root)
        #expect(result.fileURL.pathExtension == "zip")
        let folder = result.workDirectory.appendingPathComponent("Ink Notebook", isDirectory: true)
        let markdown = try String(contentsOf: folder.appendingPathComponent("Ink Notebook.md"), encoding: .utf8)
        #expect(markdown.contains("![Highlight on page 17](highlights/highlight-001.png)\n\n> The quiet heron measures tidewater. (p. 17)"))
        #expect(markdown.contains("![Highlight on page 21](highlights/highlight-002.png)\n\n> _Highlight on a scanned page_ (p. 21)"))
        #expect(markdown.contains("> The Scanned Fixture Book (p. 1)"))
        let files = (try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("highlights").path)).sorted()
        #expect(files == ["highlight-001.png", "highlight-002.png"])
        let png = try Data(contentsOf: folder.appendingPathComponent("highlights/highlight-001.png"))
        let image = try #require(UIImage(data: png))
        let scale = NotebookExporter.highlightImageScale
        #expect(image.size == CGSize(width: (Support.phraseRect.width + 2 * HighlightCrop.margin) * scale,
                                     height: (Support.phraseRect.height + 2 * HighlightCrop.margin) * scale))
        #expect(Support.darkFraction(image) > 0.05)
        // The zip holds the same entries (Files expands it).
        let zipData = try Data(contentsOf: result.fileURL)
        let entryName = Data("Ink Notebook/highlights/highlight-002.png".utf8)
        #expect(zipData.range(of: entryName) != nil)
    }

    @Test func aCropThatCannotBeDrawnLeavesTheCaptionAlone() async throws {
        let (store, book, model, _, _) = try await seeded()
        defer { NotebookTestSupport.cleanUp(store) }
        try FileManager.default.removeItem(at: store.documentURL(for: book))   // "PDF missing"
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await NotebookExporter.export(.markdownZip, notebook: try #require(model.notebook), book: book,
                                                       store: store, root: root)
        let folder = result.workDirectory.appendingPathComponent("Ink Notebook", isDirectory: true)
        let markdown = try String(contentsOf: folder.appendingPathComponent("Ink Notebook.md"), encoding: .utf8)
        #expect(!markdown.contains("!["))
        #expect(markdown.contains("> The quiet heron measures tidewater. (p. 17)"))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("highlights").path)) ?? []
        #expect(files.isEmpty)
    }

    @Test func pdfDrawsTheCropWithItsCaption() async throws {
        let (store, book, model, _, _) = try await seeded()
        defer { NotebookTestSupport.cleanUp(store) }
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await NotebookExporter.export(.pdf, notebook: try #require(model.notebook), book: book,
                                                       store: store, root: root)
        let document = try #require(PDFDocument(url: result.fileURL))
        #expect(document.pageCount >= 1)
        let text = try #require(document.string).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(text.contains("The quiet heron measures tidewater."))
        #expect(text.contains("Highlight on a scanned page"))
        #expect(text.contains("The Scanned Fixture Book"))
        // The page with the caption has the crops on it as images.
        let pageIndex = try #require((0..<document.pageCount).first {
            document.page(at: $0)?.string?.contains("heron") == true
        })
        let counts = NotebookPDFInspector.operatorCounts(try Data(contentsOf: result.fileURL), page: pageIndex + 1)
        #expect((counts["Do"] ?? 0) + (counts["BI"] ?? 0) >= 2, "the two crops are drawn: \(counts)")
        if let page = document.page(at: pageIndex) {
            let image = page.thumbnail(of: CGSize(width: 1200, height: 1600), for: .mediaBox)
            try? image.pngData()?.write(to: NotebookTestSupport.repoRoot.appendingPathComponent("build/scanned-highlight-export-page.png"))
        }
    }
}
