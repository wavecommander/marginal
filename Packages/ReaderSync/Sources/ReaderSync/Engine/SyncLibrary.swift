import Foundation
import ReaderBackup
import ReaderCore

// The seams between the sync engine and the app: the local library (`SyncLibrary`) and the ink
// merge (`SyncInkMerger`). The app implements both (C4) over `LibraryStore` and PencilKit; the
// tests implement them in memory.

/// One file beside a book that sync carries, besides the PDF.
public enum SyncFileKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// `ink/<page>.drawing`
    case pageInk(Int)
    /// `notes/<note ID>.drawing`
    case noteInk(UUID)
    /// `cover.jpg`
    case cover
    /// `conversion.json`
    case conversion

    public var description: String {
        switch self {
        case .pageInk(let page): "page ink \(page)"
        case .noteInk(let id): "note ink \(id.uuidString)"
        case .cover: "cover"
        case .conversion: "conversion"
        }
    }

    private var order: (Int, Int, String) {
        switch self {
        case .pageInk(let page): (0, page, "")
        case .noteInk(let id): (1, 0, id.uuidString)
        case .cover: (2, 0, "")
        case .conversion: (3, 0, "")
        }
    }

    public static func < (a: SyncFileKey, b: SyncFileKey) -> Bool { a.order < b.order }
}

/// A book's files by their content: what is there, by SHA-256 and size. A file that is not
/// there has no entry (an empty drawing is no file).
public typealias SyncFileDigests = [SyncFileKey: ContentDigest]

extension SyncBaseFiles {
    /// The same files as a dictionary.
    public var digests: SyncFileDigests {
        var result: SyncFileDigests = [:]
        for ref in pageInk { result[.pageInk(ref.pageIndex)] = ref.content }
        for ref in noteInk { result[.noteInk(ref.noteID)] = ref.content }
        result[.cover] = cover
        result[.conversion] = conversion
        return result
    }

    /// The files of a dictionary, page ink ascending by page and note ink by note ID.
    public init(digests: SyncFileDigests) {
        var pages: [SyncPageInkReference] = [], notes: [SyncNoteInkReference] = []
        for (key, content) in digests.sorted(by: { $0.key < $1.key }) {
            switch key {
            case .pageInk(let page): pages.append(SyncPageInkReference(pageIndex: page, content: content))
            case .noteInk(let id): notes.append(SyncNoteInkReference(noteID: id, content: content))
            case .cover, .conversion: break
            }
        }
        self.init(pageInk: pages, noteInk: notes, cover: digests[.cover], conversion: digests[.conversion])
    }
}

extension SyncReferences {
    /// Every file the head names but the records and the PDF.
    public var fileDigests: SyncFileDigests { SyncBaseFiles(self).digests }
}

/// A place in a book where the reader is working right now, which a round leaves alone.
public enum SyncSurface: Hashable, Sendable {
    /// A page with a stroke in progress: its page ink.
    case page(Int)
    /// A note being edited (text or ink): its record and its ink.
    case note(UUID)
}

/// A book the library offers to sync.
public struct SyncLibraryBook: Hashable, Sendable {
    public var bookID: UUID
    /// The PDF's SHA-256 and size, from which the book's sync key is made.
    public var pdf: ContentDigest

    public init(bookID: UUID, pdf: ContentDigest) {
        self.bookID = bookID
        self.pdf = pdf
    }
}

/// One book as it is on this device at one moment.
public struct SyncLocalSnapshot: Sendable {
    /// The records, keyed to the book.
    public var archive: BookArchive
    /// Every file beside the book that sync carries, by content.
    public var files: SyncFileDigests
    /// The PDF's SHA-256 and size.
    public var pdf: ContentDigest
    /// The PDF on disk, or `nil` when it is absent (not yet downloaded, say).
    public var pdfFile: URL?
    /// What the reader is working on now: the round leaves these alone and takes them up next time.
    public var busy: Set<SyncSurface>
    /// Opaque: whatever lets the library tell, when a change is applied, that the book has not
    /// changed since this snapshot (a revision counter, say).
    public var token: String

    public init(archive: BookArchive, files: SyncFileDigests, pdf: ContentDigest, pdfFile: URL?,
                busy: Set<SyncSurface> = [], token: String) {
        self.archive = archive
        self.files = files
        self.pdf = pdf
        self.pdfFile = pdfFile
        self.busy = busy
        self.token = token
    }
}

/// What a round changes in one book on this device.
public struct SyncLocalChange: Sendable {
    /// The book as it is to be: the records, title and reading position.
    public var archive: BookArchive
    /// The records to insert, update and delete, one by one (from the snapshot to `archive`).
    public var records: BookArchiveDiff
    /// Reader-made headings absorbed into another (old ID to the kept one), for open windows.
    public var headingIDRemap: [UUID: UUID]
    /// The decisions of the notes whose record or ink this change touches (for a note marked
    /// `needsBandLayout`, the app lays the text out and stores the layout with the ink).
    public var noteDecisions: [NoteSyncDecision]
    /// Files to write, with their complete new content.
    public var filesToWrite: [SyncFileKey: Data]
    /// Files to remove.
    public var filesToRemove: Set<SyncFileKey>

    public init(archive: BookArchive, records: BookArchiveDiff, headingIDRemap: [UUID: UUID],
                noteDecisions: [NoteSyncDecision], filesToWrite: [SyncFileKey: Data], filesToRemove: Set<SyncFileKey>) {
        self.archive = archive
        self.records = records
        self.headingIDRemap = headingIDRemap
        self.noteDecisions = noteDecisions
        self.filesToWrite = filesToWrite
        self.filesToRemove = filesToRemove
    }

    /// `true` when it changes nothing.
    public var isEmpty: Bool { records.isEmpty && filesToWrite.isEmpty && filesToRemove.isEmpty }
}

/// A book that exists only in the account, to be made on this device without its PDF.
public struct SyncNewBook: Sendable {
    /// The records, keyed to `archive.book.id`, the ID the new book is to have.
    public var archive: BookArchive
    /// What the head says about the book (page count, format, file names).
    public var info: SyncBookInfo
    /// The PDF the book is to have once it is downloaded.
    public var pdf: ContentDigest
    /// Its files, with their content.
    public var files: [SyncFileKey: Data]

    public init(archive: BookArchive, info: SyncBookInfo, pdf: ContentDigest, files: [SyncFileKey: Data]) {
        self.archive = archive
        self.info = info
        self.pdf = pdf
        self.files = files
    }
}

/// What a library reports when it refuses a change.
public enum SyncLibraryError: Error, Hashable, Sendable {
    /// The book changed (or a surface the change touches became busy) since the snapshot the
    /// change was computed from. Nothing was changed; the engine computes the book again.
    case changedSinceSnapshot(bookID: UUID)
    /// There is no such book.
    case bookNotFound(bookID: UUID)
}

/// The local library as sync sees it. The app implements it over `LibraryStore` (C4).
///
/// Contract:
/// - `apply`, `deleteBook`: refuse with `SyncLibraryError.changedSinceSnapshot`, changing
///   nothing, when the book changed since the snapshot whose `token` is given, or when a surface
///   the change touches (for `deleteBook`, any surface of the book) is busy now. The engine never
///   asks to change a surface the snapshot reported busy; this guards one that became busy since. Otherwise they make the whole change, writing record by
///   record and file by file through the store with sync's change origin so open windows reload
///   (a crash part-way is allowed: the engine's intent record recovers from it).
/// - `createBook`: makes the book with `archive.book.id`, its records and files, PDF absent.
/// - `fileData` returns the file's current content, or `nil` when there is none.
/// - Every call may throw its own errors (a full disk); the engine reports them for the book.
public protocol SyncLibrary: Sendable {
    /// The books that take part in sync (every book with a PDF fingerprint), with their PDF digest.
    func books() async throws -> [SyncLibraryBook]
    /// The book as it is now, or `nil` when it is gone.
    func snapshot(bookID: UUID) async throws -> SyncLocalSnapshot?
    /// The content of one of the book's files now, or `nil` when there is none.
    func fileData(_ file: SyncFileKey, bookID: UUID) async throws -> Data?
    /// Applies a round's change to the book, if it has not changed since the snapshot.
    func apply(_ change: SyncLocalChange, bookID: UUID, snapshotToken: String) async throws
    /// Makes a book that exists only in the account (without its PDF).
    func createBook(_ book: SyncNewBook) async throws
    /// Deletes the book (deleted on another device), if it has not changed since the snapshot.
    func deleteBook(bookID: UUID, snapshotToken: String) async throws
    /// Puts a downloaded PDF in place for the book.
    func installPDF(bookID: UUID, from file: URL, content: ContentDigest) async throws
}

/// What a three-way ink merge starts from when there is no common ancestor in hand.
public enum SyncInkBase: Hashable, Sendable {
    /// No base: merge as a union (a join, or the base ink could no longer be fetched).
    case unavailable
    /// The base had no ink here: everything on either side was added.
    case none
    /// The base ink.
    case ink(Data)
}

/// The notes behind a note ink merge, as each archive has them: the app lays out the merged text
/// to anchor the merged ink, and each side's text (and `bandLayout`, the fallback for ink data
/// without its own layout) to read that side's ink as the editor would.
public struct SyncInkNotes: Hashable, Sendable {
    /// The merged note (its text is what the merged ink is anchored to).
    public var merged: Note
    /// The note of `decision.local`, `decision.remote` and `decision.base`, when there is one.
    public var local: Note?
    public var remote: Note?
    public var base: Note?
    /// The note of each of `decision.absorbed`, in order.
    public var absorbed: [Note?]

    public init(merged: Note, local: Note?, remote: Note?, base: Note?, absorbed: [Note?] = []) {
        self.merged = merged
        self.local = local
        self.remote = remote
        self.base = base
        self.absorbed = absorbed
    }
}

/// One ink merge the engine asks for.
public struct SyncInkMergeRequest: Sendable {
    public enum Kind: Hashable, Sendable {
        /// A page's ink, by page index.
        case page(Int)
        /// A note's ink: the decision names the notes that contribute and maps each one's
        /// paragraphs to the merged note's (`NoteSyncDecision`).
        case note(NoteSyncDecision)
    }

    public var kind: Kind
    /// This device's ink (for a note: of `decision.local`'s note), `nil` for none.
    public var local: Data?
    /// The account's ink (for a note: of `decision.remote`'s note), `nil` for none.
    public var remote: Data?
    /// The common ancestor (for a note: of `decision.base`'s note).
    public var base: SyncInkBase
    /// For a note: the ink of each of `decision.absorbed`, in order, added as a union.
    public var absorbed: [Data?]
    /// For a note: the notes the inks belong to (`nil` for a page).
    public var notes: SyncInkNotes?

    public init(kind: Kind, local: Data?, remote: Data?, base: SyncInkBase, absorbed: [Data?] = [],
                notes: SyncInkNotes? = nil) {
        self.kind = kind
        self.local = local
        self.remote = remote
        self.base = base
        self.absorbed = absorbed
        self.notes = notes
    }
}

/// Merges two versions of a drawing. The app backs it with `StrokeMerge` (PencilKit): a stroke
/// added on either side is kept, one erased on one side is removed if the other left it
/// unchanged, with no base the union; for a note, each side's strokes are first moved to the
/// merged text by the decision's paragraph maps.
public protocol SyncInkMerger: Sendable {
    /// The merged drawing, or `nil` when it has no strokes (no file).
    func merge(_ request: SyncInkMergeRequest) async throws -> Data?
}
