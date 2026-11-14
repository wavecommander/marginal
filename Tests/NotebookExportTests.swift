import Foundation
import PDFKit
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// Notebook export (WP9): Markdown against a golden file with the inked note's PNG, the PDF's
/// pages, searchable text and vector ink, cancellation, file names.
@MainActor
struct NotebookExportTests {
    typealias Support = NotebookTestSupport

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NotebookExportTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func contents(_ directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    @Test func markdownMatchesTheGoldenFileWithAnImageForTheInkedNote() async throws {
        let (store, book, model) = try await Support.seeded()
        defer { Support.cleanUp(store) }
        let notebook = try #require(model.notebook)
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await NotebookExporter.export(.markdown, notebook: notebook, book: book, store: store, root: root)
        #expect(result.fileURL.lastPathComponent == "no-outline Notebook.zip")
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
        let zipSize = try #require(try FileManager.default.attributesOfItem(atPath: result.fileURL.path)[.size] as? Int)
        #expect(zipSize > 10_000)

        let folder = result.workDirectory.appendingPathComponent("no-outline Notebook", isDirectory: true)
        let markdown = try String(contentsOf: folder.appendingPathComponent("no-outline Notebook.md"), encoding: .utf8)
        let actualCopy = Support.repoRoot.appendingPathComponent("build/notebook-seeded-actual.md")
        try? FileManager.default.createDirectory(at: actualCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? markdown.write(to: actualCopy, atomically: true, encoding: .utf8)
        let golden = try String(contentsOf: Support.goldenDirectory.appendingPathComponent("seeded.md"), encoding: .utf8)
        #expect(markdown == golden, "compare build/notebook-seeded-actual.md with Tests/Fixtures/Notebook/seeded.md")
        #expect(markdown.contains("![Handwritten note](images/note-001.png)"))

        // The inked note's image: the whole note (text and ink) at 3x.
        let png = try Data(contentsOf: folder.appendingPathComponent("images/note-001.png"))
        #expect(png.count > 10_000)
        let image = try #require(UIImage(data: png))
        #expect(image.size.width == NotePageStyle.pageWidth * 3)
        #expect(contents(folder.appendingPathComponent("images")) == ["note-001.png"])

        NotebookExporter.cleanUp(result)
        #expect(await NotePageTestSupport.waitUntil { !FileManager.default.fileExists(atPath: result.workDirectory.path) })
    }

    @Test func markdownWithoutInkIsASingleFile() async throws {
        let (store, book) = try Support.makeStore(title: "Plain: A/B")
        defer { Support.cleanUp(store) }
        _ = try store.notes.save(Note(bookID: book.id, target: .page(1), text: "Only text"))
        let model = await Support.startedModel(store, book)
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await NotebookExporter.export(.markdown, notebook: try #require(model.notebook), book: book,
                                                       store: store, root: root)
        #expect(result.fileURL.lastPathComponent == "Plain A B Notebook.md")
        let text = try String(contentsOf: result.fileURL, encoding: .utf8)
        #expect(text == "# Plain: A/B\n\n## Front matter\n\n**Page 2**\n\nOnly text\n")
    }

    @Test func pdfHasPagesSearchableTextAndVectorInk() async throws {
        let (store, book, model) = try await Support.seeded()
        defer { Support.cleanUp(store) }
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var fractions: [Double] = []
        let result = try await NotebookExporter.export(.pdf, notebook: try #require(model.notebook), book: book,
                                                       store: store, root: root) { fractions.append($0) }
        #expect(result.fileURL.lastPathComponent == "no-outline Notebook.pdf")
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted())

        let document = try #require(PDFDocument(url: result.fileURL))
        #expect(document.pageCount >= 1)
        // Wrapped lines come out separated by newlines: compare with whitespace collapsed.
        let text = try #require(document.string).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for phrase in ["5.2 The Characteristic Equation", "Composition of maps is matrix multiplication",
                       "Why the determinant shows up", "at most n distinct eigenvalues", "Front matter"] {
            #expect(text.contains(phrase), "PDF text contains \(phrase)")
        }

        // The page with the inked (pen and marker) note draws its strokes as paths: many curve
        // segments (the stroke outlines), and no image for them.
        let pageIndex = try #require((0..<document.pageCount).first {
            document.page(at: $0)?.string?.contains("Why the determinant shows up") == true
        })
        let data = try Data(contentsOf: result.fileURL)
        let counts = NotebookPDFInspector.operatorCounts(data, page: pageIndex + 1)
        #expect((counts["c"] ?? 0) > 100, "curve operators: \(counts)")
        #expect((counts["f"] ?? 0) > 0)
        #expect((counts["Do"] ?? 0) == 0, "no images for vector inks: \(counts)")
        #expect(((counts["Tj"] ?? 0) + (counts["TJ"] ?? 0)) > 0)

        // A page of the export as an image, for looking at (build/notebook-export-page.png).
        if let page = document.page(at: pageIndex) {
            let image = page.thumbnail(of: CGSize(width: 1200, height: 1600), for: .mediaBox)
            try? image.pngData()?.write(to: Support.repoRoot.appendingPathComponent("build/notebook-export-page.png"))
        }
    }

    @Test func tallNotesContinueOnTheNextPage() async throws {
        let (store, book) = try Support.makeStore()
        defer { Support.cleanUp(store) }
        let long = (1...80).map { "Line \($0) of a very long note." }.joined(separator: "\n")
        _ = try store.notes.save(Note(bookID: book.id, target: .page(3), text: long))
        let model = await Support.startedModel(store, book)
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await NotebookExporter.export(.pdf, notebook: try #require(model.notebook), book: book,
                                                       store: store, root: root)
        let document = try #require(PDFDocument(url: result.fileURL))
        #expect(document.pageCount >= 3)
        let all = try #require(document.string)
        // Every line is present exactly once (cut between lines, not through them, never scaled away).
        for number in [1, 25, 26, 27, 52, 80] {
            #expect(all.components(separatedBy: "Line \(number) of a very long note.").count == 2, "line \(number)")
        }
    }

    @Test func cancellationLeavesNoFilesBehind() async throws {
        let (store, book, model) = try await Support.seeded()
        defer { Support.cleanUp(store) }
        let notebook = try #require(model.notebook)
        for format in NotebookExportFormat.allCases {
            let root = makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            final class Box { var task: Task<NotebookExportResult, any Error>? }
            let box = Box()
            let task = Task { @MainActor in
                try await NotebookExporter.export(format, notebook: notebook, book: book, store: store, root: root) { _ in
                    box.task?.cancel()
                }
            }
            box.task = task
            await #expect(throws: CancellationError.self, "\(format)") { _ = try await task.value }
            #expect(contents(root).isEmpty, "\(format) left \(contents(root))")
        }
    }

    @Test func fileNamesComeFromTheBookTitle() {
        #expect(NotebookExporter.baseName(forBookTitle: "Linear Algebra") == "Linear Algebra Notebook")
        #expect(NotebookExporter.baseName(forBookTitle: "  A/B: C?\n") == "A B C Notebook")
        #expect(NotebookExporter.baseName(forBookTitle: ".hidden") == "hidden Notebook")
        #expect(NotebookExporter.baseName(forBookTitle: " / ") == "Notebook")
        #expect(NotebookExporter.baseName(forBookTitle: String(repeating: "x", count: 200)).count == 80 + " Notebook".count)
        #expect(NotebookExporter.imageName(ordinal: 7) == "note-007.png")
    }
}

/// Counts content-stream operators on one page of a PDF.
enum NotebookPDFInspector {
    static func operatorCounts(_ data: Data, page number: Int) -> [String: Int] {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: number), let table = CGPDFOperatorTableCreate() else { return [:] }
        let box = PDFOperatorCounter()
        CGPDFOperatorTableSetCallback(table, "f") { _, info in PDFOperatorCounter.bump(info, "f") }
        CGPDFOperatorTableSetCallback(table, "c") { _, info in PDFOperatorCounter.bump(info, "c") }
        CGPDFOperatorTableSetCallback(table, "Do") { _, info in PDFOperatorCounter.bump(info, "Do") }
        CGPDFOperatorTableSetCallback(table, "BI") { _, info in PDFOperatorCounter.bump(info, "BI") }
        CGPDFOperatorTableSetCallback(table, "Tj") { _, info in PDFOperatorCounter.bump(info, "Tj") }
        CGPDFOperatorTableSetCallback(table, "TJ") { _, info in PDFOperatorCounter.bump(info, "TJ") }
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(box).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return box.counts
    }
}
