import Foundation
import ReaderBackup
import ReaderCore

// Bringing a book back (C5, `docs/CLOUD_SYNC_PLAN.md` owner decision 3): **Recently Deleted**
// (a book deleted on any device stays restorable for 30 days, from any device) and **earlier
// versions** (the heads history keeps for 30 days, one of which can become the book's content
// again).

/// A book deleted on one of the account's devices, still restorable.
public struct SyncDeletedBook: Hashable, Sendable, Identifiable {
    public var bookKey: String
    public var id: String { bookKey }
    public var title: String
    /// When it was deleted, by the deleting device's clock.
    public var deletedAt: Date
    /// The device that deleted it.
    public var deviceID: UUID
    public var deviceName: String
    /// The head version that says so.
    public var version: Int

    public init(bookKey: String, title: String, deletedAt: Date, deviceID: UUID, deviceName: String, version: Int) {
        self.bookKey = bookKey
        self.title = title
        self.deletedAt = deletedAt
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.version = version
    }

    /// When it stops being restorable: 30 days after it was deleted.
    public var expiresAt: Date { deletedAt.addingTimeInterval(SyncHousekeeping.deletedLifetime) }

    /// Whole days left before it stops being restorable (0 on the last day).
    public func daysLeft(now: Date) -> Int {
        max(0, Int((expiresAt.timeIntervalSince(now) / 86_400).rounded(.down)))
    }
}

/// What a version of a book holds, in counts (for the Earlier Versions list).
public struct SyncContentSummary: Hashable, Sendable {
    public var notes: Int
    public var highlights: Int
    public var bookmarks: Int
    public var headings: Int
    /// Pages with ink.
    public var inkedPages: Int

    public init(notes: Int, highlights: Int, bookmarks: Int, headings: Int, inkedPages: Int) {
        self.notes = notes
        self.highlights = highlights
        self.bookmarks = bookmarks
        self.headings = headings
        self.inkedPages = inkedPages
    }

    public init(archive: BookArchive, inkedPages: Int) {
        self.init(notes: archive.notes.count, highlights: archive.highlights.count, bookmarks: archive.bookmarks.count,
                  headings: archive.userHeadings.count, inkedPages: inkedPages)
    }
}

/// One earlier version of a book that history keeps.
public struct SyncBookVersion: Hashable, Sendable, Identifiable {
    public var version: Int
    public var id: Int { version }
    /// When the device that made it wrote it (its own clock).
    public var modifiedAt: Date
    /// When it was replaced by the next version (the store's clock), if known.
    public var replacedAt: Date?
    public var deviceID: UUID
    public var deviceName: String
    public var title: String
    /// What it holds; `nil` when its records are no longer in the account (it cannot be restored).
    public var summary: SyncContentSummary?

    public init(version: Int, modifiedAt: Date, replacedAt: Date?, deviceID: UUID, deviceName: String, title: String,
                summary: SyncContentSummary?) {
        self.version = version
        self.modifiedAt = modifiedAt
        self.replacedAt = replacedAt
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.title = title
        self.summary = summary
    }
}

/// What restoring an earlier version is about to change, handed to the caller just before the
/// change is written (`SyncEngine.restoreVersion`).
public struct SyncVersionRestorePlan: Hashable, Sendable {
    /// The book on this device.
    public var bookID: UUID
    public var bookKey: String
    public var version: Int
    /// The book now, and as it will be.
    public var current: SyncContentSummary
    public var restored: SyncContentSummary

    public init(bookID: UUID, bookKey: String, version: Int, current: SyncContentSummary, restored: SyncContentSummary) {
        self.bookID = bookID
        self.bookKey = bookKey
        self.version = version
        self.current = current
        self.restored = restored
    }
}

/// Why a book could not be brought back. Nothing was changed in any case.
public enum SyncRestoreError: Error, Hashable, Sendable, LocalizedError {
    /// The book is no longer deleted (restored on another device, or edited back), or has no head.
    case notDeleted
    /// Deleted more than 30 days ago: its content is gone.
    case noLongerRestorable
    /// Part of what the book (or the version) needs is no longer in the account.
    case contentGone
    /// History does not hold that version (any more).
    case versionNotFound
    /// The book is not on this device.
    case bookNotOnThisDevice
    /// The reader is working in the book (a note being edited, a stroke not yet saved).
    case bookBusy
    /// The book changed while it was being restored.
    case bookChanged
    /// The session can only pull (read-only, or over the allowance): restoring writes to the account.
    case needsFullAccess
    /// A newer version of the app wrote the book.
    case needsNewerApp(requiredLevel: Int)

    public var errorDescription: String? {
        switch self {
        case .notDeleted:
            "This book isn’t in Recently Deleted any more. It may have been restored on another device."
        case .noLongerRestorable:
            "This book was deleted more than 30 days ago, so it can’t be restored."
        case .contentGone:
            "Part of this book is no longer in Tactile Texts Cloud, so it can’t be restored. Nothing was changed."
        case .versionNotFound:
            "That version of the book is no longer kept. Nothing was changed."
        case .bookNotOnThisDevice:
            "This book isn’t on this device."
        case .bookBusy:
            "Finish what you’re doing in this book first (a note being edited or ink not yet saved), then try again. Nothing was changed."
        case .bookChanged:
            "The book changed while it was being restored, so nothing was changed. Try again."
        case .needsFullAccess:
            "Changes from this device can’t be sent to Tactile Texts Cloud right now, so nothing can be restored."
        case .needsNewerApp:
            "A newer version of Tactile Texts synced this book. Update the app on this device to restore it."
        }
    }
}

extension SyncEngine {
    // MARK: Recently Deleted

    /// The account's deleted books that can still be restored (deleted less than 30 days ago,
    /// content kept), newest deletion first. A head that does not open is left out; one in a
    /// newer format throws `formatTooNew`.
    public func recentlyDeleted() async throws -> [SyncDeletedBook] {
        let listed = try await store.listHeads()
        noteListing(listed.map(\.lastModified))
        let cutoff = now().addingTimeInterval(-SyncHousekeeping.deletedLifetime)
        var result: [SyncDeletedBook] = []
        for entry in listed {
            try Task.checkCancellation()
            let read: SyncHeadRead?
            do {
                read = try await store.readHead(bookKey: entry.bookKey)
            } catch SyncError.newerFormatVersion(let version) {
                throw SyncEngineError.formatTooNew(formatVersion: version)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            guard let head = read?.head, head.isDeleted, !head.isTombstone, let deletedAt = head.deletedAt,
                  deletedAt > cutoff else { continue }
            if let highest = try? versions.highestVersion(bookKey: entry.bookKey), highest > head.version { continue }
            result.append(SyncDeletedBook(bookKey: entry.bookKey, title: head.book.title, deletedAt: deletedAt,
                                          deviceID: head.deviceID, deviceName: head.deviceName, version: head.version))
        }
        return result.sorted { $0.deletedAt != $1.deletedAt ? $0.deletedAt > $1.deletedAt : $0.bookKey < $1.bookKey }
    }

    /// Restores a deleted book: its head becomes live again (one version above the highest seen,
    /// as the rollback guard requires), carrying the content it had when it was deleted, so it
    /// arrives on every device through the normal round; on this device it is made at once (a
    /// round for that book alone). Throws `SyncRestoreError` when it cannot be restored (nothing
    /// changed), `joinConfirmationRequired` before this device has joined, `roundInProgress`.
    /// Returns what the round did with the book here.
    @discardableResult
    public func restoreDeleted(bookKey key: String, mode: SyncMode = .full) async throws -> SyncBookReport? {
        guard !running else { throw SyncEngineError.roundInProgress }
        running = true
        defer { running = false }
        guard mode == .full else { throw SyncRestoreError.needsFullAccess }
        if try needsJoinConfirmation() { throw SyncEngineError.joinConfirmationRequired }
        var restored = false
        for _ in 1...maxAttempts where !restored {
            try Task.checkCancellation()
            // Not deleted (any more): restored on another device, or edited back; the next
            // round brings it here like any book.
            guard let read = try await readForRestore(key), read.head.isDeleted else { throw SyncRestoreError.notDeleted }
            guard !read.head.isTombstone else { throw SyncRestoreError.noLongerRestorable }
            guard try await contentIsPresent(read.head) else { throw SyncRestoreError.contentGone }
            let version = max(try versions.highestVersion(bookKey: key) ?? 0, read.head.version) + 1
            var head = read.head
            head.formatVersion = SyncFormat.formatVersion
            head.writerLevel = SyncFormat.ordinaryHeadLevel
            head.version = version
            head.previousVersion = read.head.version
            head.writeID = SyncHead.makeWriteID()
            head.deviceID = device.id
            head.deviceName = device.name
            head.modifiedAt = now()
            head.deletedAt = nil
            do {
                _ = try await store.writeHead(head, bookKey: key, condition: .ifMatch(eTag: read.eTag))
                restored = true
            } catch let error where !(error is CancellationError) {
                switch try await store.reconcileHeadWrite(bookKey: key, writeID: head.writeID) {
                case .committed: restored = true
                case .notCommitted: continue   // changed meanwhile (tombstoned, restored, edited): read again
                }
            }
            if restored { try versions.record(bookKey: key, version: version) }
        }
        guard restored else { throw SyncError.preconditionFailed(key: try SyncLayout.headKey(bookKey: key)) }
        let report = try await roundForBooks([key], mode: .full)
        return report.books.first { $0.bookKey == key }
    }

    /// The book's head, checked (format, writer level, rollback), for a restore.
    private func readForRestore(_ key: String) async throws -> SyncHeadRead? {
        let read: SyncHeadRead?
        do {
            read = try await store.readHead(bookKey: key)
        } catch SyncError.newerFormatVersion(let version) {
            throw SyncEngineError.formatTooNew(formatVersion: version)
        }
        guard let read else { return nil }
        switch read.head.access() {
        case .formatTooNew(let version): throw SyncEngineError.formatTooNew(formatVersion: version)
        case .readOnly(let level): throw SyncRestoreError.needsNewerApp(requiredLevel: level)
        case .readAndPush: break
        }
        try versions.accept(bookKey: key, version: read.head.version)
        return read
    }

    /// Whether everything the head names is in the account: its records, files and PDF.
    func contentIsPresent(_ head: SyncHead) async throws -> Bool {
        guard !head.references.isEmpty else { return false }
        for content in head.references.blobs {
            if try await !store.hasBlob(content) { return false }
        }
        return try await store.hasPDF(head.references.pdf)
    }

    // MARK: Earlier versions

    /// The earlier versions of a book that history keeps, newest first: at most `limit`, and of
    /// a run of versions written close together (less than `spacing` apart, by when each was
    /// replaced) only the last, which is how the book stood when the reader paused. Versions
    /// that were deletions, and any not older than the current head, are left out; a version
    /// whose records are gone is listed without a summary. One that does not open is left out.
    public func versions(bookKey key: String, limit: Int = 60, spacing: TimeInterval = 15 * 60) async throws -> [SyncBookVersion] {
        let current: SyncHeadRead?
        do {
            current = try await store.readHead(bookKey: key)
        } catch SyncError.newerFormatVersion(let version) {
            throw SyncEngineError.formatTooNew(formatVersion: version)
        }
        let currentVersion = current?.head.version ?? .max
        var chosen: [SyncHistoryListing] = []
        for entry in try await store.history(bookKey: key).reversed() where entry.version < currentVersion {
            if let last = chosen.last, let lastDate = last.lastModified, let date = entry.lastModified,
               lastDate.timeIntervalSince(date) < spacing {
                continue
            }
            chosen.append(entry)
        }
        var result: [SyncBookVersion] = []
        for entry in chosen {
            guard result.count < max(1, limit) else { break }
            try Task.checkCancellation()
            let head: SyncHead
            do {
                guard let read = try await store.readHistory(bookKey: key, version: entry.version) else { continue }
                head = read
            } catch SyncError.newerFormatVersion(let version) {
                throw SyncEngineError.formatTooNew(formatVersion: version)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            guard !head.isDeleted else { continue }
            var summary: SyncContentSummary?
            if let archive = try? await records(of: head) {
                summary = SyncContentSummary(archive: archive, inkedPages: head.references.pageInk.count)
            }
            result.append(SyncBookVersion(version: head.version, modifiedAt: head.modifiedAt, replacedAt: entry.lastModified,
                                          deviceID: head.deviceID, deviceName: head.deviceName, title: head.book.title,
                                          summary: summary))
        }
        return result
    }

    /// Makes an earlier version's content the book's content on this device again: its notes,
    /// highlights, bookmarks, headings, title and ink (the reading position stays as it is). It
    /// is written as an ordinary local change, so the next round carries it, with the removals
    /// it implies, to the account and the other devices like any edit; nothing in the account
    /// is written here and history is not touched.
    ///
    /// All of the version's content is fetched and checked first (`contentGone` if any is
    /// missing, nothing changed). The book must not be busy (`bookBusy`). `beforeApply` runs just
    /// before the change is written, with what will change (the app takes its safety copy
    /// there); if it throws, nothing is changed. The write is refused (`bookChanged`) if the book
    /// changed since it was read. Returns the plan that was applied, or `nil` when the version
    /// is the book as it is now.
    @discardableResult
    public func restoreVersion(bookKey key: String, version: Int,
                               beforeApply: @Sendable (SyncVersionRestorePlan) async throws -> Void) async throws
        -> SyncVersionRestorePlan? {
        guard !running else { throw SyncEngineError.roundInProgress }
        running = true
        defer { running = false }
        let entry: SyncHead?
        do {
            entry = try await store.readHistory(bookKey: key, version: version)
        } catch SyncError.newerFormatVersion(let format) {
            throw SyncEngineError.formatTooNew(formatVersion: format)
        }
        guard let entry, !entry.isDeleted else { throw SyncRestoreError.versionNotFound }
        if case .readOnly(let level) = entry.access() { throw SyncRestoreError.needsNewerApp(requiredLevel: level) }

        // Everything the version needs, in hand before anything changes.
        let remote: BookArchive
        var files: [SyncFileKey: Data] = [:]
        do {
            remote = try await records(of: entry)
            for (fileKey, content) in entry.references.fileDigests { files[fileKey] = try await store.blob(content) }
        } catch let error as SyncError {
            switch error {
            case .objectNotFound, .objectDamaged, .contentMismatch, .objectTooLarge: throw SyncRestoreError.contentGone
            default: throw error
            }
        }

        var localID: UUID?
        for book in try await library.books() where try store.bookKey(pdfSHA256: book.pdf.sha256) == key {
            if localID == nil || book.bookID.uuidString < localID!.uuidString { localID = book.bookID }
        }
        guard let localID, let snapshot = try await library.snapshot(bookID: localID) else {
            throw SyncRestoreError.bookNotOnThisDevice
        }
        guard snapshot.busy.isEmpty else { throw SyncRestoreError.bookBusy }

        var target = BookMerge.rekeyed(remote, to: localID)
        var book = snapshot.archive.book
        book.title = remote.book.title
        target.book = book
        target = BookMerge.canonicalOrder(target)
        let targetFiles = entry.references.fileDigests
        var toWrite: [SyncFileKey: Data] = [:]
        var toRemove = Set<SyncFileKey>()
        for fileKey in Set(targetFiles.keys).union(snapshot.files.keys) where targetFiles[fileKey] != snapshot.files[fileKey] {
            if let data = files[fileKey] { toWrite[fileKey] = data } else { toRemove.insert(fileKey) }
        }
        let change = SyncLocalChange(archive: target, records: BookArchiveDiff(from: snapshot.archive, to: target),
                                     headingIDRemap: [:], noteDecisions: [], filesToWrite: toWrite, filesToRemove: toRemove)
        guard !change.isEmpty else { return nil }
        let plan = SyncVersionRestorePlan(
            bookID: localID, bookKey: key, version: version,
            current: SyncContentSummary(archive: snapshot.archive,
                                        inkedPages: snapshot.files.keys.filter { if case .pageInk = $0 { true } else { false } }.count),
            restored: SyncContentSummary(archive: target, inkedPages: entry.references.pageInk.count))
        try await beforeApply(plan)
        do {
            try await library.apply(change, bookID: localID, snapshotToken: snapshot.token)
        } catch SyncLibraryError.changedSinceSnapshot {
            throw SyncRestoreError.bookChanged
        }
        return plan
    }
}
