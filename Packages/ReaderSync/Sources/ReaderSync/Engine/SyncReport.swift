import Foundation
import ReaderCore

/// How a round may use the account.
public enum SyncMode: Hashable, Sendable {
    /// Pull and push.
    case full
    /// Pull only (a lapsed subscription, or over the allowance): nothing is written to the
    /// account; local changes wait and are pushed when a full round runs.
    case pullOnly
}

/// What a device joining an account has and finds (`SyncEngine.joinPreview()`).
public struct SyncJoinPreview: Hashable, Sendable {
    /// Books on this iPad that the account does not have.
    public var onlyHere: Int
    /// Books in the account that this iPad does not have.
    public var onlyInAccount: Int
    /// Books on both (the same PDF), which are merged add-only.
    public var inBoth: Int

    public init(onlyHere: Int, onlyInAccount: Int, inBoth: Int) {
        self.onlyHere = onlyHere
        self.onlyInAccount = onlyInAccount
        self.inBoth = inBoth
    }
}

/// Why a round stopped for the whole account.
public enum SyncEngineError: Error, Hashable, Sendable, LocalizedError {
    /// This device has never synced with the account: show `joinPreview()` and run the round
    /// again with `joinConfirmed: true`. Nothing was changed.
    case joinConfirmationRequired
    /// A head is in a newer format than this app reads: sync for the account stops until the app
    /// is updated. Nothing was changed.
    case formatTooNew(formatVersion: Int)
    /// Another round of this engine is running.
    case roundInProgress

    public var errorDescription: String? {
        switch self {
        case .joinConfirmationRequired: "Confirm how the books on this device join your synced library."
        case .formatTooNew: SyncError.newerFormatVersion(0).errorDescription
        case .roundInProgress: "Sync is already running."
        }
    }
}

/// What a round did with one book.
public enum SyncBookAction: Hashable, Sendable {
    /// Nothing to do: this device and the account agree.
    case unchanged
    /// The account's changes were applied here; nothing was pushed.
    case pulled
    /// This device's changes were pushed; nothing changed here.
    case pushed
    /// Both: changes merged, applied here and pushed.
    case merged
    /// First merge of a book this device had no base for (add-only).
    case joined
    /// A book only this device had is now in the account.
    case uploadedNew
    /// A book only the account had was made here (its PDF not yet downloaded).
    case createdHere
    /// Deleted on another device, so deleted here.
    case deletedHere
    /// Deleted here, so marked deleted in the account.
    case deletedInAccount
    /// Deleted on another device, but edited here since: the edit won and the book was pushed back.
    case keptOverDeletionInAccount
    /// Deleted here, but edited in the account since: the edit won and the book was made here again.
    case restoredHere
}

/// Why part or all of a book waits for a later round.
public enum SyncSkipReason: Hashable, Sendable {
    /// The reader is working on these: their changes go in a later round.
    case busy([SyncSurface])
    /// A newer app wrote the book: it is pulled but not pushed until this app is updated.
    case readOnly(requiredLevel: Int)
    /// The round is pull-only: this device's changes wait.
    case pullOnly
    /// Another book on this iPad has the same PDF; only the first one syncs.
    case duplicatePDF(of: UUID)
}

/// A failure for one book; the round went on with the others.
public struct SyncBookFailure: Hashable, Sendable {
    /// The `SyncError` or `SyncLibraryError`, when it was one.
    public var syncError: SyncError?
    public var libraryError: SyncLibraryError?
    /// What to show or log (never key material).
    public var description: String

    public init(_ error: any Error) {
        syncError = error as? SyncError
        libraryError = error as? SyncLibraryError
        description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// One book's part in a round.
public struct SyncBookReport: Hashable, Sendable {
    /// The book's sync key.
    public var bookKey: String
    /// The book on this device, when there is one.
    public var bookID: UUID?
    public var action: SyncBookAction
    /// What waits for a later round.
    public var skipped: [SyncSkipReason]
    public var failure: SyncBookFailure?

    public init(bookKey: String, bookID: UUID?, action: SyncBookAction = .unchanged, skipped: [SyncSkipReason] = [],
                failure: SyncBookFailure? = nil) {
        self.bookKey = bookKey
        self.bookID = bookID
        self.action = action
        self.skipped = skipped
        self.failure = failure
    }

    /// Whether something about the book still waits (skipped work or a failure).
    public var isPending: Bool { !skipped.isEmpty || failure != nil }
}

/// What a round did, for the status line.
public struct SyncReport: Hashable, Sendable {
    public var mode: SyncMode
    /// Every book the round looked at closely, by sync key (books skipped as up to date are
    /// counted, not listed).
    public var books: [SyncBookReport]
    /// Books found up to date without reading anything.
    public var upToDate: Int

    public init(mode: SyncMode, books: [SyncBookReport] = [], upToDate: Int = 0) {
        self.mode = mode
        self.books = books
        self.upToDate = upToDate
    }

    /// How many books ended with each action.
    public func count(_ action: SyncBookAction) -> Int { books.filter { $0.action == action }.count }

    /// Books that failed this round.
    public var failures: [SyncBookReport] { books.filter { $0.failure != nil } }

    /// Whether anything still waits: skipped surfaces, local changes held back by pull-only or
    /// read-only, or a failure. The status line says "up to date" only when this is `false`.
    public var isPending: Bool { books.contains(where: \.isPending) }

    /// Whether the round changed anything here or in the account.
    public var changedAnything: Bool { books.contains { $0.action != .unchanged } }
}

/// The points between a round's steps (for tests that interrupt a round, and for logging).
public enum SyncStep: Hashable, Sendable {
    case roundStarted
    /// Blobs (and a new book's PDF) uploaded for the book; its head not yet written.
    case uploadedContent(bookKey: String)
    /// The intent record is on disk; the head not yet written.
    case wroteIntent(bookKey: String)
    /// The head write won (the superseded head went to history before it); nothing applied
    /// here yet.
    case wroteHead(bookKey: String)
    /// Right after `wroteHead` (kept as its own step since C5 writes history first).
    case wroteHistory(bookKey: String)
    /// The change is applied here; the base has not moved.
    case appliedLocally(bookKey: String)
    /// The base moved; the intent record is not yet removed.
    case movedBase(bookKey: String)
    /// A book was made, deleted or marked deleted; its base not yet changed.
    case changedBook(bookKey: String)
}
