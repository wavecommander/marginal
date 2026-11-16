#if DEBUG
import CoreGraphics
import Foundation
import ReaderCore

/// DEBUG-only seeding for the scanned-page highlight UI tests (S4).
///
/// `-seedScannedHighlight`: when a reader opens a book with at least 17 pages and no highlights,
/// once per process, it stores a yellow **Live Text** highlight on page 17 over the first body
/// line of `scanned.pdf` ("The quiet heron measures tidewater.", page space (72, 693, 159 × 12),
/// as PDFKit's own Live Text selection reports it; docs/SCANNED_BOOKS_FINDINGS.md), exactly as
/// `HighlightEditing` would have stored it from a selection.
///
/// Read from the process arguments here rather than `LaunchOptions`, so the seed stays inside
/// the highlights feature.
@MainActor
enum ScannedHighlightDebugSeed {
    static let argument = "-seedScannedHighlight"
    static let pageIndex = 16
    static let rect = CGRect(x: 72, y: 693, width: 159, height: 12)
    static let text = "The quiet heron measures tidewater."

    private static var seeded = Set<UUID>()

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func seedIfRequested(store: LibraryStore, book: Book) {
        guard isRequested, !seeded.contains(book.id), book.pageCount > pageIndex else { return }
        seeded.insert(book.id)
        guard ((try? store.highlights.highlights(bookID: book.id)) ?? []).isEmpty else { return }
        do {
            try store.highlights.save(Highlight(bookID: book.id, pageIndex: pageIndex, rects: [rect], color: .yellow,
                                                text: text, createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                                textSource: .liveText))
        } catch {
            print("ScannedHighlightDebugSeed: \(error)")
        }
    }
}
#endif
