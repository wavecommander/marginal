import CryptoKit
import Foundation
import S3Kit
import Testing
@testable import TactileTexts

/// `BackupServiceClient` against the fake Worker: attestation, assertions over the exact body,
/// the retry-once paths, the simulator bypass, and every contract error code.
@MainActor
struct BackupCloudServiceClientTests {
    typealias W = BackupCloudServiceFakeWorker
    static let jws = BackupCloudServiceStoreFixtures.jws(42)
    static let renewal = BackupCloudServiceRig.renewalJWS

    func client(_ worker: W, attest: FakeAppAttestClient = FakeAppAttestClient(), bypass: String? = nil) -> BackupServiceClient {
        BackupServiceClient(baseURL: URL(string: "https://\(W.host)")!, attest: attest, attestBypassSecret: bypass,
                            urlSession: worker.stub.session)
    }

    @Test func theFirstSessionAttestsTheKeyThenSignsTheRequest() async throws {
        let worker = W(r2: nil)
        let attest = FakeAppAttestClient()
        let session = try await client(worker, attest: attest).session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: Self.renewal)
        #expect(worker.log == ["POST /v1/challenge", "POST /v1/challenge", "POST /v1/attest", "POST /v1/session"])
        #expect(worker.attests == 1 && worker.registeredKeys == ["fake-key-1"])
        #expect(session.mode == .readWrite)
        #expect(session.credentials.accessKeyID == "TEMPKEY" && session.credentials.sessionToken == "token-1")
        #expect(session.credentials.expiration != nil)
        #expect(session.storage.bucket == BackupCloudServiceFakeR2.bucket)
        #expect(session.storage.prefix == "users/u-123/")
        #expect(session.storage.s3Endpoint == BackupCloudServiceFakeR2().endpoint())
        #expect(session.subscription.state == .active && session.subscription.productID == BackupCloudServiceStoreFixtures.productID)
        #expect(session.subscription.expiresAt == Date(timeIntervalSince1970: 1_802_649_600))
        #expect(session.subscription.endedAt == nil && session.subscription.deleteAfter == nil)
        #expect(session.usage == BackupServiceUsage(bytes: 1234, allowanceBytes: 10_000_000, overAllowance: false,
                                                    countedAt: Date(timeIntervalSince1970: 1_800_000_000)))

        // The key is attested once: the next session only asks for a challenge.
        _ = try await client(worker, attest: attest).session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        #expect(worker.attests == 1)
        #expect(worker.log.suffix(2) == ["POST /v1/challenge", "POST /v1/session"])
    }

    @Test func theBytesSignedAreTheBytesSent() async throws {
        let worker = W(r2: nil)
        _ = try await client(worker).session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: Self.renewal)
        let request = try #require(worker.stub.requests("POST", pathPrefix: "/v1/session").first)
        let assertion = try #require(request.headers["x-app-attest-assertion"].flatMap { Data(base64Encoded: $0) })
        #expect(String(decoding: assertion, as: UTF8.self) == "fake-assertion:fake-key-1:\(W.hex(request.body))")
        #expect(request.headers["x-app-attest-key-id"] == "fake-key-1")
        #expect(request.headers["x-app-attest-bypass"] == nil)
        #expect(request.headers["content-type"] == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: String])
        #expect(body["action"] == "session" && body["signedTransaction"] == Self.jws && body["signedRenewalInfo"] == Self.renewal)
        #expect(body["challenge"].flatMap { Data(base64Encoded: $0) }?.count == 32)

        // Without renewal info the field is left out.
        _ = try await client(worker).session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        let second = try #require(try JSONSerialization.jsonObject(with: worker.sessionBodies.last!) as? [String: String])
        #expect(second["signedRenewalInfo"] == nil && second.count == 4 && second["deviceSessionToken"] == W.liveToken)
    }

    @Test func anAlreadyRegisteredKeyIsUsed() async throws {
        let worker = W(r2: nil)
        worker.preregister("fake-key-1")
        let session = try await client(worker).session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        #expect(session.mode == .readWrite)
        #expect(worker.attests == 0)
        #expect(worker.stub.requests("POST", pathPrefix: "/v1/attest").count == 1, "409 device-already-attested, then used")
    }

    @Test func anUnknownDeviceIsAttestedAgainAndRetriedOnce() async throws {
        let worker = W(r2: nil)
        let attest = FakeAppAttestClient()
        let client = client(worker, attest: attest)
        _ = try await client.session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        worker.forgetDevices()
        let session = try await client.session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        #expect(session.mode == .readWrite)
        #expect(worker.registeredKeys == ["fake-key-2"], "the client reset and made a new key")
        #expect(worker.attests == 2)
        #expect(worker.stub.requests("POST", pathPrefix: "/v1/session").count == 3)
    }

    @Test func anInvalidAssertionIsAttestedAgainAndRetriedOnce() async throws {
        let worker = W(r2: nil)
        let client = client(worker)
        _ = try await client.session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        worker.rejectAssertions = 1
        _ = try await client.session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        #expect(worker.attests == 2 && worker.registeredKeys.contains("fake-key-2"))

        // A second refusal in a row is not retried again.
        worker.rejectAssertions = 2
        await #expect(throws: CloudServiceError.assertionInvalid) {
            try await client.session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        }
        #expect(worker.stub.requests("POST", pathPrefix: "/v1/session").count == 1 + 2 + 2)
    }

    @Test func theSimulatorSendsTheBypassAndNeverAttests() async throws {
        let worker = W(r2: nil)
        let session = try await client(worker, attest: FakeAppAttestClient(isSupported: false), bypass: W.bypass)
            .session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        #expect(session.mode == .readWrite)
        #expect(worker.bypassed == 1 && worker.attests == 0)
        let request = try #require(worker.stub.requests("POST", pathPrefix: "/v1/session").first)
        #expect(request.headers["x-app-attest-bypass"] == W.bypass)
        #expect(request.headers["x-app-attest-key-id"] == nil && request.headers["x-app-attest-assertion"] == nil)
        #expect(!worker.log.contains("POST /v1/attest"))
    }

    /// A debug build on a real device (App Attest supported) against the `dev` Worker over HTTPS:
    /// the configured bypass is sent and nothing is attested (the app's App Attest is not set up).
    @Test func aDebugBuildOnARealDeviceSendsTheBypassToAnHTTPSHost() async throws {
        let worker = W(r2: nil)
        let attest = FakeAppAttestClient(isSupported: true)
        let configuration = try #require(BackupServiceConfiguration(host: "tactile-backup-dev.example.workers.dev",
                                                                    productIDs: "a.b", attestBypass: W.bypass))
        #expect(configuration.baseURL.scheme == "https" && configuration.attestBypassSecret == W.bypass)
        let client = BackupServiceClient(baseURL: URL(string: "https://\(W.host)")!, attest: attest,
                                         attestBypassSecret: configuration.attestBypassSecret, urlSession: worker.stub.session)
        let session = try await client.session(sessionToken: W.liveToken, signedTransaction: nil, signedRenewalInfo: nil)
        #expect(session.mode == .readWrite)
        #expect(worker.bypassed == 1 && worker.attests == 0)
        let request = try #require(worker.stub.requests("POST", pathPrefix: "/v1/session").first)
        #expect(request.headers["x-app-attest-bypass"] == W.bypass)
        #expect(request.headers["x-app-attest-key-id"] == nil && request.headers["x-app-attest-assertion"] == nil)
        #expect(!worker.log.contains("POST /v1/attest"))
    }

    @Test func theBypassRule() {
        #expect(BackupServiceClient.usesBypass(secret: nil, attestSupported: true) == false, "App Attest, as in a release build")
        #expect(BackupServiceClient.usesBypass(secret: nil, attestSupported: false) == true, "fails: no secret")
        #expect(BackupServiceClient.usesBypass(secret: "s", attestSupported: false) == true)
        #expect(BackupServiceClient.usesBypass(secret: "s", attestSupported: true) == true, "debug builds only")
    }

    @Test func withoutAppAttestOrABypassNothingIsSent() async throws {
        let worker = W(r2: nil)
        await #expect(throws: CloudServiceError.appAttestUnavailable) {
            try await client(worker, attest: FakeAppAttestClient(isSupported: false))
                .session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        }
        #expect(worker.stub.requests.isEmpty)
        #expect(CloudServiceError.appAttestUnavailable.localizedDescription.contains("isn’t available on this device"))
    }

    nonisolated static let lapsedInfo = BackupServiceSubscriptionInfo(
        state: .ended, environment: "Production", productID: BackupCloudServiceStoreFixtures.productID,
        expiresAt: Date(timeIntervalSince1970: 1_798_761_600), endedAt: Date(timeIntervalSince1970: 1_798_761_600),
        readOnlyUntil: W.readOnlyUntil, deleteAfter: W.deleteAfter)

    /// Every code in `ERRORS` (src/contract.ts), with its status, and the case it becomes.
    nonisolated static let contractErrors: [(status: Int, code: String, expected: CloudServiceError)] = [
        (400, "bad-request", .badRequest),
        (404, "not-found", .notFound),
        (405, "method-not-allowed", .methodNotAllowed),
        (413, "body-too-large", .bodyTooLarge),
        (415, "unsupported-media-type", .unsupportedMediaType),
        (401, "challenge-invalid", .challengeInvalid),
        (401, "attestation-invalid", .attestationInvalid),
        (409, "device-already-attested", .deviceAlreadyAttested),
        (401, "device-unknown", .deviceUnknown),
        (401, "assertion-invalid", .assertionInvalid),
        (401, "transaction-invalid", .transactionInvalid),
        (403, "product-unknown", .productUnknown),
        (403, "environment-not-accepted", .environmentNotAccepted),
        (403, "subscription-revoked", .subscriptionRevoked(lapsedInfo)),
        (403, "subscription-lapsed", .subscriptionLapsed(lapsedInfo)),
        (403, "data-deleted", .dataDeleted(lapsedInfo)),
        (401, "notification-invalid", .notificationInvalid),
        (500, "internal", .internalError),
    ]

    @Test(arguments: 0..<contractErrors.count)
    func everyContractErrorHasItsOwnCase(index: Int) async throws {
        let (status, code, expected) = Self.contractErrors[index]
        let worker = W(r2: nil)
        let carriesDates = ["subscription-revoked", "subscription-lapsed", "data-deleted"].contains(code)
        worker.sessionFailure = .init(status: status, code: code, subscription: carriesDates ? W.endedSubscription : nil)
        await #expect(throws: expected) {
            try await client(worker).session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        }
        #expect(expected.code == code)
        #expect(CloudServiceError(code: code, subscription: carriesDates ? Self.lapsedInfo : nil) == expected)
        let message = try #require(expected.errorDescription)
        #expect(!message.isEmpty && !message.contains("Server message"), "the server's free text is not shown")
    }

    @Test func lapsedAndRevokedMessagesCarryTheDeletionDate() {
        let day = CloudServiceError.day(W.deleteAfter)
        #expect(CloudServiceError.subscriptionLapsed(Self.lapsedInfo).localizedDescription.contains(day))
        #expect(CloudServiceError.subscriptionRevoked(Self.lapsedInfo).localizedDescription.contains(day))
        #expect(CloudServiceError.subscriptionLapsed(nil).localizedDescription.contains("Resubscribe"))
        #expect(CloudServiceError.dataDeleted(nil).localizedDescription.contains("deleted"))
    }

    @Test func unknownCodesBadBodiesAndNoNetwork() async throws {
        let worker = W(r2: nil)
        worker.sessionFailure = .init(status: 418, code: "teapot", subscription: nil)
        await #expect(throws: CloudServiceError.unexpectedResponse(status: 418, code: "teapot")) {
            try await client(worker).session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        }
        let gateway = BackupCloudStub { _ in .http(502, body: Data("<html>Bad gateway</html>".utf8)) }
        let viaGateway = BackupServiceClient(baseURL: URL(string: "https://\(W.host)")!, attest: FakeAppAttestClient(),
                                             urlSession: gateway.session)
        await #expect(throws: CloudServiceError.unexpectedResponse(status: 502, code: nil)) {
            try await viaGateway.session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        }
        let offline = BackupCloudStub { _ in .fail(.notConnectedToInternet) }
        let viaOffline = BackupServiceClient(baseURL: URL(string: "https://\(W.host)")!, attest: FakeAppAttestClient(),
                                             urlSession: offline.session)
        await #expect(throws: CloudServiceError.noNetwork) {
            try await viaOffline.health()
        }
        #expect(try await client(worker).health() == "dev")
    }

    @Test func deleteMyDataIsAuthenticatedLikeASession() async throws {
        let r2 = BackupCloudServiceFakeR2()
        for index in 0..<3 { r2.put(BackupCloudServiceFixtures.key("PDFs/\(index).ttenc"), Data([1])) }
        let worker = W(r2: r2)
        let client = client(worker)
        let first = try await client.deleteMyData(sessionToken: W.liveToken)
        #expect(first == BackupServiceDeletion(done: false, deletedObjects: 2))
        let second = try await client.deleteMyData(sessionToken: W.liveToken)
        #expect(second == BackupServiceDeletion(done: true, deletedObjects: 1))
        let body = try #require(try JSONSerialization.jsonObject(with: worker.sessionBodies.last!) as? [String: String])
        #expect(body["action"] == "delete-my-data")
    }

    @Test func concurrentRequestsAreSentOneAtATime() async throws {
        let worker = W(r2: nil)
        let client = client(worker)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { _ = try await client.session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil) }
            }
            try await group.waitForAll()
        }
        #expect(worker.sessions == 6 && worker.attests == 1)
    }

    // MARK: Redaction and renewal info

    @Test func nothingSecretAppearsInDescriptions() async throws {
        let worker = W(r2: nil)
        let session = try await client(worker).session(sessionToken: W.liveToken, signedTransaction: Self.jws, signedRenewalInfo: nil)
        var dumped = ""
        dump(session, to: &dumped)
        for text in [String(describing: session), String(reflecting: session), dumped] {
            #expect(!text.contains(BackupCloudServiceCredentials.secret) && !text.contains("token-1"), "\(text)")
        }
        let configuration = try #require(BackupServiceConfiguration(host: W.host, productIDs: "a.b", attestBypass: W.bypass))
        #expect(configuration.attestBypassSecret == W.bypass, "debug builds read the bypass")
        #expect(!String(describing: configuration).contains(W.bypass))
        #expect(BackupServiceConfiguration(host: W.host, productIDs: "a.b", attestBypass: "$(BACKUP_SERVICE_ATTEST_BYPASS)")?
            .attestBypassSecret == nil)
        #expect(BackupServiceConfiguration.fromInfoDictionary(["BackupService": ["Host": W.host, "ProductIDs": "a.b",
                                                                                 "AttestBypass": W.bypass]])?
            .attestBypassSecret == W.bypass)

        let transaction = BackupCloudServiceStoreFixtures.transaction(5, purchased: 0, expires: 100)
        let status = BackupStoreSubscriptionStatus(state: .subscribed, transaction: transaction, willAutoRenew: true,
                                                   renewalInfoJWS: Self.renewal)
        var signed = BackupSignedTransaction(jws: transaction.jwsRepresentation, productID: transaction.productID,
                                             transactionID: 5, originalTransactionID: 1, expirationDate: nil)
        signed.signedRenewalInfo = Self.renewal
        for value in [status as Any, signed as Any] {
            var text = ""
            dump(value, to: &text)
            for shown in [text, String(describing: value), String(reflecting: value)] {
                #expect(!shown.contains("must-not-leak"), "\(shown)")
            }
        }
    }

    @Test func theSignedTransactionCarriesItsVerifiedRenewalInfo() async throws {
        typealias S = BackupCloudServiceStoreFixtures
        let store = BackupCloudServiceFakeStore()
        store.products = [S.product]
        let mine = S.transaction(11, original: 11, purchased: -100, expires: 1000)
        let other = S.transaction(12, original: 99, purchased: -200, expires: 1000)
        store.history = [mine, other]
        store.statuses = [
            BackupStoreSubscriptionStatus(state: .subscribed, transaction: other, willAutoRenew: true, renewalInfoJWS: "OTHER"),
            BackupStoreSubscriptionStatus(state: .subscribed, transaction: mine, willAutoRenew: true, renewalInfoJWS: Self.renewal),
        ]
        let subscription = BackupSubscription(productIDs: [S.productID], store: store)
        await subscription.load()
        let signed = try #require(await subscription.signedTransaction())
        #expect(signed.transactionID == 11 && signed.signedRenewalInfo == Self.renewal)

        store.statuses = [BackupStoreSubscriptionStatus(state: .subscribed, transaction: mine, willAutoRenew: nil)]
        #expect(await subscription.signedTransaction()?.signedRenewalInfo == nil, "unverified renewal info is not sent")
    }
}
