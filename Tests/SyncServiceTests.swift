import Foundation
import PencilKit
import ReaderBackup
import ReaderCore
import ReaderStore
import ReaderSync
import S3Kit
import Testing
import UIKit
@testable import TactileTexts

/// The pieces around the engine: the content-version rule, the S3 store's mapping, the key
/// check, pull-only rounds, one job at a time, and one engine directory per account.
@MainActor
@Suite(.serialized)
struct SyncServiceTests {
    typealias S = SyncTestSupport

    // MARK: Content-version rule

    @Test func theContentVersionRule() {
        typealias I = InkContentSupport.Inspection
        func rule(_ inspection: I, _ maximum: Int?) -> Bool {
            InkContentSupport.isSupported(inspection, maximumSupportedVersion: maximum)
        }
        #expect(rule(I(decodes: true, strokeCount: 3, declaredStrokeCount: nil, requiredVersion: 1), 5))
        #expect(rule(I(decodes: true, strokeCount: 3, declaredStrokeCount: nil, requiredVersion: 5), 5))
        #expect(!rule(I(decodes: true, strokeCount: 3, declaredStrokeCount: nil, requiredVersion: 6), 5), "needs a newer system")
        #expect(!rule(I(decodes: true, strokeCount: 2, declaredStrokeCount: 3, requiredVersion: 1), 5), "strokes dropped")
        #expect(rule(I(decodes: true, strokeCount: 3, declaredStrokeCount: 3, requiredVersion: 2), 2))
        #expect(!rule(I(decodes: false, strokeCount: 0, declaredStrokeCount: nil, requiredVersion: nil), 5), "does not decode")
        #expect(!rule(I(decodes: true, strokeCount: 0, declaredStrokeCount: nil, requiredVersion: 1), 5), "damage read as empty")
        // Cannot be determined: supported only because every stroke decoded.
        #expect(rule(I(decodes: true, strokeCount: 3, declaredStrokeCount: nil, requiredVersion: nil), 5))
        #expect(rule(I(decodes: true, strokeCount: 3, declaredStrokeCount: nil, requiredVersion: 9), nil))
        // The editors leave alone only what decodes but needs a newer system.
        #expect(InkContentSupport.needsNewerSystem(I(decodes: true, strokeCount: 3, declaredStrokeCount: nil, requiredVersion: 6),
                                                   maximumSupportedVersion: 5))
        #expect(!InkContentSupport.needsNewerSystem(.undecodable, maximumSupportedVersion: 5))
    }

    @Test func realDrawingsAreInspected() throws {
        let pen = PKDrawing(strokes: [S.stroke(40)]).dataRepresentation()
        let inspected = InkContentSupport.inspectPageInk(pen)
        #expect(inspected.decodes && inspected.strokeCount == 1 && inspected.requiredVersion == 1)
        #expect(InkContentSupport.isSupported(pageInk: pen))
        let fountain = PKDrawing(strokes: [S.versionedStroke(40)]).dataRepresentation()
        let required = try #require(InkContentSupport.inspectPageInk(fountain).requiredVersion)
        #expect(required >= 2)
        #expect(!InkContentSupport.isSupported(InkContentSupport.inspectPageInk(fountain), maximumSupportedVersion: required - 1))
        #expect(InkContentSupport.maximumSupportedVersion >= required, "this system draws it")
        #expect(!InkContentSupport.isSupported(pageInk: Data("not a drawing".utf8)))
        #expect(!InkContentSupport.isSupported(pageInk: Data()))

        // Note ink whose band list names a stroke PencilKit did not read.
        let layout = S.Merge.layout("One\nTwo")
        let ink = S.Merge.noteInk([S.Merge.noteStroke(0, in: layout), S.Merge.noteStroke(1, in: layout)], layout: layout)
        let data = try NoteInkArchive.encode(ink)
        #expect(InkContentSupport.isSupported(noteInk: data))
        var plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        plist["bands"] = [0, 1, 1]
        let lying = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        #expect(InkContentSupport.inspectNoteInk(lying).declaredStrokeCount == 3)
        #expect(!InkContentSupport.isSupported(noteInk: lying))
        #expect(InkContentSupport.needsNewerSystem(noteInk: lying))
    }

    @Test func inkThisSystemCannotReadIsBusyAndNeverPushed() async throws {
        let objects = InMemorySyncObjectStore()
        let a = try SyncTestDevice("A", objects: objects), b = try SyncTestDevice("B", objects: objects)
        defer { a.cleanUp(); b.cleanUp() }
        let bookA = try await a.importBook()
        let bookB = try await b.importBook()
        try await S.settle([a, b], objects: objects, "start")
        let unreadable = Data("drawing from a newer system".utf8)
        try await a.store.savePageInk(unreadable, bookID: bookA.id, pageIndex: 3, origin: nil)
        try await S.addPageInk(a, bookA.id, page: 4, [S.stroke(50)])
        let snapshot = try #require(try await a.core.snapshot(bookID: bookA.id))
        #expect(snapshot.busy.contains(.page(3)))
        #expect(!snapshot.busy.contains(.page(4)))
        try await a.sync()
        try await b.sync()
        #expect(try await b.store.pageInk(bookID: bookB.id, pageIndex: 3) == nil, "never pushed")
        #expect(try await b.pageStrokes(bookB.id, page: 4).count == 1)
        #expect(try await a.store.pageInk(bookID: bookA.id, pageIndex: 3) == unreadable, "kept here as it is")
        // And every round says so.
        #expect(try await a.sync().books.contains { $0.skipped.contains(.busy([.page(3)])) })
    }

    @Test func theInkMergeNeverErasesWhatItCannotRead() async throws {
        let merger = AppSyncInkMerger()
        let mine = PKDrawing(strokes: [S.stroke(40)]).dataRepresentation()
        await #expect(throws: SyncInkUnreadable.self) {
            _ = try await merger.merge(SyncInkMergeRequest(kind: .page(1), local: mine, remote: Data("garbage".utf8), base: .unavailable))
        }
        // An unreadable base merges as the union.
        let theirs = PKDrawing(strokes: [S.stroke(80)]).dataRepresentation()
        let merged = try #require(try await merger.merge(SyncInkMergeRequest(kind: .page(1), local: mine, remote: theirs,
                                                                             base: .ink(Data("garbage".utf8)))))
        #expect(try PKDrawing(data: merged).strokes.count == 2)
        // Nothing on either side: no file.
        #expect(try await merger.merge(SyncInkMergeRequest(kind: .page(1), local: nil, remote: nil, base: .none)) == nil)
    }

    // MARK: The S3 store

    @Test func theS3StoreMapsConditionsSizesAndMissingObjects() async throws {
        let r2 = SyncFakeR2()
        let store = r2.store()
        let first = try await store.put(Data("v1".utf8), at: "Sync/v1/books/k", metadata: ["write-id": "w1"], condition: .ifAbsent)
        #expect(first.hasPrefix("\""))
        let puts = r2.stub.requests("PUT", pathPrefix: "/")
        #expect(puts.last?.headers["if-none-match"] == "*")
        #expect(puts.last?.headers["x-amz-meta-write-id"] == "w1")
        await #expect(throws: SyncError.preconditionFailed(key: "Sync/v1/books/k")) {
            _ = try await store.put(Data("again".utf8), at: "Sync/v1/books/k", metadata: [:], condition: .ifAbsent)
        }
        let second = try await store.put(Data("v2".utf8), at: "Sync/v1/books/k", metadata: [:], condition: .ifMatch(eTag: first))
        #expect(r2.stub.requests("PUT", pathPrefix: "/").last?.headers["if-match"] == first)
        await #expect(throws: SyncError.preconditionFailed(key: "Sync/v1/books/k")) {
            _ = try await store.put(Data("v3".utf8), at: "Sync/v1/books/k", metadata: [:], condition: .ifMatch(eTag: first))
        }
        let read = try #require(try await store.get("Sync/v1/books/k", maxBytes: 100))
        #expect(read.data == Data("v2".utf8) && read.eTag == second)
        #expect(try await store.list(prefix: "Sync/v1/books/").map(\.eTag) == [second])
        #expect(try await store.head("Sync/v1/books/k")?.eTag == second)
        await #expect(throws: SyncError.objectTooLarge(key: "Sync/v1/books/k", limit: 1)) {
            _ = try await store.get("Sync/v1/books/k", maxBytes: 1)
        }
        #expect(try await store.get("Sync/v1/books/none", maxBytes: 100) == nil)
        #expect(try await store.head("Sync/v1/books/none") == nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sync-s3-\(UUID().uuidString)")
        await #expect(throws: SyncError.objectNotFound(key: "Sync/v1/blobs/none")) {
            try await store.download("Sync/v1/blobs/none", to: file)
        }
        try await store.delete("Sync/v1/books/k")
        try await store.delete("Sync/v1/books/k")
        #expect(try await store.list(prefix: "Sync/").isEmpty)
    }

    @Test func anAbsentETagIsAnErrorNotAPass() async throws {
        let r2 = SyncFakeR2()
        let store = r2.store()
        _ = try await store.put(Data("v1".utf8), at: "Sync/v1/books/k", metadata: [:], condition: .ifAbsent)
        r2.omitETags = true
        await #expect(throws: SyncStorageError.missingETag(key: "Sync/v1/books/k")) {
            _ = try await store.get("Sync/v1/books/k", maxBytes: 100)
        }
        await #expect(throws: SyncStorageError.missingETag(key: "Sync/v1/books/k")) {
            _ = try await store.head("Sync/v1/books/k")
        }
        await #expect(throws: SyncStorageError.missingETag(key: "Sync/v1/books/k")) {
            _ = try await store.list(prefix: "Sync/")
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.put(Data("v2".utf8), at: "Sync/v1/books/k", metadata: [:], condition: nil)
        }
    }

    @Test func theEngineRunsOverTheS3Store() async throws {
        let r2 = SyncFakeR2()
        let a = try SyncTestDevice("A", objects: r2.store()), b = try SyncTestDevice("B", objects: r2.store())
        defer { a.cleanUp(); b.cleanUp() }
        let book = try await a.importBook()
        try a.store.notes.save(Note(bookID: book.id, target: .page(1), text: "Over S3", createdAt: Date(timeIntervalSinceReferenceDate: 1)))
        #expect(try await a.sync().count(.uploadedNew) == 1)
        #expect(try await b.sync().count(.createdHere) == 1)
        let created = try #require(try b.store.books.allBooks().first)
        #expect(!b.store.hasDocument(created), "PDF missing until downloaded")
        #expect(try b.store.notes.notes(bookID: created.id).map(\.text) == ["Over S3"])
        // The PDF, downloaded and linked.
        try await b.engine.downloadPDF(bookID: created.id)
        #expect(b.store.hasDocument(created))
        #expect(b.store.storedContentDigest(bookID: created.id) == a.store.storedContentDigest(bookID: book.id))
    }

    // MARK: The key check

    private func access(_ folder: URL, keyStore: InMemoryBackupKeyStore, mode: SyncMode = .full,
                        objects: any SyncObjectStore = InMemorySyncObjectStore()) -> LocalSyncAccess {
        LocalSyncAccess(accountID: "account-1", store: objects, blobStore: FolderBackupBlobStore(root: folder),
                        keyStore: keyStore, mode: mode, temporaryDirectory: folder.appendingPathComponent("tmp"))
    }

    @Test func theKeyCheckComesFirst() async throws {
        let folder = try BackupTestSupport.scratch("SyncKey")
        defer { try? FileManager.default.removeItem(at: folder) }
        let account = folder.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)

        // Read-only, no key, nothing stored: nothing to sync, nothing made.
        let none = InMemoryBackupKeyStore()
        guard case .nothingToSync = try await access(account, keyStore: none, mode: .pullOnly).prepareRound() else {
            Issue.record("expected nothing to sync"); return
        }
        #expect(try await none.load() == nil)

        // Read-write, no key, nothing stored: a key is made and the key check left.
        guard case .ready(let made) = try await access(account, keyStore: none).prepareRound() else {
            Issue.record("expected a round"); return
        }
        #expect(made.key == (try await none.load()))
        #expect(FileManager.default.fileExists(atPath: account.appendingPathComponent(EncryptedBackupDestination.keyCheckObjectName).path))

        // Another device: no key while data exists; another key.
        guard case .needsKey(_, .noKeyOnThisDevice) = try await access(account, keyStore: InMemoryBackupKeyStore()).prepareRound() else {
            Issue.record("expected the recovery key to be asked for"); return
        }
        guard case .needsKey(_, .differentKey) = try await access(account, keyStore: InMemoryBackupKeyStore(key: .generate())).prepareRound() else {
            Issue.record("expected a different key"); return
        }
        // The right key, read-only: a round, pull-only.
        guard case .ready(let pulling) = try await access(account, keyStore: InMemoryBackupKeyStore(key: made.key), mode: .pullOnly).prepareRound() else {
            Issue.record("expected a round"); return
        }
        #expect(pulling.mode == .pullOnly)

        // The service shows the key state and runs no round.
        let library = try SyncTestDevice("lib", objects: InMemorySyncObjectStore())
        defer { library.cleanUp() }
        let objects = InMemorySyncObjectStore()
        let service = SyncService(library: library.core, access: access(account, keyStore: InMemoryBackupKeyStore(), objects: objects),
                                  root: library.store.rootDirectory.appendingPathComponent("Sync"))
        await service.syncNow()
        #expect(service.status == .needsKey(.noKeyOnThisDevice))
        #expect(objects.calls.isEmpty)
    }

    // MARK: The service

    private func service(_ device: SyncTestDevice, access: LocalSyncAccess) -> SyncService {
        SyncService(library: device.core, access: access, root: device.store.rootDirectory.appendingPathComponent("Sync"))
    }

    @Test func aPullOnlyRoundTakesChangesInAndSendsNothing() async throws {
        let folder = try BackupTestSupport.scratch("SyncPullOnly")
        defer { try? FileManager.default.removeItem(at: folder) }
        let objects = InMemorySyncObjectStore()
        let keyStore = InMemoryBackupKeyStore(key: S.key)
        let a = try SyncTestDevice("A", objects: objects), b = try SyncTestDevice("B", objects: objects)
        defer { a.cleanUp(); b.cleanUp() }
        let accessA = access(folder, keyStore: keyStore, objects: objects)
        let accessB = access(folder, keyStore: keyStore, mode: .pullOnly, objects: objects)
        let serviceA = service(a, access: accessA), serviceB = service(b, access: accessB)
        let bookA = try await a.importBook()
        await serviceA.confirmJoin()
        let bookB = try await b.importBook()
        try b.store.notes.save(Note(bookID: bookB.id, target: .page(2), text: "Waits", createdAt: Date(timeIntervalSinceReferenceDate: 1)))
        objects.clearCalls()
        await serviceB.confirmJoin()
        #expect(objects.calls.allSatisfy { ![.put, .upload, .delete].contains($0.operation) }, "pull-only writes nothing")
        #expect(serviceB.status == .waiting(.pullOnly))
        // When the session can write again, the change goes.
        accessB.mode = .full
        await serviceB.syncNow()
        #expect(serviceB.status == .upToDate(serviceB.lastSyncedAt!))
        await serviceA.syncNow()
        #expect(try a.store.notes.notes(bookID: bookA.id).map(\.text) == ["Waits"])
    }

    @Test func syncWaitsWhileABackupRunsAndABackupStopsIt() async throws {
        let folder = try BackupTestSupport.scratch("SyncBackup")
        defer { try? FileManager.default.removeItem(at: folder) }
        let objects = InMemorySyncObjectStore()
        let a = try SyncTestDevice("A", objects: objects)
        defer { a.cleanUp() }
        _ = try await a.importBook()
        let sync = service(a, access: access(folder, keyStore: InMemoryBackupKeyStore(key: S.key), objects: objects))
        let gate = SyncTestGate()
        let backups = BackupService(store: a.store, temporaryRoot: folder.appendingPathComponent("backup-tmp"),
                                    defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    flushEditors: { await gate.wait() })
        sync.backupService = backups
        let stopped = SyncTestBox(0)
        backups.beforeJob = { [sync] in
            stopped.value += 1
            await sync.stopForBackupJob()
        }
        let backup = Task { try await backups.backUpToFile(includePDFs: false) }
        #expect(await BackupTestSupport.waitUntil { backups.job != nil && gate.isWaiting })
        #expect(stopped.value == 1, "a backup starting stops sync")
        await sync.syncNow(joinConfirmed: true)
        #expect(sync.status == .waiting(.backupOrRestore))
        #expect(objects.calls.isEmpty, "no round while the backup runs")
        gate.open()
        _ = try await backup.value
        await sync.syncNow(joinConfirmed: true)
        #expect(sync.status == .upToDate(sync.lastSyncedAt!))
        #expect(!objects.keys.isEmpty)
    }

    @Test func eachAccountHasItsOwnDirectoryAndSigningBackInNeedsNoJoin() async throws {
        let folder = try BackupTestSupport.scratch("SyncAccounts")
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try SyncTestDevice("A", objects: InMemorySyncObjectStore())
        defer { a.cleanUp() }
        _ = try await a.importBook()
        let first = access(folder.appendingPathComponent("one"), keyStore: InMemoryBackupKeyStore(key: S.key))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("one"), withIntermediateDirectories: true)
        let sync = service(a, access: first)
        await sync.syncNow()
        #expect(sync.status == .needsJoinConfirmation, "a library with books joins after a confirmation")
        #expect(try await sync.joinPreview() == SyncJoinPreview(onlyHere: 1, onlyInAccount: 0, inBoth: 0))
        await sync.confirmJoin()
        guard case .upToDate = sync.status else { Issue.record("\(sync.status)"); return }
        let directory = try sync.accountDirectory("account-1")
        #expect(FileManager.default.fileExists(atPath: directory.path))
        let excluded = try sync.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
        #expect(!directory.path.contains("/Books/"))

        // Signed out: it waits; the directory stays.
        first.accountID = nil
        sync.signInChanged()
        await sync.syncNow()
        #expect(sync.status == .waiting(.signedOut))
        #expect(FileManager.default.fileExists(atPath: directory.path))

        // Another account joins on its own.
        first.accountID = "account-2"
        sync.signInChanged()
        await sync.syncNow()
        #expect(sync.status == .needsJoinConfirmation)
        #expect(try sync.accountDirectory("account-2") != directory)

        // Back to the first: carries on with no join.
        first.accountID = "account-1"
        sync.signInChanged()
        await sync.syncNow()
        guard case .upToDate = sync.status else { Issue.record("\(sync.status)"); return }
    }

    @Test func theSyncedBooksAreThoseWithABaseAndRoundsAreCounted() async throws {
        let folder = try BackupTestSupport.scratch("SyncSynced")
        defer { try? FileManager.default.removeItem(at: folder) }
        let objects = InMemorySyncObjectStore()
        let keyStore = InMemoryBackupKeyStore(key: S.key)
        let a = try SyncTestDevice("A", objects: objects), b = try SyncTestDevice("B", objects: objects)
        defer { a.cleanUp(); b.cleanUp() }
        let accessA = access(folder, keyStore: keyStore, objects: objects)
        let serviceA = service(a, access: accessA)
        let serviceB = service(b, access: access(folder, keyStore: keyStore, objects: objects))
        let bookA = try await a.importBook()
        #expect(await serviceA.syncedBookIDs().isEmpty, "never synced")
        await serviceA.syncNow()
        #expect(serviceA.roundsStarted == 1)
        #expect(await serviceA.syncedBookIDs().isEmpty, "not joined yet")
        await serviceA.confirmJoin()
        #expect(serviceA.roundsStarted == 2)
        #expect(await serviceA.syncedBookIDs() == [bookA.id])

        // The book arrives on B without its PDF; it is synced, so its PDF can be downloaded.
        await serviceB.confirmJoin()
        let arrived = try #require(try b.store.books.allBooks().first)
        #expect(!b.store.hasDocument(arrived))
        #expect(await serviceB.syncedBookIDs() == [arrived.id])
        try await serviceB.downloadPDF(bookID: arrived.id)
        #expect(b.store.hasDocument(arrived))

        // Signed out: none.
        accessA.accountID = nil
        serviceA.signInChanged()
        #expect(await serviceA.syncedBookIDs().isEmpty)
    }
}

/// A gate a test opens.
@MainActor
final class SyncTestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var isWaiting = false

    func wait() async {
        guard !isOpen else { return }
        isWaiting = true
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// An R2 bucket in memory with R2's conditional writes, ETags and user metadata, behind a stub.
nonisolated final class SyncFakeR2: BackupCloudHandling, @unchecked Sendable {
    static let bucket = "sync-bucket"
    private let lock = NSLock()
    private var objects: [String: (data: Data, metadata: [String: String])] = [:]
    private var _omitETags = false
    let stub: BackupCloudStub

    init() {
        let target = BackupCloudWeakTarget()
        stub = BackupCloudStub { target.value?.handleRequest($0) ?? .http(599) }
        target.value = self
    }

    var omitETags: Bool { get { lock.withLock { _omitETags } } set { lock.withLock { _omitETags = newValue } } }

    func store() -> SyncS3ObjectStore {
        let endpoint = S3Endpoint(host: "account.r2.cloudflarestorage.com", region: "auto", bucket: Self.bucket, prefix: "users/u-1")!
        let credentials = S3StaticCredentialsProvider(S3Credentials(accessKeyID: "TEMP", secretAccessKey: "SECRET", sessionToken: "t"))
        return SyncS3ObjectStore(client: S3Client(endpoint: endpoint, credentialsProvider: credentials, session: stub.session,
                                                  retryPolicy: S3RetryPolicy(maxAttempts: 1, sleep: { _ in })))
    }

    private static func eTag(_ data: Data) -> String { "\"\(BackupCloudFixtures.md5(data))\"" }

    func handleRequest(_ request: BackupCloudRequest) -> BackupCloudReply {
        lock.withLock { () -> BackupCloudReply in
            let bucketPath = "/\(Self.bucket)"
            let key = String(String(request.path.dropFirst(bucketPath.count)).trimmingPrefix("/"))
            let query = request.query
            func headers(_ data: Data, _ metadata: [String: String]) -> [String: String] {
                var result = ["Content-Length": String(data.count)]
                if !_omitETags { result["ETag"] = Self.eTag(data) }
                for (name, value) in metadata { result["x-amz-meta-\(name)"] = value }
                return result
            }
            if key.isEmpty, request.method == "GET" {
                let prefix = query["prefix"] ?? ""
                var xml = #"<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><IsTruncated>false</IsTruncated>"#
                for name in objects.keys.sorted() where name.hasPrefix(prefix) {
                    let data = objects[name]!.data
                    xml += "<Contents><Key>\(name)</Key><Size>\(data.count)</Size>"
                    if !_omitETags { xml += "<ETag>\(Self.eTag(data).replacingOccurrences(of: "\"", with: "&quot;"))</ETag>" }
                    xml += "</Contents>"
                }
                xml += "</ListBucketResult>"
                return .http(200, headers: ["Content-Type": "application/xml"], body: Data(xml.utf8))
            }
            switch request.method {
            case "PUT":
                let current = objects[key]
                if let match = request.headers["if-match"], current.map({ Self.eTag($0.data) }) != match {
                    return BackupCloudFakeS3.error(412, code: "PreconditionFailed")
                }
                if request.headers["if-none-match"] == "*", current != nil {
                    return BackupCloudFakeS3.error(412, code: "PreconditionFailed")
                }
                var metadata: [String: String] = [:]
                for (name, value) in request.headers where name.hasPrefix("x-amz-meta-") {
                    metadata[String(name.dropFirst("x-amz-meta-".count))] = value
                }
                objects[key] = (request.body, metadata)
                return .http(200, headers: _omitETags ? [:] : ["ETag": Self.eTag(request.body)])
            case "HEAD":
                guard let object = objects[key] else { return .http(404) }
                return .http(200, headers: headers(object.data, object.metadata))
            case "GET":
                guard let object = objects[key] else { return BackupCloudFakeS3.error(404, code: "NoSuchKey") }
                return .http(200, headers: headers(object.data, object.metadata), body: object.data)
            case "DELETE":
                objects[key] = nil
                return .http(204)
            default:
                return .http(405)
            }
        }
    }
}
