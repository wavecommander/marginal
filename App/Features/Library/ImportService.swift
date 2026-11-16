import Foundation
import Observation
import ReaderCore

/// One import in progress, observable by every Library window.
@Observable
@MainActor
final class ImportJob: Identifiable {
    enum Phase: Equatable {
        /// `converting`: a converter is making the PDF (`fraction` is its progress).
        case waiting, checking, copying, converting, finishing
    }

    nonisolated let id = UUID()
    let fileName: String
    private(set) var phase = Phase.waiting
    /// Fraction of the current phase done, `0...1`: the copy while `copying`, the conversion
    /// (chapters or images done over the total) while `converting`.
    private(set) var fraction = 0.0
    private(set) var isCancelled = false
    @ObservationIgnored fileprivate var cancelHandler: (() -> Void)?

    init(fileName: String) { self.fileName = fileName }

    /// Cancels the import: the copy or conversion stops at its next step and the partial files
    /// are removed.
    func cancel() {
        isCancelled = true
        cancelHandler?()
    }

    fileprivate func set(phase: Phase) {
        guard phase != self.phase else { return }
        self.phase = phase
        fraction = 0
    }

    /// Records progress reported for `phase`; a late report from an earlier phase is ignored.
    fileprivate func set(fraction: Double, during phase: Phase) {
        guard phase == self.phase else { return }
        self.fraction = max(self.fraction, min(1, fraction))
    }
}

/// What a successful import resolved to.
enum ImportOutcome: Equatable, Sendable {
    /// A new book was created.
    case imported(Book)
    /// The file's fingerprint matched a book already in the Library; nothing was copied.
    case existing(Book)
    /// The file needs converting and waits in the `ConversionRequest` with this ID for the
    /// reader's answer in the Convert to PDF sheet.
    case awaitingConversion(requestID: UUID)

    var book: Book? {
        switch self {
        case .imported(let book), .existing(let book): book
        case .awaitingConversion: nil
        }
    }
}

/// The result of importing one file.
struct ImportResult: Sendable {
    var fileName: String
    var result: Result<ImportOutcome, ImportError>
    /// The failure is listed in a Convert to PDF sheet, so it must not also be shown as an alert.
    var isListedInSheet = false

    var book: Book? { try? result.get().book }
    var error: ImportError? {
        if case .failure(let error) = result { error } else { nil }
    }
    /// The failure to show as an alert, if any (`nil` when the sheet lists it).
    var alertError: ImportError? { isListedInSheet ? nil : error }
    /// The request this file waits in, if it needs converting.
    var conversionRequestID: UUID? {
        if case .success(.awaitingConversion(let id)) = result { id } else { nil }
    }
}

/// A failure waiting to be shown as an alert in the window that asked for the import.
struct ImportFailureAlert: Identifiable, Equatable {
    let id = UUID()
    let windowKey: ObjectIdentifier
    let error: ImportError
}

/// The import pipeline: one per app, shared by every window (`AppEnvironment.importService`).
/// Sources are the Files picker, drops, "Open in" and `-importFixture`; all go through
/// `importFiles`.
///
/// Per batch:
/// 1. **Preflight** every file (off the main thread): format (`ImportFormatDetector`), size,
///    `BookFingerprint`, the DRM check. Nothing is copied.
/// 2. Files that need converting (a converter is registered for their format and no book has
///    their fingerprint) become one `ConversionRequest` for the requesting window, together with
///    the batch's files that cannot be imported; the window shows the Convert to PDF sheet. Only
///    when nothing needs converting are failures shown as alerts.
/// 3. PDFs go on straight away, one after another, whatever the sheet is doing:
///    - **Stage** (off the main thread): stream the file into `Imports/<newBookID>/<fileName>`
///      under the store's root (not under `Books/`, so the launch-time orphan sweep never sees
///      it), check it opens and has pages and is not locked, render the cover to `cover.jpg`.
///    - **Commit** (main actor, no suspension point): re-check the fingerprint, rename the
///      staging directory to `Books/<newBookID>` and save the `Book` (posting `.bookSaved`, so
///      every Library window updates). A crash before this leaves only `Imports/` debris,
///      removed at next launch; a crash after it leaves a complete book.
///    A file whose fingerprint is already in the Library ends with `.existing`: nothing is
///    copied, unless that book lacks its PDF (restored from a backup without it, or removed from
///    disk), which the file then supplies (`restoreMissingDocument`): a PDF after its full
///    SHA-256 is checked against the book's `document.sha256` (a mismatch fails with
///    `ImportError.pdfMismatch`), a converted book's original by being converted again.
///    `linkPDF(at:to:)` is the same for one named book ("Locate PDF…").
/// 4. **Convert** (`convert(_:options:)`, from the sheet): per file, copy the original to
///    `Imports/<newBookID>/original.<ext>`, run the format's `DocumentConverter`, run the stage
///    checks on the generated PDF, write `conversion.json`, then commit as above. **Cancel**
///    (`discard(_:)`) drops the request: nothing is copied and adopted files are deleted.
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
    /// Batches waiting for the reader's answer in a Convert to PDF sheet, oldest first. A screen
    /// shows the first one addressed to its window.
    private(set) var conversionRequests: [ConversionRequest] = []

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let converters: ConverterRegistry
    @ObservationIgnored let origin = ChangeOrigin(label: "import")
    @ObservationIgnored private var staleCleanup: Task<Void, Never>?

    /// `Imports/` under the store's root: staging area and drop landing area.
    var stagingRoot: URL { store.rootDirectory.appendingPathComponent("Imports", isDirectory: true) }

    init(store: LibraryStore, converters: ConverterRegistry = .standard) {
        self.store = store
        self.converters = converters
        let root = store.rootDirectory.appendingPathComponent("Imports", isDirectory: true)
        let startedAt = Date()
        // Staging left by a previous run (a crash mid-import). Anything created from now on is
        // newer than `startedAt` and is kept.
        staleCleanup = Task { await ImportPipeline.removeStale(in: root, before: startedAt) }
    }

    // MARK: Public API

    /// Imports one file; the convenience form for launch arguments and tests. Throws the
    /// `ImportError` (or `CancellationError` when cancelled). A file that needs converting
    /// returns `.awaitingConversion` (or, with `convertWithoutAsking`, is converted).
    @discardableResult
    func importPDF(at url: URL, consumeSource: Bool = false,
                   convertWithoutAsking: ConversionOptions? = nil) async throws -> ImportOutcome {
        let results = await importFiles([url], consumeSources: consumeSource, convertWithoutAsking: convertWithoutAsking)
        switch results[0].result {
        case .success(let outcome): return outcome
        case .failure(.cancelled): throw CancellationError()
        case .failure(let error): throw error
        }
    }

    /// Imports one batch of files. A job per file appears in `jobs` immediately. Never throws;
    /// each file's result is returned in order. Returns once the PDFs are imported and any
    /// conversion request is queued, without waiting for the reader's answer.
    /// - Parameters:
    ///   - consumeSources: the files are temporary copies (drop landing area, the app's
    ///     `Inbox`): move them instead of copying, and delete them afterwards.
    ///   - requester: the window that asked (`ObjectIdentifier` of its `WindowContext`); the
    ///     conversion request is addressed to it. `nil` leaves it unaddressed (see `address`).
    ///   - opensBookWhenDone: stored in the request ("Open in" opens the converted book).
    ///   - convertWithoutAsking: convert with these options instead of queuing a request
    ///     (`-confirmConversions`); the results are then the conversions' results.
    func importFiles(_ urls: [URL], consumeSources: Bool = false, requester: ObjectIdentifier? = nil,
                     opensBookWhenDone: Bool = false,
                     convertWithoutAsking: ConversionOptions? = nil) async -> [ImportResult] {
        let entries = urls.map { url in (url: url, job: ImportJob(fileName: url.lastPathComponent)) }
        jobs.append(contentsOf: entries.map(\.job))
        await staleCleanup?.value

        // 1. Preflight every file.
        var classified: [(scoped: Bool, result: Result<Classified, ImportError>)] = []
        for (url, job) in entries {
            let scoped = url.startAccessingSecurityScopedResource()
            job.set(phase: .checking)
            classified.append((scoped, await runJob(job) { try await self.classify(url, fileName: job.fileName) }))
        }

        // 2. Queue the files that need converting, with the batch's rejections.
        var results = [ImportResult?](repeating: nil, count: entries.count)
        var items: [(index: Int, item: ConversionItem)] = []
        var rejections: [(index: Int, error: ImportError)] = []
        for (index, (url, job)) in entries.enumerated() {
            switch classified[index].result {
            case .success(.convertible(let format, let probe)):
                items.append((index, ConversionItem(source: url, fileName: job.fileName, format: format, probe: probe,
                                                    consumeSource: consumeSources,
                                                    holdsSecurityScope: classified[index].scoped)))
            case .failure(let error):
                rejections.append((index, error))
            case .success(.pdf), .success(.existing):
                continue
            }
            jobs.removeAll { $0.id == job.id }
        }
        let request: ConversionRequest? = items.isEmpty ? nil : ConversionRequest(
            windowKey: requester, items: items.map(\.item),
            rejected: rejections.filter { $0.error != .cancelled }
                .map { RejectedFile(fileName: entries[$0.index].job.fileName, error: $0.error) },
            opensBookWhenDone: opensBookWhenDone)
        for (index, error) in rejections {
            let url = entries[index].url
            if classified[index].scoped { url.stopAccessingSecurityScopedResource() }
            if consumeSources { await disposeOfSource(url) }
            results[index] = ImportResult(fileName: entries[index].job.fileName, result: .failure(error),
                                          isListedInSheet: request != nil && convertWithoutAsking == nil)
        }
        if let request {
            for (index, _) in items {
                results[index] = ImportResult(fileName: entries[index].job.fileName,
                                              result: .success(.awaitingConversion(requestID: request.id)))
            }
            if convertWithoutAsking == nil { conversionRequests.append(request) }
        }

        // 3. PDFs, and books already in the Library, without waiting for the sheet.
        for (index, (url, job)) in entries.enumerated() {
            let outcome: Result<ImportOutcome, ImportError>
            switch classified[index].result {
            case .success(.pdf(let probe)):
                outcome = await runJob(job) { try await self.importPDF(url, probe: probe, job: job, consume: consumeSources) }
            case .success(.existing(let book)):
                outcome = await runJob(job) {
                    try await self.restoreMissingDocument(of: book, from: url, job: job)
                    return .existing(book)
                }
            case .success(.convertible), .failure:
                continue
            }
            if classified[index].scoped { url.stopAccessingSecurityScopedResource() }
            if consumeSources { await disposeOfSource(url) }
            jobs.removeAll { $0.id == job.id }
            results[index] = ImportResult(fileName: job.fileName, result: outcome)
        }

        // 4. `-confirmConversions`: convert now, as if the reader had chosen Convert.
        if let request, let options = convertWithoutAsking {
            let converted = await runConversion(request, options: options)
            for ((index, _), result) in zip(items, converted) { results[index] = result }
        }
        return results.map { $0! }
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

    // MARK: Conversion requests

    /// The request the window with this key should show now, if any.
    func conversionRequest(for windowKey: ObjectIdentifier) -> ConversionRequest? {
        conversionRequests.first { $0.windowKey == windowKey }
    }

    /// Addresses the unaddressed requests among `requestIDs` to the window with this key (the
    /// first window takes `-importFixture`'s requests once launch work is done).
    func address(_ requestIDs: [UUID], to windowKey: ObjectIdentifier) {
        for index in conversionRequests.indices
        where conversionRequests[index].windowKey == nil && requestIDs.contains(conversionRequests[index].id) {
            conversionRequests[index].windowKey = windowKey
        }
    }

    /// Convert: the request leaves the queue (its sheet closes) and each file is converted and
    /// imported in turn, with a job in `jobs` that can be cancelled. Returns each file's result
    /// in order (empty if the request is no longer queued).
    func convert(_ requestID: UUID, options: ConversionOptions) async -> [ImportResult] {
        guard let index = conversionRequests.firstIndex(where: { $0.id == requestID }) else { return [] }
        let request = conversionRequests.remove(at: index)
        return await runConversion(request, options: options)
    }

    /// Cancel: the request leaves the queue (its sheet closes). Nothing was copied; files the app
    /// adopted for it (a drop, the "Open in" inbox) are deleted and access to picked files ends.
    func discard(_ requestID: UUID) async {
        guard let index = conversionRequests.firstIndex(where: { $0.id == requestID }) else { return }
        let request = conversionRequests.remove(at: index)
        for item in request.items {
            if item.holdsSecurityScope { item.source.stopAccessingSecurityScopedResource() }
            if item.consumeSource { await disposeOfSource(item.source) }
        }
    }

    // MARK: Cover paths

    /// `Books/<id>/cover.jpg`, relative to the store's root.
    nonisolated static func coverRelativePath(bookID: UUID) -> String {
        "\(BookStorageLayout.bookDirectory(bookID: bookID))/\(ImportPipeline.coverFileName)"
    }

    func coverURL(for book: Book) -> URL {
        store.url(forRelativePath: Self.coverRelativePath(bookID: book.id))
    }

    // MARK: Preflight

    private enum Classified: Sendable {
        case pdf(ImportPipeline.Probe)
        case convertible(ImportFormat, ImportPipeline.Probe)
        case existing(Book)
    }

    private func classify(_ url: URL, fileName name: String) async throws -> Classified {
        let preflight = try await ImportPipeline.preflight(url, fileName: name)
        switch preflight.detection {
        case .unknown:
            throw ImportError.notAPDF(fileName: name)
        case .unsupported(.protectedEPUB):
            throw ImportError.protected(fileName: name)
        case .unsupported(let kind):
            throw ImportError.unsupportedFormat(fileName: name, kind: kind)
        case .supported(let format):
            guard let probe = preflight.probe else { throw ImportError.notAPDF(fileName: name) }
            if let existing = try storeBook(fingerprint: probe.fingerprint) { return .existing(existing) }
            if format == .pdf { return .pdf(probe) }
            guard converters.converter(for: format) != nil else {
                throw ImportError.unsupportedFormat(fileName: name, kind: nil)
            }
            return .convertible(format, probe)
        }
    }

    // MARK: One PDF

    private func importPDF(_ url: URL, probe: ImportPipeline.Probe, job: ImportJob, consume: Bool) async throws -> ImportOutcome {
        let name = job.fileName
        let fileName = ImportPipeline.documentFileName(name)
        let bookID = UUID()
        let staging = stagingRoot.appendingPathComponent(bookID.uuidString, isDirectory: true)
        job.set(phase: .copying)
        do {
            let staged = try await ImportPipeline.stage(
                source: url, directory: staging, fileName: fileName, consume: consume, size: probe.size,
                progress: { fraction in Task { @MainActor in job.set(fraction: fraction, during: .copying) } })
            try Task.checkCancellation()
            job.set(phase: .finishing)
            let book = Book(id: bookID, title: Self.title(forFileName: name), fingerprint: probe.fingerprint,
                            fileName: fileName, pageCount: staged.pageCount, fileSize: staged.fileSize)
            return try commit(book, staging: staging, displayName: fileName)
        } catch {
            await ImportPipeline.remove(staging)
            throw error
        }
    }

    // MARK: One conversion

    private func runConversion(_ request: ConversionRequest, options: ConversionOptions) async -> [ImportResult] {
        let entries = request.items.map { item in (item: item, job: ImportJob(fileName: item.fileName)) }
        jobs.append(contentsOf: entries.map(\.job))
        var results: [ImportResult] = []
        for (item, job) in entries {
            let outcome = await runJob(job) { try await self.convertOne(item, job: job, options: options) }
            if item.holdsSecurityScope { item.source.stopAccessingSecurityScopedResource() }
            if item.consumeSource { await disposeOfSource(item.source) }
            jobs.removeAll { $0.id == job.id }
            results.append(ImportResult(fileName: item.fileName, result: outcome))
        }
        return results
    }

    private func convertOne(_ item: ConversionItem, job: ImportJob, options: ConversionOptions) async throws -> ImportOutcome {
        let name = item.fileName
        job.set(phase: .checking)
        // Imported meanwhile (another window, an earlier file in the batch)?
        if let existing = try storeBook(fingerprint: item.probe.fingerprint) {
            try await restoreMissingDocument(of: existing, from: item.source, job: job)
            return .existing(existing)
        }
        guard let converter = converters.converter(for: item.format) else {
            throw ImportError.unsupportedFormat(fileName: name, kind: nil)
        }
        let bookID = UUID()
        let staging = stagingRoot.appendingPathComponent(bookID.uuidString, isDirectory: true)
        do {
            let made = try await convert(item.source, fileName: name, format: item.format, converter: converter,
                                         options: options, outputFileName: Self.convertedFileName(forFileName: name),
                                         staging: staging, consume: item.consumeSource, size: item.probe.size, job: job)
            job.set(phase: .finishing)
            let title = made.converted.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let book = Book(id: bookID, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? Self.title(forFileName: name),
                            fingerprint: item.probe.fingerprint, fileName: made.converted.pdf.lastPathComponent,
                            pageCount: made.staged.pageCount, fileSize: made.staged.fileSize + made.originalSize,
                            sourceFormat: item.format, originalFileName: name, converterVersion: converter.version)
            try Task.checkCancellation()
            return try commit(book, staging: staging, displayName: name)
        } catch {
            await ImportPipeline.remove(staging)
            throw error
        }
    }

    private struct Made {
        var converted: ConvertedDocument
        var staged: ImportPipeline.Staged
        var originalSize: Int64
    }

    /// Copies the original into `staging` as `original.<ext>`, converts it there to
    /// `outputFileName`, runs the stage checks on the result and writes `conversion.json`. The
    /// caller removes `staging` on failure.
    private func convert(_ source: URL, fileName name: String, format: ImportFormat, converter: any DocumentConverter,
                         options: ConversionOptions, outputFileName: String, staging: URL, consume: Bool,
                         size: Int64, job: ImportJob) async throws -> Made {
        job.set(phase: .copying)
        let original = staging.appendingPathComponent(
            BookStorageLayout.originalFileName(extension: (name as NSString).pathExtension))
        try await ImportPipeline.placeOriginal(
            source: source, at: original, directory: staging, fileName: name, consume: consume, size: size,
            progress: { fraction in Task { @MainActor in job.set(fraction: fraction, during: .copying) } })
        try Task.checkCancellation()

        job.set(phase: .converting)
        let input = ConversionInput(original: original, format: format, fileName: name, directory: staging,
                                    outputFileName: outputFileName, options: options)
        let converted = try await ImportPipeline.convert(
            with: converter, input: input,
            progress: { fraction in Task { @MainActor in job.set(fraction: fraction, during: .converting) } })
        try Task.checkCancellation()
        guard converted.pdf.deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL,
              converted.pdf.lastPathComponent != original.lastPathComponent else {
            throw ImportError.conversionFailed(fileName: name, reason: "the PDF was not written to the staging directory")
        }

        job.set(phase: .finishing)
        let staged = try await ImportPipeline.checkConverted(converted, directory: staging, fileName: name)
        try await ImportPipeline.writeConversionRecord(
            ConversionRecord(sourceFormat: format, converterVersion: converter.version, options: options),
            in: staging, fileName: name)
        return Made(converted: converted, staged: staged, originalSize: await ImportPipeline.size(of: original))
    }

    // MARK: Commit

    /// The commit step. No suspension point between the fingerprint check, the rename and the
    /// save.
    private func commit(_ book: Book, staging: URL, displayName: String) throws -> ImportOutcome {
        if let existing = try storeBook(fingerprint: book.fingerprint) {
            try? FileManager.default.removeItem(at: staging)  // a concurrent import of the same file won
            return .existing(existing)
        }
        let fileManager = FileManager.default
        let destination = store.bookDirectoryURL(bookID: book.id)
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            throw ImportError.storage(fileName: displayName, reason: error.localizedDescription)
        }
        do {
            try store.perform(as: origin) { try store.books.save(book) }
        } catch {
            try? fileManager.removeItem(at: destination)
            throw ImportError.storage(fileName: displayName, reason: String(describing: error))
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
    ///
    /// A **converted** book (`Book.isConverted`) has the fingerprint of the file it was made
    /// from, not of its PDF, so it accepts either of two files: the file it was made from (same
    /// fingerprint), which is converted again with the text size the book was made with; or its
    /// generated PDF, which only the full SHA-256 in the sidecar can vouch for (no sidecar, no
    /// link).
    /// - Returns: the book (unchanged record; its PDF is now on disk).
    @discardableResult
    func linkPDF(at url: URL, to book: Book) async throws -> Book {
        let job = ImportJob(fileName: url.lastPathComponent)
        jobs.append(job)
        defer { jobs.removeAll { $0.id == job.id } }
        let bookID = book.id
        switch await runJob(job, { try await self.runLink(url: url, bookID: bookID, job: job) }) {
        case .success(let linked): return linked
        case .failure(.cancelled): throw CancellationError()
        case .failure(let error): throw error
        }
    }

    private func runLink(url: URL, bookID: UUID, job: ImportJob) async throws -> Book {
        let name = job.fileName
        await staleCleanup?.value
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            job.set(phase: .checking)
            let preflight = try await ImportPipeline.preflight(url, fileName: name)
            guard let book = try storeBook(id: bookID) else {
                throw ImportError.storage(fileName: name, reason: "the book is no longer in the Library")
            }
            guard case .supported(let format) = preflight.detection, let probe = preflight.probe else {
                if case .unknown = preflight.detection, !book.isConverted { throw ImportError.notAPDF(fileName: name) }
                throw ImportError.pdfMismatch(bookTitle: book.title)
            }
            // A PDF chosen for a converted book is its generated PDF: the fingerprint says
            // nothing about it, only the full hash does. Any other pairing goes by fingerprint.
            let isGeneratedPDF = format == .pdf && book.isConverted
            if isGeneratedPDF {
                guard store.storedContentDigest(bookID: book.id) != nil || store.hasDocument(book) else {
                    throw ImportError.pdfMismatch(bookTitle: book.title)
                }
            } else {
                guard (format == .pdf) == !book.isConverted, probe.fingerprint == book.fingerprint else {
                    throw ImportError.pdfMismatch(bookTitle: book.title)
                }
            }
            if store.hasDocument(book) {
                // Already linked: still only "accept" the very same file (for a converted book's
                // original, the fingerprint checked above is all there is to compare).
                if format == .pdf {
                    let mine = try await store.contentDigest(of: book)
                    let theirs = try await DocumentLinking.digest(of: url)
                    guard mine == theirs else { throw ImportError.pdfMismatch(bookTitle: book.title) }
                }
                return book
            }
            try await restoreMissingDocument(of: book, from: url, isGeneratedPDF: isGeneratedPDF, size: probe.size, job: job)
            return book
        }
    }

    /// Supplies `book`'s PDF from `source` when it is missing (no-op when it is present). Used by
    /// every import whose fingerprint matches an existing book, and by `linkPDF`.
    ///
    /// **A PDF** (the book's own, or with `isGeneratedPDF` a converted book's generated PDF) is
    /// staged as a copy in `Imports/link-<uuid>/` (never in the book's directory), verifying the
    /// full SHA-256 against the book's sidecar when it has one, the fingerprint (not for a
    /// generated PDF, which must have a sidecar instead), and that the copy opens; a cover is
    /// rendered. Then, on the main actor with no suspension point: the book and its sidecar are
    /// re-checked, the PDF moves into the book's directory, the cover too if the book has none
    /// (and the cached cover image is dropped), the sidecar is written if absent, and `.bookSaved`
    /// is posted so every window refreshes. A wrong file throws `ImportError.pdfMismatch` and
    /// leaves nothing in the book's directory.
    ///
    /// **A converted book's original** (the caller has matched its fingerprint) is converted
    /// again: see `reconvertMissingDocument`.
    private func restoreMissingDocument(of book: Book, from source: URL, isGeneratedPDF: Bool = false,
                                        size: Int64? = nil, job: ImportJob) async throws {
        guard !store.hasDocument(book) else { return }
        if let format = book.sourceFormat, format.isConverted, !isGeneratedPDF {
            try await reconvertMissingDocument(of: book, format: format, from: source, job: job)
            return
        }
        let expected = store.storedContentDigest(bookID: book.id)
        if book.isConverted, expected == nil { throw ImportError.pdfMismatch(bookTitle: book.title) }
        let staging = stagingRoot.appendingPathComponent("link-\(UUID().uuidString)", isDirectory: true)
        do {
            job.set(phase: .copying)
            let staged = try await DocumentLinking.stage(
                source: source, directory: staging, fileName: book.fileName,
                fingerprint: book.isConverted ? nil : book.fingerprint,
                expected: expected, bookTitle: book.title, size: size ?? book.fileSize,
                progress: { fraction in Task { @MainActor in job.set(fraction: fraction, during: .copying) } })
            try Task.checkCancellation()
            job.set(phase: .finishing)
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
        guard destination.lastPathComponent == staged.pdf.lastPathComponent,
              book.isConverted || staged.fingerprint == book.fingerprint else {
            throw ImportError.pdfMismatch(bookTitle: book.title)
        }
        let sidecar = store.storedContentDigest(bookID: book.id)
        if let sidecar, sidecar != staged.digest { throw ImportError.pdfMismatch(bookTitle: book.title) }
        // A converted book's fingerprint is its original's: only the full hash vouches for its PDF.
        if book.isConverted, sidecar == nil { throw ImportError.pdfMismatch(bookTitle: book.title) }
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

    /// A converted book whose PDF is missing (removed from disk, or restored from a backup
    /// without it) is repaired from the file it was made from: that file is converted again with
    /// the text size the book was made with (`conversion.json`; Medium if that is missing), and
    /// the kept original is put back if that is missing too.
    ///
    /// The new PDF is not byte-for-byte the old one, so a `document.sha256` sidecar left by a
    /// restore no longer describes it and is removed (the next backup hashes the new PDF).
    /// `.bookSaved` is posted so every window refreshes.
    private func reconvertMissingDocument(of book: Book, format: ImportFormat, from source: URL, job: ImportJob) async throws {
        let destination = store.documentURL(for: book)
        let name = book.originalFileName ?? job.fileName
        guard let converter = converters.converter(for: format) else {
            throw ImportError.unsupportedFormat(fileName: name, kind: nil)
        }
        let directory = destination.deletingLastPathComponent()
        let options = await ImportPipeline.readConversionRecord(in: directory)?.options ?? ConversionOptions()
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let size = await ImportPipeline.size(of: source)
            let made = try await convert(source, fileName: name, format: format, converter: converter, options: options,
                                         outputFileName: book.fileName, staging: staging, consume: false, size: size, job: job)
            guard try storeBook(id: book.id) != nil else {
                throw ImportError.storage(fileName: name, reason: "the book is no longer in the Library")
            }
            try await ImportPipeline.restore(from: staging, into: directory, documentFileName: book.fileName, fileName: name)
            try? FileManager.default.removeItem(at: store.contentHashURL(bookID: book.id))
            CoverCache.shared.remove(at: coverURL(for: book))
            if made.staged.pageCount != book.pageCount, var stored = try store.books.book(id: book.id) {
                stored.pageCount = made.staged.pageCount
                try store.perform(as: origin) { try store.books.save(stored) }
            } else {
                store.hub.post(.bookSaved(bookID: book.id), origin: origin)
            }
        } catch {
            await ImportPipeline.remove(staging)
            throw error
        }
        await ImportPipeline.remove(staging)
    }

    // MARK: Helpers

    /// Runs `body` as the job's task, so `ImportJob.cancel()` (and cancelling the caller)
    /// cancels it. Errors become `ImportError`s.
    private func runJob<T: Sendable>(_ job: ImportJob, _ body: @escaping @MainActor () async throws -> T) async -> Result<T, ImportError> {
        let name = job.fileName
        let task = Task { () -> Result<T, ImportError> in
            do {
                return .success(try await body())
            } catch let error as ImportError {
                return .failure(error)
            } catch is CancellationError {
                return .failure(.cancelled)
            } catch {
                return .failure(.unreadable(fileName: name, reason: error.localizedDescription))
            }
        }
        job.cancelHandler = { task.cancel() }
        if job.isCancelled { task.cancel() }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        job.cancelHandler = nil
        return result
    }

    /// Deletes a source the app adopted: the whole `drop-…` folder for a drop, else the file.
    private func disposeOfSource(_ url: URL) async {
        let folder = url.deletingLastPathComponent()
        await ImportPipeline.remove(folder.lastPathComponent.hasPrefix("drop-") ? folder : url)
    }

    /// The title a new book gets: the file name without its extension.
    nonisolated static func title(forFileName name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }

    /// The generated PDF's file name for an original named `name`: its stem plus `.pdf` (never a
    /// name the book's directory reserves: `original.epub` gives `original-book.pdf`).
    nonisolated static func convertedFileName(forFileName name: String) -> String {
        ImportPipeline.documentFileName(title(forFileName: name) + ".pdf")
    }
}
