import Foundation
import OSLog
import PencilKit
import ReaderCore
import UIKit

let pageInkLog = Logger(subsystem: "software.tactile.texts", category: "PageInk")

/// One stored state of a page's ink: the data as stored (`nil`: no file) and its drawing.
nonisolated struct PageInkVersion: Sendable {
    var data: Data?
    var drawing: PKDrawing

    static let empty = PageInkVersion(data: nil, drawing: PKDrawing())
}

/// What a page needs to read and write its ink: the shared store, the book, the window's
/// change origin, and the window's save token (`ReaderSession.saveToken`): once the window has
/// seen its book deleted or replaced by a restore, no save of this context lands.
struct PageInkContext {
    let store: LibraryStore
    let bookID: UUID
    let origin: ChangeOrigin?
    var saveToken: BookSaveToken? = nil
}

/// Serialises every read and write of one page's ink **across all windows** (process-wide,
/// keyed by book and page), so a load never reads half of a save, a save never overwrites a
/// write it has not merged, and two windows' saves of the same page cannot interleave. Work for
/// different pages runs independently. Main actor; the actual file I/O runs in the store's
/// ink actor and encoding/decoding on a background executor, so nothing here blocks drawing.
@MainActor
final class PageInkQueue {
    static let shared = PageInkQueue()

    private struct Key: Hashable {
        let bookID: UUID
        let pageIndex: Int
    }

    private var tails: [Key: (id: Int, task: Task<Void, Never>)] = [:]
    private var nextID = 0

    /// Queues `operation` after every earlier operation on the same page, **now** (so a
    /// `drain` that follows sees it), and returns the task running it. The operation runs even
    /// if nobody awaits the task.
    @discardableResult
    func enqueue<T: Sendable>(bookID: UUID, pageIndex: Int, _ operation: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let key = Key(bookID: bookID, pageIndex: pageIndex)
        let previous = tails[key]?.task
        nextID += 1
        let id = nextID
        let task = Task { @MainActor () -> T in
            await previous?.value
            let value = await operation()
            if self.tails[key]?.id == id { self.tails[key] = nil }
            return value
        }
        tails[key] = (id, Task { @MainActor in _ = await task.value })
        return task
    }

    /// `enqueue` and wait for the result.
    @discardableResult
    func run<T: Sendable>(bookID: UUID, pageIndex: Int, _ operation: @escaping @MainActor () async -> T) async -> T {
        await enqueue(bookID: bookID, pageIndex: pageIndex, operation).value
    }

    /// Waits until no operation of `bookID` is queued or running.
    func drain(bookID: UUID) async {
        while let tail = tails.first(where: { $0.key.bookID == bookID })?.value.task {
            await tail.value
        }
    }

    /// Number of pages of `bookID` with queued or running operations (tests, diagnostics).
    func busyPageCount(bookID: UUID) -> Int {
        tails.keys.count { $0.bookID == bookID }
    }
}

/// Reads and writes page ink through `LibraryStore`. Call these only inside
/// `PageInkQueue.run` for the page.
enum PageInkPersistence {
    enum LoadResult: Sendable {
        case loaded(PageInkVersion)
        /// The stored data is not a drawing this system can read (written by a newer system):
        /// shown as nothing, never overwritten.
        case unreadable
        case failed(String)
    }

    enum WriteOutcome: Sendable {
        /// Stored (or already stored): `stored` is the state now in the store, whose drawing is
        /// the merge of the local drawing with any change another window stored meanwhile.
        case stored(PageInkVersion)
        /// Not written: the store holds data this system cannot read, or the book is gone.
        case skipped
        case failed(String)
    }

    /// Reads the page's ink.
    static func load(_ context: PageInkContext, pageIndex: Int) async -> LoadResult {
        do {
            guard let data = try await context.store.pageInk(bookID: context.bookID, pageIndex: pageIndex) else {
                return .loaded(.empty)
            }
            guard let drawing = await decode(data) else { return .unreadable }
            return .loaded(PageInkVersion(data: data, drawing: drawing))
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Writes `local`, first merging any change stored since `base` (`PageInkMerge`). An empty
    /// result deletes the page's file (an empty drawing is never stored). Runs through
    /// `BookWriteGate` (a restore's commit never overlaps it) and does nothing once the
    /// context's save token is revoked (`.skipped`).
    static func write(_ context: PageInkContext, pageIndex: Int, local: PKDrawing, base: PageInkVersion) async
        -> WriteOutcome {
        guard context.saveToken?.isRevoked != true else { return .skipped }
        let outcome = await BookWriteGate.shared.performSave(bookID: context.bookID, token: context.saveToken) {
            await writeNow(context, pageIndex: pageIndex, local: local, base: base)
        }
        return outcome ?? .skipped
    }

    private static func writeNow(_ context: PageInkContext, pageIndex: Int, local: PKDrawing, base: PageInkVersion) async
        -> WriteOutcome {
        let store = context.store
        // A book deleted meanwhile (by any window) must not get its ink directory back.
        guard (try? store.books.book(id: context.bookID)) != nil else { return .skipped }
        let backgroundTask = BackgroundTaskAssertion(name: "Save page ink")
        defer { backgroundTask.end() }
        do {
            let current = try await store.pageInk(bookID: context.bookID, pageIndex: pageIndex)
            var result = local
            if current != base.data {
                // Another window stored this page since `base`: merge, never drop its strokes.
                var remote = PKDrawing()
                if let current {
                    guard let decoded = await decode(current) else { return .skipped }
                    remote = decoded
                }
                result = PageInkMerge.merge(local: local, remote: remote, base: base.drawing)
            }
            if result.strokes.isEmpty {
                if current != nil {
                    try await store.deletePageInk(bookID: context.bookID, pageIndex: pageIndex, origin: context.origin)
                }
                return .stored(PageInkVersion(data: nil, drawing: result))
            }
            let data = await encode(result)
            if data != current {
                try await store.savePageInk(data, bookID: context.bookID, pageIndex: pageIndex, origin: context.origin)
            }
            return .stored(PageInkVersion(data: data, drawing: result))
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Reads what is stored now (for reconciling with another window's change).
    static func read(_ context: PageInkContext, pageIndex: Int) async -> Data?? {
        do {
            return .some(try await context.store.pageInk(bookID: context.bookID, pageIndex: pageIndex))
        } catch {
            return nil
        }
    }

    /// Decodes off the main actor; `nil` when unreadable, including a drawing this system
    /// cannot show in full (`InkContentSupport`: ink from a newer system), which is therefore
    /// shown as nothing and never written over here.
    nonisolated static func decode(_ data: Data) async -> PKDrawing? {
        await Task.detached(priority: .userInitiated) { () -> PKDrawing? in
            guard let drawing = try? PKDrawing(data: data), !InkContentSupport.needsNewerSystem(pageInk: data) else { return nil }
            return drawing
        }.value
    }

    /// Encodes off the main actor.
    nonisolated static func encode(_ drawing: PKDrawing) async -> Data {
        await Task.detached(priority: .userInitiated) { drawing.dataRepresentation() }.value
    }
}

/// Keeps the app running in the background until a save finishes (the app may be suspended
/// right after a window closes or the app backgrounds).
@MainActor
final class BackgroundTaskAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
