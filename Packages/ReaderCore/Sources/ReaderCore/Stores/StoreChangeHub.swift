import Foundation

/// One change to stored data, posted on `StoreChangeHub` after it has been committed.
///
/// Every case names the book it concerns (`bookID`), and is fine-grained enough for a window to
/// decide cheaply whether to reload anything. A change says *what* changed, never the new value:
/// the receiver re-reads through `LibraryStore`. Changes are posted only for mutations that
/// succeeded, and only when something may actually have changed (see each case).
public enum StoreChange: Hashable, Sendable {
    /// A book was inserted or its metadata changed (title, last-read page, last opened…).
    /// Library windows refresh their list; reader windows on that book may refresh their title.
    case bookSaved(bookID: UUID)
    /// The book and all of its records (notes, highlights, bookmarks, user headings) are gone.
    /// No separate changes are posted for the cascaded records. When posted by
    /// `LibraryStore.deleteBook(id:origin:)` the book's files have been removed too (or the call
    /// threw `LibraryStoreError.bookFilesNotRemoved`). Windows showing the book close.
    case bookDeleted(bookID: UUID)
    /// The note `noteID` now exists at `target` with new content (inserted, edited, or moved
    /// here by `retarget`).
    case noteSaved(bookID: UUID, target: NoteTarget, noteID: UUID)
    /// The note `noteID` no longer exists at `target`: it was deleted, saved empty (which deletes
    /// it), or moved away by `retarget` (in which case a `noteSaved` for its new target follows).
    case noteRemoved(bookID: UUID, target: NoteTarget, noteID: UUID)
    /// Highlights on this page were added, changed (recolour) or deleted.
    case highlightsChanged(bookID: UUID, pageIndex: Int)
    /// This page was bookmarked or un-bookmarked.
    case bookmarksChanged(bookID: UUID, pageIndex: Int)
    /// The book's user headings changed (added, renamed, moved or deleted): rebuild the outline.
    case userHeadingsChanged(bookID: UUID)
    /// The page's ink file was written or deleted: reload that page's canvas (unless mid-stroke).
    case pageInkChanged(bookID: UUID, pageIndex: Int)
    /// The note's ink file was written or deleted: reload that note's ink (unless mid-stroke).
    case noteInkChanged(bookID: UUID, noteID: UUID)
    /// A scanned book's page was recognised and saved (`pageIndex`), or all of the book's
    /// recognised text was removed (`nil`): a running search can read the page now.
    case recognisedTextChanged(bookID: UUID, pageIndex: Int?)
    /// A scanned book's `RecognitionState` was written or removed: windows showing the search
    /// status re-read it.
    case recognitionStateChanged(bookID: UUID)

    /// The book the change concerns.
    public var bookID: UUID {
        switch self {
        case .bookSaved(let id), .bookDeleted(let id), .userHeadingsChanged(let id): id
        case .noteSaved(let id, _, _), .noteRemoved(let id, _, _): id
        case .highlightsChanged(let id, _), .bookmarksChanged(let id, _), .pageInkChanged(let id, _): id
        case .noteInkChanged(let id, _): id
        case .recognisedTextChanged(let id, _), .recognitionStateChanged(let id): id
        }
    }

    /// The PDF page the change is about (highlights, bookmarks, page ink, page notes and a
    /// recognised page), or `nil` for changes not tied to one page.
    public var pageIndex: Int? {
        switch self {
        case .highlightsChanged(_, let page), .bookmarksChanged(_, let page), .pageInkChanged(_, let page): page
        case .noteSaved(_, let target, _), .noteRemoved(_, let target, _): target.pageIndex
        case .recognisedTextChanged(_, let page): page
        default: nil
        }
    }

    /// Whether the change can alter what a backup holds. `false` for recognised text and the
    /// recognition state, which are derived from the PDF and never backed up, so they should
    /// not make an automatic backup due.
    public var affectsBackup: Bool {
        switch self {
        case .recognisedTextChanged, .recognitionStateChanged: false
        default: true
        }
    }
}

/// Identifies who made a change: one value per window's session (or per other actor of change,
/// such as an importer). Equal only to itself; creating one is cheap (a UUID).
public struct ChangeOrigin: Hashable, Sendable, CustomStringConvertible {
    /// Unique identity of this origin.
    public let id: UUID
    /// Optional label for debugging (e.g. "reader window 2"); not part of equality.
    public let label: String?

    /// Makes a new, unique origin.
    public init(label: String? = nil) {
        id = UUID()
        self.label = label
    }

    public static func == (lhs: ChangeOrigin, rhs: ChangeOrigin) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public var description: String { label.map { "\($0) (\(id.uuidString))" } ?? id.uuidString }
}

/// A posted change and who made it.
public struct StoreChangeEvent: Hashable, Sendable {
    /// What changed.
    public let change: StoreChange
    /// Who made it; `nil` when the mutation was not attributed (made outside
    /// `LibraryStore.perform(as:_:)`, or by a background job).
    public let origin: ChangeOrigin?

    /// Pairs a change with its origin (the hub makes these; public for tests and fakes).
    public init(change: StoreChange, origin: ChangeOrigin?) {
        self.change = change
        self.origin = origin
    }

    /// `true` when `origin` is non-nil and equal to the given origin: the receiving session made
    /// this change itself and normally ignores it.
    public func isFrom(_ origin: ChangeOrigin) -> Bool { self.origin == origin }
}

/// An active subscription to a `StoreChangeHub`. Delivery stops when `cancel()` is called or when
/// the last reference to this object goes away, whichever is first. The token owns the handler,
/// so dropping the token also releases everything the handler captured; the hub keeps only a
/// weak reference.
@MainActor
public final class StoreChangeObservation {
    fileprivate var handler: (@MainActor (StoreChangeEvent) -> Void)?

    fileprivate init(handler: @escaping @MainActor (StoreChangeEvent) -> Void) {
        self.handler = handler
    }

    /// `false` once cancelled.
    public var isActive: Bool { handler != nil }

    /// Stops delivery immediately, also when called from inside a handler during delivery (no
    /// further event, including the one being delivered if this observer has not received it
    /// yet, reaches it). Releases the handler. Idempotent.
    public func cancel() { handler = nil }
}

/// The in-process change signal shared by every window. One per `LibraryStore`.
///
/// **Delivery rules**
/// - Everything runs on the main actor. `post` delivers to closure observers synchronously, in
///   registration order, then yields to every `events()` stream.
/// - Re-entrancy: a `post` made while an event is being delivered (from a handler) is queued and
///   delivered after the current event has reached every observer, so all observers see events
///   in the same order; such a nested `post` returns before its event is delivered. Handlers may
///   cancel any observation, or add new ones, during delivery: a cancelled observer receives
///   nothing further; an observer added during delivery receives only later events.
/// - The hub never retains observers' handlers beyond their `StoreChangeObservation` token.
/// - When the hub is deallocated, every `events()` stream finishes.
@MainActor
public final class StoreChangeHub {
    private final class WeakObservation {
        weak var value: StoreChangeObservation?
        init(_ value: StoreChangeObservation) { self.value = value }
    }

    private var observers: [WeakObservation] = []
    private var continuations: [Int: AsyncStream<StoreChangeEvent>.Continuation] = [:]
    private var nextStreamID = 0
    private var queue: [StoreChangeEvent] = []
    private var isDelivering = false

    /// Makes a hub with no observers.
    public init() {}

    deinit {
        for continuation in continuations.values { continuation.finish() }
    }

    /// Posts one change. See the delivery rules on the type.
    public func post(_ change: StoreChange, origin: ChangeOrigin?) {
        post([change], origin: origin)
    }

    /// Posts several changes in order, as separate events with the same origin.
    public func post(_ changes: [StoreChange], origin: ChangeOrigin?) {
        queue.append(contentsOf: changes.map { StoreChangeEvent(change: $0, origin: origin) })
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        while !queue.isEmpty {
            let event = queue.removeFirst()
            let snapshot = observers
            for box in snapshot {
                // Re-read the handler each time: an earlier handler may have cancelled this one.
                box.value?.handler?(event)
            }
            observers.removeAll { $0.value?.isActive != true }
            for continuation in continuations.values { continuation.yield(event) }
        }
    }

    /// Registers a handler for every later event. Keep the returned token for as long as you want
    /// events; it is the only strong reference to `handler`.
    public func observe(_ handler: @escaping @MainActor (StoreChangeEvent) -> Void) -> StoreChangeObservation {
        let observation = StoreChangeObservation(handler: handler)
        observers.removeAll { $0.value?.isActive != true }
        observers.append(WeakObservation(observation))
        return observation
    }

    /// An async sequence of every event posted after this call. The stream finishes when the hub
    /// is deallocated. It is unregistered when the consuming task is cancelled, or when the
    /// consumer has stopped iterating and no reference to the stream remains (so iterate it in
    /// the task that owns it, e.g. `.task { for await e in hub.events() { … } }`). Events are
    /// buffered per `bufferingPolicy` while the consumer is busy.
    public func events(bufferingPolicy: AsyncStream<StoreChangeEvent>.Continuation.BufferingPolicy = .unbounded)
        -> AsyncStream<StoreChangeEvent> {
        let id = nextStreamID
        nextStreamID += 1
        let (stream, continuation) = AsyncStream<StoreChangeEvent>.makeStream(bufferingPolicy: bufferingPolicy)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    /// Number of live closure observers (for tests and diagnostics).
    public var observerCount: Int { observers.count { $0.value?.isActive == true } }
    /// Number of registered `events()` streams (for tests and diagnostics).
    public var streamCount: Int { continuations.count }
}
