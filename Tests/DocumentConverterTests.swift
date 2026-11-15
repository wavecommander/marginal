import Foundation
import PDFKit
import ReaderCore
import Testing
import UIKit
@testable import Marginal

/// A converter for tests: writes a PDF of blank 6 × 9 in pages, reporting progress per page.
nonisolated struct StubDocumentConverter: DocumentConverter {
    var version = 7
    var formats: Set<ImportFormat> = [.epub]
    var pageCount = 3
    var title: String? = "Stub Title"
    var failure: ConversionError?

    func convert(_ input: ConversionInput, progress: @escaping @Sendable (Double) -> Void) async throws -> ConvertedDocument {
        if let failure { throw failure }
        try Task.checkCancellation()
        let bounds = CGRect(origin: .zero, size: ConversionOptions.reflowPageSize)
        var box = bounds
        guard let context = CGContext(input.outputURL as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.failed(reason: "could not create the PDF")
        }
        for page in 0..<pageCount {
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            context.endPDFPage()
            progress(Double(page + 1) / Double(pageCount))
        }
        context.closePDF()
        return ConvertedDocument(pdf: input.outputURL, pageCount: pageCount, title: title, coverImage: nil)
    }
}

struct DocumentConverterTests {
    private func makeInput(format: ImportFormat = .epub) throws -> ConversionInput {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConverterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("original.epub")
        try Data("not really an epub".utf8).write(to: original)
        return ConversionInput(original: original, format: format, fileName: "Book.epub", directory: directory,
                               outputFileName: "Book.pdf", options: ConversionOptions())
    }

    @Test func standardRegistryHasNoPDFConverter() {
        #expect(ConverterRegistry.standard.converter(for: .pdf) == nil)
        #expect(!ConverterRegistry.standard.convertibleFormats.contains(.pdf))
    }

    @Test func registryLooksUpByFormatAndLaterRegistrationWins() {
        var registry = ConverterRegistry([StubDocumentConverter(version: 1, formats: [.epub, .pdf, .markdown])])
        #expect(registry.convertibleFormats == [.epub, .markdown])
        #expect(registry.converter(for: .pdf) == nil)
        #expect(registry.converter(for: .word) == nil)
        #expect(registry.converter(for: .epub)?.version == 1)
        registry.register(StubDocumentConverter(version: 2, formats: [.epub]))
        #expect(registry.converter(for: .epub)?.version == 2)
        #expect(registry.converter(for: .markdown)?.version == 1)
    }

    @Test func stubWritesAReadablePDFAndLeavesTheOriginalAlone() async throws {
        let input = try makeInput()
        defer { try? FileManager.default.removeItem(at: input.directory) }
        let before = try Data(contentsOf: input.original)
        let fractions = Fractions()
        let converter = try #require(ConverterRegistry([StubDocumentConverter()]).converter(for: .epub))
        let converted = try await converter.convert(input) { fractions.append($0) }
        #expect(converted.pdf == input.outputURL)
        #expect(converted.pageCount == 3)
        #expect(converted.title == "Stub Title")
        #expect(PDFDocument(url: converted.pdf)?.pageCount == 3)
        #expect(PDFDocument(url: converted.pdf)?.page(at: 0)?.bounds(for: .mediaBox).size == ConversionOptions.reflowPageSize)
        #expect(fractions.values.last == 1)
        #expect(fractions.values == fractions.values.sorted())
        #expect(try Data(contentsOf: input.original) == before)
    }

    @Test func stubFailureIsThrownAndWritesNothing() async throws {
        let input = try makeInput()
        defer { try? FileManager.default.removeItem(at: input.directory) }
        let converter = StubDocumentConverter(failure: .protected)
        await #expect(throws: ConversionError.protected) {
            _ = try await converter.convert(input) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: input.outputURL.path))
    }

    @Test func cancelledConversionThrowsCancellation() async throws {
        let input = try makeInput()
        defer { try? FileManager.default.removeItem(at: input.directory) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StubDocumentConverter().convert(input) { _ in }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: input.outputURL.path))
    }
}

/// Collects progress fractions from any thread.
nonisolated final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}
