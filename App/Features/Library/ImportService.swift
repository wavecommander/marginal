import Foundation
import Observation
import ReaderCore

/// One import in progress, observable by every Library window.
@Observable
@MainActor
final class ImportJob: Identifiable {
    enum Phase: Equatable {
        case waiting, checking, copying, finishing
    }

    nonisolated let id = UUID()
    let fileName: String
    private(set) var phase = Phase.waiting
    /// Fraction of the copy done, `0...1`.
    private(set) var fraction = 0.0
    private(set) var isCancelled = false
    @ObservationIgnored fileprivate var task: Task<ImportResult, Never>?

    init(fileName: String) { self.fileName = fileName }

    /// Cancels the import: the copy stops at the next chunk and the partial files are removed.
    func cancel() {
        isCancelled = true
        task?.cancel()
    }

    fileprivate func set(phase: Phase) { self.phase = phase }
    fileprivate func set(fraction: Double) { self.fraction = max(self.fraction, min(1, fraction)) }
}

/// What a successful import resolved to.
enum ImportOutcome: Equatable, Sendable {
    /// A new book was created.
    case imported(Book)
    /// The file's fingerprint matched a book already in the Library; nothing was copied.
    case existing(Book)

    var book: Book {
        switch self {
        case .imported(let book), .existing(let book): book
        }
    }
}

/// The result of importing one file.
struct ImportResult: Sendable {
    var fileName: String
    var result: Result<ImportOutcome, ImportError>

    var book: Book? { try? result.get().book }
    var error: ImportError? {
        if case .failure(let error) = result { error } else { nil }
    }
}

/// A failure waiting to be shown as an alert in the window that asked for the import.
struct ImportFailureAlert: Identifiable, Equatable {
    let id = UUID()
    let windowKey: ObjectIdentifier
    let error: ImportError
}

/// The import pipeline: one per app, shared by every window (it lives in `FixtureImporter`,
/// which `AppEnvironment` owns). Sources are the Files picker, drops, "Open in" and
/// `-importFixture`; all go through `importFiles`.
///
/// Per file:
/// 1. **Probe** (off the main thread): size, `%PDF-` header, `BookFingerprint`. If a book with
///    that fingerprint exists the import ends here, returning `.existing`: nothing is copied,
///    unless that book lacks its PDF (restored without it), which the file then becomes after
///    its full SHA-256 is checked against the book's `document.sha256` (`restoreMissingDocument`;
///    a mismatch fails with `ImportError.pdfMismatch`). `linkPDF(at:to:)` is the same for one
///    named book ("Locate PDF…").
/// 2. **Stage** (off the main thread): stream the file into `Imports/<newBookID>/<fileName>` under
///    the store's root (not under `Books/`, so the launch-time orphan sweep never sees it),
///    check it opens and has pages and is not locked, render the cover to `cover.jpg` beside it.
/// 3. **Commit** (main actor, no suspension point): re-check the fingerprint, rename the staging
///    directory to `Books/<newBookID>` and save the `Book` (posting `.bookSaved`, so every Library
///    window updates). A crash before this leaves only `Imports/` debris, removed at next launch;
///    a crash after it leaves a complete book.
///
/// Cancelling or failing removes the staging directory. Callers that run while the launch sweep
/// may still be in progress must await `AppEnvironment.readyImportService()` first (the sweep
/// snapshots the book list, so a directory committed between its snapshot and its scan would be
/// removed).
@Observable
@MainActor
final class ImportService {
    /// Imports in flight or waiting, oldest first. Observed by the Library screens.
    private(set) var jobs: [ImportJob] = []
    /// Failures to show; a screen shows the first one addressed to its window.
    private(set) var failures: [ImportFailureAlert] = []

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let origin = ChangeOrigin(label: "import")
    @ObservationIgnored private var staleCleanup: Task<Void, Never>?

    /// `Imports/` under the store's root: staging area and drop landing area.
    var stagingRoot: URL { store.rootDirectory.appendingPathComponent("Imports", isDirectory: true) }

    init(store: LibraryStore) {
        self.store = store
        let root = store.rootDirectory.appendingPathComponent("Imports", isDirectory: true)
        let startedAt = Date()
        // Staging left by a previous run (a crash mid-import). Anything created from now on is
        // newer than `startedAt` and is kept.
        staleCleanup = Task { await ImportPipeline.removeStale(in: root, before: startedAt) }
    }

    // MARK: Public API

    /// Imports one file; the convenience form for launch arguments and tests. Throws the
    /// `ImportError` (or `CancellationError` when cancelled).
    @discardableResult
    func importPDF(at url: URL, consumeSource: Bool = false) async throws -> ImportOutcome {
        let results = await importFiles([url], consumeSources: consumeSource)
        switch results[0].result {
        case .success(let outcome): return outcome
        case .failure(.cancelled): throw CancellationError()
        case .failure(let error): throw error
        }
    }

    /// Imports the files one after another (so copies do not fight over the disk). A job per
    /// file appears in `jobs` immediately. Never throws; each file's result is returned in order.
    /// - Parameter consumeSources: the files are temporary copies (drop landing area, the app's
    ///   `Inbox`): move them instead of copying, and delete them afterwards.
    func importFiles(_ urls: [URL], consumeSources: Bool = false) async -> [ImportResult] {
        let entries = urls.map { url in (url: url, job: ImportJob(fileName: url.lastPathComponent)) }
        jobs.append(contentsOf: entries.map(\.job))
        var results: [ImportResult] = []
        for (url, job) in entries {
            let task = Task { await self.run(url: url, job: job, consume: consumeSources) }
            job.task = task
            if job.isCancelled { task.cancel() }
            results.append(await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() })
            jobs.removeAll { $0.id == job.id }
        }
        return results
    }

    /// Queues `failures` for the window identified by `windowKey` (any stable per-window object).
    func present(_ errors: [ImportError], in windowKey: ObjectIdentifier) {
        for error in errors where error != .cancelled {
            failures.append(ImportFailureAlert(windowKey: windowKey, error: error))
        }
    }

    /// The failure the window with this key should show now, if any.
    func failure(for windowKey: ObjectIdentifier) -> ImportFailureAlert? {
        failures.first { $0.windowKey == windowKey }
    }

    func dismissFailure(_ id: UUID) {
        failures.removeAll { $0.id == id }
    }

    // MARK: Cover paths

    /// `Books/<id>/cover.jpg`, relative to the store's root.
    nonisolated static func coverRelativePath(bookID: UUID) -> String {
        "\(BookStorageLayout.bookDirectory(bookID: bookID))/\(ImportPipeline.coverFileName)"
    }

    func coverURL(for book: Book) -> URL {
        store.url(forRelativePath: Self.coverRelativePath(bookID: book.id))
    }

    // MARK: One file

    private func run(url: URL, job: ImportJob, consume: Bool) async -> ImportResult {
        let name = job.fileName
        await staleCleanup?.value
        // `defer` cannot await, and the source is only a temporary copy when `consume` is set.
        let result: Result<ImportOutcome, ImportError>
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            result = .success(try await importOne(url: url, job: job, consume: consume))
        } catch let error as ImportError {
            result = .failure(error)
        } catch is CancellationError {
            result = .failure(.cancelled)
        } catch {
            result = .failure(.unreadable(fileName: name, reason: error.localizedDescription))
        }
        if scoped { url.stopAccessingSecurityScopedResource() }
        if consume {
            let folder = url.deletingLastPathComponent()
            await ImportPipeline.remove(folder.lastPathComponent.hasPrefix("drop-") ? folder : url)
        }
        return ImportResult(fileName: name, result: result)
    }

    private func importOne(url: URL, job: ImportJob, consume: Bool) async throws -> ImportOutcome {
        let name = job.fileName
        let fileName = ImportPipeline.sanitizedFileName(name)
        job.set(phase: .checking)
        let probe = try await ImportPipeline.probe(url, fileName: name)
        if let existing = try storeBook(fingerprint: probe.fingerprint) {
            // Same content as a book in the Library: link it when that book lacks its PDF
            // (verified against the book's full hash; a mismatch is refused).
            try await restoreMissingDocument(of: existing, from: url, size: probe.size, job: job)
            return .existing(existing)
        }

        let bookID = UUID()
        let staging = stagingRoot.appendingPathComponent(bookID.uuidString, isDirectory: true)
        job.set(phase: .copying)
        do {
            let staged = try await ImportPipeline.stage(
                source: url, directory: staging, fileName: fileName, consume: consume, size: probe.size,
                progress: { fraction in Task { @MainActor in job.set(fraction: fraction) } })
            try Task.checkCancellation()
            job.set(phase: .finishing)
            return try commit(bookID: bookID, staging: staging, fileName: fileName, title: Self.title(forFileName: name),
                              probe: probe, staged: staged)
        } catch {
            await ImportPipeline.remove(staging)
            throw error
        }
    }

    /// The commit step. No suspension point between the fingerprint check, the rename and the
    /// save.
    private func commit(bookID: UUID, staging: URL, fileName: String, title: String, probe: ImportPipeline.Probe,
                        staged: ImportPipeline.Staged) throws -> ImportOutcome {
        if let existing = try storeBook(fingerprint: probe.fingerprint) {
            try? FileManager.default.removeItem(at: staging)  // a concurrent import of the same file won
            return .existing(existing)
        }
        let fileManager = FileManager.default
        let destination = store.bookDirectoryURL(bookID: bookID)
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            throw ImportError.storage(fileName: fileName, reason: error.localizedDescription)
        }
        let book = Book(id: bookID, title: title, fingerprint: probe.fingerprint, fileName: fileName,
                        pageCount: staged.pageCount, fileSize: staged.fileSize)
        do {
            try store.perform(as: origin) { try store.books.save(book) }
        } catch {
            try? fileManager.removeItem(at: destination)
            throw ImportError.storage(fileName: fileName, reason: String(describing: error))
        }
        return .imported(book)
    }

    private func storeBook(fingerprint: String) throws -> Book? {
        do {
            return try store.books.book(fingerprint: fingerprint)
        } catch {
            throw ImportError.storage(fileName: "", reason: String(describing: error))
        }
    }

    private func storeBook(id: UUID) throws -> Book? {
        do {
            return try store.books.book(id: id)
        } catch {
            throw ImportError.storage(fileName: "", reason: String(describing: error))
        }
    }

    // MARK: Linking a PDF to a book that lacks it

    /// "Locate PDF…" on one book (a book restored without its PDF, or whose PDF went missing):
    /// links the file at `url` to `book`, accepting only the PDF the book's notes were made on,
    /// that is a file with the book's sampled fingerprint **and**, when the book has a
    /// `document.sha256` sidecar, its full SHA-256. Anything else throws
    /// `ImportError.pdfMismatch` naming the book; the file is never imported as another book and
    /// there is no override. Shown as a job in `jobs` like an import.
    /// - Returns: the book (unchanged record; its PDF is now on disk).
    @discardableResult
    func linkPDF(at url: URL, to book: Book) async throws -> Book {
        let job = ImportJob(fileName: url.lastPathComponent)
        jobs.append(job)
        defer { jobs.removeAll { $0.id == job.id } }
        let task = Task { await self.runLink(url: url, bookID: book.id, job: job) }
        job.task = task
        if job.isCancelled { task.cancel() }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        switch result.result {
        case .success(let outcome): return outcome.book
        case .failure(.cancelled): throw CancellationError()
        case .failure(let error): throw error
        }
    }

    private func runLink(url: URL, bookID: UUID, job: ImportJob) async -> ImportResult {
        let name = job.fileName
        await staleCleanup?.value
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            job.set(phase: .checking)
            let probe = try await ImportPipeline.probe(url, fileName: name)
            guard let book = try storeBook(id: bookID) else {
                throw ImportError.storage(fileName: name, reason: "the book is no longer in the Library")
            }
            guard probe.fingerprint == book.fingerprint else { throw ImportError.pdfMismatch(bookTitle: book.title) }
            if store.hasDocument(book) {
                // Already linked: still only "accept" the very same file.
                let mine = try await store.contentDigest(of: book)
                let theirs = try await DocumentLinking.digest(of: url)
                guard mine == theirs else { throw ImportError.pdfMismatch(bookTitle: book.title) }
                return ImportResult(fileName: name, result: .success(.existing(book)))
            }
            job.set(phase: .copying)
            try await restoreMissingDocument(of: book, from: url, size: probe.size, job: job)
            return ImportResult(fileName: name, result: .success(.existing(book)))
        } catch let error as ImportError {
            return ImportResult(fileName: name, result: .failure(error))
        } catch is CancellationError {
            return ImportResult(fileName: name, result: .failure(.cancelled))
        } catch {
            return ImportResult(fileName: name, result: .failure(.unreadable(fileName: name, reason: error.localizedDescription)))
        }
    }

    /// Links `source` to `book` when the book's PDF is missing (no-op when it is present). Used
    /// by every import whose fingerprint matches an existing book, and by `linkPDF`.
    ///
    /// Stages a copy into `Imports/link-<uuid>/` (never into the book's directory), verifying
    /// the full SHA-256 against the book's sidecar when it has one, the fingerprint, and that the
    /// copy opens; renders a cover. Then, on the main actor with no suspension point: re-checks
    /// the book and its sidecar, moves the PDF into the book's directory, the cover too if the
    /// book has none (and drops the cached cover image), writes the sidecar if absent, and posts
    /// `.bookSaved` so every window refreshes. A wrong file throws `ImportError.pdfMismatch` and
    /// leaves nothing in the book's directory.
    private func restoreMissingDocument(of book: Book, from source: URL, size: Int64? = nil, job: ImportJob? = nil) async throws {
        guard !store.hasDocument(book) else { return }
        let expected = store.storedContentDigest(bookID: book.id)
        let staging = stagingRoot.appendingPathComponent("link-\(UUID().uuidString)", isDirectory: true)
        do {
            let staged = try await DocumentLinking.stage(
                source: source, directory: staging, fileName: book.fileName, fingerprint: book.fingerprint,
                expected: expected, bookTitle: book.title, size: size ?? book.fileSize,
                progress: { fraction in Task { @MainActor in job?.set(fraction: fraction) } })
            try Task.checkCancellation()
            job?.set(phase: .finishing)
            try commitLink(bookID: book.id, staged: staged)
        } catch {
            await ImportPipeline.remove(staging)
            throw error
        }
        await ImportPipeline.remove(staging)
    }

    /// The link's commit. No suspension point between the checks and the moves.
    private func commitLink(bookID: UUID, staged: DocumentLinking.Staged) throws {
        guard let book = try storeBook(id: bookID) else {
            throw ImportError.storage(fileName: staged.pdf.lastPathComponent, reason: "the book is no longer in the Library")
        }
        let fileManager = FileManager.default
        let destination = store.documentURL(for: book)
        if fileManager.fileExists(atPath: destination.path) { return }  // linked meanwhile
        // The book may have been replaced (a restore) since staging: check against it as it is now.
        guard destination.lastPathComponent == staged.pdf.lastPathComponent, staged.fingerprint == book.fingerprint else {
            throw ImportError.pdfMismatch(bookTitle: book.title)
        }
        let sidecar = store.storedContentDigest(bookID: book.id)
        if let sidecar, sidecar != staged.digest { throw ImportError.pdfMismatch(bookTitle: book.title) }
        do {
            try fileManager.createDirectory(at: store.bookDirectoryURL(bookID: book.id), withIntermediateDirectories: true)
            try fileManager.moveItem(at: staged.pdf, to: destination)
        } catch {
            throw ImportError.storage(fileName: book.fileName, reason: error.localizedDescription)
        }
        let cover = coverURL(for: book)
        if let stagedCover = staged.cover, !fileManager.fileExists(atPath: cover.path) {
            try? fileManager.moveItem(at: stagedCover, to: cover)
        }
        CoverCache.shared.remove(at: cover)
        if sidecar == nil { try? DocumentDigest.writeSidecar(staged.digest, to: store.contentHashURL(bookID: book.id)) }
        store.hub.post(.bookSaved(bookID: book.id), origin: origin)
    }

    /// The title a new book gets: the file name without its extension.
    nonisolated static func title(forFileName name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }
}
