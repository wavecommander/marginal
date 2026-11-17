import CryptoKit
import Foundation
import Testing
@testable import GoogleSignInKit

struct GoogleSignInConfigurationTests {
    @Test func derivesTheReversedClientIDRedirect() throws {
        let configuration = try #require(GoogleSignInConfiguration(clientID: "  \(testClientID)\n"))
        #expect(configuration.clientID == testClientID)
        #expect(configuration.callbackURLScheme == testScheme)
        #expect(configuration.redirectURI.absoluteString == testRedirectURI)
        #expect(configuration.redirectURI.scheme == testScheme)
        #expect(configuration.authorizationEndpoint.absoluteString == "https://accounts.google.com/o/oauth2/v2/auth")
        #expect(configuration.tokenEndpoint.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(GoogleSignInConfiguration.scopes == ["openid", "email"])
    }

    @Test(arguments: ["", "   ", "$(GOOGLE_SIGNIN_CLIENT_ID)", "$(GOOGLE_SIGNIN_CLIENT_ID).apps.googleusercontent.com",
                      "123-abc", ".apps.googleusercontent.com", "123-abc.apps.googleusercontent.com.evil",
                      "12 3.apps.googleusercontent.com", "a.b.apps.googleusercontent.com",
                      "123_abc.apps.googleusercontent.com", "https://example.com"])
    func refusesEmptyUnexpandedOrMalformedClientIDs(_ clientID: String) {
        #expect(GoogleSignInConfiguration(clientID: clientID) == nil)
    }

    @Test func endpointsCanBeReplaced() throws {
        let configuration = try #require(GoogleSignInConfiguration(
            clientID: testClientID, authorizationEndpoint: URL(string: "https://auth.test/authorize")!,
            tokenEndpoint: URL(string: "https://auth.test/token")!))
        let request = GoogleSignInRequest.make(configuration: configuration, nonce: "n")
        #expect(request.url.absoluteString.hasPrefix("https://auth.test/authorize?"))
        #expect(configuration.tokenEndpoint.absoluteString == "https://auth.test/token")
    }
}

struct GoogleSignInRequestTests {
    @Test func authorizationURLCarriesEveryParameter() throws {
        let request = GoogleSignInRequest(configuration: testConfiguration, nonce: "n+o/nce=1", loginHint: "reader@example.com",
                                          state: "st+ate/1", codeVerifier: rfcVerifier)
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "accounts.google.com")
        #expect(components.path == "/o/oauth2/v2/auth")
        let names = (components.queryItems ?? []).map(\.name)
        #expect(Set(names).count == names.count)
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items == [
            "response_type": "code",
            "client_id": testClientID,
            "redirect_uri": testRedirectURI,
            "scope": "openid email",
            "state": "st+ate/1",
            "nonce": "n+o/nce=1",
            "code_challenge": rfcChallenge,
            "code_challenge_method": "S256",
            "prompt": "select_account",
            "login_hint": "reader@example.com",
        ])
        // Reserved characters are percent-encoded, never a literal "+" (read as a space).
        let string = request.url.absoluteString
        #expect(string.contains("scope=openid%20email"))
        #expect(string.contains("state=st%2Bate%2F1"))
        #expect(string.contains("nonce=n%2Bo%2Fnce%3D1"))
        #expect(request.nonce == "n+o/nce=1")
    }

    @Test func freshRequestsHaveAValidVerifierAndDistinctStates() throws {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let first = GoogleSignInRequest.make(configuration: testConfiguration, nonce: "server-nonce")
        let second = GoogleSignInRequest.make(configuration: testConfiguration, nonce: "server-nonce")

        #expect((43...128).contains(first.codeVerifier.count))
        #expect(first.codeVerifier.allSatisfy(allowed.contains))
        #expect(first.codeVerifier != second.codeVerifier)
        #expect(first.state != second.state)
        #expect(first.state.count >= 22)
        #expect(first.state.allSatisfy(allowed.contains))
        #expect(first.nonce == "server-nonce")

        let items = try #require(URLComponents(url: first.url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["state"] == first.state)
        #expect(query["nonce"] == "server-nonce")
        #expect(query["login_hint"] == nil)
        // S256: base64url(SHA256(verifier)), unpadded.
        let digest = Data(SHA256.hash(data: Data(first.codeVerifier.utf8)))
        let expected = digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(query["code_challenge"] == expected)
        #expect(query["code_challenge"]?.contains("=") == false)
        #expect(query["code_challenge"]?.count == 43)
        // The verifier itself never appears in the URL.
        #expect(!first.url.absoluteString.contains(first.codeVerifier))
    }

    @Test func challengeMatchesRFC7636AppendixB() {
        #expect(PKCE.challenge(for: rfcVerifier) == rfcChallenge)
        #expect(PKCE.isValidVerifier(String(repeating: "a", count: 43)))
        #expect(PKCE.isValidVerifier(String(repeating: "a", count: 128)))
        #expect(!PKCE.isValidVerifier(String(repeating: "a", count: 42)))
        #expect(!PKCE.isValidVerifier(String(repeating: "a", count: 129)))
        #expect(!PKCE.isValidVerifier(String(repeating: "a", count: 42) + "/"))
    }
}

struct RedirectValidationTests {
    let request = GoogleSignInRequest(configuration: testConfiguration, nonce: "n", state: "s1", codeVerifier: rfcVerifier)

    @Test func parsesTheCode() throws {
        #expect(try request.authorizationCode(from: redirect("state=s1&code=4%2F0Abc-def&scope=email%20openid")) == "4/0Abc-def")
        // The scheme is compared without regard to case.
        let upper = URL(string: "\(testScheme.uppercased()):/oauthredirect?state=s1&code=c")!
        #expect(try request.authorizationCode(from: upper) == "c")
    }

    @Test func refusesAStateMismatch() {
        #expect(throws: GoogleSignInError.stateMismatch) {
            try request.authorizationCode(from: redirect("state=other&code=abc"))
        }
        #expect(throws: GoogleSignInError.stateMismatch) {
            try request.authorizationCode(from: redirect("code=abc"))
        }
    }

    @Test func errorParameterIsAuthorizationDenied() {
        #expect(throws: GoogleSignInError.authorizationDenied(code: "access_denied")) {
            try request.authorizationCode(from: redirect("error=access_denied&state=s1"))
        }
        #expect(throws: GoogleSignInError.authorizationDenied(code: "invalid_scope")) {
            try request.authorizationCode(from: redirect("error=invalid_scope&state=s1"))
        }
    }

    @Test func refusesAMissingCode() {
        #expect(throws: GoogleSignInError.redirectInvalid) { try request.authorizationCode(from: redirect("state=s1")) }
        #expect(throws: GoogleSignInError.redirectInvalid) { try request.authorizationCode(from: redirect("state=s1&code=")) }
    }

    @Test(arguments: [
        "otherapp:/oauthredirect?state=s1&code=abc",
        "https://example.com/oauthredirect?state=s1&code=abc",
        "com.googleusercontent.apps.123456789012-abcdefghijklmnop:/other?state=s1&code=abc",
        "com.googleusercontent.apps.123456789012-abcdefghijklmnop://evil/oauthredirect?state=s1&code=abc",
        "com.googleusercontent.apps.999-other:/oauthredirect?state=s1&code=abc",
    ])
    func refusesAWrongSchemeOrPath(_ url: String) {
        #expect(throws: GoogleSignInError.redirectInvalid) { try request.authorizationCode(from: URL(string: url)!) }
    }

    @Test func completeValidatesBeforeAnyRequest() async {
        let server = StubServer()
        let client = GoogleSignInClient(configuration: testConfiguration, urlSession: server.session)
        await #expect(throws: GoogleSignInError.stateMismatch) {
            try await client.complete(request, redirect: redirect("state=other&code=abc"))
        }
        await #expect(throws: GoogleSignInError.authorizationDenied(code: "access_denied")) {
            try await client.complete(request, redirect: redirect("error=access_denied&state=s1"))
        }
        await #expect(throws: GoogleSignInError.redirectInvalid) {
            try await client.complete(request, redirect: URL(string: "otherapp:/oauthredirect?state=s1&code=abc")!)
        }
        #expect(server.requests.isEmpty)
        server.verify()
    }

    @Test func refusesARequestFromAnotherConfiguration() async throws {
        let server = StubServer()
        let other = try #require(GoogleSignInConfiguration(clientID: "999-other.apps.googleusercontent.com"))
        let client = GoogleSignInClient(configuration: other, urlSession: server.session)
        await #expect(throws: GoogleSignInError.redirectInvalid) {
            try await client.complete(request, redirect: redirect("state=s1&code=abc"))
        }
        server.verify()
    }

    @Test func cancellingTheTaskIsCancelled() async {
        let server = StubServer()
        server.expect("POST", tokenURL, .hang)
        let client = GoogleSignInClient(configuration: testConfiguration, urlSession: server.session)
        let request = request
        let task = Task { try await client.complete(request, redirect: redirect("state=s1&code=abc")) }
        while server.requests.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: GoogleSignInError.cancelled) { try await task.value }
        server.verify()
    }

    @Test func alreadyCancelledTaskSendsNothing() async {
        let server = StubServer()
        let client = GoogleSignInClient(configuration: testConfiguration, urlSession: server.session)
        let request = request
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.complete(request, redirect: redirect("state=s1&code=abc"))
        }
        await #expect(throws: GoogleSignInError.cancelled) { try await task.value }
        #expect(server.requests.isEmpty)
        server.verify()
    }
}

struct CodeExchangeTests {
    let server = StubServer()
    let request = GoogleSignInRequest(configuration: testConfiguration, nonce: "n", state: "s1", codeVerifier: rfcVerifier)
    var client: GoogleSignInClient { GoogleSignInClient(configuration: testConfiguration, urlSession: server.session) }
    let idToken = unsignedJWT(["iss": "https://accounts.google.com", "email": "reader@example.com", "email_verified": true],
                              signature: "c2lnbmF0dXJl")

    @Test func postsTheFormAndReturnsTheIDToken() async throws {
        server.expect("POST", tokenURL, .http(200, headers: ["Content-Type": "application/json"], body: json([
            "access_token": "ya29.access", "expires_in": 3599, "id_token": idToken, "scope": "openid email",
            "token_type": "Bearer",
        ])))

        let result = try await client.complete(request, redirect: redirect("state=s1&code=4%2F0Abc%2Bdef"))

        #expect(result.idToken == idToken)
        #expect(result.email == "reader@example.com")
        #expect(result.emailVerified == true)
        let sent = try #require(server.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == tokenURL)
        #expect(sent.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(sent.header("Authorization") == nil)
        #expect(sent.form == [
            "code": "4/0Abc+def",
            "client_id": testClientID,
            "redirect_uri": testRedirectURI,
            "grant_type": "authorization_code",
            "code_verifier": rfcVerifier,
        ])
        // Every value is percent-encoded: no literal "+", "/" or ":" in the body.
        #expect(sent.bodyString.contains("code=4%2F0Abc%2Bdef"))
        #expect(sent.bodyString.contains("redirect_uri=\(testScheme)%3A%2Foauthredirect"))
        server.verify()
    }

    @Test func aResponseWithoutAnIDTokenIsMissingIDToken() async {
        server.expect("POST", tokenURL, .http(200, body: json(["access_token": "a", "expires_in": 3599, "token_type": "Bearer"])))
        await #expect(throws: GoogleSignInError.missingIDToken) {
            try await client.complete(request, redirect: redirect("state=s1&code=c"))
        }
        server.verify()
    }

    @Test func anUnreadableResponseIsUnexpected() async {
        server.expect("POST", tokenURL, .http(200, body: Data("<html>".utf8)))
        await #expect(throws: GoogleSignInError.unexpectedResponse) {
            try await client.complete(request, redirect: redirect("state=s1&code=c"))
        }
        server.verify()
    }

    @Test func aRejectedCodeIsExchangeFailed() async {
        server.expect("POST", tokenURL, .http(400, body: json(["error": "invalid_grant", "error_description": "Bad Request"])))
        await #expect(throws: GoogleSignInError.exchangeFailed(status: 400, code: "invalid_grant")) {
            try await client.complete(request, redirect: redirect("state=s1&code=c"))
        }
        server.verify()
    }

    @Test func aServerErrorWithoutABodyIsExchangeFailed() async {
        server.expect("POST", tokenURL, .http(503))
        await #expect(throws: GoogleSignInError.exchangeFailed(status: 503, code: nil)) {
            try await client.complete(request, redirect: redirect("state=s1&code=c"))
        }
        server.verify()
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost])
    func aTransportFailureIsNetwork(_ code: URLError.Code) async {
        server.expect("POST", tokenURL, .drop(code))
        await #expect(throws: GoogleSignInError.network) {
            try await client.complete(request, redirect: redirect("state=s1&code=c"))
        }
        server.verify()
    }
}

struct GoogleIDTokenClaimsTests {
    @Test func readsTheEmailFromAnUnsignedToken() {
        let token = unsignedJWT(["sub": "1", "email": "reader@example.com", "email_verified": true])
        #expect(GoogleIDTokenClaims.email(in: token) == "reader@example.com")
        #expect(GoogleIDTokenClaims.emailVerified(in: token) == true)
    }

    @Test func emailVerifiedAcceptsStringsAndFalse() {
        #expect(GoogleIDTokenClaims.emailVerified(in: unsignedJWT(["email_verified": "true"])) == true)
        #expect(GoogleIDTokenClaims.emailVerified(in: unsignedJWT(["email_verified": false])) == false)
        #expect(GoogleIDTokenClaims.emailVerified(in: unsignedJWT(["email": "a@b.c"])) == nil)
    }

    @Test func payloadWithBase64URLCharactersAndNoPadding() {
        // "?>" and "~~~" push "/", "+" and padding into plain base64; base64url must cope.
        let token = unsignedJWT(["email": "a?>b~~~@example.com", "x": "ÿÿ"], signature: "sig")
        #expect(GoogleIDTokenClaims.email(in: token) == "a?>b~~~@example.com")
    }

    @Test func missingEmailIsNil() {
        #expect(GoogleIDTokenClaims.email(in: unsignedJWT(["sub": "1"])) == nil)
        #expect(GoogleIDTokenClaims.email(in: unsignedJWT(["email": ""])) == nil)
        #expect(GoogleIDTokenClaims.email(in: unsignedJWT(["email": 42])) == nil)
    }

    @Test(arguments: ["", "abc", "a.b", "a.b.c.d", ".e30.", "e30..", "e30.!!!.", "e30.WzFd.",
                      "e30.bm90IGpzb24.", "e30.e30"])
    func malformedTokensAreNil(_ token: String) {
        // "WzFd" is `[1]` (not an object), "bm90IGpzb24" is "not json", "e30" is `{}`.
        #expect(GoogleIDTokenClaims.email(in: token) == nil)
        #expect(GoogleIDTokenClaims.emailVerified(in: token) == nil)
    }
}

struct RedactionTests {
    @Test func requestDescriptionsHideTheVerifier() {
        let request = GoogleSignInRequest.make(configuration: testConfiguration, nonce: "n", loginHint: "reader@example.com")
        let texts = [String(describing: request), String(reflecting: request), "\(request)", dumped(request),
                     Mirror(reflecting: request).children.map { "\($0.label ?? ""): \($0.value)" }.joined()]
        for text in texts {
            #expect(!text.contains(request.codeVerifier))
            #expect(!text.isEmpty)
        }
        #expect(String(describing: request).contains("<redacted>"))
        #expect(Mirror(reflecting: request).children.contains { $0.label == "codeVerifier" && "\($0.value)" == "<redacted>" })
    }

    @Test func resultDescriptionsHideTheToken() {
        let token = unsignedJWT(["email": "reader@example.com"], signature: "c2VjcmV0LXNpZ25hdHVyZQ")
        let result = GoogleSignInResult(idToken: token)
        let texts = [String(describing: result), String(reflecting: result), "\(result)", dumped(result),
                     Mirror(reflecting: result).children.map { "\($0.label ?? ""): \($0.value)" }.joined()]
        for text in texts {
            #expect(!text.contains(token))
            #expect(!text.contains("c2VjcmV0LXNpZ25hdHVyZQ"))
            #expect(!text.contains("reader@example.com"))
        }
    }

    @Test func errorDescriptionsAreReaderText() {
        #expect(GoogleSignInError.cancelled.errorDescription == "Google sign-in was cancelled.")
        #expect(GoogleSignInError.authorizationDenied(code: "access_denied").errorDescription == "Google sign-in was cancelled.")
        #expect(GoogleSignInError.authorizationDenied(code: "access_denied").isCancellation)
        #expect(!GoogleSignInError.authorizationDenied(code: "invalid_scope").isCancellation)
        #expect(GoogleSignInError.network.errorDescription == "Couldn’t reach Google. Check your internet connection and try again.")
        for error in [GoogleSignInError.stateMismatch, .redirectInvalid, .authorizationDenied(code: "invalid_scope"),
                      .missingIDToken, .exchangeFailed(status: 400, code: "invalid_grant"), .unexpectedResponse] {
            #expect(error.errorDescription == "Couldn’t sign in with Google. Try again.")
            #expect(!error.isCancellation)
            // Google's error codes stay out of reader text.
            #expect(error.localizedDescription.contains("invalid") == false)
        }
    }

    private func dumped(_ value: Any) -> String {
        var output = ""
        dump(value, to: &output)
        return output
    }
}
