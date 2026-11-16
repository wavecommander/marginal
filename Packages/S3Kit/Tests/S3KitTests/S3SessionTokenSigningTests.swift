import CryptoKit
import Foundation
import Testing
@testable import S3Kit

/// Temporary credentials of generation `n`: a distinct key, secret and session token each time.
func temporaryCredentials(_ n: Int, expiration: Date? = nil) -> S3Credentials {
    S3Credentials(accessKeyID: "TMPKEY\(n)", secretAccessKey: "tmp-secret-\(n)/x+y=Do-Not-Leak",
                  sessionToken: "am90LXRva2Vu/\(n)+tok=Do-Not-Leak-\(n)", expiration: expiration)
}

/// Signing with a session token.
///
/// AWS publishes no Amazon S3 signing example for temporary credentials, so the vector here was
/// derived by hand from the documented algorithm ("Create a signed AWS API request": every
/// `x-amz-*` header sent, `x-amz-security-token` included, is a canonical header) with an
/// independent Python implementation (hashlib/hmac) that also reproduces AWS's published GET
/// Object example exactly. It is that example with a session token added.
struct S3SessionTokenSigningTests {
    static let token = "AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIY"
        + "RqTflfKD8YUuwthAx7mSEI/qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9H"
        + "FvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4"
        + "rvx3iSIlTJabIQwj2ICCR/oLxBA=="
    static let credentials = S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                                           secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                                           sessionToken: token)
    /// 20130524T000000Z
    static let date = Date(timeIntervalSince1970: 1_369_353_600)

    @Test func theTokenIsSentAndSignedAsXAmzSecurityToken() throws {
        let signer = S3Signer(credentials: Self.credentials, region: "us-east-1")
        let url = try #require(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt"))
        let headers = ["Range": "bytes=0-9"]
        let empty = S3Signer.emptyPayloadSHA256
        #expect(signer.canonicalRequest(method: "GET", url: url, headers: headers, payloadSHA256: empty, date: Self.date)
            == """
            GET
            /test.txt

            host:examplebucket.s3.amazonaws.com
            range:bytes=0-9
            x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            x-amz-date:20130524T000000Z
            x-amz-security-token:\(Self.token)

            host;range;x-amz-content-sha256;x-amz-date;x-amz-security-token
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """)
        #expect(signer.stringToSign(method: "GET", url: url, headers: headers, payloadSHA256: empty, date: Self.date) == """
            AWS4-HMAC-SHA256
            20130524T000000Z
            20130524/us-east-1/s3/aws4_request
            68704e632dfea6511c21997d66f0c3c9c7b50919502e25ae03b97c4171c4db49
            """)
        let signed = signer.sign(method: "GET", url: url, headers: headers, payloadSHA256: empty, date: Self.date)
        #expect(signed["Authorization"] == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/"
            + "aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date;x-amz-security-token,"
            + "Signature=83550a58e2be44fa0ba3b8668126104d584132f713849584acd2aa6cf6431fca")
        #expect(signed["X-Amz-Security-Token"] == Self.token)
        #expect(signed.count == 4)
        #expect(signer.hasSessionToken)
    }

    @Test func withoutATokenSigningIsExactlyAsBefore() throws {
        let url = try #require(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt"))
        let empty = S3Signer.emptyPayloadSHA256
        for token in [nil, "", "  "] as [String?] {
            let credentials = S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                                            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                                            sessionToken: token)
            #expect(credentials.sessionToken == nil)
            let signer = S3Signer(credentials: credentials, region: "us-east-1")
            let signed = signer.sign(method: "GET", url: url, headers: ["Range": "bytes=0-9"], payloadSHA256: empty,
                                     date: Self.date)
            // AWS's published GET Object example.
            #expect(signed["Authorization"]?.hasSuffix("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,"
                + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41") == true)
            #expect(signed.keys.sorted() == ["Authorization", "x-amz-content-sha256", "x-amz-date"])
            #expect(!signer.hasSessionToken)
        }
        let emptyToken = S3Signer(accessKeyID: "K", secretAccessKey: "S", sessionToken: "", region: "auto")
        #expect(!emptyToken.hasSessionToken)
    }

    /// The local development server's endpoint: a port and a base path. Pinned by the same
    /// hand derivation (region `auto`, the documented local credentials).
    @Test func aPortAndABasePathAreInTheHostHeaderAndTheCanonicalURI() throws {
        let endpoint = try #require(S3Endpoint.localR2(bucket: "my-bucket", prefix: "users/u1"))
        let client = S3Client(endpoint: endpoint, credentialsProvider: S3StaticCredentialsProvider(
            S3Credentials(accessKeyID: "local-access-key-id", secretAccessKey: "local-secret-access-key")))
        let url = try client.url(for: .init(method: "GET", key: nil, query: [("list-type", "2"), ("prefix", "users/u1/")]))
        #expect(url.absoluteString == "http://localhost:8787/cdn-cgi/local/r2/s3/my-bucket?list-type=2&prefix=users%2Fu1%2F")
        #expect(S3Signer.hostHeader(for: url) == "localhost:8787")
        #expect(S3Signer.canonicalURI(for: url) == "/cdn-cgi/local/r2/s3/my-bucket")
        let signer = S3Signer(accessKeyID: "local-access-key-id", secretAccessKey: "local-secret-access-key", region: "auto")
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        #expect(signer.canonicalRequest(method: "GET", url: url, payloadSHA256: S3Signer.emptyPayloadSHA256, date: date)
            == """
            GET
            /cdn-cgi/local/r2/s3/my-bucket
            list-type=2&prefix=users%2Fu1%2F
            host:localhost:8787
            x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            x-amz-date:20260101T000000Z

            host;x-amz-content-sha256;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """)
        #expect(signer.sign(method: "GET", url: url, payloadSHA256: S3Signer.emptyPayloadSHA256, date: date)["Authorization"]
            == "AWS4-HMAC-SHA256 Credential=local-access-key-id/20260101/auto/s3/aws4_request,"
            + "SignedHeaders=host;x-amz-content-sha256;x-amz-date,"
            + "Signature=74d060b34a61a6117cc2af76d03e41246e21bc821bc2d4fcfcd10266b6ff77a4")
    }

    @Test func theHostHeaderBracketsIPv6AndDropsDefaultPorts() throws {
        #expect(S3Signer.hostHeader(for: try #require(URL(string: "http://[::1]:8787/b/k"))) == "[::1]:8787")
        #expect(S3Signer.hostHeader(for: try #require(URL(string: "http://[::1]/b/k"))) == "[::1]")
        #expect(S3Signer.hostHeader(for: try #require(URL(string: "http://localhost:80/b"))) == "localhost")
        #expect(S3Signer.hostHeader(for: try #require(URL(string: "https://h.example:443/b"))) == "h.example")
        #expect(S3Signer.hostHeader(for: try #require(URL(string: "https://h.example:9000/b"))) == "h.example:9000")
    }
}

struct S3EndpointTests {
    @Test(arguments: ["localhost", "127.0.0.1", "[::1]", "::1", "LOCALHOST"])
    func httpAPortAndABasePathAreAllowedForLoopback(host: String) throws {
        let endpoint = try #require(S3Endpoint(scheme: "http", host: host, port: 8787, basePath: "cdn-cgi/local/r2/s3/",
                                               region: "auto", bucket: "b", prefix: "/users/u1/"))
        #expect(endpoint.scheme == "http")
        #expect(endpoint.port == 8787)
        #expect(endpoint.basePath == "/cdn-cgi/local/r2/s3")
        #expect(endpoint.prefix == "users/u1")
        #expect(endpoint.isLoopback)
        if host == "::1" { #expect(endpoint.host == "[::1]") }
    }

    @Test(arguments: ["example.com", "10.0.0.1", "127.0.0.2", "localhost.example.com", "my-localhost",
                      "abc.r2.cloudflarestorage.com"])
    func httpAndABasePathAreRefusedForAnyOtherHost(host: String) {
        #expect(S3Endpoint(scheme: "http", host: host, region: "auto", bucket: "b") == nil)
        #expect(S3Endpoint(scheme: "http", host: host, port: 8787, region: "auto", bucket: "b") == nil)
        #expect(S3Endpoint(scheme: "https", host: host, basePath: "/cdn-cgi/local/r2/s3", region: "auto", bucket: "b") == nil)
        #expect(S3Endpoint(scheme: "https", host: host, region: "auto", bucket: "b") != nil)
    }

    @Test func malformedEndpointsAreRefused() {
        #expect(S3Endpoint(scheme: "ftp", host: "localhost", region: "auto", bucket: "b") == nil)
        #expect(S3Endpoint(host: "https://h.example", region: "auto", bucket: "b") == nil)
        #expect(S3Endpoint(host: "h.example/b", region: "auto", bucket: "b") == nil)
        #expect(S3Endpoint(host: "h.example:9000", region: "auto", bucket: "b") == nil, "the port goes in `port`")
        #expect(S3Endpoint(host: "user@h.example", region: "auto", bucket: "b") == nil)
        #expect(S3Endpoint(host: "", region: "auto", bucket: "b") == nil)
        #expect(S3Endpoint(host: "h.example", region: " ", bucket: "b") == nil)
        #expect(S3Endpoint(host: "h.example", region: "auto", bucket: "") == nil)
        #expect(S3Endpoint(host: "h.example", region: "auto", bucket: "a/b") == nil)
        for port in [0, 65_536, -1] {
            #expect(S3Endpoint(scheme: "http", host: "localhost", port: port, region: "auto", bucket: "b") == nil)
        }
        for path in ["/a/../b", "/a//b", "./a", "/a b", "/a\tb"] {
            #expect(S3Endpoint(scheme: "http", host: "localhost", basePath: path, region: "auto", bucket: "b") == nil,
                    "base path \(path)")
        }
        #expect(S3Endpoint(scheme: "HTTPS", host: "h.example", basePath: "/", region: "auto", bucket: "b")?.basePath == "")
    }

    @Test func pathStyleURLsCarryTheBucketAndTheKeyPrefix() throws {
        let production = try #require(S3Endpoint(host: "acct.r2.cloudflarestorage.com", region: "auto",
                                                 bucket: "tactile-backups", prefix: "users/AbC123"))
        let client = S3Client(endpoint: production, credentialsProvider: S3StaticCredentialsProvider(temporaryCredentials(1)))
        let key = try client.fullKey(for: "PDFs/a b.pdf")
        #expect(key == "users/AbC123/PDFs/a b.pdf")
        #expect(try client.url(for: .init(method: "PUT", key: key)).absoluteString
            == "https://acct.r2.cloudflarestorage.com/tactile-backups/users/AbC123/PDFs/a%20b.pdf")

        let local = try #require(S3Endpoint.localR2(bucket: "tactile-backups", prefix: "users/AbC123"))
        let localClient = S3Client(endpoint: local, credentialsProvider: S3StaticCredentialsProvider(temporaryCredentials(1)))
        let url = try localClient.url(for: .init(method: "PUT", key: try localClient.fullKey(for: "PDFs/a b.pdf")))
        #expect(url.absoluteString == "http://localhost:8787/cdn-cgi/local/r2/s3/tactile-backups/users/AbC123/PDFs/a%20b.pdf")
        #expect(S3Signer.canonicalURI(for: url) == "/cdn-cgi/local/r2/s3/tactile-backups/users/AbC123/PDFs/a%20b.pdf")
        #expect(S3Signer.hostHeader(for: url) == "localhost:8787")

        let ipv6 = try #require(S3Endpoint(scheme: "http", host: "::1", port: 9000, region: "auto", bucket: "b"))
        let ipv6Client = S3Client(endpoint: ipv6, credentialsProvider: S3StaticCredentialsProvider(temporaryCredentials(1)))
        let ipv6URL = try ipv6Client.url(for: .init(method: "GET", key: "k"))
        #expect(ipv6URL.absoluteString == "http://[::1]:9000/b/k")
        #expect(S3Signer.hostHeader(for: ipv6URL) == "[::1]:9000")
    }

    @Test func aConfigurationMeansWhatItAlwaysMeant() throws {
        let plain = try #require(S3Configuration(host: "h.example", region: "auto", bucket: "b", accessKeyID: "k",
                                                 secretAccessKey: "s", prefix: "p"))
        #expect(plain.endpoint == S3Endpoint(host: "h.example", region: "auto", bucket: "b", prefix: "p"))
        #expect(plain.credentials == S3Credentials(accessKeyID: "k", secretAccessKey: "s"))
        let withPort = try #require(S3Configuration(host: "minio.example:9000", region: "us-east-1", bucket: "b",
                                                    accessKeyID: "k", secretAccessKey: "s"))
        #expect(withPort.endpoint.scheme == "https")
        #expect(withPort.endpoint.port == 9000)
        let client = S3Client(configuration: withPort)
        #expect(try client.url(for: .init(method: "GET", key: "k")).absoluteString == "https://minio.example:9000/b/k")
        #expect(client.credentialsProvider is S3StaticCredentialsProvider)
    }

    @Test func requestsReachALoopbackServerWithItsPortAndBasePath() async throws {
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let server = StubServer(loopbackHost: host)
            let port = try #require(server.port)
            server.expect("PUT", "/cdn-cgi/local/r2/s3/backup-bucket/app/ipad/Backups/a%20b.ttbackup") { request in
                #expect(request.url.scheme == "http")
                #expect(request.url.port == port)
                #expect(S3Signer.hostHeader(for: request.url) == (host == "[::1]" ? "[::1]:\(port)" : "\(host):\(port)"))
                #expect(request.headers["authorization"]?.contains("SignedHeaders=host;") == true)
                Fixtures.expectSigned(request)
                return .ok()
            }
            let client = server.client(provider: S3StaticCredentialsProvider(Fixtures.stubCredentials),
                                       endpoint: server.endpoint(basePath: "/cdn-cgi/local/r2/s3"))
            try await client.put(data: Data("x".utf8), key: "Backups/a b.ttbackup")
            server.verify()
        }
    }
}

/// No credential value reaches a description, a mirror or an error.
struct S3CredentialRedactionTests {
    static let credentials = temporaryCredentials(7, expiration: Date(timeIntervalSince1970: 1_767_226_500))
    static var secrets: [String] { [credentials.accessKeyID, credentials.secretAccessKey, credentials.sessionToken!] }

    static func expectNoSecrets<T>(in value: T, sourceLocation: SourceLocation = #_sourceLocation) {
        var dumped = ""
        dump(value, to: &dumped)
        for text in [String(describing: value), String(reflecting: value), "\(value)", dumped] {
            for secret in secrets {
                #expect(!text.contains(secret), "\(T.self) shows a credential", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func credentialsAndProvidersNeverDescribeTheirValues() async throws {
        Self.expectNoSecrets(in: Self.credentials)
        #expect(String(describing: Self.credentials).contains("<redacted>"))
        Self.expectNoSecrets(in: S3StaticCredentialsProvider(Self.credentials))
        Self.expectNoSecrets(in: S3Signer(credentials: Self.credentials, region: "auto"))
        let credentials = Self.credentials
        let refreshing = S3RefreshingCredentialsProvider(now: { Date(timeIntervalSince1970: 1_767_225_600) }) {
            credentials
        }
        _ = try await refreshing.credentials()
        Self.expectNoSecrets(in: refreshing)
        let server = StubServer()
        Self.expectNoSecrets(in: server.client(provider: S3StaticCredentialsProvider(Self.credentials)))
        Self.expectNoSecrets(in: server.client(provider: refreshing))
    }

    @Test func errorsNeverCarryTheSecretTheTokenOrTheSignature() async throws {
        let server = StubServer()
        let credentials = Self.credentials
        let echo = "secret \(credentials.secretAccessKey) token \(credentials.sessionToken!)"
        server.expect("PUT", "/backup-bucket/app/ipad/a", .error(400, code: "InvalidArgument", message: echo))
        server.expect("PUT", "/backup-bucket/app/ipad/b", .error(403, code: "AccessDenied", message: echo))
        server.expect("PUT", "/backup-bucket/app/ipad/c", .error(400, code: "ExpiredToken", message: echo))
        server.expect("PUT", "/backup-bucket/app/ipad/c", .error(401, code: "Unauthorized", message: echo))
        let client = server.client(provider: S3StaticCredentialsProvider(credentials))
        var errors: [S3Error] = []
        for key in ["a", "b", "c"] {
            do { try await client.put(data: Data("x".utf8), key: key) } catch let error as S3Error { errors.append(error) }
        }
        #expect(errors == [.unexpectedResponse(status: 400, code: "InvalidArgument", message: "secret <redacted> token <redacted>"),
                           .accessDenied(code: S3Error.notAllowedByCredentialsCode),
                           S3Error.temporaryCredentialsRejected])
        let signatures = server.requests.compactMap { $0.headers["authorization"]?.components(separatedBy: "Signature=").last }
        #expect(signatures.count == 4)
        for error in errors {
            var dumped = ""
            dump(error, to: &dumped)
            for text in [error.errorDescription ?? "", error.localizedDescription, String(describing: error), dumped] {
                for secret in Self.secrets + signatures { #expect(!text.contains(secret)) }
            }
        }
        server.verify(secrets: [credentials.secretAccessKey])
    }

    @Test func theTwoTemporaryCredentialOutcomesAreDistinctAndExplained() throws {
        let rejected = S3Error.temporaryCredentialsRejected
        let notAllowed = S3Error.accessDenied(code: S3Error.notAllowedByCredentialsCode)
        #expect(rejected.isTemporaryCredentialsRejected && !rejected.isNotAllowedByCredentials)
        #expect(notAllowed.isNotAllowedByCredentials && !notAllowed.isTemporaryCredentialsRejected)
        #expect(!rejected.isTransient && !notAllowed.isTransient)
        let others: [S3Error] = [.authenticationFailed(code: "ExpiredToken", clockSkewed: false),
                                 .authenticationFailed(code: "Unauthorized", clockSkewed: false),
                                 .accessDenied(code: "AccessDenied"), .accessDenied(code: "HTTP 403")]
        for other in others {
            #expect(!other.isTemporaryCredentialsRejected && !other.isNotAllowedByCredentials)
            #expect(other.errorDescription != rejected.errorDescription)
            #expect(other.errorDescription != notAllowed.errorDescription)
        }
        let rejectedText = try #require(rejected.errorDescription)
        let notAllowedText = try #require(notAllowed.errorDescription)
        #expect(rejectedText.contains("renewed"))
        #expect(notAllowedText.contains("read-only"))
        #expect(rejectedText != notAllowedText)
    }
}
