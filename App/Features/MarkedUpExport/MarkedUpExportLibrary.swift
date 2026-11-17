import Foundation
import Observation
import ReaderCore
import UIKit

/// One marked-up PDF export, as kept on disk beside its file (`MarkedUpExportArchive`).
nonisolated struct MarkedUpExportRecord: Codable, Identifiable, Sendable, Equatable {
    enum Status: Codable, Sendable, Equatable {
        /// Being written (in this run; a record still saying so at launch was cut short).
        case running
        /// The file is there, `byteCount` bytes.
        case finished(byteCount: Int64)
        /// Ended without a file; `reason` says why, for the user.
        case unfinished(reason: String)
    }

    /// Raised when the manifest gains something an older version could not read.
    var formatVersion = 1
    let id: UUID
    let bookID: UUID
    /// The book's title when the export started.
    var bookTitle: String
    let includesNotes: Bool
    /// The PDF's name in the export's folder (`<Title> (Marked Up).pdf`).
    let fileName: String
    let startedAt: Date
    var finishedAt: Date?
    var status: Status
    /// The user has seen how it ended (shared it, or put away the reader's notice): the reader no
    /// longer shows it. The Notebook always does.
    var acknowledged = false

    var isRunning: Bool { status == .running }
    var isFinished: Bool { if case .finished = status { true } else { false } }
    var byteCount: Int64? { if case .finished(let bytes) = status { bytes } else { nil } }
    var unfinishedReason: String? { if case .unfinished(let reason) = status { reason } else { nil } }
}

/// Where exported marked-up PDFs are kept: `<store root>/Marked-Up Exports/<export ID>/`, holding
/// the PDF and `export.json` (its `MarkedUpExportRecord`). While an export runs, the exporter
/// writes into a folder inside that one; the PDF moves up when it is done. Nothing here is
/// removed except by `remove(_:)` (the user deleted or cancelled the export, or deleted its book)
/// and the leftovers of an export that was cut short.
nonisolated struct MarkedUpExportArchive: Sendable {
    let root: URL

    static let manifestName = "export.json"
    static let reasonAppClosed = "Tactile Texts closed before the export finished."

    static func defaultRoot(storeRoot: URL) -> URL {
        storeRoot.appendingPathComponent("Marked-Up Exports", isDirectory: true)
    }

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func fileURL(for record: MarkedUpExportRecord) -> URL {
        directory(for: record.id).appendingPathComponent(record.fileName)
    }

    /// Every export on disk, newest first. An export still marked running was cut short (the app
    /// closed): it becomes unfinished and its partial file is removed. A finished export whose
    /// file is gone is dropped.
    func load() -> [MarkedUpExportRecord] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var records: [MarkedUpExportRecord] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for folder in folders {
            let manifest = folder.appendingPathComponent(Self.manifestName)
            guard let data = try? Data(contentsOf: manifest),
                  var record = try? decoder.decode(MarkedUpExportRecord.self, from: data),
                  record.id.uuidString == folder.lastPathComponent else { continue }
            removeWorkFolders(of: record)
            switch record.status {
            case .running:
                record.status = .unfinished(reason: Self.reasonAppClosed)
                record.finishedAt = record.finishedAt ?? Date()
                record.acknowledged = false
                try? save(record)
            case .finished:
                guard fm.fileExists(atPath: fileURL(for: record).path) else {
                    try? remove(record.id)
                    continue
                }
            case .unfinished:
                break
            }
            records.append(record)
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ record: MarkedUpExportRecord) throws {
        let directory = directory(for: record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: directory.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    /// Deletes the export: its folder, file and record.
    func remove(_ id: UUID) throws {
        let directory = directory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Moves the finished file from the exporter's work folder into the export's folder.
    func adopt(_ result: NotebookExportResult, for record: MarkedUpExportRecord) throws -> Int64 {
        let fm = FileManager.default
        let destination = fileURL(for: record)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: result.fileURL, to: destination)
        try? fm.removeItem(at: result.workDirectory)
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
        return size ?? 0
    }

    /// The exporter's work folders inside an export's folder (a partial file of a run cut short).
    func removeWorkFolders(of record: MarkedUpExportRecord) {
        let fm = FileManager.default
        let directory = directory(for: record.id)
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? fm.removeItem(at: item)
        }
    }
}

/// Every marked-up PDF export of the app (owned by `AppEnvironment`): running ones and the
/// files they made, kept until the user deletes them (design: "Export Marked-Up PDF", *Exported
/// PDFs*). An export belongs to its book, not to the reader window that started it: closing that
/// window or leaving the book does not stop it, and its file stays in the book's Notebook
/// ("Exported PDFs") until the user deletes it there, deletes the book, or cancels the export.
///
/// Each reader window shows its book's latest export (`ReaderSession.markedUpExportNotice`):
/// a progress card in the window that started it until the user sends it to the background,
/// otherwise a status pill; finished, the pill offers Share until the user shares or hides it.
@Observable
@MainActor
final class MarkedUpExportLibrary {
    struct Progress: Equatable {
        var fraction: Double
        let startedAt: Date
    }

    /// A notification asked to show a book's exports.
    struct RevealRequest: Equatable {
        let bookID: UUID
        let exportID: UUID
    }

    /// Why a running export was stopped.
    private enum StopReason {
        /// The user cancelled it: nothing is kept.
        case user
        /// The system ended its background time: kept as unfinished, with Try Again.
        case system
    }

    /// Newest first.
    private(set) var records: [MarkedUpExportRecord]
    /// Running exports' progress.
    private(set) var progress: [UUID: Progress] = [:]
    /// Running export → the reader window (session ID) showing its progress card.
    private(set) var cardOwners: [UUID: UUID] = [:]
    /// Reader window (session ID) → the export whose share sheet it shows.
    private(set) var shareRequests: [UUID: UUID] = [:]
    /// Reader window (session ID) → a failure to show in an alert (it happened in front of the user).
    private(set) var failureAlerts: [UUID: String] = [:]
    /// Set by a notification; the first active window opens that book's Notebook.
    var revealRequest: RevealRequest?

    let archive: MarkedUpExportArchive
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var backgroundRuns: [UUID: MarkedUpExportBackgroundRun] = [:]
    @ObservationIgnored private var stopReasons: [UUID: StopReason] = [:]
    /// Whether the app is in front of the user (tests replace it).
    @ObservationIgnored var isApplicationActive: () -> Bool = { UIApplication.shared.applicationState == .active }
    /// Set once in `init`, read only in `deinit`.
    @ObservationIgnored nonisolated(unsafe) private var notificationObserver: (any NSObjectProtocol)?

    init(archive: MarkedUpExportArchive) {
        self.archive = archive
        records = archive.load()
        notificationObserver = NotificationCenter.default.addObserver(forName: MarkedUpExportNotifications.opened,
                                                                      object: nil, queue: .main) { [weak self] note in
            guard let identifier = note.object as? String else { return }
            MainActor.assumeIsolated { self?.notificationOpened(identifier) }
        }
    }

    deinit {
        if let notificationObserver { NotificationCenter.default.removeObserver(notificationObserver) }
    }

    // MARK: Reading

    func records(for bookID: UUID) -> [MarkedUpExportRecord] {
        records.filter { $0.bookID == bookID }
    }

    func record(_ id: UUID) -> MarkedUpExportRecord? {
        records.first { $0.id == id }
    }

    func isRunning(bookID: UUID) -> Bool {
        records.contains { $0.bookID == bookID && $0.isRunning }
    }

    func fileURL(for record: MarkedUpExportRecord) -> URL {
        archive.fileURL(for: record)
    }

    /// How long a running export has left, or `nil` until it can tell.
    func remaining(_ id: UUID, now: Date = Date()) -> TimeInterval? {
        guard let progress = progress[id] else { return nil }
        return MarkedUpExportTimeEstimate.remaining(elapsed: now.timeIntervalSince(progress.startedAt),
                                                     fraction: progress.fraction)
    }

    /// What a reader of `bookID` shows: its running export, else its latest one not yet seen.
    func notice(for bookID: UUID) -> MarkedUpExportRecord? {
        let mine = records(for: bookID)
        return mine.first(where: \.isRunning) ?? mine.first(where: { !$0.acknowledged })
    }

    // MARK: Running

    /// Starts an export of `book`; `cardOwner` is the reader window that shows its progress card.
    @discardableResult
    func start(book: Book, store: LibraryStore, includeNotes: Bool, cardOwner: UUID?) -> UUID? {
        guard !isRunning(bookID: book.id) else { return nil }
        var record = MarkedUpExportRecord(id: UUID(), bookID: book.id, bookTitle: book.title, includesNotes: includeNotes,
                                          fileName: MarkedUpExport.fileName(forBookTitle: book.title, includesNotes: includeNotes),
                                          startedAt: Date(), status: .running)
        record.acknowledged = false
        do {
            try archive.save(record)
        } catch {
            record.status = .unfinished(reason: MarkedUpExportError.writeFailed.localizedDescription)
            record.finishedAt = Date()
            records.insert(record, at: 0)
            if let cardOwner { failureAlerts[cardOwner] = MarkedUpExportError.writeFailed.localizedDescription }
            return record.id
        }
        let id = record.id
        records.insert(record, at: 0)
        progress[id] = Progress(fraction: 0, startedAt: Date())
        if let cardOwner { cardOwners[id] = cardOwner }
        backgroundRuns[id] = MarkedUpExportBackgroundRun(
            title: includeNotes ? "Exporting Book with Notes" : "Exporting Marked-Up PDF", subtitle: book.title
        ) { [weak self] in
            self?.stop(id, reason: .system)
        }
        #if DEBUG
        let pageDelay = Duration.milliseconds(LaunchOptions.current.exportPageDelayMs ?? 0)
        #else
        let pageDelay = Duration.zero
        #endif
        let workRoot = archive.directory(for: id)
        tasks[id] = Task { [weak self] in
            await OpenEditorRegistry.shared.flushAll(store: store)
            // Leftovers of the temporary folder earlier versions exported into.
            await NotebookExporter.purgeStale(root: MarkedUpExporter.defaultRoot)
            do {
                try Task.checkCancellation()
                let result = try await MarkedUpExporter.export(book: book, store: store, includeNotes: includeNotes,
                                                               root: workRoot, pageDelay: pageDelay, progress: { fraction in
                    guard let self, var current = self.progress[id] else { return }
                    current.fraction = fraction
                    self.progress[id] = current
                    self.backgroundRuns[id]?.update(fraction: fraction)
                })
                if Task.isCancelled {
                    NotebookExporter.cleanUp(result)
                    self?.ended(id, outcome: .failure(CancellationError()))
                } else {
                    self?.ended(id, outcome: .success(result))
                }
            } catch {
                self?.ended(id, outcome: .failure(error))
            }
        }
        return id
    }

    private func ended(_ id: UUID, outcome: Result<NotebookExportResult, any Error>) {
        tasks[id] = nil
        progress[id] = nil
        let owner = cardOwners.removeValue(forKey: id)
        let reason = stopReasons.removeValue(forKey: id)
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            if case .success(let result) = outcome { NotebookExporter.cleanUp(result) }
            finishBackgroundRun(id, success: false)
            return
        }
        var record = records[index]
        record.finishedAt = Date()
        // Seen by the user: it ended in front of them, in the window showing its progress.
        let inFront = owner != nil && isApplicationActive()
        switch outcome {
        case .success(let result):
            do {
                let bytes = try archive.adopt(result, for: record)
                record.status = .finished(byteCount: bytes)
            } catch {
                NotebookExporter.cleanUp(result)
                record.status = .unfinished(reason: MarkedUpExportError.writeFailed.localizedDescription)
            }
        case .failure(let error):
            if error is CancellationError || reason != nil {
                if reason == .system {
                    record.status = .unfinished(reason: "The export stopped while Tactile Texts was in the background.")
                } else {
                    // The user cancelled it: nothing is kept.
                    records.remove(at: index)
                    try? archive.remove(id)
                    finishBackgroundRun(id, success: false)
                    return
                }
            } else {
                record.status = .unfinished(reason: error.localizedDescription)
            }
        }
        archive.removeWorkFolders(of: record)
        record.acknowledged = inFront
        records[index] = record
        try? archive.save(record)
        finishBackgroundRun(id, success: record.isFinished)

        if inFront, let owner {
            if record.isFinished {
                shareRequests[owner] = id
            } else if let reason = record.unfinishedReason {
                failureAlerts[owner] = reason
            }
        } else if record.isFinished {
            MarkedUpExportNotifications.post(identifier: Self.notificationID(id), title: "Export Finished",
                                             body: "“\(record.fileName)” is ready. Find it in the Notebook of “\(record.bookTitle)”.")
        } else if let reason = record.unfinishedReason {
            MarkedUpExportNotifications.post(identifier: Self.notificationID(id), title: "Export Didn't Finish",
                                             body: "“\(record.fileName)”: \(reason)")
        }
    }

    private func finishBackgroundRun(_ id: UUID, success: Bool) {
        backgroundRuns.removeValue(forKey: id)?.end(success: success)
    }

    private func stop(_ id: UUID, reason: StopReason) {
        guard let task = tasks[id] else { return }
        stopReasons[id] = reason
        task.cancel()
    }

    // MARK: Commands

    /// The user cancelled a running export (after confirming): it stops and nothing is kept.
    func cancel(_ id: UUID) {
        stop(id, reason: .user)
    }

    /// Lets the window that showed the progress card be used; asks to notify when it ends.
    func moveToBackground(_ id: UUID) {
        guard cardOwners.removeValue(forKey: id) != nil else { return }
        MarkedUpExportNotifications.requestAuthorization()
    }

    /// Shows a running export's progress card in this reader window.
    func showCard(_ id: UUID, in session: UUID) {
        guard tasks[id] != nil else { return }
        cardOwners[id] = session
    }

    /// A reader window closed (or left its book): its card, share sheet and alert go; the export
    /// carries on in the background.
    func readerClosed(_ session: UUID) {
        for (id, owner) in cardOwners where owner == session {
            cardOwners[id] = nil
        }
        shareRequests[session] = nil
        failureAlerts[session] = nil
    }

    /// Opens the share sheet for a finished export in this reader window.
    func share(_ id: UUID, in session: UUID) {
        guard record(id)?.isFinished == true else { return }
        shareRequests[session] = id
    }

    /// The share sheet of this window closed. The file stays.
    func shareDidFinish(in session: UUID) {
        if let id = shareRequests.removeValue(forKey: session) { acknowledge(id) }
    }

    func dismissFailureAlert(in session: UUID) {
        failureAlerts[session] = nil
    }

    /// The user has seen how the export ended: the reader stops showing it.
    func acknowledge(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].isRunning,
              !records[index].acknowledged else { return }
        records[index].acknowledged = true
        try? archive.save(records[index])
        MarkedUpExportNotifications.remove(identifier: Self.notificationID(id))
    }

    /// The user deleted an export (after confirming): its file and record go. A running one is
    /// cancelled.
    func delete(_ id: UUID) {
        if tasks[id] != nil {
            cancel(id)
            return
        }
        records.removeAll { $0.id == id }
        for (session, shared) in shareRequests where shared == id { shareRequests[session] = nil }
        try? archive.remove(id)
        MarkedUpExportNotifications.remove(identifier: Self.notificationID(id))
    }

    /// The user deleted the book: every export of it goes.
    func deleteAll(bookID: UUID) {
        for record in records(for: bookID) { delete(record.id) }
    }

    /// The user asked to try an unfinished export again (after confirming): its record makes way
    /// for a new export.
    @discardableResult
    func retry(_ id: UUID, book: Book, store: LibraryStore, cardOwner: UUID?) -> UUID? {
        guard let old = record(id), !old.isRunning, !isRunning(bookID: book.id) else { return nil }
        if !old.isFinished { delete(id) }
        return start(book: book, store: store, includeNotes: old.includesNotes, cardOwner: cardOwner)
    }

    // MARK: Notifications

    static func notificationID(_ id: UUID) -> String { "markedUpExport.\(id.uuidString)" }

    private func notificationOpened(_ identifier: String) {
        guard let record = records.first(where: { Self.notificationID($0.id) == identifier }) else { return }
        revealRequest = RevealRequest(bookID: record.bookID, exportID: record.id)
    }
}
