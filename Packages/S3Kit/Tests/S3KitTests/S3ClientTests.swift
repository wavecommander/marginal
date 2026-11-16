import Foundation
import Testing
@testable import S3Kit

/// Request shapes and response handling for list, head, put, delete and single-part upload.
struct S3ClientTests {
    static let awkwardKey = "Backups/My Notes + Café (copy) [1]&=?#~.ttbackup"
    static let awkwardPath = "/backup-bucket/app/ipad/Backups/"
        + "My%20Notes%20%2B%20Caf%C3%A9%20%28copy%29%20%5B1%5D%26%3D%3F%23~.ttbackup"

    @Test func listFollowsContinuationTokensAndStripsThePrefix() async throws {
        let server = StubServer()
        let token = "1/a+b=c d"
        server.expect("GET", "/backup-bucket?list-type=2&prefix=app%2Fipad%2FBackups%2F", .xml(200, """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <Name>backup-bucket</Name><Prefix>app/ipad/Backups/</Prefix><KeyCount>2</KeyCount><MaxKeys>1000</MaxKeys>
              <IsTruncated>true</IsTruncated><NextContinuationToken>\(token)</NextContinuationToken>
              <Contents><Key>app/ipad/Backups/A &amp; B.ttbackup</Key><LastModified>2026-10-12T17:50:30.000Z</LastModified>
                <ETag>"abc"</ETag><ChecksumAlgorithm>CRC32</ChecksumAlgorithm><Size>1234</Size>
                <Owner><ID>x</ID></Owner><StorageClass>STANDARD</StorageClass></Contents>
              <Contents><Key>app/ipad/Backups/Café.ttbackup</Key><LastModified>2026-10-13T08:00:00Z</LastModified>
                <Size>0</Size></Contents>
            </ListBucketResult>
            """))
        server.expect("GET", "/backup-bucket?continuation-token=1%2Fa%2Bb%3Dc%20d&list-type=2&prefix=app%2Fipad%2FBackups%2F",
                      .xml(200, """
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><IsTruncated>false</IsTruncated>
              <Contents><Key>app/ipad/Backups/Z.ttbackup</Key><Size>9876543210</Size>
                <LastModified>2026-10-14T00:00:00.000Z</LastModified></Contents><Unknown><Nested/></Unknown>
            </ListBucketResult>
            """))
        let objects = try await server.client().list(prefix: "Backups/")
        #expect(objects.map(\.key) == ["Backups/A & B.ttbackup", "Backups/Café.ttbackup", "Backups/Z.ttbackup"])
        #expect(objects.map(\.size) == [1234, 0, 9_876_543_210])
        #expect(objects[0].eTag == "\"abc\"")
        #expect(objects[0].lastModified == Date(timeIntervalSince1970: 1_791_827_430))
        #expect(objects[1].lastModified == Date(timeIntervalSince1970: 1_791_878_400))
        for request in server.requests {
            #expect(request.headers["x-amz-content-sha256"] == S3Signer.emptyPayloadSHA256)
            Fixtures.expectSigned(request)
        }
        server.verify()
    }

    @Test func listWithoutAPrefixCoversTheWholeBucket() async throws {
        let server = StubServer()
        server.expect("GET", "/backup-bucket?list-type=2",
                      .xml(200, "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"))
        #expect(try await server.client(prefix: "").list().isEmpty)
        server.verify()
    }

    @Test func listUnderTheConfiguredPrefixOnly() async throws {
        let server = StubServer()
        server.expect("GET", "/backup-bucket?list-type=2&prefix=app%2Fipad%2F",
                      .xml(200, "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"))
        #expect(try await server.client().list().isEmpty)
        server.verify()
    }

    @Test func headReturnsSizeAndMetadata() async throws {
        let server = StubServer()
        server.expect("HEAD", Self.awkwardPath, .respond(status: 200, headers: [
            "Content-Length": "5242880", "ETag": "\"d41d8\"", "Last-Modified": "Mon, 12 Oct 2026 17:50:00 GMT",
            "x-amz-meta-sha256": "abc123", "X-Amz-Meta-Created": "2026-11-15", "Content-Type": "application/octet-stream"
        ]))
        let head = try #require(try await server.client().head(key: Self.awkwardKey))
        #expect(head.size == 5_242_880)
        #expect(head.metadata == ["sha256": "abc123", "created": "2026-11-15"])
        #expect(head.eTag == "\"d41d8\"")
        #expect(head.lastModified == Date(timeIntervalSince1970: 1_791_827_400))
        Fixtures.expectSigned(server.requests[0])
        server.verify()
    }

    @Test func headOnAMissingKeyIsNil() async throws {
        let server = StubServer()
        server.expect("HEAD", "/backup-bucket/app/ipad/PDFs/missing.pdf", .respond(status: 404))
        #expect(try await server.client().head(key: "PDFs/missing.pdf") == nil)
        server.verify()
    }

    @Test func headForbiddenIsAccessDenied() async throws {
        let server = StubServer()
        server.expect("HEAD", "/backup-bucket/app/ipad/x", .respond(status: 403))
        await #expect(throws: S3Error.accessDenied(code: "HTTP 403")) { try await server.client().head(key: "x") }
        server.verify()
    }

    @Test func putSendsTheBodyItsHashAndMetadata() async throws {
        let server = StubServer()
        let data = Data("snapshot bytes".utf8)
        server.expect("PUT", Self.awkwardPath, .ok())
        try await server.client().put(data: data, key: Self.awkwardKey, metadata: ["Snapshot-Version": "3"])
        let request = try #require(server.requests.first)
        #expect(request.body == data)
        #expect(request.headers["x-amz-content-sha256"] == Fixtures.sha256(data))
        #expect(request.headers["x-amz-meta-snapshot-version"] == "3")
        #expect(request.headers["authorization"]?.contains("x-amz-meta-snapshot-version") == true)
        Fixtures.expectSigned(request)
        server.verify()
    }

    @Test func keysAreNFCNormalized() async throws {
        let server = StubServer()
        server.expect("PUT", "/backup-bucket/app/ipad/Caf%C3%A9", .ok())
        try await server.client().put(data: Data(), key: "Cafe\u{301}")
        #expect(server.requests.first?.headers["x-amz-content-sha256"] == S3Signer.emptyPayloadSHA256)
        server.verify()
    }

    @Test func invalidKeysAndMetadataAreRejectedBeforeAnyRequest() async throws {
        let server = StubServer()
        let client = server.client()
        for key in ["", "a//b", "/a", "a/", "a/../b", "./a", "tab\tkey", String(repeating: "k", count: 1020)] {
            await #expect(throws: S3Error.invalidKey(key: key)) { try await client.put(data: Data(), key: key) }
        }
        await #expect(throws: S3Error.invalidMetadata(name: "bad name")) {
            try await client.put(data: Data(), key: "k", metadata: ["bad name": "v"])
        }
        await #expect(throws: S3Error.invalidMetadata(name: "title")) {
            try await client.put(data: Data(), key: "k", metadata: ["title": "Café"])
        }
        #expect(server.requests.isEmpty)
        server.verify()
    }

    @Test func deleteSucceedsWhetherOrNotTheObjectExists() async throws {
        let server = StubServer()
        server.expect("DELETE", "/backup-bucket/app/ipad/PDFs/abc.pdf", .respond(status: 204))
        server.expect("DELETE", "/backup-bucket/app/ipad/PDFs/abc.pdf", .error(404, code: "NoSuchKey"))
        server.expect("DELETE", "/backup-bucket/app/ipad/PDFs/abc.pdf", .respond(status: 404))
        let client = server.client()
        try await client.delete(key: "PDFs/abc.pdf")
        try await client.delete(key: "PDFs/abc.pdf")
        try await client.delete(key: "PDFs/abc.pdf")
        Fixtures.expectSigned(server.requests[0])
        server.verify()
    }

    @Test func deleteInAMissingBucketThrows() async throws {
        let server = StubServer()
        server.expect("DELETE", "/backup-bucket/app/ipad/k", .error(404, code: "NoSuchBucket"))
        await #expect(throws: S3Error.bucketNotFound(bucket: StubServer.bucket)) {
            try await server.client().delete(key: "k")
        }
        server.verify()
    }

    @Test func aFileOfAtMostOnePartIsOnePutObject() async throws {
        let server = StubServer()
        let file = try Fixtures.file(size: 300_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let contents = try Data(contentsOf: file)
        server.expect("PUT", "/backup-bucket/app/ipad/Backups/Small%20one.ttbackup", .ok())
        let progress = Collected<Int64>()
        try await server.client().upload(fileAt: file, key: "Backups/Small one.ttbackup", metadata: ["kind": "snapshot"],
                                         progress: { done, total in
                                             #expect(total == 300_000)
                                             progress.append(done)
                                         })
        let request = try #require(server.requests.first)
        #expect(request.body == contents)
        #expect(request.headers["x-amz-content-sha256"] == Fixtures.sha256(contents))
        #expect(request.headers["x-amz-meta-kind"] == "snapshot")
        #expect(progress.values == [0, 300_000])
        Fixtures.expectSigned(request)
        server.verify()
    }

    @Test func transientFailuresAreRetriedWithBackoff() async throws {
        let server = StubServer()
        server.expect("PUT", "/backup-bucket/app/ipad/k", .fail(.networkConnectionLost))
        server.expect("PUT", "/backup-bucket/app/ipad/k", .error(503, code: "SlowDown"))
        server.expect("PUT", "/backup-bucket/app/ipad/k", .ok())
        try await server.client().put(data: Data("x".utf8), key: "k")
        #expect(server.sleeps == [.milliseconds(100), .milliseconds(200)])
        server.verify()
    }

    @Test func permanentFailuresAreNotRetried() async throws {
        let server = StubServer()
        server.expect("PUT", "/backup-bucket/app/ipad/k", .error(403, code: "AccessDenied"))
        await #expect(throws: S3Error.accessDenied(code: "AccessDenied")) {
            try await server.client().put(data: Data("x".utf8), key: "k")
        }
        #expect(server.sleeps.isEmpty)
        server.verify()
    }

    @Test func retriesAreBounded() async throws {
        let server = StubServer()
        for _ in 0..<3 { server.expect("GET", "/backup-bucket?list-type=2&prefix=app%2Fipad%2F", .error(500, code: "InternalError")) }
        await #expect(throws: S3Error.unexpectedResponse(status: 500, code: "InternalError", message: "message")) {
            try await server.client(maxAttempts: 3).list()
        }
        server.verify()
    }

    @Test func theStubFailsTheTestOnAnyRequestItDoesNotExpect() async throws {
        let server = StubServer()
        server.expect("HEAD", "/backup-bucket/app/ipad/expected", .respond(status: 404))
        await #expect(throws: S3Error.unexpectedResponse(status: 418, code: nil, message: nil)) {
            try await server.client().delete(key: "surprise")
        }
        withKnownIssue("one unexpected request and one unmet expectation") { server.verify() }
    }

    @Test func backoffIsExponentialCappedAndJittered() {
        let policy = S3RetryPolicy(maxAttempts: 10, initialDelay: .milliseconds(500), maximumDelay: .seconds(4),
                                   random: { 0 })
        #expect(policy.delay(beforeRetry: 1) == .milliseconds(250))
        #expect(policy.delay(beforeRetry: 2) == .milliseconds(500))
        #expect(policy.delay(beforeRetry: 4) == .seconds(2))
        #expect(policy.delay(beforeRetry: 9) == .seconds(2), "capped at maximumDelay, halved by jitter")
        let full = S3RetryPolicy(initialDelay: .milliseconds(500), maximumDelay: .seconds(4), random: { 1 })
        #expect(full.delay(beforeRetry: 3) == .seconds(2))
    }
}
