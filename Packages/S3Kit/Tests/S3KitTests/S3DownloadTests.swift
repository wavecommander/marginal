import Foundation
import Testing
@testable import S3Kit

struct S3DownloadTests {
    static let path = "/backup-bucket/app/ipad/Backups/Tuesday%20%28iPad%29.ttbackup"
    static let key = "Backups/Tuesday (iPad).ttbackup"

    /// A fresh directory per test, so leftovers can be counted.
    static func directory() throws -> URL {
        let url = Fixtures.temporaryURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func payload(_ size: Int) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }) }

    @Test func downloadsToTheDestinationAndChecksTheHash() async throws {
        let server = StubServer()
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Self.payload(200_000)
        server.expect("GET", Self.path) { request in
            #expect(request.headers["range"] == nil)
            #expect(request.headers["x-amz-content-sha256"] == S3Signer.emptyPayloadSHA256)
            Fixtures.expectSigned(request)
            return .respond(status: 200, headers: ["Content-Length": "\(body.count)", "ETag": "\"v1\""], body: body)
        }
        let destination = directory.appendingPathComponent("restored.ttbackup")
        let progress = Collected<Int64>()
        let size = try await server.client().download(key: Self.key, to: destination,
                                                      expectedSHA256: Fixtures.sha256(body).uppercased(),
                                                      progress: { done, total in
                                                          #expect(total == 200_000)
                                                          progress.append(done)
                                                      })
        #expect(size == 200_000)
        #expect(try Data(contentsOf: destination) == body)
        #expect(progress.values.last == 200_000)
        #expect(Fixtures.leftovers(in: directory, containing: "s3partial").isEmpty)
        server.verify()
    }

    @Test func aDroppedConnectionResumesWithARangeRequest() async throws {
        let server = StubServer()
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Self.payload(100_000)
        server.expect("GET", Self.path, .partial(status: 200, headers: ["Content-Length": "100000", "ETag": "\"v1\""],
                                                 body: body.prefix(30_000), error: .networkConnectionLost))
        server.expect("GET", Self.path) { request in
            #expect(request.headers["range"] == "bytes=30000-")
            #expect(request.headers["if-match"] == "\"v1\"")
            #expect(request.headers["authorization"]?.contains("SignedHeaders=host;if-match;range;") == true)
            Fixtures.expectSigned(request)
            return .partial(status: 206, headers: ["Content-Range": "bytes 30000-99999/100000", "ETag": "\"v1\"",
                                                   "Content-Length": "70000"],
                            body: body[30_000..<60_000], error: .timedOut)
        }
        server.expect("GET", Self.path) { request in
            #expect(request.headers["range"] == "bytes=60000-")
            return .respond(status: 206, headers: ["Content-Range": "bytes 60000-99999/100000", "ETag": "\"v1\""],
                            body: body.suffix(from: 60_000))
        }
        let destination = directory.appendingPathComponent("restored.ttbackup")
        try await server.client().download(key: Self.key, to: destination, expectedSHA256: Fixtures.sha256(body))
        #expect(try Data(contentsOf: destination) == body)
        #expect(Fixtures.leftovers(in: directory, containing: "s3partial").isEmpty)
        server.verify()
    }

    @Test func aChangedObjectRestartsTheDownload() async throws {
        let server = StubServer()
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Self.payload(50_000), new = Data(Self.payload(60_000).reversed())
        server.expect("GET", Self.path, .partial(status: 200, headers: ["Content-Length": "50000", "ETag": "\"v1\""],
                                                 body: old.prefix(10_000), error: .networkConnectionLost))
        server.expect("GET", Self.path, .error(412, code: "PreconditionFailed"))
        server.expect("GET", Self.path) { request in
            #expect(request.headers["range"] == nil)
            return .respond(status: 200, headers: ["Content-Length": "60000", "ETag": "\"v2\""], body: new)
        }
        let destination = directory.appendingPathComponent("restored.ttbackup")
        try await server.client().download(key: Self.key, to: destination, expectedSHA256: Fixtures.sha256(new))
        #expect(try Data(contentsOf: destination) == new)
        server.verify()
    }

    @Test func aHashMismatchRemovesTheFileAndKeepsTheOldOne() async throws {
        let server = StubServer()
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("restored.ttbackup")
        try Data("previous".utf8).write(to: destination)
        server.expect("GET", Self.path, .respond(status: 200, headers: ["Content-Length": "1000"], body: Self.payload(1000)))
        await #expect(throws: S3Error.checksumMismatch(key: Self.key)) {
            try await server.client().download(key: Self.key, to: destination,
                                               expectedSHA256: String(repeating: "0", count: 64))
        }
        #expect(try Data(contentsOf: destination) == Data("previous".utf8))
        #expect(Fixtures.leftovers(in: directory, containing: "s3partial").isEmpty)
        server.verify()
    }

    @Test func aSuccessfulDownloadReplacesAnExistingFile() async throws {
        let server = StubServer()
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("restored.ttbackup")
        try Data("previous".utf8).write(to: destination)
        server.expect("GET", Self.path, .respond(status: 200, headers: ["Content-Length": "3"], body: Data("new".utf8)))
        try await server.client().download(key: Self.key, to: destination)
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        server.verify()
    }

    @Test func cancellationRemovesThePartialFile() async throws {
        let server = StubServer()
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        server.expect("GET", Self.path, .stall(status: 200, headers: ["Content-Length": "100000"],
                                               body: Self.payload(40_000)))
        let destination = directory.appendingPathComponent("restored.ttbackup")
        let client = server.client()
        let task = Task { try await client.download(key: Self.key, to: destination) }
        _ = await server.nextStall()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(Fixtures.leftovers(in: directory, containing: "s3partial").isEmpty)
        server.verify()
    }

    @Test func aMissingObjectThrowsNotFound() async throws {
        let server = StubServer()
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        server.expect("GET", Self.path, .error(404, code: "NoSuchKey", message: "The specified key does not exist."))
        await #expect(throws: S3Error.objectNotFound(key: Self.key)) {
            try await server.client().download(key: Self.key, to: directory.appendingPathComponent("x"))
        }
        #expect(Fixtures.leftovers(in: directory, containing: "s3partial").isEmpty)
        server.verify()
    }

    @Test func aConnectionThatKeepsDroppingWithoutProgressGivesUp() async throws {
        let server = StubServer()
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<3 { server.expect("GET", Self.path, .fail(.notConnectedToInternet)) }
        await #expect(throws: S3Error.noNetwork(urlErrorCode: URLError.notConnectedToInternet.rawValue)) {
            try await server.client(maxAttempts: 3).download(key: Self.key, to: directory.appendingPathComponent("x"))
        }
        server.verify()
    }

    @Test func contentRangeParsing() {
        #expect(DownloadState.parseContentRange("bytes 100-199/1000")! == (100, 1000))
        #expect(DownloadState.parseContentRange("bytes 0-0/*")! == (0, nil))
        #expect(DownloadState.parseContentRange("items 0-1/2") == nil)
    }
}
