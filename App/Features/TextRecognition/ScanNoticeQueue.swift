import Foundation
import Observation
import ReaderCore

/// One scanned-book notice: the scanned books one import found, for one window.
struct ScanNotice: Identifiable, Equatable {
    let id: UUID
    /// The window that shows it (`ObjectIdentifier` of its `WindowContext`); `nil` until a window
    /// takes it (an `-importFixture` import, addressed by the first window with its conversion
    /// requests: `ImportService.address`).
    var windowKey: ObjectIdentifier?
    /// The books, in import order.
    var books: [ScanNoticeBook]
    /// The books have been checked against the store since the notice was queued (still not
    /// decided, still in the Library), so it may be shown (`ScanNoticeQueue.check`).
    var isChecked = false

    var title: String { ScanNoticeText.title(for: books) }
    var message: String { ScanNoticeText.message(for: books) }
}

/// The scanned-book notices waiting to be shown (S3; design, "Scanned books" ▸ "The notice").
/// One per import that found scanned books; owned by `ImportService` and shared by every window.
///
/// - **One per import, in the window that imported.** `ImportService.importFiles` posts one
///   notice for the batch's newly imported PDFs that detection found scanned, addressed to the
///   requesting window. Books converted from pictures get no notice (the Convert to PDF sheet
///   already said their pages are pictures), and a book already in the Library gets none.
/// - **When.** The Library shows it as a system alert once its window has no Convert to PDF
///   sheet or import alert up and is showing the Library (`LibraryScreen`), so it comes after
///   any sheet. "Open in" waits for the answer before opening the book
///   (`IncomingDocumentHandler`); a book imported from the Library is not opened.
/// - **Never stale.** Before it is shown, `check` drops the books that are no longer "not
///   decided" (made searchable from search meanwhile, or `-recognizeBook`) or no longer in the
///   Library, and drops the notice when none is left.
/// - **A closed window.** "Open in" drops its notice when the window it waits in closes
///   (`drop`), so the wait always ends.
/// - **Nowhere else.** Notices live in memory only: a notice not answered before the app quits
///   is not shown again (the book stays "not decided" and search makes the offer).
@Observable
@MainActor
final class ScanNoticeQueue {
    private(set) var notices: [ScanNotice] = []
    @ObservationIgnored private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init() {}

    /// Queues a notice about `books` for the window with `windowKey` (`nil`: the first window
    /// takes it). Returns its ID, or `nil` when `books` is empty.
    @discardableResult
    func post(_ books: [ScanNoticeBook], windowKey: ObjectIdentifier?) -> UUID? {
        guard !books.isEmpty else { return nil }
        let notice = ScanNotice(id: UUID(), windowKey: windowKey, books: books)
        notices.append(notice)
        return notice.id
    }

    /// The first notice addressed to the window with this key, checked or not.
    func notice(for windowKey: ObjectIdentifier) -> ScanNotice? {
        notices.first { $0.windowKey == windowKey }
    }

    /// The notice about this book, if one waits.
    func notice(about bookID: UUID) -> ScanNotice? {
        notices.first { notice in notice.books.contains { $0.id == bookID } }
    }

    /// Addresses every unaddressed notice to the window with this key (the first window takes
    /// `-importFixture`'s notices once launch work is done).
    func addressUnaddressed(to windowKey: ObjectIdentifier) {
        for index in notices.indices where notices[index].windowKey == nil {
            notices[index].windowKey = windowKey
        }
    }

    /// Re-reads the notice's books just before it is shown: keeps the ones still in the Library
    /// and still "not decided" (their titles as they are now), drops the notice when none is
    /// left, otherwise marks it checked.
    func check(_ id: UUID, store: LibraryStore) async {
        guard let books = notices.first(where: { $0.id == id })?.books else { return }
        var kept: [ScanNoticeBook] = []
        for book in books {
            guard let stored = try? store.books.book(id: book.id),
                  ((try? await store.recognitionState(bookID: book.id)) ?? nil) == .notDecided else { continue }
            kept.append(ScanNoticeBook(id: stored.id, title: stored.title, pageCount: stored.pageCount))
        }
        guard let index = notices.firstIndex(where: { $0.id == id }) else { return }
        if kept.isEmpty {
            finish(id)
        } else {
            notices[index].books = kept
            notices[index].isChecked = true
        }
    }

    /// The reader's answer. The notice leaves the queue at once (so its alert does not come
    /// back), then each of its books is accepted (Make Searchable) or declined (Not Now) through
    /// the engine, and anyone waiting for the answer (`waitUntilAnswered`) goes on. Returns that
    /// work (`nil` when the notice is not queued).
    @discardableResult
    func answer(_ id: UUID, makeSearchable: Bool, recognition: TextRecognitionEngine) -> Task<Void, Never>? {
        guard let notice = notices.first(where: { $0.id == id }) else { return nil }
        notices.removeAll { $0.id == id }
        return Task {
            for book in notice.books {
                if makeSearchable {
                    await recognition.accept(bookID: book.id)
                } else {
                    await recognition.decline(bookID: book.id)
                }
            }
            finish(id)
        }
    }

    /// Returns once the notice has been answered or dropped (at once if it is not queued).
    func waitUntilAnswered(_ id: UUID) async {
        guard notices.contains(where: { $0.id == id }) else { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    /// Drops the notice unanswered (its window closed): its books stay "not decided", so search
    /// still makes the offer, and anyone waiting for the answer goes on.
    func drop(_ id: UUID) {
        finish(id)
    }

    private func finish(_ id: UUID) {
        notices.removeAll { $0.id == id }
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }
}
