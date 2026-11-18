import Foundation
import os
import ReaderBackup
import ReaderCore
import ReaderSync

/// The sync engine's view of the library (`SyncLibrary`, called from the engine's actor), over
/// `LibrarySyncCore` on the main actor.
nonisolated final class LibrarySyncSource: SyncLibrary, @unchecked Sendable {
    let core: LibrarySyncCore

    init(core: LibrarySyncCore) {
        self.core = core
    }

    func books() async throws -> [SyncLibraryBook] { try await core.books() }
    func snapshot(bookID: UUID) async throws -> SyncLocalSnapshot? { try await core.snapshot(bookID: bookID) }
    func fileData(_ file: SyncFileKey, bookID: UUID) async throws -> Data? { try await core.fileData(file, bookID: bookID) }
    func apply(_ change: SyncLocalChange, bookID: UUID, snapshotToken: String) async throws {
        try await core.apply(change, bookID: bookID, snapshotToken: snapshotToken)
    }
    func createBook(_ book: SyncNewBook) async throws { try await core.createBook(book) }
    func deleteBook(bookID: UUID, snapshotToken: String) async throws {
        try await core.deleteBook(bookID: bookID, snapshotToken: snapshotToken)
    }
    func installPDF(bookID: UUID, from file: URL, content: ContentDigest) async throws {
        try await core.installPDF(bookID: bookID, from: file, content: content)
    }
}

/// What sync can ask of the open editors: save what is pending, and what the reader is working
/// on. `OpenEditorRegistry` in the app; tests add their own busy surfaces.
@MainActor
protocol SyncEditorProbe: AnyObject {
    func flushForSync(store: LibraryStore) async
    func syncBusySurfaces(bookID: UUID, store: LibraryStore) -> SyncBusyEditors
}

extension OpenEditorRegistry: SyncEditorProbe {}

/// Why the library refused to make a sync change (besides `SyncLibraryError`).
nonisolated enum LibrarySyncError: Error, Hashable, Sendable, LocalizedError {
    /// The book's PDF is neither on this device nor described by a hash sidecar, so which book
    /// it is in the account cannot be known.
    case pdfUnknown(bookID: UUID)
    /// The PDF downloaded for a book is not the book's PDF.
    case pdfMismatch(bookID: UUID)

    var errorDescription: String? {
        switch self {
        case .pdfUnknown: "This book’s PDF isn’t on this device, so it can’t be synced until you locate it."
        case .pdfMismatch: "The PDF from Tactile Texts Cloud isn’t this book’s PDF, so it wasn’t used."
        }
    }
}

/// The library side of sync (`docs/CLOUD_SYNC_PLAN.md` "On the iPad"), on the main actor with
/// the store. One per `LibraryStore`, shared by every account's engine.
///
/// - **Snapshot tokens.** Every change the store's hub reports moves the book's revision (the
///   observer is installed when this is made, before any snapshot, and the hub reports every
///   committed write of records and ink files). A snapshot's token is the revision when it was
///   read, read in the same main-actor pass as the records; a change that lands while the files
///   are being read moves it, so the change computed from that snapshot is refused.
/// - **Files** (page ink, note ink of the book's notes, `cover.jpg`, `conversion.json`) by
///   SHA-256, cached per file by size, modification date and file number, so a round reads only
///   what changed.
/// - **Busy surfaces**: what the open editors are working on (`SyncEditorProbe`), plus every page
///   and note whose stored ink this system cannot read in full (`InkContentSupport`), every
///   round, so the engine never pushes it and keeps its base.
/// - **Changes** are written with `LibraryChangeWriter`, the book's saves paused at
///   `BookWriteGate`: a save in flight finishes first (and, having moved the revision, makes the
///   change be computed again), and a save that would start waits and then merges over what sync
///   wrote.
@MainActor
final class LibrarySyncCore {
    let store: LibraryStore
    /// The change origin of everything sync writes (windows reload as for another window).
    let origin = ChangeOrigin(label: "sync")
    let editors: any SyncEditorProbe
    /// Tests: surfaces to report busy as well as the editors'.
    var extraBusy: (UUID) -> SyncBusyEditors = { _ in SyncBusyEditors() }
    /// Tests: runs at the start of `apply`, after the snapshot was taken (to change the book in
    /// between).
    var beforeApply: ((UUID) async -> Void)?

    private var revisions: [UUID: Int] = [:]
    private var observation: StoreChangeObservation?
    private let fileCache = SyncFileDigestCache()

    init(store: LibraryStore, editors: any SyncEditorProbe = OpenEditorRegistry.shared) {
        self.store = store
        self.editors = editors
        observation = store.hub.observe { [weak self] event in self?.record(event) }
    }

    /// The book's revision: moves on every change the hub reports for it.
    func revision(of bookID: UUID) -> Int { revisions[bookID] ?? 0 }

    private func record(_ event: StoreChangeEvent) {
        switch event.change {
        case .recognisedTextChanged, .recognitionStateChanged: return   // derived from the PDF; never synced
        default: revisions[event.change.bookID, default: 0] += 1
        }
    }

    // MARK: SyncLibrary

    /// Every book whose PDF is known by its full SHA-256 (hashing a PDF the first time, cached in
    /// its sidecar), after the open editors saved what is pending.
    func books() async throws -> [SyncLibraryBook] {
        await editors.flushForSync(store: store)
        var result: [SyncLibraryBook] = []
        for book in try store.books.allBooks() {
            try Task.checkCancellation()
            if let digest = try? await store.contentDigest(of: book) { result.append(SyncLibraryBook(bookID: book.id, pdf: digest)) }
        }
        return result
    }

    func snapshot(bookID: UUID) async throws -> SyncLocalSnapshot? {
        let token = revision(of: bookID)
        guard let archive = try store.archive(bookID: bookID) else { return nil }
        guard let pdf = try await store.contentDigest(of: archive.book) else { throw LibrarySyncError.pdfUnknown(bookID: bookID) }
        let pdfFile: URL? = store.hasDocument(archive.book) ? store.documentURL(for: archive.book) : nil
        let scan = await SyncBookFiles.scan(directory: store.bookDirectoryURL(bookID: bookID),
                                            noteIDs: Set(archive.notes.map(\.id)), cache: fileCache)
        var busy = Set<SyncSurface>()
        let editing = busyEditors(bookID)
        for page in editing.pages { busy.insert(.page(page)) }
        for note in editing.notes { busy.insert(.note(note)) }
        for note in archive.notes where editing.noteTargets.contains(note.target) { busy.insert(.note(note.id)) }
        for key in scan.unsupported {
            switch key {
            case .pageInk(let page): busy.insert(.page(page))
            case .noteInk(let id): busy.insert(.note(id))
            case .cover, .conversion: break
            }
        }
        return SyncLocalSnapshot(archive: archive, files: scan.digests, pdf: pdf, pdfFile: pdfFile, busy: busy,
                                 token: String(token))
    }

    func fileData(_ file: SyncFileKey, bookID: UUID) async throws -> Data? {
        guard try store.books.book(id: bookID) != nil else { return nil }
        return await Self.read(writer.url(of: file, bookID: bookID))
    }

    func apply(_ change: SyncLocalChange, bookID: UUID, snapshotToken: String) async throws {
        if let beforeApply { await beforeApply(bookID) }
        let pause = await BookWriteGate.shared.pause([bookID])
        defer { BookWriteGate.shared.resume(pause) }
        guard String(revision(of: bookID)) == snapshotToken else { throw SyncLibraryError.changedSinceSnapshot(bookID: bookID) }
        guard let current = try store.archive(bookID: bookID) else { throw SyncLibraryError.bookNotFound(bookID: bookID) }
        if touchesBusySurface(change, current: current, bookID: bookID) {
            throw SyncLibraryError.changedSinceSnapshot(bookID: bookID)
        }
        let writer = writer
        try writer.writeRecords(change.records, target: change.archive, current: current)
        try await writer.writeFiles(bookID: bookID, write: change.filesToWrite, remove: change.filesToRemove)
        var touched = Set(change.records.notes.added.map(\.id) + change.records.notes.changed.map(\.id))
        touched.formUnion(change.noteDecisions.map(\.noteID))
        for key in Set(change.filesToWrite.keys).union(change.filesToRemove) {
            if case .noteInk(let id) = key { touched.insert(id) }
        }
        try await writer.settleNotes(bookID: bookID, noteIDs: touched)
    }

    func createBook(_ new: SyncNewBook) async throws {
        var book = new.archive.book
        let id = book.id
        // One book per PDF: a book that took this PDF meanwhile is the account's book here; the
        // next round joins it instead.
        let taken = try store.books.book(id: id) != nil
        if taken || !LibraryPDFIndex.bookIDs(withSidecarSHA256: new.pdf.sha256, in: store).isEmpty {
            throw SyncLibraryError.changedSinceSnapshot(bookID: id)
        }
        // The file name is this device's to choose (sync carries no file names of its own): the
        // account's, made safe.
        var fileName = ImportPipeline.documentFileName(ImportPipeline.sanitizedFileName(book.fileName))
        if fileName.isEmpty || fileName.hasPrefix(".") { fileName = "book.pdf" }
        book.fileName = fileName
        book.pageCount = max(book.pageCount, new.info.pageCount)
        let directory = store.bookDirectoryURL(bookID: id)
        try await Self.prepareDirectory(directory, sidecar: new.pdf)
        // The files, then the records: a crash before the book record leaves only a directory,
        // which the launch sweep removes.
        let writer = writer
        try await writer.writeFiles(bookID: id, write: new.files.filter { if case .noteInk = $0.key { false } else { true } },
                                    remove: [])
        try store.perform(as: origin) { try store.books.save(book) }
        try writer.writeRecords(BookArchiveDiff(from: BookArchive(book: book), to: new.archive), target: new.archive,
                                current: BookArchive(book: book))
        let noteInk = new.files.filter { if case .noteInk = $0.key { true } else { false } }
        try await writer.writeFiles(bookID: id, write: noteInk, remove: [])
        try await writer.settleNotes(bookID: id, noteIDs: Set(new.archive.notes.map(\.id)))
    }

    func deleteBook(bookID: UUID, snapshotToken: String) async throws {
        let pause = await BookWriteGate.shared.pause([bookID])
        defer { BookWriteGate.shared.resume(pause) }
        guard String(revision(of: bookID)) == snapshotToken, busyEditors(bookID).isEmpty else {
            throw SyncLibraryError.changedSinceSnapshot(bookID: bookID)
        }
        do {
            try await store.deleteBook(id: bookID, origin: origin)
        } catch LibraryStoreError.bookFilesNotRemoved {
            // The book is gone; the launch sweep removes what is left of its directory.
        }
        BookDeletion.removeWindowPreferences(bookID: bookID)
    }

    func installPDF(bookID: UUID, from file: URL, content: ContentDigest) async throws {
        guard let book = try store.books.book(id: bookID) else { throw SyncLibraryError.bookNotFound(bookID: bookID) }
        if store.hasDocument(book) { return }
        if let sidecar = store.storedContentDigest(bookID: bookID), sidecar != content {
            throw LibrarySyncError.pdfMismatch(bookID: bookID)
        }
        let staging = store.rootDirectory.appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged: DocumentLinking.Staged
        do {
            staged = try await DocumentLinking.stage(source: file, directory: staging, fileName: book.fileName,
                                                     fingerprint: book.isConverted ? nil : book.fingerprint,
                                                     expected: content, bookTitle: book.title, size: content.size,
                                                     progress: { _ in })
        } catch ImportError.pdfMismatch {
            throw LibrarySyncError.pdfMismatch(bookID: bookID)
        }
        // On the main actor with no suspension point: the book as it is now.
        guard let current = try store.books.book(id: bookID) else { throw SyncLibraryError.bookNotFound(bookID: bookID) }
        let destination = store.documentURL(for: current)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.createDirectory(at: store.bookDirectoryURL(bookID: bookID), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staged.pdf, to: destination)
        let cover = store.url(forRelativePath: ImportService.coverRelativePath(bookID: bookID))
        if let stagedCover = staged.cover, !FileManager.default.fileExists(atPath: cover.path) {
            try? FileManager.default.moveItem(at: stagedCover, to: cover)
        }
        CoverCache.shared.remove(at: cover)
        if store.storedContentDigest(bookID: bookID) == nil {
            try? DocumentDigest.writeSidecar(staged.digest, to: store.contentHashURL(bookID: bookID))
        }
        store.hub.post(.bookSaved(bookID: bookID), origin: origin)
    }

    // MARK: Helpers

    var writer: LibraryChangeWriter { LibraryChangeWriter(store: store, origin: origin) }

    private func busyEditors(_ bookID: UUID) -> SyncBusyEditors {
        var busy = editors.syncBusySurfaces(bookID: bookID, store: store)
        busy.formUnion(extraBusy(bookID))
        return busy
    }

    /// Whether the change writes a page, note or note target the reader is working on now.
    private func touchesBusySurface(_ change: SyncLocalChange, current: BookArchive, bookID: UUID) -> Bool {
        let busy = busyEditors(bookID)
        guard !busy.isEmpty else { return false }
        var pages = Set<Int>(), notes = Set<UUID>(), targets = Set<NoteTarget>()
        for key in Set(change.filesToWrite.keys).union(change.filesToRemove) {
            switch key {
            case .pageInk(let page): pages.insert(page)
            case .noteInk(let id): notes.insert(id)
            case .cover, .conversion: break
            }
        }
        let currentNotes = Dictionary(current.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for note in change.records.notes.added + change.records.notes.changed {
            notes.insert(note.id)
            targets.insert(note.target)
            if let old = currentNotes[note.id] { targets.insert(old.target) }
        }
        for id in change.records.notes.removed {
            notes.insert(id)
            if let old = currentNotes[id] { targets.insert(old.target) }
        }
        return !pages.isDisjoint(with: busy.pages) || !notes.isDisjoint(with: busy.notes)
            || !targets.isDisjoint(with: busy.noteTargets)
    }

    @concurrent
    nonisolated private static func read(_ url: URL) async -> Data? {
        try? Data(contentsOf: url)
    }

    @concurrent
    nonisolated private static func prepareDirectory(_ directory: URL, sidecar: ContentDigest) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DocumentDigest.writeSidecar(sidecar, to: directory.appendingPathComponent(BookStorageLayout.contentHashFileName))
    }
}

/// Per-device preferences of a book that go when the book goes (as the Library's Delete does).
@MainActor
enum BookDeletion {
    static func removeWindowPreferences(bookID: UUID) {
        ReaderScrollDirectionStore().removeDirection(for: bookID)
        ReaderNotesPanelStore().removeValue(for: bookID)
        ReaderPositionStore().removePosition(for: bookID)
    }
}

// MARK: - Files by content

/// A book's synced files by SHA-256, read off the main actor.
nonisolated enum SyncBookFiles {
    struct Scan: Sendable {
        var digests: SyncFileDigests = [:]
        /// Ink this system cannot read in full (`InkContentSupport`).
        var unsupported: Set<SyncFileKey> = []
    }

    @concurrent
    static func scan(directory: URL, noteIDs: Set<UUID>, cache: SyncFileDigestCache) async -> Scan {
        var scan = Scan()
        let manager = FileManager.default
        func add(_ key: SyncFileKey, _ url: URL) {
            guard let entry = cache.entry(for: url, key: key) else { return }
            scan.digests[key] = entry.digest
            if !entry.supported { scan.unsupported.insert(key) }
        }
        let ink = directory.appendingPathComponent("ink", isDirectory: true)
        for name in (try? manager.contentsOfDirectory(atPath: ink.path)) ?? [] {
            guard let page = BookStorageLayout.pageIndex(fromPageInkFileName: name) else { continue }
            add(.pageInk(page), ink.appendingPathComponent(name))
        }
        let notes = directory.appendingPathComponent("notes", isDirectory: true)
        for name in (try? manager.contentsOfDirectory(atPath: notes.path)) ?? [] {
            guard name.hasSuffix(".drawing"), let id = UUID(uuidString: String(name.dropLast(".drawing".count))),
                  noteIDs.contains(id) else { continue }
            add(.noteInk(id), notes.appendingPathComponent(name))
        }
        add(.cover, directory.appendingPathComponent(ImportPipeline.coverFileName))
        add(.conversion, directory.appendingPathComponent(ImportPipeline.conversionRecordFileName))
        return scan
    }
}

/// Digests (and the content-version verdict) of files, kept while a file's size, modification
/// date and file number are unchanged (an atomic write replaces all three).
nonisolated final class SyncFileDigestCache: Sendable {
    struct Entry: Sendable {
        var digest: ContentDigest
        var supported: Bool
    }

    private struct Stamp: Hashable, Sendable {
        var size: Int
        var modified: Date
        var fileNumber: Int
    }

    private let entries = OSAllocatedUnfairLock<[String: (Stamp, Entry)]>(initialState: [:])

    /// The file's entry, `nil` when it is not a readable regular file.
    func entry(for url: URL, key: SyncFileKey) -> Entry? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
        let number = (values.fileResourceIdentifier as? NSObject)?.hash ?? 0
        let stamp = Stamp(size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast, fileNumber: number)
        if let cached = entries.withLock({ $0[url.path] }), cached.0 == stamp { return cached.1 }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let supported: Bool = switch key {
        case .pageInk: InkContentSupport.isSupported(pageInk: data)
        case .noteInk: InkContentSupport.isSupported(noteInk: data)
        case .cover, .conversion: true
        }
        let entry = Entry(digest: ContentDigest(sha256: ContentHash.sha256(of: data), size: Int64(data.count)), supported: supported)
        entries.withLock { $0[url.path] = (stamp, entry) }
        return entry
    }
}
