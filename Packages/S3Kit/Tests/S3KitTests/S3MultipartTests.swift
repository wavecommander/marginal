import Foundation
import Testing
@testable import S3Kit

struct S3MultipartTests {
    static let mib = 1024 * 1024
    static let path = "/backup-bucket/app/ipad/PDFs/0f1e2d.pdf"
    static let uploadID = "up/1+x="
    static let encodedUploadID = "up%2F1%2Bx%3D"
    static let size = 12 * mib + 123

    static func initiated() -> StubReply {
        .xml(200, """
            <?xml version="1.0" encoding="UTF-8"?>
            <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <Bucket>backup-bucket</Bucket><Key>app/ipad/PDFs/0f1e2d.pdf</Key><UploadId>\(uploadID)</UploadId>
            </InitiateMultipartUploadResult>
            """)
    }

    static func partTarget(_ number: Int) -> String { "\(path)?partNumber=\(number)&uploadId=\(encodedUploadID)" }
    static var completeTarget: String { "\(path)?uploadId=\(encodedUploadID)" }

    /// Checks a part's number, byte range and payload hash against the file, then answers with an ETag.
    static func part(_ number: Int, of contents: Data, partSize: Int = 5 * mib) -> @Sendable (RecordedRequest) -> StubReply {
        { request in
            let start = (number - 1) * partSize
            let expected = contents.subdata(in: start..<min(start + partSize, contents.count))
            #expect(request.body == expected, "part \(number) carries bytes \(start)..<\(start + expected.count)")
            #expect(request.headers["x-amz-content-sha256"] == Fixtures.sha256(expected))
            Fixtures.expectSigned(request)
            return .respond(status: 200, headers: ["ETag": "\"etag-\(number)&<x>\""])
        }
    }

    static let completeBody = #"<?xml version="1.0" encoding="UTF-8"?>"#
        + #"<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">"#
        + "<Part><ETag>&quot;etag-1&amp;&lt;x&gt;&quot;</ETag><PartNumber>1</PartNumber></Part>"
        + "<Part><ETag>&quot;etag-2&amp;&lt;x&gt;&quot;</ETag><PartNumber>2</PartNumber></Part>"
        + "<Part><ETag>&quot;etag-3&amp;&lt;x&gt;&quot;</ETag><PartNumber>3</PartNumber></Part>"
        + "</CompleteMultipartUpload>"

    static func completed(_ request: RecordedRequest) -> StubReply {
        #expect(String(decoding: request.body, as: UTF8.self) == completeBody)
        #expect(request.headers["x-amz-content-sha256"] == Fixtures.sha256(request.body))
        #expect(request.headers["content-type"] == "application/xml")
        Fixtures.expectSigned(request)
        // S3 may send whitespace to keep the connection open before the document.
        return .xml(200, "  \n  " + """
            <?xml version="1.0" encoding="UTF-8"?>
            <CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <Location>https://example/x</Location><Bucket>backup-bucket</Bucket><Key>app/ipad/PDFs/0f1e2d.pdf</Key>
              <ETag>"3858f62230ac3c915f300c664312c11f-3"</ETag>
            </CompleteMultipartUploadResult>
            """)
    }

    static func stored(size: Int = size) -> StubReply {
        .respond(status: 200, headers: ["Content-Length": "\(size)", "ETag": "\"x-3\""])
    }

    @Test func aLargeFileGoesUpInEqualPartsAndIsVerified() async throws {
        let server = StubServer()
        let file = try Fixtures.file(size: Self.size)
        defer { try? FileManager.default.removeItem(at: file) }
        let contents = try Data(contentsOf: file)
        server.expect("POST", "\(Self.path)?uploads") { request in
            #expect(request.headers["x-amz-meta-sha256"] == "0f1e2d")
            #expect(request.headers["x-amz-content-sha256"] == S3Signer.emptyPayloadSHA256)
            #expect(request.body.isEmpty)
            Fixtures.expectSigned(request)
            return Self.initiated()
        }
        for number in 1...3 { server.expect("PUT", Self.partTarget(number), reply: Self.part(number, of: contents)) }
        server.expect("POST", Self.completeTarget, reply: Self.completed)
        server.expect("HEAD", Self.path, Self.stored())

        let progress = Collected<Int64>()
        try await server.client().upload(fileAt: file, key: "PDFs/0f1e2d.pdf", metadata: ["sha256": "0f1e2d"],
                                         partSize: Int64(5 * Self.mib), progress: { done, _ in progress.append(done) })
        #expect(progress.values == [0, Int64(5 * Self.mib), Int64(10 * Self.mib), Int64(Self.size)])
        server.verify()
    }

    @Test func aFailedPartIsRetriedOnItsOwn() async throws {
        let server = StubServer()
        let file = try Fixtures.file(size: Self.size)
        defer { try? FileManager.default.removeItem(at: file) }
        let contents = try Data(contentsOf: file)
        server.expect("POST", "\(Self.path)?uploads", Self.initiated())
        server.expect("PUT", Self.partTarget(1), reply: Self.part(1, of: contents))
        server.expect("PUT", Self.partTarget(2), .fail(.networkConnectionLost))
        server.expect("PUT", Self.partTarget(2), .error(500, code: "InternalError"))
        server.expect("PUT", Self.partTarget(2), reply: Self.part(2, of: contents))
        server.expect("PUT", Self.partTarget(3), reply: Self.part(3, of: contents))
        server.expect("POST", Self.completeTarget, reply: Self.completed)
        server.expect("HEAD", Self.path, Self.stored())
        try await server.client().upload(fileAt: file, key: "PDFs/0f1e2d.pdf", partSize: Int64(5 * Self.mib))
        #expect(server.sleeps == [.milliseconds(100), .milliseconds(200)])
        server.verify()
    }

    @Test func aPartThatKeepsFailingAbortsTheUpload() async throws {
        let server = StubServer()
        let file = try Fixtures.file(size: Self.size)
        defer { try? FileManager.default.removeItem(at: file) }
        let contents = try Data(contentsOf: file)
        server.expect("POST", "\(Self.path)?uploads", Self.initiated())
        server.expect("PUT", Self.partTarget(1), reply: Self.part(1, of: contents))
        for _ in 0..<4 { server.expect("PUT", Self.partTarget(2), .fail(.timedOut)) }
        server.expect("DELETE", Self.completeTarget, .respond(status: 204))
        await #expect(throws: S3Error.noNetwork(urlErrorCode: URLError.timedOut.rawValue)) {
            try await server.client(maxAttempts: 4).upload(fileAt: file, key: "PDFs/0f1e2d.pdf",
                                                           partSize: Int64(5 * Self.mib))
        }
        #expect(server.sleeps.count == 3)
        server.verify()
    }

    @Test func cancellationAbortsTheUpload() async throws {
        let server = StubServer()
        let file = try Fixtures.file(size: Self.size)
        defer { try? FileManager.default.removeItem(at: file) }
        let contents = try Data(contentsOf: file)
        server.expect("POST", "\(Self.path)?uploads", Self.initiated())
        server.expect("PUT", Self.partTarget(1), reply: Self.part(1, of: contents))
        server.expect("PUT", Self.partTarget(2), .hang)
        server.expect("DELETE", Self.completeTarget, .respond(status: 204))
        let client = server.client()
        let task = Task {
            try await client.upload(fileAt: file, key: "PDFs/0f1e2d.pdf", partSize: Int64(5 * Self.mib))
        }
        _ = await server.nextStall()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.requests.last?.method == "DELETE")
        server.verify()
    }

    @Test func anErrorBodyWithHTTP200FailsTheCompletion() async throws {
        let server = StubServer()
        let file = try Fixtures.file(size: Self.size)
        defer { try? FileManager.default.removeItem(at: file) }
        let contents = try Data(contentsOf: file)
        server.expect("POST", "\(Self.path)?uploads", Self.initiated())
        for number in 1...3 { server.expect("PUT", Self.partTarget(number), reply: Self.part(number, of: contents)) }
        server.expect("POST", Self.completeTarget, .xml(200, """
               <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>InvalidPart</Code><Message>One or more of the specified parts could not be found.</Message>
            <RequestId>656c76696e6727732072657175657374</RequestId></Error>
            """))
        server.expect("DELETE", Self.completeTarget, .respond(status: 204))
        await #expect(throws: S3Error.unexpectedResponse(status: 200, code: "InvalidPart",
                                                         message: "One or more of the specified parts could not be found.")) {
            try await server.client().upload(fileAt: file, key: "PDFs/0f1e2d.pdf", partSize: Int64(5 * Self.mib))
        }
        server.verify()
    }

    @Test func aTransientErrorBodyWithHTTP200IsRetried() async throws {
        let server = StubServer()
        let file = try Fixtures.file(size: Self.size)
        defer { try? FileManager.default.removeItem(at: file) }
        let contents = try Data(contentsOf: file)
        server.expect("POST", "\(Self.path)?uploads", Self.initiated())
        for number in 1...3 { server.expect("PUT", Self.partTarget(number), reply: Self.part(number, of: contents)) }
        server.expect("POST", Self.completeTarget, .xml(200, """
                <Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>
            """))
        server.expect("POST", Self.completeTarget, reply: Self.completed)
        server.expect("HEAD", Self.path, Self.stored())
        try await server.client().upload(fileAt: file, key: "PDFs/0f1e2d.pdf", partSize: Int64(5 * Self.mib))
        server.verify()
    }

    @Test func aStoredSizeThatDiffersFails() async throws {
        let server = StubServer()
        let file = try Fixtures.file(size: Self.size)
        defer { try? FileManager.default.removeItem(at: file) }
        let contents = try Data(contentsOf: file)
        server.expect("POST", "\(Self.path)?uploads", Self.initiated())
        for number in 1...3 { server.expect("PUT", Self.partTarget(number), reply: Self.part(number, of: contents)) }
        server.expect("POST", Self.completeTarget, reply: Self.completed)
        server.expect("HEAD", Self.path, Self.stored(size: 10 * Self.mib))
        await #expect(throws: S3Error.sizeMismatch(key: "PDFs/0f1e2d.pdf", expected: Int64(Self.size),
                                                   actual: Int64(10 * Self.mib))) {
            try await server.client().upload(fileAt: file, key: "PDFs/0f1e2d.pdf", partSize: Int64(5 * Self.mib))
        }
        server.verify()
    }

    @Test func thePartSizeIsRaisedWhenTheFileWouldNeedTooManyParts() throws {
        let mib = Int64(Self.mib), gib = 1024 * mib
        #expect(try S3Client.partSize(forFileSize: gib) == 16 * mib, "a 1 GB PDF: 64 parts of the default size")
        #expect(try S3Client.partSize(forFileSize: 10_000 * 16 * mib) == 16 * mib, "exactly 10,000 parts")
        #expect(try S3Client.partSize(forFileSize: 10_000 * 16 * mib + 1) == 17 * mib)
        let large = try S3Client.partSize(forFileSize: 200 * gib)
        #expect(large == 21 * mib)
        #expect((200 * gib + large - 1) / large <= 10_000)
        #expect(try S3Client.partSize(forFileSize: 100 * mib, preferred: mib) == 5 * mib, "never below 5 MiB")
        #expect(try S3Client.partSize(forFileSize: 100 * mib, preferred: 10 * gib) == S3Client.maximumPartSize)
        #expect(throws: S3Error.storageLimit(code: "TooManyParts")) {
            try S3Client.partSize(forFileSize: 10_000 * S3Client.maximumPartSize + 1)
        }
    }
}
