import Foundation
import PDFKit
import ReaderCore
import Testing
import UIKit
@testable import Marginal

// `StubDocumentConverter` lives in the app target (App/Features/Import/StubDocumentConverter.swift,
// DEBUG only) so UI tests can register it with `-stubConverters`.

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
