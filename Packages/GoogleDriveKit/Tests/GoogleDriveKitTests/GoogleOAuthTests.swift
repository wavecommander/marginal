import CryptoKit
import Foundation
import Testing
@testable import GoogleDriveKit

struct GoogleOAuthConfigurationTests {
    @Test func derivesTheReversedClientIDRedirect() throws {
        let configuration = try #require(GoogleOAuthConfiguration(clientID: "  \(testClientID)\n"))
        #expect(configuration.clientID == testClientID)
        #expect(configuration.callbackScheme == "com.googleusercontent.apps.123456789012-abcdefghijklmnop")
        #expect(configuration.redirectURI == "com.googleusercontent.apps.123456789012-abcdefghijklmnop:/oauth2redirect")
        #expect(configuration.scopes == [GoogleDriveScope.driveFile])
    }

    @Test(arguments: [nil, "", "   ", "$(GOOGLE_DRIVE_CLIENT_ID)", "123-abc", ".apps.googleusercontent.com",
                      "123-abc.apps.googleusercontent.com.evil", "12 3.apps.googleusercontent.com",
                      "a.b.apps.googleusercontent.com", "123_abc.apps.googleusercontent.com"])
    func refusesMissingOrMalformedClientIDs(_ clientID: String?) {
        #expect(GoogleOAuthConfiguration(clientID: clientID) == nil)
    }
}

struct GooglePKCETests {
    @Test func freshVerifierIsLongEnoughAndUnreserved() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let first = GooglePKCE()
        #expect((43...128).contains(first.verifier.count))
        #expect(first.verifier.allSatisfy(allowed.contains))
        #expect(GooglePKCE().verifier != first.verifier)
    }

    @Test func challengeIsBase64URLOfSHA256() {
        let pkce = GooglePKCE()
        let digest = Data(SHA256.hash(data: Data(pkce.verifier.utf8)))
        let expected = digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(pkce.challenge == expected)
        #expect(!pkce.challenge.contains("="))
    }

    @Test func matchesRFC7636AppendixB() throws {
        let pkce = try #require(GooglePKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func refusesInvalidVerifiers() {
        #expect(GooglePKCE(verifier: String(repeating: "a", count: 42)) == nil)
        #expect(GooglePKCE(verifier: String(repeating: "a", count: 129)) == nil)
        #expect(GooglePKCE(verifier: String(repeating: "a", count: 42) + "/") == nil)
        #expect(GooglePKCE(verifier: String(repeating: "a", count: 128)) != nil)
    }
}

struct GoogleAuthorizationRequestTests {
    let pkce = GooglePKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")!

    @Test func authorizationURLCarriesEveryParameter() throws {
        let request = GoogleAuthorizationRequest(configuration: testConfiguration, pkce: pkce, state: "st+ate/1",
                                                 loginHint: "reader@example.com")
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "accounts.google.com")
        #expect(components.path == "/o/oauth2/v2/auth")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items == [
            "client_id": testClientID,
            "redirect_uri": "com.googleusercontent.apps.123456789012-abcdefghijklmnop:/oauth2redirect",
            "response_type": "code",
            "scope": "https://www.googleapis.com/auth/drive.file",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
            "state": "st+ate/1",
            "login_hint": "reader@example.com",
        ])
        // Reserved characters are percent-encoded, never left as a literal "+" (read as a space).
        #expect(request.url.absoluteString.contains("state=st%2Bate%2F1"))
        #expect(request.url.absoluteString.contains("scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file"))
    }

    @Test func freshRequestsHaveDistinctStates() {
        let first = GoogleAuthorizationRequest(configuration: testConfiguration)
        let second = GoogleAuthorizationRequest(configuration: testConfiguration)
        #expect(first.state != second.state)
        #expect(first.state.count >= 22)
        #expect(!first.url.absoluteString.contains("login_hint"))
    }

    func callback(_ query: String) -> URL {
        URL(string: "com.googleusercontent.apps.123456789012-abcdefghijklmnop:/oauth2redirect?\(query)")!
    }

    @Test func parsesTheCode() throws {
        let request = GoogleAuthorizationRequest(configuration: testConfiguration, pkce: pkce, state: "s1")
        let code = try request.authorizationCode(fromCallback: callback("state=s1&code=4%2F0Abc-def&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file"))
        #expect(code == "4/0Abc-def")
    }

    @Test func refusesAStateMismatch() {
        let request = GoogleAuthorizationRequest(configuration: testConfiguration, pkce: pkce, state: "s1")
        #expect(throws: GoogleDriveError.signInFailed(reason: "state mismatch")) {
            try request.authorizationCode(fromCallback: callback("state=other&code=abc"))
        }
        #expect(throws: GoogleDriveError.signInFailed(reason: "state mismatch")) {
            try request.authorizationCode(fromCallback: callback("code=abc"))
        }
    }

    @Test func accessDeniedIsCancelledSignIn() {
        let request = GoogleAuthorizationRequest(configuration: testConfiguration, pkce: pkce, state: "s1")
        #expect(throws: GoogleDriveError.signInCancelled) {
            try request.authorizationCode(fromCallback: callback("error=access_denied&state=s1"))
        }
    }

    @Test func otherErrorsAndMissingCodeFail() {
        let request = GoogleAuthorizationRequest(configuration: testConfiguration, pkce: pkce, state: "s1")
        #expect(throws: GoogleDriveError.signInFailed(reason: "invalid_scope")) {
            try request.authorizationCode(fromCallback: callback("error=invalid_scope&state=s1"))
        }
        #expect(throws: GoogleDriveError.signInFailed(reason: "missing authorization code")) {
            try request.authorizationCode(fromCallback: callback("state=s1"))
        }
        #expect(throws: GoogleDriveError.signInFailed(reason: "unexpected redirect")) {
            try request.authorizationCode(fromCallback: URL(string: "otherapp:/oauth2redirect?state=s1&code=abc")!)
        }
    }
}

struct GoogleAuthSessionTests {
    @Test func exchangesTheCodeAndSavesTheTokens() async throws {
        let harness = Harness(tokens: nil)
        harness.server.expect("POST", tokenURL, tokenResponse("access-new", expiresIn: 3599, refreshToken: "refresh-new"))
        let request = GoogleAuthorizationRequest(configuration: testConfiguration, pkce: GooglePKCE(), state: "s1")
        let callback = URL(string: "\(testConfiguration.redirectURI)?state=s1&code=4%2Fcode")!

        let tokens = try await harness.auth.completeSignIn(request: request, callbackURL: callback)

        #expect(tokens == GoogleTokenSet(accessToken: "access-new", expiresAt: harness.clock.value.addingTimeInterval(3599),
                                         refreshToken: "refresh-new", grantedScopes: [GoogleDriveScope.driveFile]))
        #expect(await harness.store.load() == tokens)
        let sent = try #require(harness.server.requests.first)
        #expect(sent.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(sent.header("Authorization") == nil)
        #expect(sent.form == [
            "code": "4/code",
            "client_id": testClientID,
            "code_verifier": request.pkce.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": testConfiguration.redirectURI,
        ])
        #expect(try await harness.auth.validAccessToken() == "access-new")
        harness.server.verify()
    }

    @Test func refusesASignInWithoutDriveAccess() async throws {
        let harness = Harness(tokens: nil)
        harness.server.expect("POST", tokenURL, tokenResponse("a", refreshToken: "r", scope: "openid"))
        let request = GoogleAuthorizationRequest(configuration: testConfiguration)
        await #expect(throws: GoogleDriveError.driveAccessNotGranted) {
            try await harness.auth.exchange(code: "c", request: request)
        }
        #expect(await harness.store.load() == nil)
        harness.server.verify()
    }

    @Test func rejectedCodeIsASignInFailure() async throws {
        let harness = Harness(tokens: nil)
        harness.server.expect("POST", tokenURL, .http(400, body: json(["error": "invalid_grant", "error_description": "Bad Request"])))
        await #expect(throws: GoogleDriveError.signInFailed(reason: "invalid_grant")) {
            try await harness.auth.exchange(code: "c", request: GoogleAuthorizationRequest(configuration: testConfiguration))
        }
        harness.server.verify()
    }

    @Test func notSignedInWithoutTokens() async {
        let harness = Harness(tokens: nil)
        await #expect(throws: GoogleDriveError.notSignedIn) { try await harness.auth.validAccessToken() }
        harness.server.verify()
    }

    @Test func usesTheSavedTokenWhileValid() async throws {
        let harness = Harness()
        #expect(try await harness.auth.validAccessToken() == "access-1")
        harness.server.verify()
    }

    @Test func refreshesWhenExpiredOrWithinTheMargin() async throws {
        let harness = Harness()
        // 4 minutes before expiry is inside the 5-minute safety margin.
        harness.clock.value = GoogleTokenSet.valid.expiresAt.addingTimeInterval(-240)
        harness.server.expect("POST", tokenURL, tokenResponse("access-2"))

        #expect(try await harness.auth.validAccessToken() == "access-2")

        let form = try #require(harness.server.requests.first).form
        #expect(form == ["client_id": testClientID, "refresh_token": "refresh-1", "grant_type": "refresh_token"])
        let saved = try #require(await harness.store.load())
        #expect(saved.refreshToken == "refresh-1")
        #expect(saved.expiresAt == harness.clock.value.addingTimeInterval(3599))

        harness.clock.value = saved.expiresAt.addingTimeInterval(10)
        harness.server.expect("POST", tokenURL, tokenResponse("access-3", refreshToken: "refresh-2"))
        #expect(try await harness.auth.validAccessToken() == "access-3")
        #expect(await harness.store.load()?.refreshToken == "refresh-2")
        harness.server.verify()
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let harness = Harness()
        harness.clock.value = GoogleTokenSet.valid.expiresAt.addingTimeInterval(60)
        harness.server.expect("POST", tokenURL, delay: 0.3, tokenResponse("access-2"))

        let auth = harness.auth
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await auth.validAccessToken() } }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }

        #expect(tokens == Array(repeating: "access-2", count: 8))
        #expect(harness.server.requests.count == 1)
        harness.server.verify()
    }

    @Test func rejectedRefreshTokenNeedsSignInAgainAndClearsTheStore() async throws {
        let harness = Harness()
        harness.clock.value = GoogleTokenSet.valid.expiresAt.addingTimeInterval(60)
        harness.server.expect("POST", tokenURL, .http(400, body: json(["error": "invalid_grant", "error_description": "Token has been expired or revoked."])))

        await #expect(throws: GoogleDriveError.needsSignInAgain) { try await harness.auth.validAccessToken() }
        #expect(await harness.store.load() == nil)
        // Later calls say the same without another request.
        await #expect(throws: GoogleDriveError.needsSignInAgain) { try await harness.auth.validAccessToken() }
        #expect(harness.server.requests.count == 1)
        harness.server.verify()
    }

    @Test func signOutRevokesAndClears() async throws {
        let harness = Harness()
        harness.server.expect("POST", "https://oauth2.googleapis.com/revoke", .http(200))

        #expect(try await harness.auth.signOut())

        let sent = try #require(harness.server.requests.first)
        #expect(sent.url.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(sent.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(sent.form == ["token": "refresh-1"])
        #expect(await harness.store.load() == nil)
        await #expect(throws: GoogleDriveError.notSignedIn) { try await harness.auth.validAccessToken() }
        harness.server.verify()
    }

    @Test func signOutClearsEvenOffline() async throws {
        let harness = Harness()
        harness.server.expect("POST", "https://oauth2.googleapis.com/revoke", .drop(.notConnectedToInternet))
        #expect(try await harness.auth.signOut() == false)
        #expect(await harness.store.load() == nil)
        harness.server.verify()
    }
}
