import Foundation
import PDFKit
import ReaderCore
import ReaderStore
import Testing
@testable import Marginal

/// The F6 converters through the import flow, end to end, with a registry built here (the
/// app's `ConverterRegistry.standard` gains them at merge).
@MainActor
@Suite(.serialized)
struct WebConverterImportTests {
    private func makeService() throws -> (LibraryStore, ImportService, URL) {
        let store = try LibraryStore.ephemeral()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("F6ImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let registry = ConverterRegistry([ImagesConverter(), EPUBConverter(), TextDocumentConverter(), OfficeDocumentConverter(), SlidesConverter()])
        return (store, ImportService(store: store, converters: registry), scratch)
    }

    private func importOne(_ url: URL, service: ImportService, options: ConversionOptions = ConversionOptions()) async throws -> Book {
        let window = ObjectIdentifier(service)
        _ = await service.importFiles([url], requester: window)
        let request = try #require(service.conversionRequest(for: window))
        let results = await service.convert(request.id, options: options)
        guard case .success(.imported(let book)) = results.first?.result else {
            Issue.record("\(url.lastPathComponent) was not imported: \(String(describing: results.first?.result))")
            throw CancellationError()
        }
        return book
    }

    @Test func markdownAndWordFilesBecomeBooks() async throws {
        let (store, service, scratch) = try makeService()
        defer {
            try? FileManager.default.removeItem(at: store.rootDirectory)
            try? FileManager.default.removeItem(at: scratch)
        }
        // Markdown.
        let markdown = scratch.appendingPathComponent("Harbour Handbook.md")
        try Data(F6Fixtures.markdown.utf8).write(to: markdown)
        let mdBook = try await importOne(markdown, service: service, options: ConversionOptions(textSize: .large))
        #expect(mdBook.sourceFormat == .markdown)
        #expect(mdBook.title == "The Harbour Handbook")
        #expect(mdBook.originalFileName == "Harbour Handbook.md")
        #expect(mdBook.converterVersion == TextDocumentConverter().version)
        let mdDirectory = store.rootDirectory.appendingPathComponent(BookStorageLayout.bookDirectory(bookID: mdBook.id))
        #expect(try Data(contentsOf: mdDirectory.appendingPathComponent("original.md")) == Data(contentsOf: markdown))
        let mdPDF = try #require(PDFDocument(url: store.rootDirectory.appendingPathComponent(
            BookStorageLayout.documentPath(bookID: mdBook.id, fileName: mdBook.fileName))))
        #expect(mdPDF.pageCount == mdBook.pageCount)
        #expect(mdPDF.findString("MDWORD-appendix", withOptions: []).count == 1)
        #expect((mdPDF.outlineRoot?.numberOfChildren ?? 0) == 2)
        #expect(FileManager.default.fileExists(atPath: service.coverURL(for: mdBook).path))
        // conversion.json keeps the text size.
        let record = try String(contentsOf: mdDirectory.appendingPathComponent("conversion.json"), encoding: .utf8)
        #expect(record.contains("large"))

        // Word.
        let docx = scratch.appendingPathComponent("Harbour Notes.docx")
        try FileManager.default.copyItem(at: F6Fixtures.fixture("f6-sample.docx"), to: docx)
        let wordBook = try await importOne(docx, service: service)
        #expect(wordBook.sourceFormat == .word)
        #expect(wordBook.title == "F6 Sample Title")
        #expect(wordBook.converterVersion == OfficeDocumentConverter().version)
        let wordPDF = try #require(PDFDocument(url: store.rootDirectory.appendingPathComponent(
            BookStorageLayout.documentPath(bookID: wordBook.id, fileName: wordBook.fileName))))
        #expect(wordPDF.pageCount == wordBook.pageCount)
        #expect(wordPDF.findString("F6WORD-closing", withOptions: []).count == 1)
        #expect(FileManager.default.fileExists(atPath: service.coverURL(for: wordBook).path))
        // Nothing is left in the staging area.
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: service.stagingRoot.path)) ?? []
        #expect(staging.isEmpty, "\(staging)")
    }

    @Test func aPresentationBecomesABook() async throws {
        let (store, service, scratch) = try makeService()
        defer {
            try? FileManager.default.removeItem(at: store.rootDirectory)
            try? FileManager.default.removeItem(at: scratch)
        }
        let pptx = scratch.appendingPathComponent("Deck.pptx")
        try FileManager.default.copyItem(at: F6Fixtures.fixture("f6-slides.pptx"), to: pptx)
        let book = try await importOne(pptx, service: service)
        #expect(book.sourceFormat == .powerPoint)
        #expect(book.pageCount == 5)
        #expect(book.title == "F6 Deck Title")
    }
}
