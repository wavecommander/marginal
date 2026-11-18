import Foundation
import ReaderBackup
import ReaderCore

/// Brings one device's library and the account's `Sync/v1` folder into agreement, one round at
/// a time (`docs/CLOUD_SYNC_PLAN.md` "Sync").
///
/// **Before a round** the app has checked the key against the account
/// (`EncryptedBackupDestination.checkKey()`): with a wrong key every object reads as damaged.
/// The engine's directory is `Application Support/Sync/<account>/`; it holds the bases
/// (`bases/`), the highest head version seen per book (`versions/`), intent records
/// (`intents/`), the heads that need nothing here (`seen.json`) and the join mark (`joined`).
///
/// **A round** (`sync(mode:joinConfirmed:)`):
/// 1. One listing of `Sync/v1/books/`. A device with no bases that has never joined stops here
///    with `joinConfirmationRequired` unless the caller confirmed the join.
/// 2. Every head whose ETag is not the one this device last agreed (its base's, or the seen
///    one) is read. A head in a newer format stops the round (`formatTooNew`) before anything
///    has changed.
/// 3. Book by book, in key order. A book whose head ETag is its base's and that has not changed
///    here is skipped. Otherwise: the head is read (the rollback guard refuses an older version
///    than seen; a newer app's head is pulled but never pushed), its records blob fetched, and
///    the book merged three-way with `BookMerge.merge(local:remote:base:)` (add-only when there
///    is no base: a join), files three-way by content (an ink merge where both changed, against
///    the base ink fetched from the account, or as a union when it is gone). Busy surfaces keep
///    this device's version here, the account's version in the head, and the old base's in the
///    base, so the next round sees both sides' changes to them.
/// 4. To push: new blobs are uploaded (a new book's PDF once) under the reuse rule (an existing
///    blob older than a day is written again, `SyncHousekeeping`), the blobs kept from the head
///    being replaced are checked at most once a day (and any missing one this device holds is
///    uploaded), the superseded head goes to history, an intent record is written, and the head
///    is written with `ifMatch` the ETag read (`ifAbsent` for a new book) and a fresh write ID
///    (after checking the uploads again if more than an hour has passed). On a refusal or an
///    ambiguous failure the write ID is reconciled: if the head is not ours, the intent is
///    dropped and the book starts again from scratch (a fresh snapshot of the untouched local
///    copy and the old base).
/// 5. The change is applied here (guarded by the snapshot: if the book changed meanwhile, the
///    book is computed again, and the intent record says what base to use), then the base
///    moves, then the intent record is removed.
///
/// A round can be cancelled or cut off anywhere. Blobs are content-named, so uploading again is
/// harmless; a head write is reconciled by its write ID; and between the head write and the base
/// moving, the intent record (`SyncApplyIntent`) lets the next round finish exactly where this
/// one stopped. Making, deleting and marking a book deleted need no intent: each is followed by
/// one base change, and the next round reaches the same state from either side of it.
///
/// **Modes.** `.pullOnly` writes nothing to the account: changes from the account are applied,
/// this device's changes wait. A book written by a newer app is treated so in every mode.
///
/// **Deleted books** (C5). A deleted head keeps the book's content for 30 days: Recently Deleted
/// lists it and `restoreDeleted` brings it back (`SyncRecovery.swift`); then housekeeping makes it
/// a tombstone (`SyncHead.isTombstone`), which still deletes an unchanged copy here, while an
/// edited copy goes back up as it is. History, earlier versions and housekeeping are in
/// `SyncRecovery.swift` and `SyncHousekeeping.swift`; none of them runs during a round.
public actor SyncEngine {
    /// The device as heads name it.
    public struct Device: Hashable, Sendable {
        public var id: UUID
        public var name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The account's sync objects.
    public let store: EncryptedSyncStore
    let library: any SyncLibrary
    let inkMerger: any SyncInkMerger
    let directory: URL
    let bases: SyncBaseStore
    let versions: SyncRollbackGuard
    let state: SyncEngineState
    let device: Device
    let now: @Sendable () -> Date
    /// How many times a book is computed again in one round (lost races, refused applies)
    /// before it is reported as failed for this round.
    let maxAttempts: Int

    var running = false
    private var stepHook: (@Sendable (SyncStep) async throws -> Void)?
    private var housekeepingHook: (@Sendable (SyncHousekeepingStep) async throws -> Void)?
    /// The latest last-modified time any listing has shown: the store's clock is at least this,
    /// so a device whose own clock is behind still judges a blob's age conservatively.
    var storeTimeHint: Date?
    /// Blobs this engine checked are in the account, by SHA-256, with when (this device's
    /// clock): a push re-checks the ones it relies on without uploading at most once a day
    /// (`SyncHousekeeping.verifyInterval`), and uploads any that went missing.
    var verifiedBlobs: [String: Date] = [:]
    /// The bases on disk by book key (normally one each), kept in step during a round.
    private var baseIDs: [String: Set<UUID>] = [:]
    /// The bases on disk, read once and then kept in step (only this engine writes them).
    private var baseCache: [UUID: SyncBase]?

    public init(store: EncryptedSyncStore, library: any SyncLibrary, inkMerger: any SyncInkMerger, directory: URL,
                device: Device, now: @escaping @Sendable () -> Date = { Date() }, maxAttempts: Int = 6) {
        self.store = store
        self.library = library
        self.inkMerger = inkMerger
        self.directory = directory
        self.bases = SyncBaseStore(root: directory.appendingPathComponent("bases", isDirectory: true))
        self.versions = SyncRollbackGuard(directory: directory.appendingPathComponent("versions", isDirectory: true))
        self.state = SyncEngineState(directory: directory)
        self.device = device
        self.now = now
        self.maxAttempts = max(1, maxAttempts)
    }

    /// Called between the steps of a round; an error it throws ends the round with that error
    /// (tests use it to cut a round off between steps).
    func setStepHook(_ hook: (@Sendable (SyncStep) async throws -> Void)?) {
        stepHook = hook
    }

    /// Called between housekeeping's steps (tests interleave another device's work there, or
    /// cut the run off by throwing).
    func setHousekeepingHook(_ hook: (@Sendable (SyncHousekeepingStep) async throws -> Void)?) {
        housekeepingHook = hook
    }

    func housekeepingStep(_ step: SyncHousekeepingStep) async throws {
        try Task.checkCancellation()
        try await housekeepingHook?(step)
    }

    /// The store's time as well as this device can tell it: its own clock, or the latest date a
    /// listing showed when that is later.
    func estimatedStoreTime() -> Date {
        max(now(), storeTimeHint ?? .distantPast)
    }

    func noteListing(_ dates: [Date?]) {
        if let latest = dates.compactMap({ $0 }).max(), latest > (storeTimeHint ?? .distantPast) { storeTimeHint = latest }
    }

    // MARK: Join

    /// Whether the next round needs `joinConfirmed`: this device has no bases and has never
    /// joined the account.
    public func needsJoinConfirmation() throws -> Bool {
        try bases.bookIDs().isEmpty && !state.hasJoined
    }

    /// What a join would find: books only here, only in the account (not deleted), and on both.
    public func joinPreview() async throws -> SyncJoinPreview {
        var here = Set<String>()
        for book in try await library.books() { here.insert(try store.bookKey(pdfSHA256: book.pdf.sha256)) }
        var live = Set<String>()
        for listed in try await store.listHeads() {
            do {
                if let read = try await store.readHead(bookKey: listed.bookKey), !read.head.isDeleted { live.insert(listed.bookKey) }
            } catch SyncError.newerFormatVersion(let version) {
                throw SyncEngineError.formatTooNew(formatVersion: version)
            }
        }
        return SyncJoinPreview(onlyHere: here.subtracting(live).count, onlyInAccount: live.subtracting(here).count,
                               inBoth: here.intersection(live).count)
    }

    // MARK: PDFs

    /// Downloads the book's PDF from the account and installs it (the app decides when:
    /// `docs/CLOUD_SYNC_PLAN.md` decision 5). Nothing happens when it is already here.
    public func downloadPDF(bookID: UUID) async throws {
        guard let snapshot = try await library.snapshot(bookID: bookID) else {
            throw SyncLibraryError.bookNotFound(bookID: bookID)
        }
        guard snapshot.pdfFile == nil else { return }
        let folder = directory.appendingPathComponent("tmp", isDirectory: true)
        try mappingFileErrors(folder) { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let file = folder.appendingPathComponent("\(UUID().uuidString).pdf", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: file) }
        try await store.downloadPDF(snapshot.pdf, to: file)
        try await library.installPDF(bookID: bookID, from: file, content: snapshot.pdf)
    }

    // MARK: Round

    /// Runs one round. Throws `joinConfirmationRequired`, `formatTooNew` or `roundInProgress`
    /// (nothing changed), the store's error when the listing fails, or `CancellationError`;
    /// a failure with one book is reported in the result and the round goes on.
    public func sync(mode: SyncMode = .full, joinConfirmed: Bool = false) async throws -> SyncReport {
        guard !running else { throw SyncEngineError.roundInProgress }
        running = true
        defer { running = false }
        do {
            return try await round(mode: mode, joinConfirmed: joinConfirmed, only: nil)
        } catch let abort as HookAbort {
            throw abort.error
        }
    }

    /// A round limited to the books `keys` (after restoring one from Recently Deleted). The
    /// caller holds `running`.
    func roundForBooks(_ keys: Set<String>, mode: SyncMode) async throws -> SyncReport {
        do {
            return try await round(mode: mode, joinConfirmed: false, only: keys)
        } catch let abort as HookAbort {
            throw abort.error
        }
    }

    private struct RoundContext {
        var mode: SyncMode
        var localIDs: Set<UUID>
        var listing: [String: SyncHeadListing]
        var prefetched: [String: Result<SyncHeadRead?, any Error>]
        var seen: [String: String]
    }

    private enum Outcome {
        case done(SyncBookReport?)
        /// Compute the book again, from this base.
        case retry(base: SyncBase?)
    }

    private struct HookAbort: Error {
        let error: any Error
    }

    func step(_ step: SyncStep) async throws {
        try Task.checkCancellation()
        guard let hook = stepHook else { return }
        do {
            try await hook(step)
        } catch {
            throw HookAbort(error: error)
        }
    }

    private func round(mode: SyncMode, joinConfirmed: Bool, only: Set<String>?) async throws -> SyncReport {
        try await step(.roundStarted)
        let books = try await library.books()
        var localByKey: [String: [UUID]] = [:]
        for book in books { localByKey[try store.bookKey(pdfSHA256: book.pdf.sha256), default: []].append(book.bookID) }
        for key in localByKey.keys { localByKey[key]!.sort { $0.uuidString < $1.uuidString } }
        let basesByKey = try loadBases(localByKey: localByKey)
        let intentKeys = try state.intentKeys()
        let listed = try await store.listHeads()
        noteListing(listed.map(\.lastModified))
        let listing = Dictionary(listed.map { ($0.bookKey, $0) }, uniquingKeysWith: { a, _ in a })

        if basesByKey.isEmpty && !state.hasJoined {
            if localByKey.isEmpty && listing.isEmpty && intentKeys.isEmpty { return SyncReport(mode: mode) }
            guard joinConfirmed else { throw SyncEngineError.joinConfirmationRequired }
            try state.markJoined()
        }

        var context = RoundContext(mode: mode, localIDs: Set(books.map(\.bookID)), listing: listing, prefetched: [:],
                                   seen: state.seen().filter { listing[$0.key] != nil })
        let seenBefore = state.seen()

        // Every head that changed since this device last agreed with it, before anything changes:
        // a newer format stops the round here.
        for (key, listed) in listing.sorted(by: { $0.key < $1.key }) where only?.contains(key) ?? true {
            let known = basesByKey[key]?.headETag ?? context.seen[key]
            guard known != listed.eTag || intentKeys.contains(key) else { continue }
            try Task.checkCancellation()
            do {
                context.prefetched[key] = .success(try await store.readHead(bookKey: key))
            } catch SyncError.newerFormatVersion(let version) {
                throw SyncEngineError.formatTooNew(formatVersion: version)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                context.prefetched[key] = .failure(error)
            }
        }

        var report = SyncReport(mode: mode)
        let keys = Set(localByKey.keys).union(basesByKey.keys).union(listing.keys).union(intentKeys).sorted()
        for key in keys where only?.contains(key) ?? true {
            try Task.checkCancellation()
            let ids = localByKey[key] ?? []
            for duplicate in ids.dropFirst() {
                report.books.append(SyncBookReport(bookKey: key, bookID: duplicate, skipped: [.duplicatePDF(of: ids[0])]))
            }
            do {
                if let book = try await syncBook(key: key, localID: ids.first, base: basesByKey[key], context: &context) {
                    report.books.append(book)
                } else {
                    report.upToDate += 1
                }
            } catch let abort as HookAbort {
                throw abort
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SyncEngineError {
                throw error
            } catch SyncError.newerFormatVersion(let version) {
                throw SyncEngineError.formatTooNew(formatVersion: version)
            } catch {
                report.books.append(SyncBookReport(bookKey: key, bookID: ids.first, failure: SyncBookFailure(error)))
            }
        }
        if context.seen != seenBefore { try state.saveSeen(context.seen) }
        return report
    }

    /// The bases by book key, preferring one whose book is the local book with that key.
    private func loadBases(localByKey: [String: [UUID]]) throws -> [String: SyncBase] {
        if baseCache == nil {
            var cache: [UUID: SyncBase] = [:]
            for id in try bases.bookIDs() {
                // A base that cannot be read counts as none: the book joins again, add-only.
                if let base = (try? bases.base(bookID: id)) ?? nil { cache[id] = base }
            }
            baseCache = cache
        }
        baseIDs = [:]
        var result: [String: SyncBase] = [:]
        for (id, base) in (baseCache ?? [:]).sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            baseIDs[base.bookKey, default: []].insert(id)
            if let existing = result[base.bookKey], localByKey[base.bookKey]?.first == existing.archive.book.id { continue }
            if result[base.bookKey] == nil || localByKey[base.bookKey]?.first == id { result[base.bookKey] = base }
        }
        return result
    }

    private func saveBase(_ base: SyncBase) throws {
        let id = base.archive.book.id
        try keepingCache {
            try bases.replace(base)
            baseCache?[id] = base
            for other in baseIDs[base.bookKey, default: []] where other != id {
                try bases.remove(bookID: other)
                baseCache?[other] = nil
            }
        }
        baseIDs[base.bookKey] = [id]
    }

    private func removeBases(_ key: String) throws {
        try keepingCache {
            for id in baseIDs[key, default: []] {
                try bases.remove(bookID: id)
                baseCache?[id] = nil
            }
        }
        baseIDs[key] = nil
    }

    /// Runs a change to the bases on disk; if it fails part-way, the cache is dropped and read
    /// again from disk next round.
    private func keepingCache(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            baseCache = nil
            throw error
        }
    }

    // MARK: One book

    private func syncBook(key: String, localID: UUID?, base storedBase: SyncBase?,
                          context: inout RoundContext) async throws -> SyncBookReport? {
        var base = storedBase
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            if let intent = try state.intent(bookKey: key) {
                base = try await recover(intent, mode: context.mode)
            }
            let first = attempt == 1
            let outcome: Outcome
            if let localID, let snapshot = try await library.snapshot(bookID: localID) {
                outcome = try await syncPresent(key: key, snapshot: snapshot, base: base, first: first, context: &context)
            } else {
                outcome = try await syncAbsent(key: key, base: base, first: first, context: &context)
            }
            switch outcome {
            case .done(let report): return report
            case .retry(let next): base = next
            }
        }
        // Another device kept winning, or the book kept changing here: next round.
        throw SyncError.preconditionFailed(key: try SyncLayout.headKey(bookKey: key))
    }

    /// The book's head for this attempt, checked against the rollback guard.
    private func head(_ key: String, first: Bool, context: RoundContext) async throws -> SyncHeadRead? {
        let read: SyncHeadRead?
        if first, let prefetched = context.prefetched[key] {
            read = try prefetched.get()
        } else if first, context.listing[key] == nil {
            read = nil
        } else {
            read = try await store.readHead(bookKey: key)
        }
        if let read {
            if case .formatTooNew(let version) = read.head.access() { throw SyncEngineError.formatTooNew(formatVersion: version) }
            try versions.accept(bookKey: key, version: read.head.version)
        }
        return read
    }

    private func unchanged(_ snapshot: SyncLocalSnapshot, since base: SyncBase) -> Bool {
        snapshot.files == base.files.digests && SyncPlanning.sameContent(base.archive, snapshot.archive)
    }

    /// A book this device has.
    private func syncPresent(key: String, snapshot: SyncLocalSnapshot, base: SyncBase?, first: Bool,
                             context: inout RoundContext) async throws -> Outcome {
        let id = snapshot.archive.book.id
        if first, let base, let listed = context.listing[key], listed.eTag == base.headETag, unchanged(snapshot, since: base) {
            return .done(nil)
        }
        let read = try await head(key, first: first, context: context)
        var readOnlyLevel: Int?
        if let read, case .readOnly(let level) = read.head.access() { readOnlyLevel = level }
        let canPush = context.mode == .full && readOnlyLevel == nil
        let hold: SyncSkipReason = readOnlyLevel.map { .readOnly(requiredLevel: $0) } ?? .pullOnly

        var report = SyncBookReport(bookKey: key, bookID: id)
        let remote: BookArchive
        let remoteFiles: SyncFileDigests
        let mergeBase: SyncBase?
        var forcePush = false
        let condition: SyncWriteCondition
        if let read, !read.head.isDeleted {
            remote = try await records(of: read.head)
            remoteFiles = read.head.references.fileDigests
            mergeBase = base
            condition = .ifMatch(eTag: read.eTag)
        } else if let read, let base {
            // Deleted on another device. Unchanged here since: delete it here too (not while the
            // reader is working in it).
            if unchanged(snapshot, since: base) {
                guard snapshot.busy.isEmpty else {
                    report.skipped = [.busy(sortedSurfaces(snapshot.busy))]
                    return .done(report)
                }
                do {
                    try await library.deleteBook(bookID: id, snapshotToken: snapshot.token)
                } catch SyncLibraryError.changedSinceSnapshot {
                    return .retry(base: base)
                }
                try await step(.changedBook(bookKey: key))
                try removeBases(key)
                report.action = .deletedHere
                return .done(report)
            }
            // Edited here since: the edit wins and the book goes back to the account, merged with
            // what the account had when it was deleted.
            guard canPush else {
                report.skipped = [hold]
                return .done(report)
            }
            if let content = try await contentOfDeletedHead(read.head) {
                remote = content
                remoteFiles = read.head.references.fileDigests
                mergeBase = base
            } else {
                // Deleted so long ago that its content is gone (a tombstone): there is nothing
                // to merge with, so this device's copy goes back up as it is, add-only.
                remote = BookArchive(book: snapshot.archive.book)
                remoteFiles = [:]
                mergeBase = nil
            }
            forcePush = true
            condition = .ifMatch(eTag: read.eTag)
            report.action = .keptOverDeletionInAccount
        } else {
            // Not in the account (or deleted there, and never synced here): this device's copy
            // goes up as it is. A book with no base is never deleted here.
            guard canPush else {
                report.skipped = [hold]
                return .done(report)
            }
            if read == nil, base != nil {
                // The head this base agreed with is gone (the account was emptied, say): the base
                // is no ancestor of anything now. Without it, a head another device makes
                // meanwhile is joined add-only.
                try removeBases(key)
                return .retry(base: nil)
            }
            remote = BookArchive(book: snapshot.archive.book)
            remoteFiles = [:]
            mergeBase = nil
            forcePush = true
            condition = read.map { .ifMatch(eTag: $0.eTag) } ?? .ifAbsent
            report.action = read == nil ? .uploadedNew : .keptOverDeletionInAccount
        }

        let busyPages = Set(snapshot.busy.compactMap { surface -> Int? in if case .page(let page) = surface { page } else { nil } })
        guard let plan = SyncPlanning.recordPlan(local: snapshot.archive, remote: remote, base: mergeBase?.archive,
                                                 busy: snapshot.busy) else {
            report.action = .unchanged
            report.skipped = [.busy(sortedSurfaces(snapshot.busy))]
            return .done(report)
        }
        let baseFiles = mergeBase?.files.digests
        var cache: [ContentDigest: Data] = [:]
        var merged: SyncFileDigests = [:]
        let resolutions = SyncPlanning.filePlan(plan, local: snapshot.files, remote: remoteFiles, base: baseFiles,
                                                busyPages: busyPages)
        for (fileKey, resolution) in resolutions.sorted(by: { $0.key < $1.key }) {
            switch resolution {
            case .content(let content):
                merged[fileKey] = content
            case .merge(let job):
                merged[fileKey] = try await runInk(job, snapshot: snapshot, cache: &cache)
            }
        }
        let sliceNotes = plan.slice.ids
        let targetFiles = SyncPlanning.replacingBusy(merged, pages: busyPages, notes: sliceNotes, with: snapshot.files)
        let pushFiles = SyncPlanning.replacingBusy(merged, pages: busyPages, notes: sliceNotes, with: remoteFiles)
        let needsPush = forcePush || !SyncPlanning.sameContent(remote, plan.push) || pushFiles != remoteFiles
        let pushing = needsPush && canPush
        if needsPush && !canPush { report.skipped.append(hold) }
        if heldBack(plan, targetFiles: targetFiles, pushFiles: pushFiles, busyPages: busyPages) {
            report.skipped.append(.busy(sortedSurfaces(snapshot.busy)))
        }

        let accountArchive = pushing ? plan.push : remote
        let accountFiles = pushing ? pushFiles : remoteFiles
        let newBaseArchive = SyncPlanning.baseArchive(accountAfter: accountArchive, oldBase: mergeBase?.archive,
                                                      slice: plan.slice, localBook: snapshot.archive.book)
        let newBaseFiles = SyncPlanning.replacingBusy(accountFiles, pages: busyPages, notes: sliceNotes, with: baseFiles)
        // A base that keeps a busy surface as the old base had it is not the head's as a whole:
        // it must not let a later round skip the book as up to date (the account's version of
        // that surface would then never arrive).
        let baseIsWhole = newBaseFiles == accountFiles && SyncPlanning.sameContent(newBaseArchive, accountArchive)

        // What changes here, with every byte in hand before anything is written.
        var toWrite: [SyncFileKey: Data] = [:]
        var toRemove = Set<SyncFileKey>()
        for fileKey in Set(targetFiles.keys).union(snapshot.files.keys) where targetFiles[fileKey] != snapshot.files[fileKey] {
            if let content = targetFiles[fileKey] {
                toWrite[fileKey] = try await bytes(content, snapshot: snapshot, cache: &cache)
            } else {
                toRemove.insert(fileKey)
            }
        }
        let change = SyncLocalChange(archive: plan.target, records: BookArchiveDiff(from: snapshot.archive, to: plan.target),
                                     headingIDRemap: plan.merge.headingIDRemap,
                                     noteDecisions: plan.merge.noteDecisions.filter { !sliceNotes.contains($0.noteID) },
                                     filesToWrite: toWrite, filesToRemove: toRemove)
        let applying = !change.isEmpty
        if report.action == .unchanged {
            if mergeBase == nil { report.action = .joined }
            else if applying && pushing { report.action = .merged }
            else if applying { report.action = .pulled }
            else if pushing { report.action = .pushed }
        }

        guard pushing || applying else {
            // Nothing to write anywhere; the base may still move (a head that changes nothing here).
            if let read {
                let newBase = SyncBase(bookKey: key, headVersion: read.head.version,
                                       headETag: baseIsWhole ? read.eTag : SyncPlanning.unmatchedETag,
                                       archive: newBaseArchive, files: SyncBaseFiles(digests: newBaseFiles))
                if newBase != base { try saveBase(newBase) }
            }
            return .done(report)
        }

        var intent: SyncApplyIntent
        let version: Int
        let eTag: String
        if pushing {
            let recordsData = try SyncRecords.encode(BookMerge.canonicalOrder(plan.push))
            let recordsContent = ContentDigest(of: recordsData)
            // The content the head will name, uploaded (or confirmed fresh) shortly before the
            // head is written; if the push is held up for long (the app suspended mid-round), it
            // is checked again just before the head write, so housekeeping cannot have taken it.
            try await uploadContent(key: key, read: read, snapshot: snapshot, recordsData: recordsData,
                                    recordsContent: recordsContent, pushFiles: pushFiles, remoteFiles: remoteFiles,
                                    cache: &cache)
            let uploadedAt = now()
            try await step(.uploadedContent(bookKey: key))
            // The superseded head goes to history before it is replaced, so that whenever a head
            // is seen replaced its predecessor is already in history (housekeeping lists heads,
            // then history, and keeps what either refers to). A lost race leaves a history entry
            // equal to the live head, which is harmless and listed nowhere.
            if let superseded = read?.head, !superseded.isTombstone { try await store.writeHistory(superseded, bookKey: key) }

            version = max(try versions.highestVersion(bookKey: key) ?? 0, read?.head.version ?? 0) + 1
            let head = SyncHead(version: version, previousVersion: read?.head.version, deviceID: device.id,
                                deviceName: device.name, modifiedAt: now(),
                                book: info(plan.push.book, previous: read?.head.book),
                                references: SyncReferences(records: recordsContent, pdf: snapshot.pdf, files: pushFiles))
            intent = SyncApplyIntent(bookKey: key, bookID: id, writeID: head.writeID, committedETag: nil, headVersion: version,
                                     supersededHead: read?.head, oldBase: base,
                                     newBase: SyncContent(archive: newBaseArchive, files: newBaseFiles),
                                     oldLocal: SyncContent(archive: snapshot.archive, files: snapshot.files),
                                     target: SyncContent(archive: plan.target, files: targetFiles),
                                     newBaseIsPartial: baseIsWhole ? nil : true)
            try state.save(intent)
            try await step(.wroteIntent(bookKey: key))
            if !Self.isRecent(uploadedAt, now: now()) {
                try await uploadContent(key: key, read: read, snapshot: snapshot, recordsData: recordsData,
                                        recordsContent: recordsContent, pushFiles: pushFiles, remoteFiles: remoteFiles,
                                        cache: &cache)
            }
            do {
                eTag = try await store.writeHead(head, bookKey: key, condition: condition)
            } catch let error where !(error is CancellationError) && !(error is HookAbort) {
                // Refused, or no answer: the write ID says whose head is there now.
                switch try await store.reconcileHeadWrite(bookKey: key, writeID: head.writeID) {
                case .committed(let committed):
                    eTag = committed
                case .notCommitted:
                    // Another device got there first: start again from the untouched copy here
                    // and the same base.
                    try state.removeIntent(bookKey: key)
                    return .retry(base: base)
                }
            }
            intent.committedETag = eTag
            try state.save(intent)
            try versions.record(bookKey: key, version: version)
            try await step(.wroteHead(bookKey: key))
            try await step(.wroteHistory(bookKey: key))
        } else {
            // Not pushing means a live head was read (every other case pushes or returned).
            guard let read else { return .done(report) }
            version = read.head.version
            eTag = read.eTag
            intent = SyncApplyIntent(bookKey: key, bookID: id, writeID: nil, committedETag: eTag, headVersion: version,
                                     supersededHead: nil, oldBase: base,
                                     newBase: SyncContent(archive: newBaseArchive, files: newBaseFiles),
                                     oldLocal: SyncContent(archive: snapshot.archive, files: snapshot.files),
                                     target: SyncContent(archive: plan.target, files: targetFiles),
                                     newBaseIsPartial: baseIsWhole ? nil : true)
            try state.save(intent)
            try await step(.wroteIntent(bookKey: key))
        }

        if applying {
            do {
                try await library.apply(change, bookID: id, snapshotToken: snapshot.token)
            } catch SyncLibraryError.changedSinceSnapshot {
                // The intent record stays: the next attempt starts from the base it gives.
                return .retry(base: base)
            }
            try await step(.appliedLocally(bookKey: key))
        }
        try saveBase(SyncBase(bookKey: key, headVersion: version, headETag: baseIsWhole ? eTag : SyncPlanning.unmatchedETag,
                              archive: newBaseArchive, files: SyncBaseFiles(digests: newBaseFiles)))
        try await step(.movedBase(bookKey: key))
        try state.removeIntent(bookKey: key)
        return .done(report)
    }

    /// A book this device does not have (any more).
    private func syncAbsent(key: String, base: SyncBase?, first: Bool, context: inout RoundContext) async throws -> Outcome {
        guard let base else {
            // Only in the account: make it here, unless it is deleted there.
            if first, let listed = context.listing[key], context.seen[key] == listed.eTag { return .done(nil) }
            guard let read = try await head(key, first: first, context: context) else { return .done(nil) }
            if read.head.isDeleted {
                context.seen[key] = read.eTag
                return .done(nil)
            }
            let id = try await createHere(key: key, read: read, bookID: nil, context: &context)
            context.seen[key] = nil
            return .done(SyncBookReport(bookKey: key, bookID: id, action: .createdHere))
        }

        var report = SyncBookReport(bookKey: key, bookID: base.archive.book.id)
        let current = try await head(key, first: first, context: context)
        guard let read = current, !read.head.isDeleted else {
            // Gone from both, or deleted on both.
            try removeBases(key)
            if let current { context.seen[key] = current.eTag }
            return .done(nil)
        }
        if read.eTag != base.headETag {
            let remote = try await records(of: read.head)
            if !SyncPlanning.sameContent(base.archive, remote) || read.head.references.fileDigests != base.files.digests {
                // Edited in the account since this device last agreed with it: the edit wins.
                let id = try await createHere(key: key, read: read, bookID: base.archive.book.id, context: &context)
                return .done(SyncBookReport(bookKey: key, bookID: id, action: .restoredHere))
            }
        }
        // Deleted here: mark it deleted in the account.
        var readOnlyLevel: Int?
        if case .readOnly(let level) = read.head.access() { readOnlyLevel = level }
        guard context.mode == .full, readOnlyLevel == nil else {
            report.skipped = [readOnlyLevel.map { .readOnly(requiredLevel: $0) } ?? .pullOnly]
            return .done(report)
        }
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
        head.deletedAt = now()
        // History first, as for every write (see `syncPresent`).
        try await store.writeHistory(read.head, bookKey: key)
        do {
            _ = try await store.writeHead(head, bookKey: key, condition: .ifMatch(eTag: read.eTag))
        } catch let error where !(error is CancellationError) && !(error is HookAbort) {
            if case .notCommitted = try await store.reconcileHeadWrite(bookKey: key, writeID: head.writeID) {
                return .retry(base: base)
            }
        }
        try versions.record(bookKey: key, version: version)
        try await step(.wroteHead(bookKey: key))
        try await step(.wroteHistory(bookKey: key))
        try removeBases(key)
        try await step(.movedBase(bookKey: key))
        report.action = .deletedInAccount
        return .done(report)
    }

    /// Makes the account's book here (without its PDF) and sets its base; returns its ID.
    private func createHere(key: String, read: SyncHeadRead, bookID: UUID?, context: inout RoundContext) async throws -> UUID {
        let remote = try await records(of: read.head)
        var files: [SyncFileKey: Data] = [:]
        for (fileKey, content) in read.head.references.fileDigests { files[fileKey] = try await store.blob(content) }
        let id = bookID ?? (context.localIDs.contains(remote.book.id) ? UUID() : remote.book.id)
        var archive = BookMerge.rekeyed(remote, to: id)
        archive.book.id = id
        archive = BookMerge.canonicalOrder(archive)
        try await library.createBook(SyncNewBook(archive: archive, info: read.head.book, pdf: read.head.references.pdf,
                                                 files: files))
        context.localIDs.insert(id)
        try await step(.changedBook(bookKey: key))
        try saveBase(SyncBase(bookKey: key, headVersion: read.head.version, headETag: read.eTag, archive: archive,
                              files: SyncBaseFiles(read.head.references)))
        try await step(.movedBase(bookKey: key))
        return id
    }

    // MARK: Recovery

    /// Finishes what an interrupted round left in an intent record (`SyncApplyIntent`) and
    /// returns the book's base to go on from.
    private func recover(_ recorded: SyncApplyIntent, mode: SyncMode) async throws -> SyncBase? {
        var intent = recorded
        let key = intent.bookKey
        if intent.committedETag == nil {
            guard let writeID = intent.writeID else {
                try state.removeIntent(bookKey: key)
                return intent.oldBase
            }
            switch try await store.reconcileHeadWrite(bookKey: key, writeID: writeID) {
            case .committed(let eTag):
                intent.committedETag = eTag
                try state.save(intent)
                try versions.record(bookKey: key, version: intent.headVersion)
            case .notCommitted:
                // The head is not ours (never written, or already replaced before anything
                // here changed): nothing to finish.
                try state.removeIntent(bookKey: key)
                return intent.oldBase
            }
        }
        if mode == .full, let superseded = intent.supersededHead, !superseded.isTombstone {
            try await store.writeHistory(superseded, bookKey: key)
        }
        let snapshot = try await library.snapshot(bookID: intent.bookID)
        let base = SyncPlanning.effectiveBase(intent, local: snapshot)
        if let base { try saveBase(base) } else { try removeBases(key) }
        try state.removeIntent(bookKey: key)
        return base
    }

    // MARK: Content

    /// Puts in the account everything a new head will name: a new book's PDF, the records blob
    /// and every file blob the head being replaced does not already name, each under the reuse
    /// rule (an existing blob older than `SyncHousekeeping.reuseAge` is written again, so its
    /// date is fresh); and checks, at most once a day each, that the blobs it keeps from the head
    /// being replaced are still there, uploading from this device any that went missing (the
    /// repair after a blob was lost).
    private func uploadContent(key: String, read: SyncHeadRead?, snapshot: SyncLocalSnapshot, recordsData: Data,
                               recordsContent: ContentDigest, pushFiles: SyncFileDigests, remoteFiles: SyncFileDigests,
                               cache: inout [ContentDigest: Data]) async throws {
        let reuseAfter = estimatedStoreTime().addingTimeInterval(-SyncHousekeeping.reuseAge)
        if read == nil || read?.head.isDeleted == true, let file = snapshot.pdfFile {
            try await store.uploadPDF(fileAt: file, content: snapshot.pdf, reuseIfWrittenAfter: reuseAfter)
        }
        if recordsContent != read?.head.references.records {
            try await store.putBlob(recordsData, reuseIfWrittenAfter: reuseAfter)
            verifiedBlobs[recordsContent.sha256] = now()
        }
        let inAccount = Set(remoteFiles.values)
        for content in Set(pushFiles.values).subtracting(inAccount).sorted(by: { $0.sha256 < $1.sha256 }) {
            try await store.putBlob(try await bytes(content, snapshot: snapshot, cache: &cache), reuseIfWrittenAfter: reuseAfter)
            verifiedBlobs[content.sha256] = now()
        }
        // Kept from the head being replaced: still there? (Never trusted for more than a day.)
        var kept = Set(pushFiles.values).intersection(inAccount)
        if recordsContent == read?.head.references.records { kept.insert(recordsContent) }
        for content in kept.sorted(by: { $0.sha256 < $1.sha256 }) {
            if let checked = verifiedBlobs[content.sha256], Self.isRecent(checked, now: now(), within: SyncHousekeeping.verifyInterval) {
                continue
            }
            if try await !store.hasBlob(content) {
                let data: Data?
                if content == recordsContent {
                    data = recordsData
                } else if snapshot.files.values.contains(content) {
                    data = try? await bytes(content, snapshot: snapshot, cache: &cache)
                } else {
                    data = nil
                }
                // Missing, and not held here: the head being replaced already names it; the
                // device that holds it puts it back.
                guard let data else { continue }
                try await store.putBlob(data, reuseIfWrittenAfter: reuseAfter)
            }
            verifiedBlobs[content.sha256] = now()
        }
    }

    /// Whether `date` is within `interval` before `now` (and not after it: a clock that went
    /// back counts as stale).
    static func isRecent(_ date: Date, now: Date, within interval: TimeInterval = SyncHousekeeping.maximumPushSpan) -> Bool {
        let elapsed = now.timeIntervalSince(date)
        return elapsed >= 0 && elapsed <= interval
    }

    /// A deleted head's records, if its content is all still in the account; `nil` for a
    /// tombstone, or when any of it is gone (collected after 30 days).
    private func contentOfDeletedHead(_ head: SyncHead) async throws -> BookArchive? {
        guard !head.isTombstone else { return nil }
        let archive: BookArchive
        do {
            archive = try await records(of: head)
        } catch SyncError.objectNotFound {
            return nil
        }
        for content in head.references.fileDigests.values {
            if try await !store.hasBlob(content) { return nil }
        }
        return archive
    }

    func records(of head: SyncHead) async throws -> BookArchive {
        let data = try await store.blob(head.references.records)
        return try SyncRecords.decode(data, key: try store.blobKey(sha256: head.references.records.sha256))
    }

    /// Content by digest: from memory, else from this device's files (checked against the
    /// snapshot), else from the account.
    private func bytes(_ content: ContentDigest, snapshot: SyncLocalSnapshot,
                       cache: inout [ContentDigest: Data]) async throws -> Data {
        if let data = cache[content] { return data }
        let data: Data
        if let fileKey = snapshot.files.first(where: { $0.value == content })?.key {
            data = try await localBytes(fileKey, content, snapshot: snapshot)
        } else {
            data = try await store.blob(content)
        }
        cache[content] = data
        return data
    }

    private func localBytes(_ fileKey: SyncFileKey, _ content: ContentDigest, snapshot: SyncLocalSnapshot) async throws -> Data {
        let id = snapshot.archive.book.id
        guard let data = try await library.fileData(fileKey, bookID: id), ContentDigest(of: data) == content else {
            throw SyncLibraryError.changedSinceSnapshot(bookID: id)
        }
        return data
    }

    private func runInk(_ job: SyncInkJob, snapshot: SyncLocalSnapshot,
                        cache: inout [ContentDigest: Data]) async throws -> ContentDigest? {
        func optional(_ content: ContentDigest?, _ cache: inout [ContentDigest: Data]) async throws -> Data? {
            guard let content else { return nil }
            return try await bytes(content, snapshot: snapshot, cache: &cache)
        }
        let local = try await optional(job.local, &cache)
        let remote = try await optional(job.remote, &cache)
        let base: SyncInkBase
        switch job.base {
        case .unavailable:
            base = .unavailable
        case .none:
            base = .none
        case .content(let content):
            do {
                base = .ink(try await bytes(content, snapshot: snapshot, cache: &cache))
            } catch SyncError.objectNotFound {
                base = .unavailable
            }
        }
        var absorbed: [Data?] = []
        for source in job.absorbed {
            do {
                absorbed.append(try await optional(source.content, &cache))
            } catch SyncError.objectNotFound where source.side == .base {
                absorbed.append(nil)
            }
        }
        let result = try await inkMerger.merge(SyncInkMergeRequest(kind: job.kind, local: local, remote: remote, base: base,
                                                                   absorbed: absorbed, notes: job.notes))
        guard let result, !result.isEmpty else { return nil }
        let content = ContentDigest(of: result)
        cache[content] = result
        return content
    }

    // MARK: Helpers

    /// Whether this round left something of a busy surface for later: the two sides differ on it.
    private func heldBack(_ plan: SyncRecordPlan, targetFiles: SyncFileDigests, pushFiles: SyncFileDigests,
                          busyPages: Set<Int>) -> Bool {
        let mine = Set(plan.target.notes.filter(plan.slice.contains)), theirs = Set(plan.push.notes.filter(plan.slice.contains))
        if mine != theirs { return true }
        let keys = busyPages.map(SyncFileKey.pageInk) + plan.slice.ids.map(SyncFileKey.noteInk)
        return keys.contains { targetFiles[$0] != pushFiles[$0] }
    }

    private func sortedSurfaces(_ surfaces: Set<SyncSurface>) -> [SyncSurface] {
        surfaces.sorted { a, b in
            switch (a, b) {
            case (.page(let x), .page(let y)): x < y
            case (.note(let x), .note(let y)): x.uuidString < y.uuidString
            case (.page, .note): true
            case (.note, .page): false
            }
        }
    }

    private func info(_ book: Book, previous: SyncBookInfo?) -> SyncBookInfo {
        SyncBookInfo(title: book.title, pageCount: max(0, book.pageCount), fingerprint: book.fingerprint,
                     sourceFormat: book.sourceFormat?.rawValue ?? previous?.sourceFormat,
                     originalFileName: book.originalFileName ?? previous?.originalFileName,
                     converterVersion: book.converterVersion ?? previous?.converterVersion,
                     readingPosition: book.lastOpenedAt.map { SyncReadingPosition(pageIndex: max(0, book.lastReadPageIndex), date: $0) })
    }
}

extension SyncReferences {
    /// References to the records, the PDF and these files.
    init(records: ContentDigest, pdf: ContentDigest, files: SyncFileDigests) {
        let f = SyncBaseFiles(digests: files)
        self.init(records: records, pdf: pdf, pageInk: f.pageInk, noteInk: f.noteInk, cover: f.cover, conversion: f.conversion)
    }
}
