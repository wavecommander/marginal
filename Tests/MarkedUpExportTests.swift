import CryptoKit
import Foundation
import PDFKit
import PencilKit
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import TactileTexts

/// "Export Marked-Up PDF": the export holds every page of the book with its text and vector
/// content (not pictures of the pages), the reader's highlights and page ink in place (rotated
/// and cropped pages too), the PDF's own links, the book's outline with the reader's headings,
/// and optionally the notes appendix with its outline entries and links back to the pages. The
/// imported PDF is untouched. Scanned and converted books, cancellation and failures.
@Suite(.serialized)
@MainActor
struct MarkedUpExportTests {
    typealias Support = MarkedUpExportTestSupport

    @Test func exportsTheWholeBookWithItsTextOutlineInkHighlightsAndNotes() async throws {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("small.pdf"), pageCount: 12)
        defer { NotebookTestSupport.cleanUp(store) }
        let source = store.documentURL(for: book)
        let before = try Data(contentsOf: source)
        let sourceDocument = try #require(PDFDocument(url: source))

        // small.pdf: "1 Linear Systems" p1, "1.1 Foundations" p2, "1.2 Exercises" p4, "2 Vector Spaces" p5, …
        // A heading of the reader's own on page 7, ink on page 2, a highlight on page 3, notes.
        try store.headings.save(UserHeading(bookID: book.id, title: "My Interlude", pageIndex: 6, parent: nil))
        try await store.savePageInk(Support.penInk(), bookID: book.id, pageIndex: 1, origin: nil)
        let highlightRect = CGRect(x: 552, y: 600, width: 40, height: 14)  // in the right margin, no text
        try store.highlights.save(Highlight(bookID: book.id, pageIndex: 2, rects: [highlightRect], color: .yellow,
                                            text: "Highlighted"))
        _ = try store.notes.save(Note(bookID: book.id, target: .page(1), text: "A note on page two"))
        let outline = Outline(pdfEntries: await ReaderDocumentLoader.outlineEntries(at: source), pageCount: 12)
        let chapter2 = try #require(outline.nodes.first { $0.title == "2 Vector Spaces" })
        _ = try store.notes.save(Note(bookID: book.id, target: .heading(chapter2.anchor), text: "About chapter two"))

        var fractions: [Double] = []
        let root = Support.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await MarkedUpExporter.export(book: book, store: store, includeNotes: true, root: root,
                                                       progress: { fractions.append($0) })
        #expect(result.fileURL.lastPathComponent == "Ink (Marked Up with Notes).pdf")
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted())
        #expect(try Data(contentsOf: source) == before, "the imported PDF is not changed")

        let export = try #require(PDFDocument(url: result.fileURL))
        #expect(export.pageCount > 12, "the book's 12 pages and the appendix")
        #expect(export.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Ink")

        // Every book page keeps its text (drawn as text, not a picture of it) and its size.
        for index in 0..<12 {
            let original = try #require(sourceDocument.page(at: index))
            let copied = try #require(export.page(at: index))
            #expect(Support.words(copied.string) == Support.words(original.string), "text of page \(index + 1)")
            #expect(copied.bounds(for: .mediaBox).size == original.bounds(for: .cropBox).size)
            #expect(Support.imageXObjects(result.fileURL, page: index + 1) == 0, "page \(index + 1) has no pictures")
        }

        // Pen ink is vector paths; the highlight is drawn where it was made.
        let data = try Data(contentsOf: result.fileURL)
        let inked = NotebookPDFInspector.operatorCounts(data, page: 2)
        let plain = NotebookPDFInspector.operatorCounts(data, page: 4)
        #expect((inked["c"] ?? 0) > (plain["c"] ?? 0) + 20, "curves of the stroke outlines: \(inked) vs \(plain)")
        #expect((inked["Do"] ?? 0) == (plain["Do"] ?? 0) && (inked["BI"] ?? 0) == 0, "no images for pen ink")
        let page3 = try #require(export.page(at: 2))
        let image = Support.render(page3, scale: 2)
        try? image.pngData()?.write(to: Support.shot("marked-up-highlight.png"))
        let geometry = PageInkGeometry(page: page3)
        let highlightCentre = CGPoint(x: highlightRect.midX, y: highlightRect.midY).applying(geometry.pageToInk)
        #expect(Support.isYellow(image, at: highlightCentre, scale: 2), "the highlight is yellow where it was made")
        #expect(!Support.isYellow(Support.render(try #require(sourceDocument.page(at: 2)), scale: 2), at: highlightCentre, scale: 2))
        let page2 = Support.render(try #require(export.page(at: 1)), scale: 2)
        try? page2.pngData()?.write(to: Support.shot("marked-up-ink.png"))
        let onStroke = CGPoint(x: 445, y: 200)
        #expect(Support.isDark(page2, at: onStroke, scale: 2), "the ink stroke is on page 2")
        #expect(!Support.isDark(Support.render(try #require(sourceDocument.page(at: 1)), scale: 2), at: onStroke, scale: 2))

        // The outline: the book's, with the reader's heading where Contents shows it, then Notes.
        let rootItem = try #require(export.outlineRoot)
        let top = Support.children(rootItem)
        #expect(top.map(\.label) == ["1 Linear Systems", "2 Vector Spaces", "My Interlude", "3 Eigenvalues", "Notes"])
        #expect(top.map { Support.pageIndex($0, in: export) } == [0, 4, 6, 8, 12])
        #expect(Support.children(top[1]).map(\.label) == ["2.1 Foundations", "2.2 Exercises"])
        let notes = try #require(top.last)
        #expect(Support.children(notes).map(\.label) == ["1 Linear Systems", "2 Vector Spaces"])
        #expect(Support.children(Support.children(notes)[0]).map(\.label) == ["1.1 Foundations"])
        #expect(Support.children(notes).allSatisfy { (Support.pageIndex($0, in: export) ?? -1) >= 12 })

        // The appendix: the notes as text, page labels linking back to the book's pages.
        if let first = export.page(at: 12) {
            try? Support.render(first, scale: 2).pngData()?.write(to: Support.shot("marked-up-appendix.png"))
            print("appendix links: \(first.annotations.map { "\($0.type ?? "?") \($0.bounds)" })")
        }
        let appendixText = (12..<export.pageCount).compactMap { export.page(at: $0)?.string }.joined(separator: " ")
        #expect(appendixText.contains("A note on page two"))
        #expect(appendixText.contains("About chapter two"))
        let appendixLinks = (12..<export.pageCount).flatMap { Support.linkTargets(export, page: $0) }
        #expect(appendixLinks.contains(1), "p. 2 links to page 2: \(appendixLinks)")
        #expect(appendixLinks.contains(4), "the chapter's heading links to its first page: \(appendixLinks)")
    }

    @Test func bookOnlyHasNoAppendixAndKeepsThePDFsOwnLinks() async throws {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("links.pdf"), pageCount: 12)
        defer { NotebookTestSupport.cleanUp(store) }
        _ = try store.notes.save(Note(bookID: book.id, target: .page(1), text: "Not exported"))
        let root = Support.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await MarkedUpExporter.export(book: book, store: store, includeNotes: false, root: root)
        #expect(result.fileURL.lastPathComponent == "Ink (Marked Up).pdf")
        let export = try #require(PDFDocument(url: result.fileURL))
        #expect(export.pageCount == 12)
        #expect(!(export.string ?? "").contains("Not exported"))
        #expect(Support.children(try #require(export.outlineRoot)).map(\.label) == ["1 Linear Systems", "2 Vector Spaces", "3 Eigenvalues"])
        // links.pdf: page 7 links to pages 6 and 12, page 3 to page 7.
        #expect(Set(Support.linkTargets(export, page: 6)) == [5, 11])
        #expect(Support.linkTargets(export, page: 2) == [6])
        let original = try #require(PDFDocument(url: store.documentURL(for: book)))
        let originalRects = Support.linkRects(original, page: 6)
        #expect(Support.linkRects(export, page: 6).count == originalRects.count)
        for (copied, source) in zip(Support.linkRects(export, page: 6), originalRects) {
            #expect(abs(copied.midX - source.midX) < 1 && abs(copied.midY - source.midY) < 1, "\(copied) vs \(source)")
        }
    }

    @Test func rotatedAndCroppedPagesKeepInkAndHighlightsInPlace() async throws {
        // small.pdf with page 1 rotated 90° and page 2 cropped.
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("rotated-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: made) }
        let document = try #require(PDFDocument(url: PageInkTestSupport.fixture("small.pdf")))
        try #require(document.page(at: 0)).rotation = 90
        let crop = CGRect(x: 100, y: 150, width: 300, height: 400)
        try #require(document.page(at: 1)).setBounds(crop, for: .cropBox)
        #expect(document.write(to: made))
        let (store, book) = try PageInkTestSupport.makeStore(pdf: made, pageCount: 12)
        defer { NotebookTestSupport.cleanUp(store) }

        let reread = try #require(PDFDocument(url: store.documentURL(for: book)))
        let rotated = PageInkGeometry(page: try #require(reread.page(at: 0)))
        let cropped = PageInkGeometry(page: try #require(reread.page(at: 1)))
        #expect(rotated.rotation == 90 && cropped.cropBox == crop)
        // Ink (in ink space: the page upright, top-left origin) and a highlight in a blank corner.
        let rotatedInk = PKDrawing(strokes: [PageInkTestSupport.stroke(from: CGPoint(x: 100, y: 300), to: CGPoint(x: 400, y: 300),
                                                                       width: 14, color: .black)])
        let croppedInk = PKDrawing(strokes: [PageInkTestSupport.stroke(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 200, y: 40),
                                                                       width: 14, color: .black)])
        try await store.savePageInk(rotatedInk.dataRepresentation(), bookID: book.id, pageIndex: 0, origin: nil)
        try await store.savePageInk(croppedInk.dataRepresentation(), bookID: book.id, pageIndex: 1, origin: nil)
        let corner = CGRect(x: 520, y: 30, width: 60, height: 40)  // page space, bottom-right, no text
        try store.highlights.save(Highlight(bookID: book.id, pageIndex: 0, rects: [corner], color: .yellow, text: ""))

        let root = Support.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await MarkedUpExporter.export(book: book, store: store, includeNotes: false, root: root)
        let export = try #require(PDFDocument(url: result.fileURL))
        let first = try #require(export.page(at: 0)), second = try #require(export.page(at: 1))
        #expect(first.bounds(for: .mediaBox).size == rotated.size, "the rotated page is upright: \(first.bounds(for: .mediaBox))")
        #expect(first.rotation == 0)
        #expect(second.bounds(for: .mediaBox).size == crop.size)

        let firstImage = Support.render(first, scale: 2)
        let secondImage = Support.render(second, scale: 2)
        try? firstImage.pngData()?.write(to: Support.shot("marked-up-rotated.png"))
        try? secondImage.pngData()?.write(to: Support.shot("marked-up-cropped.png"))
        #expect(Support.isDark(firstImage, at: CGPoint(x: 250, y: 300), scale: 2), "ink on the rotated page")
        #expect(Support.isYellow(firstImage, at: CGPoint(x: corner.midX, y: corner.midY).applying(rotated.pageToInk), scale: 2),
                "the highlight on the rotated page")
        #expect(!Support.isYellow(firstImage, at: CGPoint(x: corner.midX, y: corner.midY), scale: 2))
        #expect(Support.isDark(secondImage, at: CGPoint(x: 120, y: 40), scale: 2), "ink on the cropped page")
        // The page's text is still there, upright: the export's page 1 reads like the original's.
        #expect(Support.words(first.string) == Support.words(reread.page(at: 0)?.string))
    }

    @Test func scannedBookKeepsItsPicturesAndHighlights() async throws {
        let (store, book) = try ScannedHighlightTestSupport.makeStore()
        defer { NotebookTestSupport.cleanUp(store) }
        let highlight = ScannedHighlightTestSupport.phraseHighlight(book)
        try store.highlights.save(highlight)
        let source = store.documentURL(for: book)
        let before = try Data(contentsOf: source)
        let root = Support.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await MarkedUpExporter.export(book: book, store: store, includeNotes: true, root: root)
        #expect(try Data(contentsOf: source) == before)
        let export = try #require(PDFDocument(url: result.fileURL))
        #expect(export.pageCount == 30, "no notes: no appendix")
        #expect((export.page(at: 0)?.string ?? "").contains("The Scanned Fixture Book"), "the typed cover keeps its text")
        #expect((export.page(at: 16)?.string ?? "").isEmpty, "no text layer is added to a scanned page")
        let page = try #require(export.page(at: ScannedHighlightTestSupport.phrasePage))
        let image = Support.render(page, scale: 2)
        try? image.pngData()?.write(to: Support.shot("marked-up-scanned.png"))
        let geometry = PageInkGeometry(page: page)
        let rect = ScannedHighlightTestSupport.phraseRect
        let inGap = CGPoint(x: rect.maxX - 2, y: rect.maxY - 1).applying(geometry.pageToInk)
        #expect(Support.isYellow(image, at: inGap, scale: 2) || Support.isYellow(image, at: CGPoint(x: rect.minX + 1, y: rect.maxY - 1)
            .applying(geometry.pageToInk), scale: 2), "the scanned-page highlight is drawn from its rects")
        // The page pictures are carried over, not re-made larger.
        let sizes = try [source, result.fileURL].map { try #require(FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) }
        print("scanned.pdf \(sizes[0] / 1024) KB → export \(sizes[1] / 1024) KB")
        #expect(Double(sizes[1]) < Double(sizes[0]) * 1.5)
    }

    @Test func convertedBookExportsItsGeneratedPDF() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MarkedUpConvert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let markdown = Support.repoRoot.appendingPathComponent("Tests/Fixtures/f3-notes.md")
        let input = ConversionInput(original: markdown, format: .markdown, fileName: "f3-notes.md", directory: scratch,
                                    outputFileName: "book.pdf", options: ConversionOptions())
        let converted = try await TextDocumentConverter().convert(input) { _ in }
        let (store, book) = try PageInkTestSupport.makeStore(pdf: converted.pdf, pageCount: converted.pageCount)
        defer { NotebookTestSupport.cleanUp(store) }
        var stored = book
        stored.sourceFormat = .markdown
        stored.originalFileName = "f3-notes.md"
        try store.books.save(stored)
        try await store.savePageInk(Support.penInk(), bookID: book.id, pageIndex: 0, origin: nil)
        _ = try store.notes.save(Note(bookID: book.id, target: .page(0), text: "Converted note"))
        let root = Support.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await MarkedUpExporter.export(book: stored, store: store, includeNotes: true, root: root)
        let export = try #require(PDFDocument(url: result.fileURL))
        let generated = try #require(PDFDocument(url: converted.pdf))
        #expect(export.pageCount > generated.pageCount)
        #expect(Support.words(export.page(at: 0)?.string) == Support.words(generated.page(at: 0)?.string))
        #expect((export.string ?? "").contains("Converted note"))
    }

    @Test func cancellingLeavesNoFilesBehind() async throws {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("small.pdf"), pageCount: 12)
        defer { NotebookTestSupport.cleanUp(store) }
        let root = Support.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        final class Box { var task: Task<NotebookExportResult, any Error>? }
        let box = Box()
        let task = Task { @MainActor in
            try await MarkedUpExporter.export(book: book, store: store, includeNotes: false, root: root, progress: { fraction in
                if fraction > 0.3 { box.task?.cancel() }
            })
        }
        box.task = task
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty)
    }

    /// Markup that cannot be read stops the export; it is never left out silently.
    @Test func pageInkThatCannotBeReadFailsTheExportAndNamesThePage() async throws {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("small.pdf"), pageCount: 12)
        defer { NotebookTestSupport.cleanUp(store) }
        try await store.savePageInk(Support.penInk(), bookID: book.id, pageIndex: 1, origin: nil)
        try await store.savePageInk(Data("not a drawing".utf8), bookID: book.id, pageIndex: 4, origin: nil)
        let root = Support.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: MarkedUpExportError.unreadablePageInk(pageNumber: 5)) {
            _ = try await MarkedUpExporter.export(book: book, store: store, includeNotes: false, root: root)
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty, "nothing is left behind")
        #expect(MarkedUpExportError.unreadablePageInk(pageNumber: 5).errorDescription?.contains("page 5") == true)
    }

    @Test func noteInkThatCannotBeReadFailsOnlyTheExportWithNotes() async throws {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("small.pdf"), pageCount: 12)
        defer { NotebookTestSupport.cleanUp(store) }
        let note = Note(bookID: book.id, target: .page(1), text: "Typed text", hasInk: true)
        _ = try store.notes.save(note)
        try await store.saveNoteInk(Data("not ink".utf8), bookID: book.id, noteID: note.id, origin: nil)
        let root = Support.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: MarkedUpExportError.unreadableNoteInk) {
            _ = try await MarkedUpExporter.export(book: book, store: store, includeNotes: true, root: root)
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty, "nothing is left behind")

        // Book Only does not draw the notes, so their ink is not its concern.
        let result = try await MarkedUpExporter.export(book: book, store: store, includeNotes: false, root: root)
        #expect(PDFDocument(url: result.fileURL)?.pageCount == 12)
    }

    @Test func aBookWithoutItsPDFSaysSo() async throws {
        let (store, book) = try PageInkTestSupport.makeStore()
        defer { NotebookTestSupport.cleanUp(store) }
        await #expect(throws: MarkedUpExportError.missingPDF) {
            _ = try await MarkedUpExporter.export(book: book, store: store, includeNotes: true, root: Support.makeRoot())
        }
    }
}

/// Exporting `large.pdf` (1,500 pages) page by page: the footprint stays bounded while it runs.
/// The bound is process-wide and generous (unit tests run on one simulator, in `test.sh`'s
/// second pass, but other suites in the process can still allocate meanwhile).
@MainActor
struct MarkedUpExportMemoryTests {
    @Test func aLargeBookExportsWithBoundedMemory() async throws {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("large.pdf"), pageCount: 1500)
        defer { NotebookTestSupport.cleanUp(store) }
        for page in stride(from: 0, to: 1500, by: 50) {
            try await store.savePageInk(MarkedUpExportTestSupport.penInk(), bookID: book.id, pageIndex: page, origin: nil)
            try store.highlights.save(Highlight(bookID: book.id, pageIndex: page, rects: [CGRect(x: 72, y: 600, width: 200, height: 14)],
                                                color: .green, text: "x"))
        }
        let root = MarkedUpExportTestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = SearchTestSupport.footprintMB()
        var peak = start
        var yields = 0
        let clock = ContinuousClock()
        let began = clock.now
        let result = try await MarkedUpExporter.export(book: book, store: store, includeNotes: false, root: root, progress: { _ in
            yields += 1
            if yields % 25 == 0 { peak = max(peak, SearchTestSupport.footprintMB()) }
        })
        let elapsed = clock.now - began
        let export = try #require(CGPDFDocument(result.fileURL as CFURL))
        #expect(export.numberOfPages == 1500)
        let sizes = try [PageInkTestSupport.fixture("large.pdf"), result.fileURL].map {
            try #require(FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int)
        }
        print("large.pdf export: \(elapsed), footprint \(Int(start)) MB → peak \(Int(peak)) MB, " +
              "\(sizes[0] / 1024) KB → \(sizes[1] / 1024) KB")
        #expect(peak - start < 250, "footprint grew \(Int(peak - start)) MB")
    }
}

@MainActor
enum MarkedUpExportTestSupport {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MarkedUpExportTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// `build/<name>`, for looking at.
    static func shot(_ name: String) -> URL {
        let directory = repoRoot.appendingPathComponent("build", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    /// A pen stroke and a marker stroke (both vector inks), in ink space.
    static func penInk() -> Data {
        PKDrawing(strokes: [
            PageInkTestSupport.stroke(from: CGPoint(x: 150, y: 200), to: CGPoint(x: 450, y: 200), width: 10, color: .black),
            PageInkTestSupport.stroke(from: CGPoint(x: 150, y: 260), to: CGPoint(x: 450, y: 300), ink: .marker, width: 14),
        ]).dataRepresentation()
    }

    static func words(_ string: String?) -> [String] {
        (string ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func children(_ item: PDFOutline) -> [PDFOutline] {
        (0..<item.numberOfChildren).compactMap { item.child(at: $0) }
    }

    static func pageIndex(_ item: PDFOutline, in document: PDFDocument) -> Int? {
        let page = item.destination?.page ?? (item.action as? PDFActionGoTo)?.destination.page
        return page.map { document.index(for: $0) }
    }

    private static func links(_ document: PDFDocument, page index: Int) -> [PDFAnnotation] {
        (document.page(at: index)?.annotations ?? []).filter { $0.type == "Link" }
            .sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
    }

    /// The page indices the page's links go to.
    static func linkTargets(_ document: PDFDocument, page index: Int) -> [Int] {
        links(document, page: index).compactMap { link in
            (link.destination ?? (link.action as? PDFActionGoTo)?.destination)?.page.map { document.index(for: $0) }
        }
    }

    static func linkRects(_ document: PDFDocument, page index: Int) -> [CGRect] {
        links(document, page: index).map(\.bounds)
    }

    /// Image XObjects in the page's own resources (a picture of the page would be one).
    static func imageXObjects(_ url: URL, page number: Int) -> Int {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: number),
              let dictionary = page.dictionary else { return -1 }
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return 0 }
        var images = 0
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream, let info = CGPDFStreamGetDictionary(stream) {
                var subtype: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(info, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" {
                    images += 1
                }
            }
            return true
        }, nil)
        return images
    }

    /// The page drawn on white at `scale` pixels per point (top-left origin, as ink space).
    static func render(_ page: PDFPage, scale: CGFloat) -> UIImage {
        let box = page.bounds(for: .mediaBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: box.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: box.size))
            context.cgContext.translateBy(x: 0, y: box.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            if let ref = page.pageRef { context.cgContext.drawPDFPage(ref) }
        }
    }

    static func pixel(_ image: UIImage, at point: CGPoint, scale: CGFloat) -> (r: Int, g: Int, b: Int) {
        guard let cgImage = image.cgImage else { return (0, 0, 0) }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0) }
        context.draw(cgImage, in: CGRect(x: -point.x * scale, y: -(CGFloat(cgImage.height) - point.y * scale),
                                         width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    static func isDark(_ image: UIImage, at point: CGPoint, scale: CGFloat) -> Bool {
        let p = pixel(image, at: point, scale: scale)
        return p.r + p.g + p.b < 200
    }

    /// Yellow on white under a multiply blend: red stays high, blue drops.
    static func isYellow(_ image: UIImage, at point: CGPoint, scale: CGFloat) -> Bool {
        let p = pixel(image, at: point, scale: scale)
        return p.r > 200 && p.g > 180 && p.b < 190
    }
}
