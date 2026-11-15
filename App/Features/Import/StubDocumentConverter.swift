#if DEBUG
import CoreGraphics
import Foundation
import ReaderCore

/// A converter for tests (DEBUG builds only): writes a PDF of blank 6 × 9 in pages, reporting
/// progress per page. Unit tests use it directly; UI tests get it for every convertible format
/// with the `-stubConverters` launch argument (`ConverterRegistry.withStubConverters`), so the
/// import flow can be exercised before the real converters exist.
nonisolated struct StubDocumentConverter: DocumentConverter {
    var version = 7
    var formats: Set<ImportFormat> = [.epub]
    var pageCount = 3
    var title: String? = "Stub Title"
    var failure: ConversionError?
    /// Pause after each page, so a test can watch progress or cancel mid-conversion.
    var pageDelay: Duration = .zero

    func convert(_ input: ConversionInput, progress: @escaping @Sendable (Double) -> Void) async throws -> ConvertedDocument {
        if let failure { throw failure }
        try Task.checkCancellation()
        let bounds = CGRect(origin: .zero, size: ConversionOptions.reflowPageSize)
        var box = bounds
        guard let context = CGContext(input.outputURL as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.failed(reason: "could not create the PDF")
        }
        do {
            for page in 0..<pageCount {
                try Task.checkCancellation()
                context.beginPDFPage(nil)
                context.endPDFPage()
                progress(Double(page + 1) / Double(pageCount))
                if pageDelay > .zero { try await Task.sleep(for: pageDelay) }
            }
        } catch {
            context.closePDF()
            try? FileManager.default.removeItem(at: input.outputURL)
            throw error
        }
        context.closePDF()
        return ConvertedDocument(pdf: input.outputURL, pageCount: pageCount, title: title, coverImage: nil)
    }
}

extension ConverterRegistry {
    /// `standard` with `StubDocumentConverter` registered for every format that is converted
    /// (`-stubConverters`). `-stubConverterPageDelay <ms>` slows it down.
    static func withStubConverters(pageDelay: Duration = .zero) -> ConverterRegistry {
        var registry = ConverterRegistry.standard
        registry.register(StubDocumentConverter(formats: Set(ImportFormat.allCases.filter(\.isConverted)),
                                                pageDelay: pageDelay))
        return registry
    }
}
#endif
