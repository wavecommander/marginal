import Foundation
import ReaderBackup
import S3Kit
import Testing
@testable import TactileTexts

/// `S3BackupDestination` and `S3BackupConfiguration`, against a fake bucket behind a
/// `URLProtocol` stub.
struct BackupCloudS3Tests {
    static let prefix = "tactile/ipad"

    static func info(prefix: String = BackupCloudS3Tests.prefix, displayName: String = "") -> [String: Any] {
        ["S3Backup": ["Host": "account.r2.cloudflarestorage.com", "Region": "auto", "Bucket": BackupCloudFakeS3.bucket,
                      "AccessKeyID": BackupCloudFakeS3.accessKeyID, "SecretAccessKey": BackupCloudFakeS3.secret,
                      "Prefix": prefix, "DisplayName": displayName]]
    }

    struct Harness {
        let s3 = BackupCloudFakeS3()
        let destination: S3BackupDestination

        init(prefix: String = BackupCloudS3Tests.prefix) {
            let configuration = S3BackupConfiguration.fromInfoDictionary(BackupCloudS3Tests.info(prefix: prefix))!
            destination = S3BackupDestination(configuration: configuration, urlSession: s3.stub.session,
                                              retryPolicy: S3RetryPolicy(maxAttempts: 1, sleep: { _ in }),
                                              now: { BackupCloudFixtures.date })
        }

        /// The full key under the prefix.
        func key(_ relative: String) -> String { "\(BackupCloudS3Tests.prefix)/\(relative)" }
    }

    // MARK: Configuration

    @Test func configurationReaderNotSetUpCases() {
        #expect(S3BackupConfiguration.fromInfoDictionary(nil) == nil)
        #expect(S3BackupConfiguration.fromInfoDictionary([:]) == nil)
        #expect(S3BackupConfiguration.fromInfoDictionary(["S3Backup": "not a dictionary"]) == nil)
        // This build: every value empty.
        #expect(S3BackupConfiguration.fromInfoDictionary() == nil)
        let empty: [String: Any] = ["S3Backup": ["Host": "", "Region": "", "Bucket": "", "AccessKeyID": "",
                                                 "SecretAccessKey": "", "Prefix": "", "DisplayName": ""]]
        #expect(S3BackupConfiguration.fromInfoDictionary(empty) == nil)
        for key in ["Host", "Region", "Bucket", "AccessKeyID", "SecretAccessKey"] {
            var values = Self.info()["S3Backup"] as! [String: Any]
            values[key] = ""
            #expect(S3BackupConfiguration.fromInfoDictionary(["S3Backup": values]) == nil, "\(key) empty")
            values[key] = "  "
            #expect(S3BackupConfiguration.fromInfoDictionary(["S3Backup": values]) == nil, "\(key) blank")
            values[key] = "$(S3_BACKUP_\(key.uppercased()))"
            #expect(S3BackupConfiguration.fromInfoDictionary(["S3Backup": values]) == nil, "\(key) placeholder")
            values[key] = nil
            #expect(S3BackupConfiguration.fromInfoDictionary(["S3Backup": values]) == nil, "\(key) missing")
            values[key] = 7
            #expect(S3BackupConfiguration.fromInfoDictionary(["S3Backup": values]) == nil, "\(key) not a string")
        }
        var withScheme = Self.info()["S3Backup"] as! [String: Any]
        withScheme["Host"] = "https://account.r2.cloudflarestorage.com"
        #expect(S3BackupConfiguration.fromInfoDictionary(["S3Backup": withScheme]) == nil)
    }

    @Test func configurationReaderValues() throws {
        let set = try #require(S3BackupConfiguration.fromInfoDictionary(Self.info(prefix: "/tactile/ipad/")))
        #expect(set.s3.host == "account.r2.cloudflarestorage.com" && set.s3.region == "auto")
        #expect(set.s3.bucket == BackupCloudFakeS3.bucket && set.s3.prefix == "tactile/ipad")
        #expect(set.displayName == "S3 Storage")

        var values = Self.info()["S3Backup"] as! [String: Any]
        values["Prefix"] = "$(S3_BACKUP_PREFIX)"
        values["DisplayName"] = "$(S3_BACKUP_NAME)"
        let placeholders = try #require(S3BackupConfiguration.fromInfoDictionary(["S3Backup": values]))
        #expect(placeholders.s3.prefix == "" && placeholders.displayName == "S3 Storage")

        values["DisplayName"] = " Cloudflare R2 "
        #expect(S3BackupConfiguration.fromInfoDictionary(["S3Backup": values])?.displayName == "Cloudflare R2")
        let destination = S3BackupDestination(configuration: S3BackupConfiguration.fromInfoDictionary(["S3Backup": values])!)
        #expect(destination.id == "s3" && destination.displayName == "Cloudflare R2")
    }

    // MARK: Protocol through the adapter

    @Test func snapshotsRoundTripNewestFirstIgnoringForeignKeys() async throws {
        let h = Harness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let olderData = BackupCloudFixtures.bytes(3000, seed: 1), newerData = BackupCloudFixtures.bytes(5000, seed: 2)
        let progress = BackupCloudLocked<[Double]>([])
        let older = try await h.destination.uploadSnapshot(
            from: try BackupCloudFixtures.write(olderData, in: scratch), name: BackupCloudNames.older,
            progress: { value in progress.mutate { $0.append(value) } })
        #expect(progress.value.last == 1)
        try await h.destination.uploadSnapshot(from: try BackupCloudFixtures.write(newerData, in: scratch),
                                               name: BackupCloudNames.newer, progress: nil)
        #expect(older.id == "Backups/\(BackupCloudNames.older)" && older.byteSize == 3000)
        #expect(h.s3.object(h.key("Backups/\(BackupCloudNames.older)"))?.data == olderData)

        h.s3.put(h.key("Backups/notes.txt"), Data("x".utf8))
        h.s3.put(h.key("Backups/nested/\(BackupCloudNames.older)"), Data("x".utf8))
        h.s3.put(h.key("Backups/.\(BackupCloudNames.older)"), Data("x".utf8))
        h.s3.put("elsewhere/Backups/\(BackupCloudNames.newer)", Data("x".utf8))

        let listed = try await h.destination.listSnapshots()
        #expect(listed.map(\.name) == [BackupCloudNames.newer, BackupCloudNames.older])
        #expect(listed.map(\.byteSize) == [5000, 3000])
        #expect(listed.last == older)

        let target = scratch.appendingPathComponent("downloaded.ttbackup")
        try await h.destination.downloadSnapshot(listed[0], to: target, progress: nil)
        #expect(try Data(contentsOf: target) == newerData)

        try await h.destination.deleteSnapshot(listed[0])
        try await h.destination.deleteSnapshot(listed[0])  // already gone: succeeds
        #expect(try await h.destination.listSnapshots().map(\.name) == [BackupCloudNames.older])
        await #expect(throws: BackupError.snapshotNotFound(name: listed[0].name)) {
            try await h.destination.downloadSnapshot(listed[0], to: target, progress: nil)
        }
        #expect(try Data(contentsOf: target) == newerData, "a failed download leaves the target as it was")
    }

    @Test func snapshotNameWithSpacesApostropheAndAccentRoundTrips() async throws {
        let h = Harness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        // A device name as the system may hand it over: decomposed "é" (e + U+0301), typographic apostrophe.
        let decomposed = SnapshotName.make(createdAt: BackupCloudFixtures.date, deviceName: "Rene\u{301}e’s  iPad")
        let nfc = decomposed.precomposedStringWithCanonicalMapping
        #expect(decomposed.unicodeScalars.count != nfc.unicodeScalars.count)
        let data = BackupCloudFixtures.bytes(2048)

        let uploaded = try await h.destination.uploadSnapshot(from: try BackupCloudFixtures.write(data, in: scratch),
                                                              name: decomposed, progress: nil)
        #expect(uploaded.name == decomposed, "the same name (canonically equivalent)")
        #expect(Array(uploaded.name.unicodeScalars) == Array(nfc.unicodeScalars), "stored and returned in NFC")
        #expect(h.s3.keys.map { Array($0.unicodeScalars) } == [Array(h.key("Backups/\(nfc)").unicodeScalars)])

        let listed = try await h.destination.listSnapshots()
        #expect(listed == [uploaded])
        #expect(listed.first?.deviceName == "Renée’s  iPad")
        let target = scratch.appendingPathComponent("out")
        try await h.destination.downloadSnapshot(listed[0], to: target, progress: nil)
        #expect(try Data(contentsOf: target) == data)
        try await h.destination.deleteSnapshot(listed[0])
        #expect(h.s3.keys.isEmpty)
        #expect(try await h.destination.listSnapshots().isEmpty)

        // The keys went over the wire percent-encoded, spaces as %20.
        let put = try #require(h.s3.stub.requests.first { $0.method == "PUT" })
        #expect(put.url.path(percentEncoded: true).contains("Ren%C3%A9e%E2%80%99s%20%20iPad.ttbackup"))
    }

    @Test func snapshotDownloadOfTheWrongSizeIsRefused() async throws {
        let h = Harness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        try await h.destination.uploadSnapshot(from: try BackupCloudFixtures.write(BackupCloudFixtures.bytes(4000), in: scratch),
                                               name: BackupCloudNames.older, progress: nil)
        let listed = try await h.destination.listSnapshots()
        h.s3.truncateDownloads = true
        let target = scratch.appendingPathComponent("out")
        await #expect(throws: BackupError.contentMismatch(name: BackupCloudNames.older)) {
            try await h.destination.downloadSnapshot(listed[0], to: target, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).count == 1, "no partial file left")
    }

    @Test func invalidSnapshotNamesAndIDsAreRefusedWithoutARequest() async throws {
        let h = Harness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try BackupCloudFixtures.write(Data("x".utf8), in: scratch)
        await #expect(throws: BackupError.invalidSnapshotName(name: "notes.txt")) {
            try await h.destination.uploadSnapshot(from: file, name: "notes.txt", progress: nil)
        }
        let foreign = BackupSnapshotInfo(id: "PDFs/\(BackupCloudNames.older)", name: BackupCloudNames.older,
                                         createdAt: .now, deviceName: "iPad", byteSize: 1)
        await #expect(throws: BackupError.invalidSnapshotName(name: BackupCloudNames.older)) {
            try await h.destination.deleteSnapshot(foreign)
        }
        #expect(h.s3.stub.requests.isEmpty)
    }

    @Test func pdfsByHash() async throws {
        let h = Harness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let pdf = BackupCloudFixtures.bytes(7000, seed: 9)
        let hash = BackupCloudFixtures.sha256(pdf)
        let file = try BackupCloudFixtures.write(pdf, in: scratch)

        #expect(try await h.destination.hasPDF(sha256: hash, size: 7000) == false)
        await #expect(throws: BackupError.pdfNotAtDestination(sha256: hash)) {
            try await h.destination.downloadPDF(sha256: hash, to: scratch.appendingPathComponent("none.pdf"), progress: nil)
        }
        let progress = BackupCloudLocked<[Double]>([])
        try await h.destination.uploadPDF(from: file, sha256: hash.uppercased(), size: 7000,
                                          progress: { value in progress.mutate { $0.append(value) } })
        #expect(progress.value.last == 1 && progress.value == progress.value.sorted())
        let stored = try #require(h.s3.object(h.key("PDFs/\(hash).pdf")))
        #expect(stored.data == pdf && stored.metadata["sha256"] == hash)
        #expect(try await h.destination.hasPDF(sha256: hash, size: 7000))
        #expect(try await h.destination.hasPDF(sha256: hash, size: 7001) == false, "wrong size")

        // Uploading again is skipped.
        let puts = h.s3.stub.requests.filter { $0.method == "PUT" }.count
        try await h.destination.uploadPDF(from: file, sha256: hash, size: 7000, progress: nil)
        #expect(h.s3.stub.requests.filter { $0.method == "PUT" }.count == puts)

        let target = scratch.appendingPathComponent("restored.pdf")
        try await h.destination.downloadPDF(sha256: hash, to: target, progress: nil)
        #expect(try Data(contentsOf: target) == pdf)

        h.s3.corruptDownloads = true
        let corrupt = scratch.appendingPathComponent("corrupt.pdf")
        await #expect(throws: BackupError.contentMismatch(name: "\(hash).pdf")) {
            try await h.destination.downloadPDF(sha256: hash, to: corrupt, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
    }

    @Test func pdfStoredWithAnotherHashDoesNotCount() async throws {
        let h = Harness()
        let pdf = BackupCloudFixtures.bytes(100)
        let hash = BackupCloudFixtures.sha256(pdf)
        h.s3.put(h.key("PDFs/\(hash).pdf"), pdf, metadata: ["sha256": BackupCloudFixtures.sha256(Data("x".utf8))])
        #expect(try await h.destination.hasPDF(sha256: hash, size: 100) == false)
        h.s3.put(h.key("PDFs/\(hash).pdf"), pdf)  // no metadata (written by another tool): size decides
        #expect(try await h.destination.hasPDF(sha256: hash, size: 100))
    }

    @Test func pdfWhoseBytesDoNotMatchTheHashIsNotSent() async throws {
        let h = Harness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try BackupCloudFixtures.write(BackupCloudFixtures.bytes(500), in: scratch, name: "Book.pdf")
        let wrong = BackupCloudFixtures.sha256(Data("other".utf8))
        await #expect(throws: BackupError.contentMismatch(name: "Book.pdf")) {
            try await h.destination.uploadPDF(from: file, sha256: wrong, size: 500, progress: nil)
        }
        #expect(h.s3.stub.requests.allSatisfy { $0.method != "PUT" })
        #expect(h.s3.keys.isEmpty)
    }

    @Test func availabilityIsAlwaysAvailableWithoutANetworkCall() async {
        let h = Harness()
        h.s3.override = .fail(.notConnectedToInternet)
        #expect(await h.destination.availability() == .available)
        #expect(h.s3.stub.requests.isEmpty)
    }

    // MARK: Errors

    @Test func s3ErrorsMapToReaderFacingErrors() async throws {
        let name = "S3 Storage"
        let cases: [(BackupCloudReply, CloudBackupError)] = [
            (BackupCloudFakeS3.error(403, code: "SignatureDoesNotMatch"), .credentialsRejected(destination: name)),
            (BackupCloudFakeS3.error(403, code: "InvalidAccessKeyId"), .credentialsRejected(destination: name)),
            (BackupCloudFakeS3.error(403, code: "RequestTimeTooSkewed"), .clockWrong(destination: name)),
            (BackupCloudFakeS3.error(403, code: "AccessDenied"), .accessDenied(destination: name)),
            (BackupCloudFakeS3.error(404, code: "NoSuchBucket"), .bucketNotFound(destination: name)),
            (BackupCloudFakeS3.error(403, code: "QuotaExceeded"), .storageFull(destination: name)),
            (.http(507), .storageFull(destination: name)),
            (.fail(.notConnectedToInternet), .noNetwork(destination: name)),
            (.fail(.timedOut), .noNetwork(destination: name)),
            (BackupCloudFakeS3.error(503, code: "SlowDown"), .serviceError(destination: name, diagnostic: "HTTP 503 SlowDown")),
            (BackupCloudFakeS3.error(400, code: "InvalidRequest"), .serviceError(destination: name, diagnostic: "HTTP 400 InvalidRequest")),
        ]
        for (reply, expected) in cases {
            let h = Harness()
            h.s3.override = reply
            await #expect(throws: expected) { try await h.destination.listSnapshots() }
        }
        let distinct: Set<CloudBackupError> = [.storageFull(destination: name), .noNetwork(destination: name),
                                                .credentialsRejected(destination: name)]
        #expect(Set(distinct.map(\.localizedDescription)).count == 3)
    }

    // MARK: Secrets

    @Test func secretNeverAppearsInErrorsOrDescriptions() async throws {
        let secret = BackupCloudFakeS3.secret
        let configuration = try #require(S3BackupConfiguration.fromInfoDictionary(Self.info()))
        var dumped = ""
        dump(configuration, to: &dumped)
        for text in [String(describing: configuration), String(reflecting: configuration), dumped, "\(configuration)"] {
            #expect(!text.contains(secret))
            #expect(!text.contains("must-not-leak"))
        }

        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try BackupCloudFixtures.write(Data("abc".utf8), in: scratch)
        let hash = BackupCloudFixtures.sha256(Data("abc".utf8))
        var errors: [any Error] = []
        for reply: BackupCloudReply in [
            BackupCloudFakeS3.error(403, code: "SignatureDoesNotMatch", message: "The signature with key \(secret) does not match"),
            BackupCloudFakeS3.error(400, code: "InvalidArgument", message: "Bad secret \(secret)"),
            BackupCloudFakeS3.error(500, code: "InternalError", message: secret),
            BackupCloudFakeS3.error(403, code: "RequestTimeTooSkewed", message: secret),
            BackupCloudFakeS3.error(403, code: "AccessDenied", message: secret),
            .http(418, body: Data("teapot \(secret)".utf8)),
            .fail(.notConnectedToInternet),
        ] {
            let h = Harness()
            h.s3.override = reply
            for operation: () async throws -> Void in [
                { _ = try await h.destination.listSnapshots() },
                { _ = try await h.destination.uploadSnapshot(from: file, name: BackupCloudNames.older, progress: nil) },
                { _ = try await h.destination.hasPDF(sha256: hash, size: 3) },
                { try await h.destination.downloadPDF(sha256: hash, to: scratch.appendingPathComponent("p"), progress: nil) },
            ] {
                do { try await operation() } catch { errors.append(error) }
            }
        }
        let corrupt = Harness()
        try await corrupt.destination.uploadPDF(from: file, sha256: hash, size: 3, progress: nil)
        corrupt.s3.corruptDownloads = true
        do { try await corrupt.destination.downloadPDF(sha256: hash, to: scratch.appendingPathComponent("q"), progress: nil) }
        catch { errors.append(error) }

        #expect(errors.count == 29)
        for error in errors {
            for text in [error.localizedDescription, String(describing: error), String(reflecting: error)] {
                #expect(!text.contains(secret), "\(type(of: error)) shows the secret")
                #expect(!text.contains("must-not-leak"))
            }
            #expect(error is CloudBackupError || error is BackupError, "unmapped: \(type(of: error))")
        }
        // No request carried the secret either.
        for request in corrupt.s3.stub.requests {
            #expect(!request.url.absoluteString.contains(secret))
            #expect(!request.headers.values.contains { $0.contains(secret) })
        }
    }
}

/// `BackupDestinationFactory.s3`, which the composition root registers when it returns one.
struct BackupCloudFactoryTests {
    @Test func thisBuildOffersNoBucket() {
        #expect(BackupDestinationFactory.s3() == nil)
        #expect(BackupDestinationFactory.s3(infoDictionary: [:]) == nil)
    }

    @Test func configuredBuildOffersTheBucket() async {
        let made = BackupDestinationFactory.s3(infoDictionary: BackupCloudS3Tests.info(displayName: "Cloudflare R2"))
        #expect(made?.id == "s3")
        #expect(made?.displayName == "Cloudflare R2")
        #expect(await made?.availability() == .available)
    }
}
