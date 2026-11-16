import Foundation
import PDFKit

/// The reader's on-screen document (`ReaderDocumentLoader.openDocument`): a `PDFDocument` with
/// one override, a workaround for PDFKit (TSOFT-222; `PDFKitWorkarounds.batchedSelection`): a
/// selection that spans many pages is built in one batch instead of page by page.
nonisolated final class ReaderPDFDocument: PDFDocument {
    /// Spans of at least this many pages (first to last) are built in one batch.
    static let batchThreshold = PDFKitWorkarounds.batchedSelectionThreshold

    override func selection(from startPage: PDFPage, atCharacterIndex startCharacter: Int,
                            to endPage: PDFPage, atCharacterIndex endCharacter: Int) -> PDFSelection? {
        batchedSelection(from: startPage, atCharacterIndex: startCharacter, to: endPage, atCharacterIndex: endCharacter)
            ?? super.selection(from: startPage, atCharacterIndex: startCharacter, to: endPage, atCharacterIndex: endCharacter)
    }

    /// The batched equivalent of PDFKit's selection (end character inclusive, as PDFKit's), or
    /// `nil` to let PDFKit build it.
    func batchedSelection(from startPage: PDFPage, atCharacterIndex startCharacter: Int,
                          to endPage: PDFPage, atCharacterIndex endCharacter: Int) -> PDFSelection? {
        PDFKitWorkarounds.batchedSelection(in: self, from: startPage, atCharacterIndex: startCharacter,
                                           to: endPage, atCharacterIndex: endCharacter)
    }
}
