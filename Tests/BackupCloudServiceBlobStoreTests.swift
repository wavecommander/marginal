import Foundation
import ReaderBackup
import S3Kit
import Testing
@testable import Marginal

/// `S3BackupBlobStore` against a fake R2 bucket with temporary credentials, and the whole
/// encrypted stack (`EncryptedBackupDestination` over it) with no network.
struct BackupCloudServiceBlobStoreTests {
    typealias F = BackupCloudServiceFixtures

    static let apostropheName = "Ben’s iPad backup 1.ttenc"

    // MARK: Operations

    @Test func listsAFolderWithNamesRelativeToIt() async throws {
        let r2 = BackupCloudServiceFakeR2()
        let store = F.store(r2)
        r2.put(F.key("Backups/a.ttenc"), Data("12345".utf8))
        r2.put(F.key("Backups/\(Self.apostropheName)"), Data("123".utf8))
        r2.put(F.key("Backups/deeper/x.ttenc"), Data("1".utf8))
        r2.put(F.key("Backups/.hidden"), Data("1".utf8))
        r2.put(F.key("PDFs/p.ttenc"), Data("12".utf8))
        r2.put(F.key("key-check"), Data("1".utf8))

        let backups = try await store.list(.backups).sorted { $0.name < $1.name }
        #expect(backups == [BackupBlobInfo(name: Self.apostropheName, byteSize: 3), BackupBlobInfo(name: "a.ttenc", byteSize: 5)])
        #expect(try await store.list(.pdfs) == [BackupBlobInfo(name: "p.ttenc", byteSize: 2)])

        let lists = r2.stub.requests("GET", pathPrefix: "/\(BackupCloudServiceFakeR2.bucket)")
        #expect(lists.map { $0.query["prefix"] } == ["users/u-123/Backups/", "users/u-123/PDFs/"])
        #expect(lists.allSatisfy { $0.headers["x-amz-security-token"] == "token-1" })

        let emptyR2 = BackupCloudServiceFakeR2()
        #expect(try await F.store(emptyR2).list(.backups).isEmpty)
    }

    @Test func sizeOrNil() async throws {
        let r2 = BackupCloudServiceFakeR2()
        let store = F.store(r2)
        r2.put(F.key("PDFs/p.ttenc"), Data(count: 42))
        r2.put(F.key("key-check"), Data(count: 49))
        #expect(try await store.size(of: .pdf("p.ttenc")) == 42)
        #expect(try await store.size(of: .control("key-check")) == 49)
        #expect(try await store.size(of: .pdf("missing.ttenc")) == nil)
        let heads = r2.stub.requests.filter { $0.method == "HEAD" }
        #expect(heads.map(\.path) == ["/tactile-backups/users/u-123/PDFs/p.ttenc", "/tactile-backups/users/u-123/key-check",
                                      "/tactile-backups/users/u-123/PDFs/missing.ttenc"])
    }

    @Test func uploadsASmallFileInOneRequest() async throws {
        let r2 = BackupCloudServiceFakeR2()
        let store = F.store(r2)
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let content = BackupCloudFixtures.bytes(3000)
        let file = try BackupCloudFixtures.write(content, in: scratch)
        let fractions = BackupCloudLocked<[Double]>([])
        try await store.upload(from: file, to: .backup(Self.apostropheName), progress: { value in fractions.mutate { $0.append(value) } })
        #expect(r2.object(F.key("Backups/\(Self.apostropheName)")) == content)
        let puts = r2.stub.requests("PUT", pathPrefix: "/")
        #expect(puts.count == 1)
        #expect(puts.first?.headers["x-amz-security-token"] == "token-1")
        #expect(puts.first?.headers["x-amz-content-sha256"] == BackupCloudFixtures.sha256(content))
        #expect(fractions.value.last == 1)
        // Replacing.
        let second = try BackupCloudFixtures.write(Data("new".utf8), in: scratch)
        try await store.upload(from: second, to: .backup(Self.apostropheName), progress: nil)
        #expect(r2.object(F.key("Backups/\(Self.apostropheName)")) == Data("new".utf8))
    }

    @Test func uploadsALargeFileInParts() async throws {
        let r2 = BackupCloudServiceFakeR2()
        let store = F.store(r2, partSize: S3Client.minimumPartSize)
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let content = BackupCloudFixtures.bytes(11 * 1024 * 1024 + 17, seed: 7)
        let file = try BackupCloudFixtures.write(content, in: scratch)
        let fractions = BackupCloudLocked<[Double]>([])
        try await store.upload(from: file, to: .pdf("big file.ttenc"), progress: { value in fractions.mutate { $0.append(value) } })

        #expect(r2.object(F.key("PDFs/big file.ttenc")) == content)
        let sequence = r2.stub.requests.map { request -> String in
            let q = request.query
            if q["uploads"] != nil { return "create" }
            if let part = q["partNumber"] { return "part \(part)" }
            if q["uploadId"] != nil { return request.method == "POST" ? "complete" : "abort" }
            return request.method
        }
        #expect(sequence == ["create", "part 1", "part 2", "part 3", "complete", "HEAD"])
        let parts = r2.stub.requests.filter { $0.query["partNumber"] != nil }
        #expect(parts.map(\.body.count) == [5 * 1024 * 1024, 5 * 1024 * 1024, 1024 * 1024 + 17])
        #expect(r2.stub.requests.allSatisfy { $0.headers["x-amz-security-token"] == "token-1" })
        #expect(r2.pendingUploads == 0)
        #expect(fractions.value.last == 1)
        #expect(fractions.value == fractions.value.sorted())
    }

    @Test func downloadsToAFile() async throws {
        let r2 = BackupCloudServiceFakeR2()
        let store = F.store(r2)
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let content = BackupCloudFixtures.bytes(70_000)
        r2.put(F.key("Backups/\(Self.apostropheName)"), content)
        let target = scratch.appendingPathComponent("download")
        try Data("old".utf8).write(to: target)
        let fractions = BackupCloudLocked<[Double]>([])
        try await store.download(.backup(Self.apostropheName), to: target, progress: { value in fractions.mutate { $0.append(value) } })
        #expect(try Data(contentsOf: target) == content)
        #expect(fractions.value.last == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == ["download"])
    }

    @Test func aMissingObjectIsFileNotFoundAndLeavesNothing() async throws {
        let r2 = BackupCloudServiceFakeR2()
        let store = F.store(r2)
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let target = scratch.appendingPathComponent("download")
        try Data("old".utf8).write(to: target)
        await #expect(throws: BackupError.fileNotFound(name: "gone.ttenc")) {
            try await store.download(.pdf("gone.ttenc"), to: target, progress: nil)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test func deletesAndAlreadyGoneIsSuccess() async throws {
        let r2 = BackupCloudServiceFakeR2()
        let store = F.store(r2)
        r2.put(F.key("Backups/\(Self.apostropheName)"), Data("x".utf8))
        try await store.delete(.backup(Self.apostropheName))
        #expect(r2.keys.isEmpty)
        try await store.delete(.backup(Self.apostropheName))   // R2: 204 for a missing key
        r2.override = BackupCloudFakeS3.error(404, code: "NoSuchKey")
        try await store.delete(.backup(Self.apostropheName))   // S3: 404 NoSuchKey
        #expect(r2.stub.requests("DELETE", pathPrefix: "/").count == 3)
    }

    @Test func namesAreNormalisedToNFCAndKeepSpacesAndApostrophes() async throws {
        let r2 = BackupCloudServiceFakeR2()
        let store = F.store(r2)
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try BackupCloudFixtures.write(Data("abc".utf8), in: scratch)
        let decomposed = "Cafe\u{301} notes’ copy.ttenc"
        let composed = "Caf\u{E9} notes’ copy.ttenc"
        try await store.upload(from: file, to: .backup(decomposed), progress: nil)
        #expect(r2.keys == [F.key("Backups/\(composed)")])
        let listed = try await store.list(.backups)
        #expect(listed.map(\.name) == [composed])
        #expect(listed.first?.name.unicodeScalars.elementsEqual(composed.unicodeScalars) == true)
        // The listed name is the one to use.
        #expect(try await store.size(of: .backup(listed[0].name)) == 3)
        let target = scratch.appendingPathComponent("back")
        try await store.download(.backup(listed[0].name), to: target, progress: nil)
        #expect(try Data(contentsOf: target) == Data("abc".utf8))
        try await store.delete(.backup(listed[0].name))
        #expect(r2.keys.isEmpty)
        // On the wire: percent-encoded once.
        let put = try #require(r2.stub.requests("PUT", pathPrefix: "/").first)
        #expect(put.url.absoluteString.hasSuffix("/Backups/Caf%C3%A9%20notes%E2%80%99%20copy.ttenc"))
    }

    @Test func unsafeNamesAreRefusedBeforeAnyRequest() async throws {
        let r2 = BackupCloudServiceFakeR2()
        let store = F.store(r2)
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try BackupCloudFixtures.write(Data("abc".utf8), in: scratch)
        for name in ["", ".hidden", "a/b", "a\\b", "..", String(repeating: "x", count: 256)] {
            let key = BackupBlobKey.backup(name)
            await #expect(throws: BackupError.unsafeEntryName(name: name)) { _ = try await store.size(of: key) }
            await #expect(throws: BackupError.unsafeEntryName(name: name)) { try await store.upload(from: file, to: key, progress: nil) }
            await #expect(throws: BackupError.unsafeEntryName(name: name)) {
                try await store.download(key, to: scratch.appendingPathComponent("x"), progress: nil)
            }
            await #expect(throws: BackupError.unsafeEntryName(name: name)) { try await store.delete(key) }
        }
        #expect(r2.stub.requests.isEmpty)
    }

    @Test func availabilityMakesNoNetworkCall() async {
        let r2 = BackupCloudServiceFakeR2()
        r2.override = .fail(.notConnectedToInternet)
        let credentials = BackupCloudServiceCredentials(r2: r2)
        credentials.failure = BackupCloudServiceNotSubscribed()
        let store = F.store(r2, credentials: credentials)
        #expect(await store.availability() == .available)
        #expect(r2.stub.requests.isEmpty)
        #expect(credentials.calls == 0)
    }

    // MARK: Errors

    @Test func readOnlyAccessIsNotAllowedByAccessAndReadsStillWork() async throws {
        let r2 = BackupCloudServiceFakeR2()
        let store = F.store(r2)
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try BackupCloudFixtures.write(Data("abc".utf8), in: scratch)
        r2.put(F.key("PDFs/p.ttenc"), Data("abc".utf8))
        r2.readOnly = true
        let expected = CloudBackupError.notAllowedByAccess(destination: F.displayName)
        await #expect(throws: expected) { try await store.upload(from: file, to: .pdf("q.ttenc"), progress: nil) }
        await #expect(throws: expected) { try await store.delete(.pdf("p.ttenc")) }
        let large = F.store(r2, partSize: S3Client.minimumPartSize)
        let big = try BackupCloudFixtures.write(BackupCloudFixtures.bytes(6 * 1024 * 1024), in: scratch)
        await #expect(throws: expected) { try await large.upload(from: big, to: .pdf("big.ttenc"), progress: nil) }
        // Not retried and no refresh: "not allowed" is not "expired".
        #expect(r2.stub.requests("PUT", pathPrefix: "/").count == 1)
        #expect(try await store.size(of: .pdf("p.ttenc")) == 3)
        #expect(try await store.list(.pdfs).count == 1)
        let target = scratch.appendingPathComponent("p")
        try await store.download(.pdf("p.ttenc"), to: target, progress: nil)
        #expect(try Data(contentsOf: target) == Data("abc".utf8))
        // A key outside the credential's prefix is refused the same way.
        let outside = S3BackupBlobStore(endpoint: S3Endpoint(host: BackupCloudServiceFakeR2.host, region: "auto",
                                                             bucket: BackupCloudServiceFakeR2.bucket, prefix: "users/someone-else")!,
                                        credentialsProvider: BackupCloudServiceCredentials(r2: r2), displayName: F.displayName,
                                        session: r2.stub.session, retryPolicy: S3RetryPolicy(maxAttempts: 1, sleep: { _ in }))
        r2.readOnly = false
        await #expect(throws: expected) { _ = try await outside.list(.backups) }
        await #expect(throws: expected) { try await outside.upload(from: file, to: .pdf("q.ttenc"), progress: nil) }
    }

    @Test func expiredAccessIsRenewedOnceAndThenNeedsRenewal() async throws {
        let r2 = BackupCloudServiceFakeR2()
        let credentials = BackupCloudServiceCredentials(r2: r2)
        let store = F.store(r2, credentials: credentials)
        r2.put(F.key("PDFs/p.ttenc"), Data("abc".utf8))
        // The service moved on to a new token: one refresh, then success.
        r2.validToken = "token-2"
        #expect(try await store.size(of: .pdf("p.ttenc")) == 3)
        #expect(credentials.rejections == 1)
        #expect(try await store.list(.pdfs).count == 1)
        // Fresh credentials are refused too: ask the service again later.
        credentials.followRejections = false
        r2.validToken = "never"
        let expected = CloudBackupError.accessNeedsRenewal(destination: F.displayName)
        await #expect(throws: expected) { _ = try await store.list(.pdfs) }
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        await #expect(throws: expected) { try await store.download(.pdf("p.ttenc"), to: scratch.appendingPathComponent("x"), progress: nil) }
        await #expect(throws: expected) { try await store.delete(.pdf("p.ttenc")) }
        #expect(expected.localizedDescription != CloudBackupError.notAllowedByAccess(destination: F.displayName).localizedDescription)
    }

    @Test func aCredentialsProviderErrorPassesThroughUntouched() async throws {
        let r2 = BackupCloudServiceFakeR2()
        let credentials = BackupCloudServiceCredentials(r2: r2)
        credentials.failure = BackupCloudServiceNotSubscribed()
        let store = F.store(r2, credentials: credentials, partSize: S3Client.minimumPartSize)
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try BackupCloudFixtures.write(Data("abc".utf8), in: scratch)
        let expected = BackupCloudServiceNotSubscribed()
        await #expect(throws: expected) { _ = try await store.list(.backups) }
        await #expect(throws: expected) { _ = try await store.size(of: .pdf("p.ttenc")) }
        await #expect(throws: expected) { try await store.upload(from: file, to: .pdf("p.ttenc"), progress: nil) }
        await #expect(throws: expected) { try await store.download(.pdf("p.ttenc"), to: scratch.appendingPathComponent("x"), progress: nil) }
        await #expect(throws: expected) { try await store.delete(.pdf("p.ttenc")) }
        #expect(r2.stub.requests.isEmpty)

        // Failing in the middle of a multipart upload: still the provider's own error.
        credentials.failure = nil
        let big = try BackupCloudFixtures.write(BackupCloudFixtures.bytes(11 * 1024 * 1024), in: scratch)
        let failing = CountdownCredentials(base: credentials, failAfter: 2, error: expected)
        let store2 = F.store(r2, credentials: failing, partSize: S3Client.minimumPartSize)
        await #expect(throws: expected) { try await store2.upload(from: big, to: .pdf("big.ttenc"), progress: nil) }
        #expect(r2.object(F.key("PDFs/big.ttenc")) == nil)
    }

    @Test func otherServiceErrorsMapToReaderFacingErrors() async throws {
        let name = F.displayName
        let cases: [(BackupCloudReply, any Error & Equatable)] = [
            (.fail(.notConnectedToInternet), CloudBackupError.noNetwork(destination: name)),
            (BackupCloudFakeS3.error(403, code: "QuotaExceeded"), CloudBackupError.storageFull(destination: name)),
            (BackupCloudFakeS3.error(404, code: "NoSuchBucket"), CloudBackupError.bucketNotFound(destination: name)),
            (BackupCloudFakeS3.error(403, code: "RequestTimeTooSkewed"), CloudBackupError.clockWrong(destination: name)),
            (BackupCloudFakeS3.error(500, code: "InternalError"), CloudBackupError.serviceError(destination: name, diagnostic: "HTTP 500 InternalError")),
        ]
        for (reply, expected) in cases {
            let r2 = BackupCloudServiceFakeR2()
            r2.override = reply
            do {
                _ = try await F.store(r2).list(.backups)
                Issue.record("no error for \(expected)")
            } catch {
                #expect((error as? CloudBackupError) == (expected as? CloudBackupError), "\(error)")
            }
        }
    }

    // MARK: The whole stack, with no network

    @Test func encryptedDestinationOverTheBlobStore() async throws {
        let r2 = BackupCloudServiceFakeR2()
        let store = F.store(r2, partSize: S3Client.minimumPartSize)
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let key = BackupEncryptionKey.generate()
        func destination(_ key: BackupEncryptionKey) -> EncryptedBackupDestination {
            EncryptedBackupDestination(id: "tactile-cloud", displayName: F.displayName, store: store, key: key,
                                       temporaryDirectory: scratch.appendingPathComponent("tmp"))
        }
        let cloud = destination(key)
        #expect(try await cloud.checkKey() == .nothingStored)

        let deviceName = "Ben’s iPad"
        let snapshotName = SnapshotName.make(createdAt: BackupCloudFixtures.date, deviceName: deviceName)
        let snapshotMarker = "SNAPSHOT-PLAINTEXT-MARKER"
        let snapshot = Data((snapshotMarker + " notes and ink ").utf8) + BackupCloudFixtures.bytes(40_000)
        let snapshotFile = try BackupCloudFixtures.write(snapshot, in: scratch, name: "snapshot.ttbackup")
        let pdfMarker = "PDF-PLAINTEXT-MARKER"
        let pdf = Data("%PDF-1.7 \(pdfMarker) ".utf8) + BackupCloudFixtures.bytes(6 * 1024 * 1024, seed: 3)
        let pdfFile = try BackupCloudFixtures.write(pdf, in: scratch, name: "book.pdf")
        let pdfHash = BackupCloudFixtures.sha256(pdf)

        let uploaded = try await cloud.uploadSnapshot(from: snapshotFile, name: snapshotName, progress: nil)
        try await cloud.uploadPDF(from: pdfFile, sha256: pdfHash, size: Int64(pdf.count), progress: nil)
        #expect(r2.stub.requests.contains { $0.query["partNumber"] != nil }, "the PDF went up in parts")

        let listed = try await cloud.listSnapshots()
        #expect(listed.count == 1)
        #expect(listed.first?.deviceName == deviceName)
        #expect(listed.first?.name == snapshotName)
        #expect(listed.first?.id == uploaded.id)
        #expect(try await cloud.hasPDF(sha256: pdfHash, size: Int64(pdf.count)))
        #expect(try await cloud.hasPDF(sha256: BackupCloudFixtures.sha256(Data("other".utf8)), size: 5) == false)

        // Nothing readable in the stored names or bytes.
        let keys = r2.keys
        #expect(keys.count == 3)
        #expect(keys.allSatisfy { $0.hasPrefix(BackupCloudServiceFakeR2.prefix + "/") })
        #expect(keys.contains(F.key("key-check")))
        for storedKey in keys {
            for secret in ["Ben", "iPad", pdfHash, snapshotName, "book"] {
                #expect(!storedKey.contains(secret), "\(storedKey) shows \(secret)")
            }
        }
        let bytes = r2.allBytes
        for plaintext in [snapshotMarker, pdfMarker, deviceName, "%PDF", pdfHash, snapshotName] {
            #expect(bytes.range(of: Data(plaintext.utf8)) == nil, "the stored bytes show \(plaintext)")
        }

        // Download and compare.
        let snapshotBack = scratch.appendingPathComponent("snapshot-back")
        try await cloud.downloadSnapshot(listed[0], to: snapshotBack, progress: nil)
        #expect(try Data(contentsOf: snapshotBack) == snapshot)
        let pdfBack = scratch.appendingPathComponent("pdf-back")
        try await cloud.downloadPDF(sha256: pdfHash, to: pdfBack, progress: nil)
        #expect(try Data(contentsOf: pdfBack) == pdf)

        // Another key is told it's the wrong one, and can't write.
        let stranger = destination(BackupEncryptionKey.generate())
        #expect(try await stranger.checkKey() == .differentKey)
        await #expect(throws: BackupError.wrongEncryptionKey) { _ = try await stranger.listSnapshots() }
        await #expect(throws: BackupError.wrongEncryptionKey) {
            try await stranger.uploadPDF(from: pdfFile, sha256: pdfHash, size: Int64(pdf.count), progress: nil)
        }
        #expect(await stranger.availability() == .unavailable(reason: BackupError.wrongEncryptionKey.localizedDescription))
        // The same key in a new destination value (another device with the synced key) matches.
        #expect(try await destination(key).checkKey() == .matches)

        // Delete.
        try await cloud.deleteSnapshot(listed[0])
        #expect(try await cloud.listSnapshots().isEmpty)
        #expect(r2.keys.count == 2)   // the PDF and the key check stay
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.appendingPathComponent("tmp").path).isEmpty)
    }

    // MARK: Secrets

    @Test func noSecretOrTokenInErrorsOrDescriptions() async throws {
        let secrets = [BackupCloudServiceCredentials.secret, "token-1", "token-2"]
        let r2 = BackupCloudServiceFakeR2()
        let store = F.store(r2)
        var texts = [String(describing: store), String(reflecting: store), "\(store.client.credentialsProvider)"]
        var dumped = ""
        dump(store, to: &dumped)
        texts.append(dumped)
        var errors: [any Error] = []
        for reply: BackupCloudReply in [
            BackupCloudFakeS3.error(403, code: "AccessDenied", message: "denied for \(secrets[0]) token-1"),
            BackupCloudFakeS3.error(400, code: "InvalidArgument", message: "bad token-1 \(secrets[0])"),
            BackupCloudFakeS3.error(500, code: "InternalError", message: secrets[0]),
            .http(418, body: Data("teapot token-1".utf8)),
        ] {
            r2.override = reply
            do { _ = try await store.list(.backups) } catch { errors.append(error) }
        }
        r2.override = nil
        r2.validToken = "never"
        let expiring = BackupCloudServiceCredentials(r2: nil)
        do { _ = try await F.store(r2, credentials: expiring).list(.backups) } catch { errors.append(error) }
        #expect(errors.count == 5)
        for error in errors {
            texts += [error.localizedDescription, String(describing: error), String(reflecting: error)]
        }
        for text in texts {
            for secret in secrets { #expect(!text.contains(secret), "shows a secret: \(text)") }
        }
    }
}

/// Forwards to `base` for `failAfter` calls, then throws `error`.
nonisolated final class CountdownCredentials: S3CredentialsProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private let base: any S3CredentialsProvider
    private let error: any Error

    init(base: any S3CredentialsProvider, failAfter: Int, error: any Error) {
        self.base = base
        remaining = failAfter
        self.error = error
    }

    func credentials() async throws -> S3Credentials {
        let fail = lock.withLock { () -> Bool in
            remaining -= 1
            return remaining < 0
        }
        if fail { throw error }
        return try await base.credentials()
    }

    func credentialsRejected(_ credentials: S3Credentials) async {
        await base.credentialsRejected(credentials)
    }
}
