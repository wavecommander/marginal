import Foundation
import Testing
@testable import S3Kit

/// Conditional puts, the ETag of a put, small objects read into memory, and keys with several
/// `/`-separated segments (what sync needs: `docs/CLOUD_SYNC_FINDINGS.md` sections 1 and 2).
struct S3ConditionalTests {
    static let syncKey = "Sync/v1/books/abc"
    static let syncPath = "/backup-bucket/app/ipad/Sync/v1/books/abc"

    // MARK: Keys

    @Test func eachKeySegmentIsEncodedOnItsOwnWithLiteralSlashes() async throws {
        let server = StubServer()
        server.expect("PUT", Self.syncPath, .ok(headers: ["ETag": "\"e1\""]))
        server.expect("PUT", "/backup-bucket/app/ipad/Sync/v1/history/a%20b%2Bc/12", .ok(headers: ["ETag": "\"e2\""]))
        let client = server.client()
        try await client.putObject(data: Data("head".utf8), key: Self.syncKey)
        try await client.putObject(data: Data("old".utf8), key: "Sync/v1/history/a b+c/12")
        for request in server.requests {
            #expect(!request.url.absoluteString.contains("%2F"))
            Fixtures.expectSigned(request)
        }
        // The canonical request names the same path, slashes literal.
        let signer = S3Signer(credentials: Fixtures.stubCredentials, region: "auto")
        let canonical = signer.canonicalRequest(method: "PUT", url: server.requests[0].url, payloadSHA256: "x",
                                                date: StubServer.signingDate)
        #expect(canonical.split(separator: "\n")[1] == Self.syncPath)
        server.verify()
    }

    @Test func aThreeLevelKeyWorksForEveryOperation() async throws {
        let server = StubServer()
        server.expect("HEAD", Self.syncPath, .respond(status: 200, headers: ["Content-Length": "4", "ETag": "\"e\""]))
        server.expect("GET", Self.syncPath, .ok("head", headers: ["ETag": "\"e\""]))
        server.expect("DELETE", Self.syncPath, .respond(status: 204))
        server.expect("GET", "/backup-bucket?list-type=2&prefix=app%2Fipad%2FSync%2Fv1%2Fbooks%2F", .xml(200, """
            <ListBucketResult><IsTruncated>false</IsTruncated>
              <Contents><Key>app/ipad/Sync/v1/books/abc</Key><Size>4</Size><ETag>"e"</ETag></Contents>
            </ListBucketResult>
            """))
        let client = server.client()
        #expect(try await client.head(key: Self.syncKey)?.eTag == "\"e\"")
        #expect(try await client.getObject(key: Self.syncKey)?.data == Data("head".utf8))
        try await client.delete(key: Self.syncKey)
        let listed = try await client.list(prefix: "Sync/v1/books/")
        #expect(listed.map(\.key) == [Self.syncKey])
        #expect(listed.map(\.eTag) == ["\"e\""])
        for request in server.requests { Fixtures.expectSigned(request) }
        server.verify()
    }

    // MARK: Conditional puts

    @Test func anUnconditionalPutReturnsTheStoredETag() async throws {
        let server = StubServer()
        server.expect("PUT", Self.syncPath, .ok(headers: ["ETag": "\"9b2cf535f27731c974343645a3985328\""]))
        let eTag = try await server.client().putObject(data: Data("x".utf8), key: Self.syncKey)
        #expect(eTag == "\"9b2cf535f27731c974343645a3985328\"")
        let request = try #require(server.requests.first)
        #expect(request.headers["if-match"] == nil)
        #expect(request.headers["if-none-match"] == nil)
        server.verify()
    }

    @Test func ifMatchIsSentSignedAndReturnsTheNewETag() async throws {
        let server = StubServer()
        server.expect("PUT", Self.syncPath, .ok(headers: ["ETag": "\"new\""]))
        let eTag = try await server.client().putObject(data: Data("v2".utf8), key: Self.syncKey,
                                                       metadata: ["write-id": "0123abcd"],
                                                       condition: .ifMatch(eTag: "\"old\""))
        #expect(eTag == "\"new\"")
        let request = try #require(server.requests.first)
        #expect(request.headers["if-match"] == "\"old\"")
        #expect(request.headers["x-amz-meta-write-id"] == "0123abcd")
        let signed = request.headers["authorization"] ?? ""
        #expect(signed.contains("if-match;"))
        #expect(signed.contains("x-amz-meta-write-id"))
        Fixtures.expectSigned(request)
        server.verify()
    }

    @Test func ifAbsentSendsIfNoneMatchStarSigned() async throws {
        let server = StubServer()
        server.expect("PUT", Self.syncPath, .ok(headers: ["ETag": "\"first\""]))
        let eTag = try await server.client().putObject(data: Data("v1".utf8), key: Self.syncKey, condition: .ifAbsent)
        #expect(eTag == "\"first\"")
        let request = try #require(server.requests.first)
        #expect(request.headers["if-none-match"] == "*")
        #expect(request.headers["authorization"]?.contains("if-none-match;") == true)
        Fixtures.expectSigned(request)
        server.verify()
    }

    @Test func a412IsItsOwnErrorAndIsNotRetried() async throws {
        let server = StubServer()
        server.expect("PUT", Self.syncPath, .error(412, code: "PreconditionFailed", message: "At least one of the pre-conditions you specified did not hold"))
        server.expect("PUT", Self.syncPath, .respond(status: 412))
        let client = server.client()
        do {
            try await client.putObject(data: Data("v".utf8), key: Self.syncKey, condition: .ifMatch(eTag: "\"stale\""))
            Issue.record("expected a precondition failure")
        } catch let error as S3Error {
            #expect(error == .preconditionFailed)
            #expect(error.isPreconditionFailed)
            #expect(!error.isTransient)
            #expect(error.errorDescription?.contains("changed the file") == true)
        }
        await #expect(throws: S3Error.preconditionFailed) {
            try await client.putObject(data: Data("v".utf8), key: Self.syncKey, condition: .ifAbsent)
        }
        #expect(server.sleeps.isEmpty)
        server.verify()
    }

    @Test func aTimedOutConditionalPutIsRetriedWithTheSameCondition() async throws {
        // The first attempt committed but its answer was lost: the retry meets its own object
        // and is refused, which the caller reconciles by reading the object back.
        let server = StubServer()
        server.expect("PUT", Self.syncPath, .fail(.timedOut))
        server.expect("PUT", Self.syncPath, .error(412, code: "PreconditionFailed"))
        await #expect(throws: S3Error.preconditionFailed) {
            try await server.client().putObject(data: Data("v".utf8), key: Self.syncKey,
                                                metadata: ["write-id": "w1"], condition: .ifMatch(eTag: "\"e0\""))
        }
        #expect(server.requests.map { $0.headers["if-match"] } == ["\"e0\"", "\"e0\""])
        #expect(server.requests.map { $0.headers["x-amz-meta-write-id"] } == ["w1", "w1"])
        server.verify()
    }

    @Test func a412OnAnUnconditionalPutIsAnUnexpectedResponse() async throws {
        let server = StubServer()
        server.expect("PUT", Self.syncPath, .error(412, code: "PreconditionFailed", message: "m"))
        await #expect(throws: S3Error.unexpectedResponse(status: 412, code: "PreconditionFailed", message: "m")) {
            try await server.client().putObject(data: Data(), key: Self.syncKey)
        }
        server.verify()
    }

    @Test func aPutWithoutAnETagInTheAnswerThrows() async throws {
        let server = StubServer()
        server.expect("PUT", Self.syncPath, .ok())
        await #expect(throws: S3Error.self) {
            try await server.client().putObject(data: Data(), key: Self.syncKey, condition: .ifAbsent)
        }
        server.verify()
    }

    @Test func thePlainPutStillReturnsNothingAndNeedsNoETag() async throws {
        let server = StubServer()
        server.expect("PUT", Self.syncPath, .ok())
        try await server.client().put(data: Data("x".utf8), key: Self.syncKey)
        server.verify()
    }

    // MARK: Small objects

    @Test func getObjectReturnsDataETagAndMetadata() async throws {
        let server = StubServer()
        let body = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0) })
        server.expect("GET", Self.syncPath, .respond(status: 200, headers: [
            "Content-Length": "3000", "ETag": "\"abc\"", "x-amz-meta-write-id": "5f1e",
            "Last-Modified": "Mon, 12 Oct 2026 17:50:00 GMT"
        ], body: body))
        let object = try #require(try await server.client().getObject(key: Self.syncKey, maxBytes: 3000))
        #expect(object.data == body)
        #expect(object.eTag == "\"abc\"")
        #expect(object.metadata == ["write-id": "5f1e"])
        #expect(object.lastModified == Date(timeIntervalSince1970: 1_791_827_400))
        let request = try #require(server.requests.first)
        #expect(request.headers["if-none-match"] == nil)
        Fixtures.expectSigned(request)
        server.verify()
    }

    @Test func getObjectOnAMissingKeyIsNil() async throws {
        let server = StubServer()
        server.expect("GET", Self.syncPath, .error(404, code: "NoSuchKey"))
        server.expect("GET", Self.syncPath, .respond(status: 404))
        let client = server.client()
        #expect(try await client.getObject(key: Self.syncKey) == nil)
        #expect(try await client.getObject(key: Self.syncKey) == nil)
        server.verify()
    }

    @Test func getObjectInAMissingBucketThrows() async throws {
        let server = StubServer()
        server.expect("GET", Self.syncPath, .error(404, code: "NoSuchBucket"))
        await #expect(throws: S3Error.bucketNotFound(bucket: StubServer.bucket)) {
            try await server.client().getObject(key: Self.syncKey)
        }
        server.verify()
    }

    @Test func getObjectRefusesMoreThanTheLimit() async throws {
        let server = StubServer()
        // Announced too large.
        server.expect("GET", Self.syncPath, .respond(status: 200, headers: ["Content-Length": "11", "ETag": "\"a\""],
                                                     body: Data(count: 11)))
        // Not announced (chunked), but more arrives than allowed.
        server.expect("GET", Self.syncPath, .respond(status: 200, headers: ["ETag": "\"a\""], body: Data(count: 11)))
        let client = server.client()
        for _ in 0..<2 {
            do {
                _ = try await client.getObject(key: Self.syncKey, maxBytes: 10)
                Issue.record("expected the object to be refused")
            } catch let error as S3Error {
                #expect(error.isObjectTooLarge)
                #expect(!error.isTransient)
            }
        }
        #expect(server.sleeps.isEmpty)
        server.verify()
    }

    @Test func getObjectAcceptsExactlyTheLimit() async throws {
        let server = StubServer()
        server.expect("GET", Self.syncPath, .respond(status: 200, headers: ["ETag": "\"a\""], body: Data(count: 10)))
        #expect(try await server.client().getObject(key: Self.syncKey, maxBytes: 10)?.data.count == 10)
        server.verify()
    }

    @Test func getObjectRetriesTransientFailures() async throws {
        let server = StubServer()
        server.expect("GET", Self.syncPath, .fail(.networkConnectionLost))
        server.expect("GET", Self.syncPath, .error(503, code: "SlowDown"))
        server.expect("GET", Self.syncPath, .ok("ok", headers: ["ETag": "\"a\""]))
        #expect(try await server.client().getObject(key: Self.syncKey)?.data == Data("ok".utf8))
        #expect(server.sleeps.count == 2)
        server.verify()
    }

    @Test func getObjectIfNoneMatch() async throws {
        let server = StubServer()
        server.expect("GET", Self.syncPath, .respond(status: 304, headers: ["ETag": "\"same\""]))
        server.expect("GET", Self.syncPath, .ok("changed", headers: ["ETag": "\"other\""]))
        server.expect("GET", Self.syncPath, .error(404, code: "NoSuchKey"))
        let client = server.client()
        #expect(try await client.getObject(key: Self.syncKey, ifNoneMatch: "\"same\"") == .notModified)
        let changed = try await client.getObject(key: Self.syncKey, ifNoneMatch: "\"same\"")
        #expect(changed == .found(S3Object(data: Data("changed".utf8), eTag: "\"other\"", metadata: [:], lastModified: nil)))
        #expect(try await client.getObject(key: Self.syncKey, ifNoneMatch: "\"same\"") == .notFound)
        for request in server.requests {
            #expect(request.headers["if-none-match"] == "\"same\"")
            #expect(request.headers["authorization"]?.contains("if-none-match;") == true)
            Fixtures.expectSigned(request)
        }
        server.verify()
    }

    @Test func writeIDMetadataRoundTripsThroughPutHeadAndGet() async throws {
        let server = StubServer()
        // A stub that stores what it is given and answers with it, as the service would.
        let stored = Collected<[String: String]>()
        server.handle { request in
            switch request.method {
            case "PUT":
                stored.append(request.headers.filter { $0.key.hasPrefix("x-amz-meta-") })
                return .ok(headers: ["ETag": "\"e\""])
            case "HEAD", "GET":
                var headers = stored.values.last ?? [:]
                headers["ETag"] = "\"e\""
                headers["Content-Length"] = "1"
                return .respond(status: 200, headers: headers, body: request.method == "GET" ? Data("h".utf8) : Data())
            default:
                return nil
            }
        }
        let client = server.client()
        try await client.putObject(data: Data("h".utf8), key: Self.syncKey, metadata: ["write-id": "c0ffee"],
                                   condition: .ifAbsent)
        #expect(try await client.head(key: Self.syncKey)?.metadata == ["write-id": "c0ffee"])
        #expect(try await client.getObject(key: Self.syncKey)?.metadata == ["write-id": "c0ffee"])
        server.verify()
    }
}
