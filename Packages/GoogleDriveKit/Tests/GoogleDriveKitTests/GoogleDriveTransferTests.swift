import CryptoKit
import Foundation
import Testing
@testable import GoogleDriveKit

private let fileFields = "id,name,mimeType,size,md5Checksum,sha256Checksum,parents,appProperties,trashed,createdTime,modifiedTime"
private let KiB = 1024

private func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func md5Hex(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Plays Drive's side of one resumable session: checks each chunk against the file, keeps the
/// received count, and answers 308 with `Range` or, at the end, the file resource.
final class ResumableSession: @unchecked Sendable {
    let url: String
    let content: Data
    private let lock = NSLock()
    private var received = 0
    private(set) var violations: [String] = []
    let remoteSHA256: String?
    let remoteMD5: String?

    init(id: String, content: Data, remoteSHA256: String? = nil, remoteMD5: String? = nil, reportSHA256: Bool = true) {
        url = "\(uploadURL)?uploadType=resumable&upload_id=\(id)"
        self.content = content
        self.remoteSHA256 = reportSHA256 ? (remoteSHA256 ?? sha256Hex(content)) : nil
        self.remoteMD5 = remoteMD5 ?? md5Hex(content)
    }

    var receivedBytes: Int { lock.withLock { received } }

    /// `acceptAtMost` simulates a connection that dropped after the server stored that many bytes.
    func handle(_ request: StubServer.Request, acceptAtMost: Int? = nil) -> StubServer.Reply {
        lock.withLock {
            let total = content.count
            guard let range = request.header("Content-Range") else {
                violations.append("no Content-Range")
                return .http(400)
            }
            if request.header("Authorization") != nil { violations.append("Authorization on a session PUT") }
            if request.header("Content-Length") != String(request.body.count) {
                violations.append("Content-Length \(request.header("Content-Length") ?? "nil") for \(request.body.count) bytes")
            }
            if range == "bytes */\(total)" {
                if !request.body.isEmpty { violations.append("status query with a body") }
            } else {
                let scanner = range.dropFirst("bytes ".count).split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }
                guard range.hasPrefix("bytes "), scanner.count == 3, scanner[2] == total else {
                    violations.append("bad Content-Range \(range)")
                    return .http(400)
                }
                let (first, last) = (scanner[0], scanner[1])
                if first != received { violations.append("chunk starts at \(first), server has \(received)") }
                if request.body != content.subdata(in: first..<(last + 1)) { violations.append("body differs from file at \(first)") }
                let isLast = last + 1 == total
                if !isLast && request.body.count % (256 * KiB) != 0 { violations.append("chunk not a 256 KiB multiple") }
                received = first + min(request.body.count, acceptAtMost ?? request.body.count)
            }
            if received == total {
                let file = driveFileJSON(id: "uploaded-1", name: "book.pdf", size: Int64(total), sha256: remoteSHA256,
                                         md5: remoteMD5, parents: ["folder-1"])
                return .http(200, headers: ["Content-Type": "application/json"], body: json(file))
            }
            return .http(308, headers: received > 0 ? ["Range": "bytes=0-\(received - 1)"] : [:])
        }
    }
}

private func initiate(_ session: ResumableSession) -> StubServer.Reply {
    .http(200, headers: ["Location": session.url])
}

private func chunkRanges(_ request: [StubServer.Request]) -> [String] {
    request.map { $0.header("Content-Range") ?? "-" }
}

struct GoogleDriveUploadTests {
    let directory = TemporaryDirectory()

    @Test func uploadsInChunksWithExactRanges() async throws {
        let harness = Harness()
        let content = testBytes(3 * 512 * KiB + 1000)
        let local = directory.file("book.pdf", contents: content)
        let session = ResumableSession(id: "s1", content: content)
        harness.server.expect("POST", "\(uploadURL)?", initiate(session))
        for _ in 0..<4 { harness.server.expect("PUT", session.url) { session.handle($0) } }
        let progress = Locked<[Int64]>([])

        let file = try await harness.client.uploadFile(
            at: local, name: "book.pdf", mimeType: "application/pdf", inFolder: "folder-1",
            appProperties: ["sha256": sha256Hex(content)], expectedSHA256: sha256Hex(content),
            chunkSize: 512 * KiB, progress: { p in progress.mutate { $0.append(p.completedBytes) } })

        #expect(file.id == "uploaded-1")
        #expect(file.size == Int64(content.count))
        #expect(session.violations.isEmpty, "\(session.violations)")

        let start = harness.server.requests[0]
        #expect(start.urlWithoutQuery == uploadURL)
        #expect(start.query == ["uploadType": "resumable", "fields": fileFields])
        #expect(start.header("Authorization") == "Bearer access-1")
        #expect(start.header("Content-Type") == "application/json; charset=UTF-8")
        #expect(start.header("X-Upload-Content-Type") == "application/pdf")
        #expect(start.header("X-Upload-Content-Length") == String(content.count))
        #expect(start.json["name"] as? String == "book.pdf")
        #expect(start.json["mimeType"] as? String == "application/pdf")
        #expect(start.json["parents"] as? [String] == ["folder-1"])
        #expect(start.json["appProperties"] as? [String: String] == ["sha256": sha256Hex(content)])

        let puts = harness.server.requests("PUT", session.url)
        #expect(puts.allSatisfy { $0.url.absoluteString == session.url })
        #expect(chunkRanges(puts) == [
            "bytes 0-524287/1573864",
            "bytes 524288-1048575/1573864",
            "bytes 1048576-1572863/1573864",
            "bytes 1572864-1573863/1573864",
        ])
        #expect(puts.map { $0.header("Content-Length") } == ["524288", "524288", "524288", "1000"])
        #expect(progress.value == [524_288, 1_048_576, 1_572_864, 1_573_864])
        harness.server.verify()
    }

    @Test func roundsTheChunkSizeToA256KiBMultiple() async throws {
        let harness = Harness()
        let content = testBytes(700 * KiB)
        let session = ResumableSession(id: "s1", content: content)
        harness.server.expect("POST", "\(uploadURL)?", initiate(session))
        for _ in 0..<3 { harness.server.expect("PUT", session.url) { session.handle($0) } }

        try await harness.client.uploadFile(at: directory.file("a.pdf", contents: content), name: "a.pdf",
                                            mimeType: "application/pdf", inFolder: "folder-1", chunkSize: 300 * KiB)

        #expect(chunkRanges(harness.server.requests("PUT", session.url)) == [
            "bytes 0-262143/716800", "bytes 262144-524287/716800", "bytes 524288-716799/716800",
        ])
        #expect(session.violations.isEmpty, "\(session.violations)")
        harness.server.verify()
    }

    @Test func resumesAfterAConnectionDropsMidChunk() async throws {
        let harness = Harness()
        let content = testBytes(4 * 256 * KiB + 123)
        let session = ResumableSession(id: "s1", content: content)
        harness.server.expect("POST", "\(uploadURL)?", initiate(session))
        harness.server.expect("PUT", session.url) { session.handle($0) }
        // The second chunk breaks after the server stored 100,000 of its bytes.
        harness.server.expect("PUT", session.url) { request in
            _ = session.handle(request, acceptAtMost: 100_000)
            return .drop(.networkConnectionLost)
        }
        harness.server.expect("PUT", session.url) { session.handle($0) }  // status query
        harness.server.expect("PUT", session.url) { session.handle($0) }

        let file = try await harness.client.uploadFile(
            at: directory.file("b.pdf", contents: content), name: "b.pdf", mimeType: "application/pdf",
            inFolder: "folder-1", expectedSHA256: sha256Hex(content), chunkSize: 512 * KiB)

        #expect(file.sha256Checksum == sha256Hex(content))
        #expect(session.violations.isEmpty, "\(session.violations)")
        #expect(chunkRanges(harness.server.requests("PUT", session.url)) == [
            "bytes 0-524287/1048699",
            "bytes 524288-1048575/1048699",
            "bytes */1048699",
            "bytes 624288-1048698/1048699",
        ])
        #expect(harness.server.requests("PUT", session.url).count == 4)
        #expect(harness.sleeps.value == [.milliseconds(1500)])
        harness.server.verify()
    }

    @Test func resumesAfterAServerErrorFromWhatTheServerHas() async throws {
        let harness = Harness()
        let content = testBytes(3 * 256 * KiB)
        let session = ResumableSession(id: "s1", content: content)
        harness.server.expect("POST", "\(uploadURL)?", initiate(session))
        harness.server.expect("PUT", session.url) { request in
            _ = session.handle(request, acceptAtMost: 300_000)
            return .http(503, body: driveError(503, reason: "backendError"))
        }
        harness.server.expect("PUT", session.url) { session.handle($0) }  // status: bytes=0-299999
        harness.server.expect("PUT", session.url) { session.handle($0) }

        try await harness.client.uploadFile(at: directory.file("c.pdf", contents: content), name: "c.pdf",
                                            mimeType: "application/pdf", inFolder: "folder-1", chunkSize: 512 * KiB)

        #expect(session.violations.isEmpty, "\(session.violations)")
        #expect(chunkRanges(harness.server.requests("PUT", session.url)) == [
            "bytes 0-524287/786432",
            "bytes */786432",
            "bytes 300000-786431/786432",
        ])
        #expect(harness.sleeps.value == [.milliseconds(1500)])
        harness.server.verify()
    }

    @Test func restartsAnExpiredSession() async throws {
        let harness = Harness()
        let content = testBytes(2 * 256 * KiB + 10)
        let first = ResumableSession(id: "old", content: content)
        let second = ResumableSession(id: "new", content: content)
        harness.server.expect("POST", "\(uploadURL)?", initiate(first))
        harness.server.expect("PUT", first.url) { first.handle($0) }
        harness.server.expect("PUT", first.url, .http(404, body: driveError(404, reason: "notFound")))
        harness.server.expect("POST", "\(uploadURL)?", initiate(second))
        for _ in 0..<3 { harness.server.expect("PUT", second.url) { second.handle($0) } }

        try await harness.client.uploadFile(at: directory.file("d.pdf", contents: content), name: "d.pdf",
                                            mimeType: "application/pdf", inFolder: "folder-1", chunkSize: 256 * KiB)

        #expect(second.violations.isEmpty, "\(second.violations)")
        #expect(chunkRanges(harness.server.requests("PUT", second.url)) == [
            "bytes 0-262143/524298", "bytes 262144-524287/524298", "bytes 524288-524297/524298",
        ])
        harness.server.verify()
    }

    @Test func rateLimitedSessionStartGivesUpAfterTheBoundedAttempts() async throws {
        let harness = Harness(maxAttempts: 3)
        for _ in 0..<3 {
            harness.server.expect("POST", "\(uploadURL)?", .http(429, body: driveError(429, reason: "rateLimitExceeded")))
        }
        await #expect(throws: GoogleDriveError.rateLimited) {
            try await harness.client.uploadFile(at: directory.file("e.pdf", contents: testBytes(10)), name: "e.pdf",
                                                mimeType: "application/pdf", inFolder: "folder-1")
        }
        #expect(harness.sleeps.value == [.milliseconds(1500), .milliseconds(2500)])
        harness.server.verify()
    }

    @Test func rateLimitedChunkBacksOffAndContinues() async throws {
        let harness = Harness()
        let content = testBytes(256 * KiB + 1)
        let session = ResumableSession(id: "s1", content: content)
        harness.server.expect("POST", "\(uploadURL)?", initiate(session))
        harness.server.expect("PUT", session.url, .http(429, body: driveError(429, reason: "rateLimitExceeded")))
        harness.server.expect("PUT", session.url, .http(429, body: driveError(429, reason: "rateLimitExceeded")))
        for _ in 0..<3 { harness.server.expect("PUT", session.url) { session.handle($0) } }

        try await harness.client.uploadFile(at: directory.file("f.pdf", contents: content), name: "f.pdf",
                                            mimeType: "application/pdf", inFolder: "folder-1", chunkSize: 256 * KiB)

        #expect(chunkRanges(harness.server.requests("PUT", session.url)) == [
            "bytes 0-262143/262145", "bytes */262145", "bytes */262145", "bytes 0-262143/262145", "bytes 262144-262144/262145",
        ])
        #expect(harness.sleeps.value == [.milliseconds(1500), .milliseconds(2500)])
        harness.server.verify()
    }

    @Test func storageFullDuringUploadIsNotRetried() async throws {
        let harness = Harness()
        harness.server.expect("POST", "\(uploadURL)?", .http(403, body: driveError(403, reason: "storageQuotaExceeded")))
        await #expect(throws: GoogleDriveError.storageFull) {
            try await harness.client.uploadFile(at: directory.file("g.pdf", contents: testBytes(10)), name: "g.pdf",
                                                mimeType: "application/pdf", inFolder: "folder-1")
        }
        harness.server.verify()
    }

    @Test func checksumMismatchDeletesTheRemoteFile() async throws {
        let harness = Harness()
        let content = testBytes(1000)
        let session = ResumableSession(id: "s1", content: content, remoteSHA256: String(repeating: "0", count: 64))
        harness.server.expect("POST", "\(uploadURL)?", initiate(session))
        harness.server.expect("PUT", session.url) { session.handle($0) }
        harness.server.expect("DELETE", "\(filesURL)/uploaded-1", .http(204))

        await #expect(throws: GoogleDriveError.checksumMismatch(expected: sha256Hex(content), actual: String(repeating: "0", count: 64))) {
            try await harness.client.uploadFile(at: directory.file("h.pdf", contents: content), name: "h.pdf",
                                                mimeType: "application/pdf", inFolder: "folder-1",
                                                expectedSHA256: sha256Hex(content))
        }
        #expect(harness.server.requests("DELETE", filesURL).first?.header("Authorization") == "Bearer access-1")
        harness.server.verify()
    }

    @Test func fallsBackToMD5WhenDriveHasNoSHA256() async throws {
        let harness = Harness()
        let content = testBytes(1000)
        let session = ResumableSession(id: "s1", content: content, remoteMD5: String(repeating: "f", count: 32), reportSHA256: false)
        harness.server.expect("POST", "\(uploadURL)?", initiate(session))
        harness.server.expect("PUT", session.url) { session.handle($0) }
        harness.server.expect("DELETE", "\(filesURL)/uploaded-1", .http(204))

        await #expect(throws: GoogleDriveError.checksumMismatch(expected: md5Hex(content), actual: String(repeating: "f", count: 32))) {
            try await harness.client.uploadFile(at: directory.file("i.pdf", contents: content), name: "i.pdf",
                                                mimeType: "application/pdf", inFolder: "folder-1",
                                                expectedSHA256: sha256Hex(content))
        }
        harness.server.verify()
    }

    @Test func aLocalFileThatIsNotTheExpectedOneIsRefused() async throws {
        let harness = Harness()
        let content = testBytes(1000)
        let session = ResumableSession(id: "s1", content: content)
        harness.server.expect("POST", "\(uploadURL)?", initiate(session))
        harness.server.expect("PUT", session.url) { session.handle($0) }
        harness.server.expect("DELETE", "\(filesURL)/uploaded-1", .http(204))
        let wrong = String(repeating: "a", count: 64)
        await #expect(throws: GoogleDriveError.checksumMismatch(expected: wrong, actual: sha256Hex(content))) {
            try await harness.client.uploadFile(at: directory.file("j.pdf", contents: content), name: "j.pdf",
                                                mimeType: "application/pdf", inFolder: "folder-1", expectedSHA256: wrong)
        }
        harness.server.verify()
    }

    @Test func uploadsAnEmptyFile() async throws {
        let harness = Harness()
        let session = ResumableSession(id: "s1", content: Data())
        harness.server.expect("POST", "\(uploadURL)?", initiate(session))
        harness.server.expect("PUT", session.url) { session.handle($0) }
        let file = try await harness.client.uploadFile(at: directory.file("empty", contents: Data()), name: "empty",
                                                       mimeType: "application/octet-stream", inFolder: "folder-1",
                                                       expectedSHA256: sha256Hex(Data()))
        #expect(file.size == 0)
        #expect(chunkRanges(harness.server.requests("PUT", session.url)) == ["bytes */0"])
        harness.server.verify()
    }

    @Test func cancellationStopsTheUpload() async throws {
        let harness = Harness()
        let content = testBytes(4 * 256 * KiB)
        let session = ResumableSession(id: "s1", content: content)
        harness.server.expect("POST", "\(uploadURL)?", initiate(session))
        harness.server.expect("PUT", session.url) { session.handle($0) }
        harness.server.expect("PUT", session.url, delay: 10) { session.handle($0) }
        let local = directory.file("k.pdf", contents: content)
        let client = harness.client
        let task = Task {
            try await client.uploadFile(at: local, name: "k.pdf", mimeType: "application/pdf", inFolder: "folder-1",
                                        chunkSize: 256 * KiB)
        }
        while harness.server.requests.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        harness.server.verify()
    }
}

struct GoogleDriveDownloadTests {
    let directory = TemporaryDirectory()

    private func metadata(_ harness: Harness, id: String = "d1", content: Data, sha256: String? = nil, md5: String? = nil) {
        harness.server.expect("GET", "\(filesURL)/\(id)?", .http(200, body: json(driveFileJSON(
            id: id, name: "book.pdf", size: Int64(content.count), sha256: sha256 ?? sha256Hex(content), md5: md5 ?? md5Hex(content)))))
    }

    @Test func downloadsToTheDestination() async throws {
        let harness = Harness()
        let content = testBytes(2 * 1024 * KiB + 77)
        metadata(harness, content: content)
        harness.server.expect("GET", "\(filesURL)/d1?alt=media", .http(200, body: content))
        let destination = directory.url.appendingPathComponent("book.pdf")
        let progress = Locked<[Int64]>([])

        let file = try await harness.client.downloadFile(id: "d1", to: destination, expectedSHA256: sha256Hex(content),
                                                         progress: { p in progress.mutate { $0.append(p.completedBytes) } })

        #expect(file.id == "d1")
        #expect(try Data(contentsOf: destination) == content)
        #expect(directory.contents == ["book.pdf"])
        let media = harness.server.requests[1]
        #expect(media.url.absoluteString == "\(filesURL)/d1?alt=media")
        #expect(media.header("Authorization") == "Bearer access-1")
        #expect(media.header("Range") == nil)
        #expect(harness.server.requests[0].query == ["fields": fileFields])
        #expect(progress.value.last == Int64(content.count))
        #expect(progress.value == progress.value.sorted())
        harness.server.verify()
    }

    @Test func resumesWithARangeAfterAnInterruption() async throws {
        let harness = Harness()
        let content = testBytes(600 * KiB)
        metadata(harness, content: content)
        harness.server.expect("GET", "\(filesURL)/d1?alt=media",
                              .partial(200, body: content.prefix(200_000), then: .networkConnectionLost))
        harness.server.expect("GET", "\(filesURL)/d1?alt=media",
                              .http(206, headers: ["Content-Range": "bytes 200000-\(content.count - 1)/\(content.count)"],
                                    body: content.subdata(in: 200_000..<content.count)))
        let destination = directory.url.appendingPathComponent("book.pdf")

        try await harness.client.downloadFile(id: "d1", to: destination, expectedSHA256: sha256Hex(content))

        #expect(try Data(contentsOf: destination) == content)
        #expect(harness.server.requests[2].header("Range") == "bytes=200000-")
        #expect(harness.sleeps.value == [.milliseconds(1500)])
        harness.server.verify()
    }

    @Test func startsOverWhenTheServerIgnoresTheRange() async throws {
        let harness = Harness()
        let content = testBytes(300 * KiB)
        metadata(harness, content: content)
        harness.server.expect("GET", "\(filesURL)/d1?alt=media", .partial(200, body: content.prefix(1000), then: .timedOut))
        harness.server.expect("GET", "\(filesURL)/d1?alt=media", .http(200, body: content))
        let destination = directory.url.appendingPathComponent("book.pdf")
        try await harness.client.downloadFile(id: "d1", to: destination)
        #expect(try Data(contentsOf: destination) == content)
        harness.server.verify()
    }

    @Test func checksumMismatchRemovesThePartialFile() async throws {
        let harness = Harness()
        let content = testBytes(5000)
        var corrupted = content
        corrupted[10] ^= 0xFF
        metadata(harness, content: content)
        harness.server.expect("GET", "\(filesURL)/d1?alt=media", .http(200, body: corrupted))
        let destination = directory.url.appendingPathComponent("book.pdf")

        await #expect(throws: GoogleDriveError.checksumMismatch(expected: sha256Hex(content), actual: sha256Hex(corrupted))) {
            try await harness.client.downloadFile(id: "d1", to: destination)
        }
        #expect(directory.contents.isEmpty)
        harness.server.verify()
    }

    @Test func refusesBeforeDownloadingWhenDriveReportsAnotherChecksum() async throws {
        let harness = Harness()
        let content = testBytes(5000)
        metadata(harness, content: content)
        let wanted = String(repeating: "b", count: 64)
        await #expect(throws: GoogleDriveError.checksumMismatch(expected: wanted, actual: sha256Hex(content))) {
            try await harness.client.downloadFile(id: "d1", to: directory.url.appendingPathComponent("x.pdf"),
                                                  expectedSHA256: wanted)
        }
        #expect(directory.contents.isEmpty)
        harness.server.verify()
    }

    @Test func cancellationRemovesThePartialFile() async throws {
        let harness = Harness()
        let content = testBytes(3 * 1024 * KiB)
        metadata(harness, content: content)
        harness.server.expect("GET", "\(filesURL)/d1?alt=media", .hang(200, body: content.prefix(1536 * KiB)))
        let destination = directory.url.appendingPathComponent("book.pdf")
        let client = harness.client
        let received = Locked<Int64>(0)
        let task = Task {
            try await client.downloadFile(id: "d1", to: destination, progress: { p in received.value = p.completedBytes })
        }
        while received.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: destination.path + ".partial"))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(directory.contents.isEmpty)
        harness.server.verify()
    }

    @Test func missingFileIsNotFound() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)/gone?", .http(404, body: driveError(404, reason: "notFound")))
        await #expect(throws: GoogleDriveError.notFound) {
            try await harness.client.downloadFile(id: "gone", to: directory.url.appendingPathComponent("x.pdf"))
        }
        #expect(directory.contents.isEmpty)
        harness.server.verify()
    }

    @Test func a401DuringDownloadRefreshesOnce() async throws {
        let harness = Harness()
        let content = testBytes(1000)
        metadata(harness, content: content)
        harness.server.expect("GET", "\(filesURL)/d1?alt=media", .http(401, body: driveError(401, reason: "authError")))
        harness.server.expect("POST", tokenURL, tokenResponse("access-2"))
        harness.server.expect("GET", "\(filesURL)/d1?alt=media", .http(200, body: content))
        let destination = directory.url.appendingPathComponent("book.pdf")
        try await harness.client.downloadFile(id: "d1", to: destination)
        #expect(harness.server.requests[3].header("Authorization") == "Bearer access-2")
        #expect(try Data(contentsOf: destination) == content)
        harness.server.verify()
    }
}
