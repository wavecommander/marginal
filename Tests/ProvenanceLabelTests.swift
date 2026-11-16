import ReaderCore
import Testing
@testable import TactileTexts

/// "Converted from …" (F7): one sentence per converted format, nothing for a PDF.
@MainActor
struct ProvenanceLabelTests {
    private func book(_ format: ImportFormat?, original: String? = nil) -> Book {
        Book(title: "T", fingerprint: "f", fileName: "book.pdf", pageCount: 3, fileSize: 1,
             sourceFormat: format, originalFileName: original, converterVersion: format == nil ? nil : 1)
    }

    @Test func everyConvertedFormatHasItsOwnLabel() {
        let converted = ImportFormat.allCases.filter(\.isConverted)
        let labels = converted.compactMap(\.convertedFromLabel)
        #expect(labels.count == converted.count)
        #expect(Set(labels).count == labels.count, "each format has its own sentence")
        #expect(labels.allSatisfy { $0.hasPrefix("Converted from ") })
        #expect(ImportFormat.epub.convertedFromLabel == "Converted from EPUB")
        #expect(ImportFormat.comicArchive.convertedFromLabel == "Converted from a comic archive")
    }

    @Test func aPDFHasNoLabel() {
        #expect(ImportFormat.pdf.convertedFromLabel == nil)
        #expect(book(nil).convertedFromLabel == nil, "imported as a PDF")
        #expect(book(.pdf).convertedFromLabel == nil)
    }

    @Test func aConvertedBookHasItsFormatsLabel() {
        #expect(book(.epub, original: "Middlemarch.epub").convertedFromLabel == "Converted from EPUB")
        #expect(book(.image).convertedFromLabel == "Converted from an image")
    }
}
