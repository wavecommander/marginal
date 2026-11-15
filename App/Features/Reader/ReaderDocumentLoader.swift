import Foundation
import PDFKit
import ReaderCore
import UIKit

/// Moves a non-`Sendable` value across an isolation boundary **once**, when the sender keeps no
/// reference to it (e.g. a `PDFDocument` opened on a background thread and handed to the main
/// actor, which then owns it exclusively).
nonisolated final class TransferBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Background work on PDFs. Every function opens **its own** `PDFDocument` (or takes only
/// `Sendable` values), so nothing here shares the on-screen document across threads.
nonisolated enum ReaderDocumentLoader {
    /// Opens the document off the main thread; the caller (main actor) becomes its only owner.
    /// PDFKit opens lazily: this reads the file's structure, not every page.
    @concurrent
    static func openDocument(at url: URL) async -> TransferBox<PDFDocument>? {
        guard let document = ReaderPDFDocument(url: url) else { return nil }
        return TransferBox<PDFDocument>(document)
    }

    /// Flattens the PDF outline depth-first (pre-order) from a private document instance.
    /// Visits only outline items (not pages); resolving a destination's page index is cheap.
    @concurrent
    static func outlineEntries(at url: URL) async -> [RawOutlineEntry] {
        guard let document = PDFDocument(url: url), let root = document.outlineRoot else { return [] }
        return flatten(root, in: document)
    }

    /// The flattening rule `RawOutlineEntry` asks for: every item, in pre-order, level 1 for the
    /// root's children; `pageIndex` from the destination (or a go-to action), `nil` otherwise.
    static func flatten(_ root: PDFOutline, in document: PDFDocument) -> [RawOutlineEntry] {
        var entries: [RawOutlineEntry] = []
        func visit(_ item: PDFOutline, level: Int) {
            for index in 0..<item.numberOfChildren {
                guard let child = item.child(at: index) else { continue }
                var page = child.destination?.page
                if page == nil, let action = child.action as? PDFActionGoTo {
                    page = action.destination.page
                }
                let pageIndex = page.map { document.index(for: $0) }.flatMap { $0 == NSNotFound ? nil : $0 }
                entries.append(RawOutlineEntry(title: child.label ?? "", level: level, pageIndex: pageIndex))
                visit(child, level: level + 1)
            }
        }
        visit(root, level: 1)
        return entries
    }

    /// Builds the merged outline off the main thread.
    @concurrent
    static func buildOutline(entries: [RawOutlineEntry], userHeadings: [UserHeading], pageCount: Int) async -> Outline {
        Outline(pdfEntries: entries, userHeadings: userHeadings, pageCount: pageCount)
    }

    /// Builds the Notebook tree off the main thread.
    @concurrent
    static func buildNotebook(outline: Outline, notes: [Note], highlights: [Highlight],
                              bookmarks: [Bookmark]) async -> Notebook {
        NotebookBuilder.build(outline: outline, notes: notes, highlights: highlights, bookmarks: bookmarks)
    }
}

/// Renders page thumbnails off the main thread from a **private** `PDFDocument` (never the
/// on-screen one). One per session (`ReaderSession.thumbnails`); requests are serialised.
/// Cancel the calling task to skip work that has not started (e.g. a cell scrolled away).
///
///     let image = await session.thumbnails.thumbnail(forPageAt: 41, size: CGSize(width: 120, height: 160))
actor PDFThumbnailRenderer {
    private let url: URL
    private var document: PDFDocument?

    init(url: URL) {
        self.url = url
    }

    /// A thumbnail fitting `size` (points; rendered at `scale`), or `nil` if the page does not
    /// exist or the task was cancelled before rendering started.
    func thumbnail(forPageAt pageIndex: Int, size: CGSize, scale: CGFloat = 2) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if document == nil { document = PDFDocument(url: url) }
        guard let page = document?.page(at: pageIndex) else { return nil }
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let image = page.thumbnail(of: pixelSize, for: .cropBox)
        guard let cgImage = image.cgImage else { return image }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }

    /// Releases the private document (its page cache). The next request reopens it.
    func purge() {
        document = nil
    }
}
