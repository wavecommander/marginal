import Foundation
import PDFKit

/// The reader's on-screen document (`ReaderDocumentLoader.openDocument`): a `PDFDocument` with
/// one override, a workaround for PDFKit (TSOFT-222).
///
/// When the text-selection edit menu is built, UIKit asks the selection for its range in the
/// whole document (`UITextContextMenuInteraction` → `_selectedNSRange`), and PDFKit's text-input
/// view answers it with `selection(from:atCharacterIndex:to:atCharacterIndex:)` from the start
/// of page 1 to the selection, twice per menu. PDFKit builds that selection page by page and
/// re-normalises it after every page, which grows with the square of the page number: measured
/// on the iOS 27 simulator with `large.pdf`, about 3 s per call at page 1,200 (6 s before the
/// menu appears), 0.4 s at page 600, 60 ms at page 300.
///
/// This override builds the same selection (the same text ranges on the same pages) from
/// per-page selections added in one batch. Spans of fewer than `batchThreshold` pages, and
/// anything out of range, go to PDFKit unchanged. Reading a page's character count still lays
/// out its text the first time (PDFKit does the same); nothing here walks the book otherwise.
nonisolated final class ReaderPDFDocument: PDFDocument {
    /// Spans of at least this many pages (first to last) are built in one batch.
    static let batchThreshold = 3

    override func selection(from startPage: PDFPage, atCharacterIndex startCharacter: Int,
                            to endPage: PDFPage, atCharacterIndex endCharacter: Int) -> PDFSelection? {
        batchedSelection(from: startPage, atCharacterIndex: startCharacter, to: endPage, atCharacterIndex: endCharacter)
            ?? super.selection(from: startPage, atCharacterIndex: startCharacter, to: endPage, atCharacterIndex: endCharacter)
    }

    /// The batched equivalent of PDFKit's selection (end character inclusive, as PDFKit's), or
    /// `nil` to let PDFKit build it.
    func batchedSelection(from startPage: PDFPage, atCharacterIndex startCharacter: Int,
                          to endPage: PDFPage, atCharacterIndex endCharacter: Int) -> PDFSelection? {
        let first = index(for: startPage)
        let last = index(for: endPage)
        guard first != NSNotFound, last != NSNotFound, last - first >= Self.batchThreshold,
              startCharacter >= 0, endCharacter >= 0 else { return nil }
        let startCount = startPage.numberOfCharacters
        let endCount = endPage.numberOfCharacters
        guard startCharacter < startCount, endCharacter < endCount else { return nil }
        var parts: [PDFSelection] = []
        if let head = startPage.selection(for: NSRange(location: startCharacter, length: startCount - startCharacter)) {
            parts.append(head)
        }
        for pageIndex in (first + 1)..<last {
            guard let page = page(at: pageIndex) else { continue }
            let count = page.numberOfCharacters
            if count > 0, let whole = page.selection(for: NSRange(location: 0, length: count)) {
                parts.append(whole)
            }
        }
        if let tail = endPage.selection(for: NSRange(location: 0, length: endCharacter + 1)) {
            parts.append(tail)
        }
        guard !parts.isEmpty else { return nil }
        let result = PDFSelection(document: self)
        result.add(parts)
        return result
    }
}
