import Foundation
import Testing
@testable import S3Kit

/// New credentials on every call: `temporaryCredentials(1)`, `(2)`, ...
actor RotatingCredentialsProvider: S3CredentialsProvider {
    private(set) var calls = 0
    private(set) var rejected: [Int] = []

    func credentials() async throws -> S3Credentials {
        calls += 1
        return temporaryCredentials(calls)
    }

    func credentialsRejected(_ credentials: S3Credentials) {
        rejected.append(Int(credentials.accessKeyID.dropFirst("TMPKEY".count)) ?? 0)
    }
}

/// The generation of `temporaryCredentials(_:)` a request was signed with, from its token.
func generation(of request: RecordedRequest) -> Int? {
    guard let token = request.headers["x-amz-security-token"],
          let part = token.split(separator: "/").last?.split(separator: "+").first else { return nil }
    return Int(part)
}

/// Checks the request is signed with exactly the credentials of the generation its token names.
func expectSignedWithItsOwnGeneration(_ request: RecordedRequest, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let number = generation(of: request) else {
        Issue.record("\(request.method) \(request.target) carries no session token", sourceLocation: sourceLocation)
        return
    }
    Fixtures.expectSigned(request, with: temporaryCredentials(number), sourceLocation: sourceLocation)
}

/// Every operation with temporary credentials: the token is sent and signed on each request.
struct S3TemporaryCredentialsClientTests {
    static let mib = 1024 * 1024
    static let path = S3MultipartTests.path
    static let size = S3MultipartTests.size

    static func etag(_ number: Int) -> StubReply { .respond(status: 200, headers: ["ETag": "\"etag-\(number)\""]) }

    static func completed(_ request: RecordedRequest) -> StubReply {
        .xml(200, "<CompleteMultipartUploadResult><ETag>\"x-3\"</ETag></CompleteMultipartUploadResult>")
    }

    static func listPage(truncated: Bool, token: String? = nil) -> StubReply {
        .xml(200, "<ListBucketResult><IsTruncated>\(truncated)</IsTruncated>"
            + (token.map { "<NextContinuationToken>\($0)</NextContinuationToken>" } ?? "")
            + "<Contents><Key>app/ipad/Backups/A.ttbackup</Key><Size>1</Size></Contents></ListBucketResult>")
    }

    /// Runs every kind of request once: two list pages, head, put, delete, a single-part
    /// upload, a three-part upload (create, parts, complete, size check), a multipart upload
    /// that fails and is aborted, and a download that drops and resumes with a ranged request.
    static func exerciseEveryRequest(_ client: S3Client, server: StubServer) async throws {
        let file = try Fixtures.file(size: Self.size)
        let small = try Fixtures.file(size: 1000)
        let directory = Fixtures.temporaryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: small)
            try? FileManager.default.removeItem(at: directory)
        }
        server.expect("GET", "/backup-bucket?list-type=2&prefix=app%2Fipad%2F", Self.listPage(truncated: true, token: "t2"))
        server.expect("GET", "/backup-bucket?continuation-token=t2&list-type=2&prefix=app%2Fipad%2F",
                      Self.listPage(truncated: false))
        server.expect("HEAD", "/backup-bucket/app/ipad/k", .respond(status: 200, headers: ["Content-Length": "3"]))
        server.expect("PUT", "/backup-bucket/app/ipad/k", .ok())
        server.expect("DELETE", "/backup-bucket/app/ipad/k", .respond(status: 204))
        server.expect("PUT", "/backup-bucket/app/ipad/small", .ok())
        server.expect("POST", "\(Self.path)?uploads", S3MultipartTests.initiated())
        for number in 1...3 { server.expect("PUT", S3MultipartTests.partTarget(number), Self.etag(number)) }
        server.expect("POST", S3MultipartTests.completeTarget, reply: Self.completed)
        server.expect("HEAD", Self.path, S3MultipartTests.stored())
        server.expect("POST", "\(Self.path)?uploads", S3MultipartTests.initiated())
        server.expect("PUT", S3MultipartTests.partTarget(1), .error(400, code: "InvalidArgument"))
        server.expect("DELETE", S3MultipartTests.completeTarget, .respond(status: 204))
        let body = S3DownloadTests.payload(50_000)
        server.expect("GET", "/backup-bucket/app/ipad/k", .partial(status: 200, headers: ["Content-Length": "50000",
                                                                                          "ETag": "\"v1\""],
                                                                   body: body.prefix(20_000), error: .networkConnectionLost))
        server.expect("GET", "/backup-bucket/app/ipad/k") { request in
            #expect(request.headers["range"] == "bytes=20000-")
            return .respond(status: 206, headers: ["Content-Range": "bytes 20000-49999/50000", "ETag": "\"v1\""],
                            body: body.suffix(from: 20_000))
        }

        #expect(try await client.list().count == 2)
        #expect(try await client.head(key: "k")?.size == 3)
        try await client.put(data: Data("abc".utf8), key: "k")
        try await client.delete(key: "k")
        try await client.upload(fileAt: small, key: "small")
        try await client.upload(fileAt: file, key: "PDFs/0f1e2d.pdf", partSize: Int64(5 * Self.mib))
        await #expect(throws: S3Error.self) {
            try await client.upload(fileAt: file, key: "PDFs/0f1e2d.pdf", partSize: Int64(5 * Self.mib))
        }
        let destination = directory.appendingPathComponent("restored")
        try await client.download(key: "k", to: destination, expectedSHA256: Fixtures.sha256(body))
        #expect(try Data(contentsOf: destination) == body)
    }

    static let everyKindOfRequest = ["GET list 1", "GET list 2", "HEAD", "PUT", "DELETE", "PUT small", "POST create",
                                     "PUT part 1", "PUT part 2", "PUT part 3", "POST complete", "HEAD size",
                                     "POST create", "PUT part 1", "DELETE abort", "GET", "GET range"]

    @Test func theTokenIsSentAndSignedOnEveryRequest() async throws {
        let server = StubServer()
        let credentials = temporaryCredentials(5)
        try await Self.exerciseEveryRequest(server.client(provider: S3StaticCredentialsProvider(credentials)), server: server)
        #expect(server.requests.count == Self.everyKindOfRequest.count)
        for request in server.requests {
            #expect(request.headers["x-amz-security-token"] == credentials.sessionToken)
            Fixtures.expectSigned(request, with: credentials)
        }
        server.verify(secrets: [credentials.secretAccessKey])
    }

    @Test func noTokenIsSentWithoutOne() async throws {
        let server = StubServer()
        try await Self.exerciseEveryRequest(server.client(), server: server)
        #expect(server.requests.count == Self.everyKindOfRequest.count)
        for request in server.requests {
            #expect(request.headers["x-amz-security-token"] == nil)
            #expect(request.headers["authorization"]?.contains("x-amz-security-token") == false)
            Fixtures.expectSigned(request)
        }
        server.verify()
    }

    @Test func everyRequestAsksTheProviderAgain() async throws {
        let server = StubServer()
        let provider = RotatingCredentialsProvider()
        try await Self.exerciseEveryRequest(server.client(provider: provider), server: server)
        let generations = server.requests.compactMap(generation(of:))
        #expect(generations == Array(1...Self.everyKindOfRequest.count))
        for request in server.requests { expectSignedWithItsOwnGeneration(request) }
        #expect(await provider.calls == Self.everyKindOfRequest.count)
        server.verify()
    }

    @Test func aMultipartUploadSurvivesTheCredentialsChangingBetweenParts() async throws {
        let server = StubServer()
        let file = try Fixtures.file(size: Self.size)
        defer { try? FileManager.default.removeItem(at: file) }
        let contents = try Data(contentsOf: file)
        // Credentials that expire every 100 seconds, while each part takes 90: every part after
        // the first starts inside the refresh margin and gets fresh ones.
        let source = CredentialSource(lifetime: 100)
        let provider = source.provider()
        server.expect("POST", "\(Self.path)?uploads") { request in
            expectSignedWithItsOwnGeneration(request)
            return S3MultipartTests.initiated()
        }
        for number in 1...3 {
            server.expect("PUT", S3MultipartTests.partTarget(number)) { request in
                let start = (number - 1) * 5 * Self.mib
                #expect(request.body == contents.subdata(in: start..<min(start + 5 * Self.mib, contents.count)))
                expectSignedWithItsOwnGeneration(request)
                source.clock.advance(by: 90)
                return Self.etag(number)
            }
        }
        server.expect("POST", S3MultipartTests.completeTarget) { request in
            expectSignedWithItsOwnGeneration(request)
            return Self.completed(request)
        }
        server.expect("HEAD", Self.path, S3MultipartTests.stored())
        try await server.client(provider: provider).upload(fileAt: file, key: "PDFs/0f1e2d.pdf",
                                                           partSize: Int64(5 * Self.mib))
        #expect(server.requests.compactMap(generation(of:)) == [1, 1, 2, 3, 4, 4])
        #expect(source.fetches == 4)
        server.verify()
    }

    @Test(arguments: zip([400, 400, 401, 401], ["ExpiredToken", "InvalidToken", "Unauthorized", ""]))
    func anExpiredTokenOnAPartIsRefreshedAndThePartRetriedOnce(status: Int, code: String) async throws {
        let server = StubServer()
        let file = try Fixtures.file(size: Self.size)
        defer { try? FileManager.default.removeItem(at: file) }
        let source = CredentialSource(lifetime: 900)
        let provider = source.provider()
        let rejection: StubReply = code.isEmpty ? .respond(status: status) : .error(status, code: code)
        server.expect("POST", "\(Self.path)?uploads", S3MultipartTests.initiated())
        server.expect("PUT", S3MultipartTests.partTarget(1), Self.etag(1))
        server.expect("PUT", S3MultipartTests.partTarget(2), rejection)
        server.expect("PUT", S3MultipartTests.partTarget(2), Self.etag(2))
        server.expect("PUT", S3MultipartTests.partTarget(3), Self.etag(3))
        server.expect("POST", S3MultipartTests.completeTarget, reply: Self.completed)
        server.expect("HEAD", Self.path, S3MultipartTests.stored())
        try await server.client(provider: provider).upload(fileAt: file, key: "PDFs/0f1e2d.pdf",
                                                           partSize: Int64(5 * Self.mib))
        #expect(server.requests.compactMap(generation(of:)) == [1, 1, 1, 2, 2, 2, 2])
        for request in server.requests { expectSignedWithItsOwnGeneration(request) }
        #expect(source.fetches == 2)
        #expect(server.sleeps.isEmpty, "a refresh is not a backoff")
        server.verify()
    }

    @Test func aTokenRejectedTwiceIsTheDistinctErrorAndTheUploadIsAborted() async throws {
        let server = StubServer()
        let file = try Fixtures.file(size: Self.size)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = RotatingCredentialsProvider()
        server.expect("POST", "\(Self.path)?uploads", S3MultipartTests.initiated())
        server.expect("PUT", S3MultipartTests.partTarget(1), .error(400, code: "ExpiredToken"))
        server.expect("PUT", S3MultipartTests.partTarget(1), .error(401, code: "Unauthorized"))
        server.expect("DELETE", S3MultipartTests.completeTarget, .respond(status: 204))
        await #expect(throws: S3Error.temporaryCredentialsRejected) {
            try await server.client(provider: provider).upload(fileAt: file, key: "PDFs/0f1e2d.pdf",
                                                               partSize: Int64(5 * Self.mib))
        }
        #expect(server.requests.compactMap(generation(of:)) == [1, 2, 3, 4])
        #expect(await provider.rejected == [2, 3])
        #expect(server.sleeps.isEmpty)
        server.verify()
    }

    @Test func aRefusalOutsideThePrefixIsNotRetriedOrRefreshed() async throws {
        let server = StubServer()
        let source = CredentialSource(lifetime: 900)
        let provider = source.provider()
        server.expect("PUT", "/backup-bucket/app/ipad/k", .error(403, code: "AccessDenied", message: "Access Denied"))
        server.expect("DELETE", "/backup-bucket/app/ipad/k", .error(403, code: "AccessDenied"))
        server.expect("GET", "/backup-bucket?list-type=2&prefix=app%2Fipad%2F", .error(403, code: "AccessDenied"))
        let client = server.client(provider: provider)
        let notAllowed = S3Error.accessDenied(code: S3Error.notAllowedByCredentialsCode)
        await #expect(throws: notAllowed) { try await client.put(data: Data("x".utf8), key: "k") }
        await #expect(throws: notAllowed) { try await client.delete(key: "k") }
        await #expect(throws: notAllowed) { try await client.list() }
        #expect(server.requests.count == 3)
        #expect(source.fetches == 1)
        #expect(server.sleeps.isEmpty)
        server.verify()
    }

    /// A HEAD response has no body, so a 403 there may be an expired credential (R2's 403
    /// `SignatureDoesNotMatch`) or a refusal: one refresh tells them apart.
    @Test func aBodiless403IsRefreshedOnceThenTakenAsARefusal() async throws {
        let server = StubServer()
        let source = CredentialSource(lifetime: 900)
        let provider = source.provider()
        server.expect("HEAD", "/backup-bucket/app/ipad/k", .respond(status: 403))
        server.expect("HEAD", "/backup-bucket/app/ipad/k", .respond(status: 403))
        server.expect("HEAD", "/backup-bucket/app/ipad/j", .respond(status: 403))
        server.expect("HEAD", "/backup-bucket/app/ipad/j", .respond(status: 200, headers: ["Content-Length": "4"]))
        let client = server.client(provider: provider)
        await #expect(throws: S3Error.accessDenied(code: S3Error.notAllowedByCredentialsCode)) {
            try await client.head(key: "k")
        }
        #expect(try await client.head(key: "j")?.size == 4)
        #expect(server.requests.compactMap(generation(of:)) == [1, 2, 3, 4])
        #expect(source.fetches == 4)
        #expect(server.sleeps.isEmpty)
        server.verify()
    }

    // Measured on a real R2 bucket on 15 November 2026 (not documented): a temporary credential
    // whose JWT `exp` has passed is refused with 403 SignatureDoesNotMatch.

    @Test func signatureDoesNotMatchWithATokenIsRefreshedAndRetriedOnce() async throws {
        let server = StubServer()
        let file = try Fixtures.file(size: Self.size)
        defer { try? FileManager.default.removeItem(at: file) }
        let source = CredentialSource(lifetime: 900)
        server.expect("POST", "\(Self.path)?uploads", S3MultipartTests.initiated())
        server.expect("PUT", S3MultipartTests.partTarget(1), Self.etag(1))
        server.expect("PUT", S3MultipartTests.partTarget(2), .error(403, code: "SignatureDoesNotMatch"))
        server.expect("PUT", S3MultipartTests.partTarget(2), Self.etag(2))
        server.expect("PUT", S3MultipartTests.partTarget(3), Self.etag(3))
        server.expect("POST", S3MultipartTests.completeTarget, reply: Self.completed)
        server.expect("HEAD", Self.path, S3MultipartTests.stored())
        try await server.client(provider: source.provider()).upload(fileAt: file, key: "PDFs/0f1e2d.pdf",
                                                                    partSize: Int64(5 * Self.mib))
        #expect(server.requests.compactMap(generation(of:)) == [1, 1, 1, 2, 2, 2, 2])
        for request in server.requests { expectSignedWithItsOwnGeneration(request) }
        #expect(source.fetches == 2)
        #expect(server.sleeps.isEmpty)
        server.verify()
    }

    @Test func signatureDoesNotMatchTwiceWithATokenIsTheCredentialsRejectedError() async throws {
        let server = StubServer()
        let provider = RotatingCredentialsProvider()
        server.expect("PUT", "/backup-bucket/app/ipad/k", .error(403, code: "SignatureDoesNotMatch"))
        server.expect("PUT", "/backup-bucket/app/ipad/k", .error(403, code: "SignatureDoesNotMatch"))
        await #expect(throws: S3Error.temporaryCredentialsRejected) {
            try await server.client(provider: provider).put(data: Data("x".utf8), key: "k")
        }
        #expect(server.requests.compactMap(generation(of:)) == [1, 2])
        #expect(await provider.rejected == [1, 2])
        #expect(server.sleeps.isEmpty)
        server.verify()
    }

    @Test func clockSkewWithATokenKeepsTheClockHint() async throws {
        let server = StubServer()
        let provider = RotatingCredentialsProvider()
        server.expect("PUT", "/backup-bucket/app/ipad/k", .error(403, code: "RequestTimeTooSkewed"))
        await #expect(throws: S3Error.authenticationFailed(code: "RequestTimeTooSkewed", clockSkewed: true)) {
            try await server.client(provider: provider).put(data: Data("x".utf8), key: "k")
        }
        #expect(await provider.calls == 1)
        server.verify()
    }

    @Test func signatureDoesNotMatchWithALongLivedKeyIsNotRefreshed() async throws {
        let server = StubServer()
        server.expect("PUT", "/backup-bucket/app/ipad/k", .error(403, code: "SignatureDoesNotMatch"))
        server.expect("PUT", "/backup-bucket/app/ipad/k", .error(403, code: "SignatureDoesNotMatch"))
        await #expect(throws: S3Error.authenticationFailed(code: "SignatureDoesNotMatch", clockSkewed: false)) {
            try await server.client().put(data: Data("x".utf8), key: "k")
        }
        #expect(server.requests.count == 1)
        // A provider handing out long-lived keys (no session token) is not refreshed either.
        let longLived = S3Credentials(accessKeyID: StubServer.accessKeyID, secretAccessKey: StubServer.secret)
        let source = CredentialSource()
        let counting = S3RefreshingCredentialsProvider { _ = try await source.fetch(); return longLived }
        await #expect(throws: S3Error.authenticationFailed(code: "SignatureDoesNotMatch", clockSkewed: false)) {
            try await server.client(provider: counting).put(data: Data("x".utf8), key: "k")
        }
        #expect(server.requests.count == 2)
        #expect(source.fetches == 1)
        server.verify()
    }

    @Test func aRefusedPartAbortsTheUploadWithoutARetry() async throws {
        let server = StubServer()
        let file = try Fixtures.file(size: Self.size)
        defer { try? FileManager.default.removeItem(at: file) }
        let source = CredentialSource(lifetime: 900)
        server.expect("POST", "\(Self.path)?uploads", S3MultipartTests.initiated())
        server.expect("PUT", S3MultipartTests.partTarget(1), .error(403, code: "AccessDenied"))
        server.expect("DELETE", S3MultipartTests.completeTarget, .respond(status: 204))
        await #expect(throws: S3Error.accessDenied(code: S3Error.notAllowedByCredentialsCode)) {
            try await server.client(provider: source.provider()).upload(fileAt: file, key: "PDFs/0f1e2d.pdf",
                                                                        partSize: Int64(5 * Self.mib))
        }
        #expect(source.fetches == 1)
        server.verify()
    }

    @Test func aLongLivedKeyIsNeverRefreshed() async throws {
        let server = StubServer()
        server.expect("PUT", "/backup-bucket/app/ipad/k", .error(401, code: "Unauthorized"))
        server.expect("PUT", "/backup-bucket/app/ipad/k", .error(400, code: "ExpiredToken"))
        server.expect("PUT", "/backup-bucket/app/ipad/k", .error(403, code: "AccessDenied"))
        let client = server.client()
        await #expect(throws: S3Error.authenticationFailed(code: "Unauthorized", clockSkewed: false)) {
            try await client.put(data: Data("x".utf8), key: "k")
        }
        await #expect(throws: S3Error.authenticationFailed(code: "ExpiredToken", clockSkewed: false)) {
            try await client.put(data: Data("x".utf8), key: "k")
        }
        await #expect(throws: S3Error.accessDenied(code: "AccessDenied")) {
            try await client.put(data: Data("x".utf8), key: "k")
        }
        #expect(server.requests.count == 3)
        server.verify()
    }

    @Test func aListPageWithAnExpiredTokenIsRefreshedAndRetried() async throws {
        let server = StubServer()
        let source = CredentialSource(lifetime: 900)
        server.expect("GET", "/backup-bucket?list-type=2&prefix=app%2Fipad%2F", Self.listPage(truncated: true, token: "t2"))
        server.expect("GET", "/backup-bucket?continuation-token=t2&list-type=2&prefix=app%2Fipad%2F",
                      .error(401, code: "Unauthorized"))
        server.expect("GET", "/backup-bucket?continuation-token=t2&list-type=2&prefix=app%2Fipad%2F",
                      Self.listPage(truncated: false))
        #expect(try await server.client(provider: source.provider()).list().count == 2)
        #expect(server.requests.compactMap(generation(of:)) == [1, 1, 2])
        server.verify()
    }

    @Test func aRangedDownloadWithAnExpiredTokenIsRefreshedAndResumed() async throws {
        let server = StubServer()
        let directory = Fixtures.temporaryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = CredentialSource(lifetime: 900)
        let body = S3DownloadTests.payload(60_000)
        server.expect("GET", S3DownloadTests.path, .partial(status: 200, headers: ["Content-Length": "60000", "ETag": "\"v1\""],
                                                            body: body.prefix(25_000), error: .networkConnectionLost))
        server.expect("GET", S3DownloadTests.path, .error(400, code: "ExpiredToken"))
        server.expect("GET", S3DownloadTests.path) { request in
            #expect(request.headers["range"] == "bytes=25000-")
            #expect(request.headers["if-match"] == "\"v1\"")
            expectSignedWithItsOwnGeneration(request)
            return .respond(status: 206, headers: ["Content-Range": "bytes 25000-59999/60000", "ETag": "\"v1\""],
                            body: body.suffix(from: 25_000))
        }
        let destination = directory.appendingPathComponent("restored")
        try await server.client(provider: source.provider()).download(key: S3DownloadTests.key, to: destination,
                                                                      expectedSHA256: Fixtures.sha256(body))
        #expect(try Data(contentsOf: destination) == body)
        #expect(server.requests.compactMap(generation(of:)) == [1, 1, 2])
        #expect(source.fetches == 2)
        #expect(server.sleeps.count == 1, "one backoff for the dropped connection, none for the refresh")
        server.verify()
    }

    @Test func aDownloadWhoseTokenIsRejectedTwiceStopsAndLeavesNothing() async throws {
        let server = StubServer()
        let directory = Fixtures.temporaryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RotatingCredentialsProvider()
        server.expect("GET", S3DownloadTests.path, .error(401, code: "Unauthorized"))
        server.expect("GET", S3DownloadTests.path, .respond(status: 401))
        await #expect(throws: S3Error.temporaryCredentialsRejected) {
            try await server.client(provider: provider).download(key: S3DownloadTests.key,
                                                                 to: directory.appendingPathComponent("x"))
        }
        #expect(Fixtures.leftovers(in: directory, containing: "s3partial").isEmpty)
        #expect(await provider.rejected == [1, 2])
        server.verify()
    }

    @Test func aProviderErrorIsThrownAsItIsBeforeAnyRequest() async throws {
        let server = StubServer()
        let source = CredentialSource()
        source.failNext()
        await #expect(throws: CredentialSource.Failure()) {
            try await server.client(provider: source.provider()).put(data: Data("x".utf8), key: "k")
        }
        #expect(server.requests.isEmpty)
        server.verify()
    }

    @Test func aProviderErrorDuringADownloadIsThrownAsItIsAndLeavesNothing() async throws {
        let server = StubServer()
        let directory = Fixtures.temporaryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = CredentialSource()
        source.failNext()
        let destination = directory.appendingPathComponent("x")
        await #expect(throws: CredentialSource.Failure()) {
            try await server.client(provider: source.provider()).download(key: S3DownloadTests.key, to: destination)
        }
        #expect(server.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(Fixtures.leftovers(in: directory, containing: "s3partial").isEmpty)
        server.verify()
    }
}
