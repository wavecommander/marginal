import Foundation
import os
import PDFKit
import ReaderCore

/// The recognition queue's worker thread: one serial GCD queue at `.utility` QoS (below the
/// reader's interactive work and the search worker's `.userInitiated`), which owns the one
/// **private** `PDFDocument` recognition reads and does one page at a time.
///
/// Memory: a `PDFDocument` keeps every page it has handed out, with the page's decoded image,
/// until it is released (as the search worker found for text). The worker therefore reopens its
/// document every `pagesPerDocument` pages, wraps each page in an autorelease pool, and lets the
/// engine release the document whenever the queue goes idle. One page's bitmap (about 3.7 MB at
/// 200 dpi for a Letter page, at most `PageImageRenderer.maximumPixels`) exists at a time.
///
/// No PDFKit object leaves the queue; only `Sendable` values do.
nonisolated final class TextRecognitionWorker: @unchecked Sendable {
    // `@unchecked`: every mutable property is touched only on `queue`.

    /// What reading one page found.
    enum PageOutcome: Sendable {
        /// The page was recognised (possibly with no words: a blank or picture-only page).
        case recognised(RecognisedPage)
        /// The page has text of its own in the file; it is not recognised.
        case hasOwnText
        /// The page could not be read (file, render or recogniser failure).
        case failed(String)
    }

    /// The pages of a book that need no recognition (text of their own), found once per job.
    struct Survey: Sendable {
        var pageCount: Int
        var pagesWithOwnText: Set<Int>
    }

    /// Pages read through one document before it is released and the file reopened.
    static let pagesPerDocument = 8

    private let queue = DispatchQueue(label: "software.tactile.marginal.text-recognition", qos: .utility)
    private let recognizer: any PageRecognizing
    private let dpi: CGFloat
    private var document: PDFDocument?
    private var documentURL: URL?
    private var pagesFromDocument = 0

    /// Live private documents of every worker (tests: none is left once the queue is idle).
    static let liveDocuments = OSAllocatedUnfairLock(initialState: 0)

    init(recognizer: any PageRecognizing, dpi: CGFloat = PageImageRenderer.defaultDPI) {
        self.recognizer = recognizer
        self.dpi = dpi
    }

    deinit {
        if document != nil { Self.liveDocuments.withLock { $0 -= 1 } }
    }

    // MARK: Jobs (each runs on the queue)

    /// The book's page count and the pages (other than `skipping`) with text of their own, or
    /// `nil` when the file cannot be opened.
    func survey(url: URL, skipping: Set<Int>) async -> Survey? {
        await onQueue { worker in
            guard let count = worker.pageCount(url: url) else { return nil }
            var own: Set<Int> = []
            for index in 0..<count where !skipping.contains(index) {
                let hasText: Bool = autoreleasepool {
                    guard let page = worker.page(url: url, index: index, budget: PDFTextSearch.pagesPerDocument) else { return false }
                    return PageTextPolicy.hasOwnText(page)
                }
                if hasText { own.insert(index) }
            }
            return Survey(pageCount: count, pagesWithOwnText: own)
        }
    }

    /// Reads one page: skipped when it has text of its own, otherwise rendered and recognised.
    func recognise(url: URL, pageIndex: Int) async -> PageOutcome {
        await onQueue { worker in
            autoreleasepool {
                guard let page = worker.page(url: url, index: pageIndex, budget: Self.pagesPerDocument) else {
                    return .failed("page \(pageIndex) could not be opened")
                }
                if PageTextPolicy.hasOwnText(page) { return .hasOwnText }
                guard let rendered = PageImageRenderer.render(page, dpi: worker.dpi) else {
                    return .failed("page \(pageIndex) could not be rendered")
                }
                do {
                    let lines = try worker.recognizer.recognise(rendered.image)
                    return .recognised(PageImageRenderer.recognisedPage(pageIndex: pageIndex, lines: lines, box: rendered.box))
                } catch {
                    return .failed("page \(pageIndex): \(error)")
                }
            }
        }
    }

    /// Releases the private document (the queue is going idle or the app is being suspended).
    func releaseDocument() async {
        await onQueue { worker in worker.close() }
    }

    // MARK: Queue-confined

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable (TextRecognitionWorker) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body(self)) }
        }
    }

    private func pageCount(url: URL) -> Int? {
        if document == nil || documentURL != url { reopen(url) }
        return document?.pageCount
    }

    private func page(url: URL, index: Int, budget: Int) -> PDFPage? {
        if document == nil || documentURL != url || pagesFromDocument >= budget { reopen(url) }
        guard let document, index >= 0, index < document.pageCount else { return nil }
        pagesFromDocument += 1
        return document.page(at: index)
    }

    private func reopen(_ url: URL) {
        close()
        autoreleasepool { document = PDFDocument(url: url) }
        if document != nil {
            documentURL = url
            Self.liveDocuments.withLock { $0 += 1 }
        }
    }

    private func close() {
        pagesFromDocument = 0
        documentURL = nil
        guard document != nil else { return }
        document = nil
        Self.liveDocuments.withLock { $0 -= 1 }
    }
}
