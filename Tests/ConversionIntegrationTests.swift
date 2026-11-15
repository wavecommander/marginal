import Foundation
import PDFKit
import ReaderCore
import ReaderStore
import Testing
@testable import Marginal

/// The import flow with the app's real converters (`ConverterRegistry.standard`), end to end.
@MainActor
struct ConversionIntegrationTests {
    private func makeService() throws -> (LibraryStore, ImportService, URL) {
        let store = try LibraryStore.ephemeral()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("IntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return (store, ImportService(store: store), scratch)
    }

    @Test func aComicArchiveBecomesABookThroughTheSheet() async throws {
        let (store, service, scratch) = try makeService()
        defer {
            try? FileManager.default.removeItem(at: store.rootDirectory)
            try? FileManager.default.removeItem(at: scratch)
        }
        let cbz = scratch.appendingPathComponent("Tiny Comic.cbz")
        let colours: [ImagesFixtures.RGB] = [.init(r: 200, g: 30, b: 30), .init(r: 30, g: 200, b: 30), .init(r: 30, g: 30, b: 200)]
        // Written out of order: page10 must come after page2.
        try ImagesZIPWriter.write([
            ("page10.jpg", ImagesFixtures.jpeg(ImagesFixtures.solid(width: 300, height: 400, color: colours[2]))),
            ("page1.jpg", ImagesFixtures.jpeg(ImagesFixtures.solid(width: 300, height: 400, color: colours[0]))),
            ("ComicInfo.xml", Data("<ComicInfo/>".utf8)),
            ("page2.png", ImagesFixtures.png(ImagesFixtures.solid(width: 400, height: 300, color: colours[1]))),
        ], to: cbz)

        let window = ObjectIdentifier(service)
        let queued = await service.importFiles([cbz], requester: window)
        let request = try #require(service.conversionRequest(for: window))
        #expect(queued.first?.conversionRequestID == request.id)
        #expect(request.groups == [.comicsAndImages])
        #expect(!request.offersTextSizeChoice)
        #expect(try store.books.allBooks().isEmpty)

        let results = await service.convert(request.id, options: ConversionOptions())
        guard case .success(.imported(let book)) = results.first?.result else {
            Issue.record("the comic was not imported: \(String(describing: results.first?.result))"); return
        }
        #expect(book.title == "Tiny Comic")
        #expect(book.sourceFormat == .comicArchive)
        #expect(book.originalFileName == "Tiny Comic.cbz")
        #expect(book.converterVersion == ImagesConverter().version)
        #expect(book.pageCount == 3)

        let directory = store.rootDirectory.appendingPathComponent(BookStorageLayout.bookDirectory(bookID: book.id))
        let pdfURL = store.rootDirectory.appendingPathComponent(BookStorageLayout.documentPath(bookID: book.id, fileName: book.fileName))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("original.cbz").path))
        #expect(try Data(contentsOf: directory.appendingPathComponent("original.cbz")) == Data(contentsOf: cbz))
        #expect(FileManager.default.fileExists(atPath: service.coverURL(for: book).path))

        let pdf = try #require(PDFDocument(url: pdfURL))
        #expect(pdf.pageCount == 3)
        for index in 0..<3 {
            let page = try #require(pdf.page(at: index))
            // Ink is stored in crop-box space: the box must start at the origin, unrotated.
            #expect(page.bounds(for: .cropBox).origin == .zero)
            #expect(page.rotation == 0)
            let centre = ImagesPDFInspector.colours(in: pdfURL, page: index, at: [CGPoint(x: 0.5, y: 0.5)])
            #expect(ImagesPDFInspector.nearest(centre[0], in: colours) == colours[index])
        }
        // The same file again is the same book: no second sheet.
        let again = await service.importFiles([cbz], requester: window)
        #expect(service.conversionRequest(for: window) == nil)
        if case .success(.existing(let existing)) = again.first?.result { #expect(existing.id == book.id) }
        else { Issue.record("a second import did not find the existing book") }
    }
}
