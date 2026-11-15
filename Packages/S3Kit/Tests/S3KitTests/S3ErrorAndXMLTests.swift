import Foundation
import Testing
@testable import S3Kit

struct S3ErrorMappingTests {
    static func body(_ code: String, _ message: String = "m") -> Data {
        Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>\(code)</Code><Message>\(message)</Message><Resource>/b/k</Resource><RequestId>R</RequestId></Error>
            """.utf8)
    }

    static func map(_ status: Int, _ body: Data, key: String? = "k") -> S3Error {
        S3Error.from(status: status, body: body, bucket: "b", key: key, secret: StubServer.secret)
    }

    @Test func serviceCodesMapToPlainLanguageErrors() {
        #expect(Self.map(403, Self.body("SignatureDoesNotMatch"))
            == .authenticationFailed(code: "SignatureDoesNotMatch", clockSkewed: false))
        #expect(Self.map(403, Self.body("InvalidAccessKeyId"))
            == .authenticationFailed(code: "InvalidAccessKeyId", clockSkewed: false))
        #expect(Self.map(401, Self.body("Unauthorized")) == .authenticationFailed(code: "Unauthorized", clockSkewed: false))
        #expect(Self.map(403, Self.body("RequestTimeTooSkewed"))
            == .authenticationFailed(code: "RequestTimeTooSkewed", clockSkewed: true))
        #expect(Self.map(404, Self.body("NoSuchBucket")) == .bucketNotFound(bucket: "b"))
        #expect(Self.map(403, Self.body("AccessDenied")) == .accessDenied(code: "AccessDenied"))
        #expect(Self.map(404, Self.body("NoSuchKey")) == .objectNotFound(key: "k"))
        #expect(Self.map(403, Self.body("NotEntitled")) == .storageLimit(code: "NotEntitled"))
        #expect(Self.map(403, Self.body("AccountProblem")) == .storageLimit(code: "AccountProblem"))
        #expect(Self.map(400, Self.body("EntityTooLarge")) == .storageLimit(code: "EntityTooLarge"))
        #expect(Self.map(507, Self.body("XMinioStorageFull")) == .storageLimit(code: "XMinioStorageFull"))
        #expect(Self.map(400, Self.body("BadDigest")) == .checksumMismatch(key: "k"))
        #expect(Self.map(400, Self.body("XAmzContentSHA256Mismatch")) == .checksumMismatch(key: "k"))
        #expect(Self.map(400, Self.body("InvalidArgument", "Bad thing"))
            == .unexpectedResponse(status: 400, code: "InvalidArgument", message: "Bad thing"))
    }

    @Test func bodilessAndMalformedResponsesKeepTheStatus() {
        #expect(Self.map(403, Data()) == .accessDenied(code: "HTTP 403"))
        #expect(Self.map(401, Data()) == .authenticationFailed(code: "HTTP 401", clockSkewed: false))
        #expect(Self.map(507, Data()) == .storageLimit(code: "HTTP 507"))
        #expect(Self.map(502, Data("<html><body>Bad gateway</body></html>".utf8))
            == .unexpectedResponse(status: 502, code: nil, message: nil))
        #expect(Self.map(500, Data("<Error><Code>Internal".utf8)) == .unexpectedResponse(status: 500, code: nil, message: nil))
        #expect(Self.map(400, Data("not xml at all".utf8)) == .unexpectedResponse(status: 400, code: nil, message: nil))
        #expect(Self.map(400, Data("<Error><Message>no code</Message></Error>".utf8))
            == .unexpectedResponse(status: 400, code: nil, message: nil))
    }

    @Test func clockSkewSaysToCheckTheClock() throws {
        let skewed = try #require(Self.map(403, Self.body("RequestTimeTooSkewed")).errorDescription)
        #expect(skewed.contains("clock"))
        let rejected = try #require(Self.map(403, Self.body("SignatureDoesNotMatch")).errorDescription)
        #expect(!rejected.contains("clock"))
        #expect(rejected.contains("credentials"))
    }

    @Test func transientErrorsAreThoseWorthRepeating() {
        #expect(S3Error.noNetwork(urlErrorCode: -1005).isTransient)
        #expect(S3Error.unexpectedResponse(status: 503, code: "SlowDown", message: nil).isTransient)
        #expect(S3Error.unexpectedResponse(status: 429, code: nil, message: nil).isTransient)
        #expect(S3Error.unexpectedResponse(status: 400, code: "RequestTimeout", message: nil).isTransient)
        #expect(S3Error.unexpectedResponse(status: 200, code: "InternalError", message: nil).isTransient)
        #expect(!S3Error.unexpectedResponse(status: 400, code: "InvalidPart", message: nil).isTransient)
        #expect(!S3Error.accessDenied(code: "AccessDenied").isTransient)
    }

    @Test func theSecretNeverReachesAnErrorDescription() {
        // A service that echoed the secret back would still not leak it.
        let echoed = Self.map(400, Self.body("InvalidArgument", "key \(StubServer.secret) rejected"))
        #expect(echoed == .unexpectedResponse(status: 400, code: "InvalidArgument", message: "key <redacted> rejected"))
        let errors: [S3Error] = [
            echoed, Self.map(403, Self.body("SignatureDoesNotMatch")), Self.map(403, Self.body("RequestTimeTooSkewed")),
            Self.map(404, Self.body("NoSuchBucket")), Self.map(403, Self.body("AccessDenied")),
            Self.map(404, Self.body("NoSuchKey")), .noNetwork(urlErrorCode: -1009), .storageLimit(code: "NotEntitled"),
            .checksumMismatch(key: "k"), .sizeMismatch(key: "k", expected: 2, actual: 1), .invalidKey(key: "k"),
            .invalidMetadata(name: "n"), .fileAccess(path: "/p", reason: "r")
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(!(error.errorDescription ?? "").contains(StubServer.secret))
            #expect(!String(describing: error).contains(StubServer.secret))
            #expect(!error.localizedDescription.contains(StubServer.secret))
        }
    }

    @Test func aServiceErrorThroughTheClientIsMappedAndCarriesNoSecret() async throws {
        let server = StubServer()
        // Amazon S3 adds the string to sign and canonical request to a signature mismatch.
        server.expect("GET", "/backup-bucket?list-type=2&prefix=app%2Fipad%2F", .xml(403, """
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>SignatureDoesNotMatch</Code>
            <Message>The request signature we calculated does not match the signature you provided.</Message>
            <AWSAccessKeyId>AKIDTESTEXAMPLE</AWSAccessKeyId><StringToSign>AWS4-HMAC-SHA256 ...</StringToSign>
            <SignatureProvided>abc</SignatureProvided><CanonicalRequest>GET /</CanonicalRequest>
            <RequestId>R</RequestId><HostId>H</HostId></Error>
            """))
        do {
            _ = try await server.client().list()
            Issue.record("Expected a throw")
        } catch let error as S3Error {
            #expect(error == .authenticationFailed(code: "SignatureDoesNotMatch", clockSkewed: false))
            #expect(!(error.errorDescription ?? "").contains(StubServer.secret))
        }
        server.verify()
    }

    @Test func theConfigurationNeverDescribesItsSecret() {
        let configuration = StubServer().configuration()
        #expect(!String(describing: configuration).contains(StubServer.secret))
        #expect(!String(reflecting: configuration).contains(StubServer.secret))
        #expect("\(configuration)".contains("<redacted>"))
        var dumped = ""
        dump(configuration, to: &dumped)
        #expect(!dumped.contains(StubServer.secret))
        #expect(dumped.contains("backup-bucket"))
    }
}

struct S3XMLTests {
    @Test func namespacePrefixesAndUnknownElementsAreTolerated() throws {
        let page = try S3XML.listPage(from: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <s3:ListBucketResult xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/" xmlns:x="urn:other">
              <x:Extension a="1"><x:Deep>ignored</x:Deep></x:Extension>
              <s3:IsTruncated>true</s3:IsTruncated>
              <s3:NextContinuationToken><![CDATA[tok<en>]]></s3:NextContinuationToken>
              <s3:Contents><s3:Key>a&lt;b&gt;&amp;&quot;c&apos;</s3:Key><s3:Size>7</s3:Size><s3:Future>x</s3:Future></s3:Contents>
            </s3:ListBucketResult>
            """.utf8))
        #expect(page.isTruncated)
        #expect(page.nextContinuationToken == "tok<en>")
        #expect(page.objects == [S3ObjectSummary(key: "a<b>&\"c'", size: 7, lastModified: nil, eTag: nil)])
    }

    @Test func aMalformedListIsAnError() {
        #expect(throws: (any Error).self) { try S3XML.listPage(from: Data("<ListBucketResult><Contents>".utf8)) }
        #expect(throws: (any Error).self) {
            try S3XML.listPage(from: Data("<ListBucketResult><Contents><Key>k</Key></Contents></ListBucketResult>".utf8))
        }
        #expect(throws: (any Error).self) { try S3XML.listPage(from: Data("<Error><Code>X</Code></Error>".utf8)) }
    }

    @Test func multipartDocuments() throws {
        #expect(try S3XML.uploadID(from: Data("""
            <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Bucket>b</Bucket>
            <Key>k</Key><UploadId>VXBsb2FkIElE</UploadId></InitiateMultipartUploadResult>
            """.utf8)) == "VXBsb2FkIElE")
        #expect(try S3XML.completeResult(from: Data("""
            \n   \n<CompleteMultipartUploadResult><ETag>"e-2"</ETag></CompleteMultipartUploadResult>
            """.utf8)) == .completed(eTag: "\"e-2\""))
        #expect(try S3XML.completeResult(from: Data("""
            <?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>InternalError</Code><Message>Try again.</Message></Error>
            """.utf8)) == .failed(.init(code: "InternalError", message: "Try again.")))
    }

    @Test func theCompletionBodyIsEscaped() throws {
        let body = S3XML.completeBody(parts: [(1, "\"a&b\""), (2, "<'x'>")])
        let text = String(decoding: body, as: UTF8.self)
        #expect(text == #"<?xml version="1.0" encoding="UTF-8"?>"#
            + #"<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">"#
            + "<Part><ETag>&quot;a&amp;b&quot;</ETag><PartNumber>1</PartNumber></Part>"
            + "<Part><ETag>&lt;&apos;x&apos;&gt;</ETag><PartNumber>2</PartNumber></Part></CompleteMultipartUpload>")
        // And it round-trips through a real XML parser.
        let parsed = try S3XML.parse(body)
        #expect(parsed.children("Part").compactMap { $0.string("ETag") } == ["\"a&b\"", "<'x'>"])
    }
}
