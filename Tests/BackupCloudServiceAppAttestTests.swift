import CryptoKit
import DeviceCheck
import Foundation
import Testing
@testable import TactileTexts

/// `AppAttestClient`: the fake, the system service in the simulator (unsupported), and
/// `DeviceAppAttestClient` over a scripted service for key handling and error mapping.
struct BackupCloudServiceAppAttestTests {
    /// A scripted `DCAppAttestService`.
    final class ScriptedService: AppAttestService, @unchecked Sendable {
        private let lock = NSLock()
        let isSupported: Bool
        private var keys = 0
        private var _errors: [String: [any Error]] = [:]
        private(set) var calls: [(String, String, Data)] = []

        init(isSupported: Bool = true) { self.isSupported = isSupported }

        /// Errors thrown, in order, by the next calls of `operation` (`generateKey`, `attest`, `assert`).
        func fail(_ operation: String, with errors: any Error...) {
            lock.withLock { _errors[operation, default: []] += errors }
        }

        private func next(_ operation: String, key: String, hash: Data) throws {
            try lock.withLock {
                calls.append((operation, key, hash))
                if var queued = _errors[operation], !queued.isEmpty {
                    let error = queued.removeFirst()
                    _errors[operation] = queued
                    throw error
                }
            }
        }

        var generated: Int { lock.withLock { keys } }

        func generateKey() async throws -> String {
            try next("generateKey", key: "", hash: Data())
            return lock.withLock { keys += 1; return "key-\(keys)" }
        }

        func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
            try next("attest", key: keyID, hash: clientDataHash)
            return Data("attestation-\(keyID)".utf8)
        }

        func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
            try next("assert", key: keyID, hash: clientDataHash)
            return Data("assertion-\(keyID)".utf8)
        }
    }

    static func dcError(_ code: DCError.Code) -> NSError {
        NSError(domain: DCErrorDomain, code: code.rawValue)
    }

    func client(_ service: ScriptedService) -> (DeviceAppAttestClient, String) {
        let suite = "software.tactile.texts.tests.attest.\(UUID().uuidString)"
        return (DeviceAppAttestClient(service: service, defaultsSuiteName: suite), suite)
    }

    // MARK: Simulator

    @Test(.timeLimit(.minutes(1))) func theSimulatorCannotAttest() async throws {
        #expect(!SystemAppAttestService().isSupported)
        let suite = "software.tactile.texts.tests.attest.\(UUID().uuidString)"
        let client = DeviceAppAttestClient(defaultsSuiteName: suite)
        #expect(!client.isSupported)
        await #expect(throws: AppAttestError.unsupported) { _ = try await client.keyID() }
        await #expect(throws: AppAttestError.unsupported) { _ = try await client.attest(challenge: Data("c".utf8)) }
        await #expect(throws: AppAttestError.unsupported) { _ = try await client.assertion(for: Data("r".utf8)) }
        // And the system service itself says so when asked anyway.
        do {
            _ = try await SystemAppAttestService().generateKey()
            Issue.record("the simulator generated an App Attest key")
        } catch {
            #expect(AppAttestError.mapping(error, step: .generateKey) == .unsupported, "\(error)")
        }
    }

    // MARK: Device client over a scripted service

    @Test func createsRemembersAttestsAndAsserts() async throws {
        let service = ScriptedService()
        let (client, suite) = client(service)
        let id = try await client.keyID()
        #expect(id == "key-1")
        #expect(try await client.keyID() == "key-1")
        #expect(service.generated == 1)
        // A new client value over the same storage remembers it.
        #expect(try await DeviceAppAttestClient(service: service, defaultsSuiteName: suite).keyID() == "key-1")

        // An assertion needs an attested key.
        await #expect(throws: AppAttestError.keyInvalidated) { _ = try await client.assertion(for: Data("r".utf8)) }

        let challenge = Data("server-challenge-0123456789abcdef".utf8)
        let attestation = try await client.attest(challenge: challenge)
        #expect(attestation == AppAttestation(keyID: "key-1", attestationObject: Data("attestation-key-1".utf8)))
        #expect(service.calls.last?.2 == Data(SHA256.hash(data: challenge)))
        #expect(await client.hasAttestedKey)

        let request = Data(#"{"challenge":"abc","path":"/v1/session"}"#.utf8)
        let assertion = try await client.assertion(for: request)
        #expect(assertion == AppAttestAssertion(keyID: "key-1", assertionObject: Data("assertion-key-1".utf8)))
        #expect(service.calls.last?.0 == "assert")
        #expect(service.calls.last?.2 == Data(SHA256.hash(data: request)))

        await client.reset()
        #expect(try await client.keyID() == "key-2")
        #expect(await !client.hasAttestedKey)
    }

    @Test func concurrentCallersShareOneKey() async throws {
        let service = ScriptedService()
        let (client, _) = client(service)
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await client.keyID() } }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(ids.count == 1)
    }

    @Test func serverUnavailableKeepsTheKeyForARetry() async throws {
        let service = ScriptedService()
        let (client, _) = client(service)
        service.fail("attest", with: Self.dcError(.serverUnavailable))
        await #expect(throws: AppAttestError.temporarilyUnavailable) { _ = try await client.attest(challenge: Data("c".utf8)) }
        // Retry with the same key, as Apple advises.
        let attestation = try await client.attest(challenge: Data("c".utf8))
        #expect(attestation.keyID == "key-1")
        #expect(service.generated == 1)
    }

    @Test func anInvalidKeyIsForgottenSoTheNextCallStartsOver() async throws {
        let service = ScriptedService()
        let (client, _) = client(service)
        _ = try await client.attest(challenge: Data("c".utf8))
        // The iPad was restored from a backup: the remembered key is gone.
        service.fail("assert", with: Self.dcError(.invalidKey))
        await #expect(throws: AppAttestError.keyInvalidated) { _ = try await client.assertion(for: Data("r".utf8)) }
        #expect(try await client.keyID() == "key-2")
        #expect(await !client.hasAttestedKey)

        // Any other attestation failure also discards the key (Apple's guidance).
        service.fail("attest", with: Self.dcError(.unknownSystemFailure))
        await #expect(throws: AppAttestError.keyInvalidated) { _ = try await client.attest(challenge: Data("c".utf8)) }
        #expect(try await client.keyID() == "key-3")
    }

    @Test func keyGenerationFailures() async throws {
        let service = ScriptedService()
        let (client, _) = client(service)
        service.fail("generateKey", with: Self.dcError(.featureUnsupported), Self.dcError(.unknownSystemFailure))
        await #expect(throws: AppAttestError.unsupported) { _ = try await client.keyID() }
        await #expect(throws: AppAttestError.temporarilyUnavailable) { _ = try await client.keyID() }
        #expect(try await client.keyID() == "key-1")
    }

    // MARK: Error mapping

    @Test func deviceCheckErrorsMapToThreeReaderOutcomes() {
        typealias E = AppAttestError
        #expect(E.mapping(Self.dcError(.featureUnsupported), step: .attest) == .unsupported)
        #expect(E.mapping(Self.dcError(.serverUnavailable), step: .attest) == .temporarilyUnavailable)
        #expect(E.mapping(Self.dcError(.serverUnavailable), step: .assert) == .temporarilyUnavailable)
        #expect(E.mapping(Self.dcError(.invalidKey), step: .assert) == .keyInvalidated)
        #expect(E.mapping(Self.dcError(.invalidKey), step: .attest) == .keyInvalidated)
        #expect(E.mapping(Self.dcError(.unknownSystemFailure), step: .attest) == .keyInvalidated)
        #expect(E.mapping(Self.dcError(.unknownSystemFailure), step: .assert) == .temporarilyUnavailable)
        #expect(E.mapping(Self.dcError(.unknownSystemFailure), step: .generateKey) == .temporarilyUnavailable)
        #expect(E.mapping(Self.dcError(.invalidInput), step: .assert) == .failed(code: DCError.Code.invalidInput.rawValue))
        #expect(E.mapping(DCError(.invalidKey), step: .assert) == .keyInvalidated)
        #expect(E.mapping(URLError(.notConnectedToInternet), step: .attest) == .failed(code: URLError.notConnectedToInternet.rawValue))
        #expect(E.mapping(AppAttestError.unsupported, step: .attest) == .unsupported)
        let messages = [E.unsupported, .temporarilyUnavailable, .keyInvalidated, .failed(code: 4)].map(\.localizedDescription)
        #expect(Set(messages).count == 4)
    }

    // MARK: Fake

    @Test func theFakeMakesRecognisableObjects() async throws {
        let fake = FakeAppAttestClient()
        #expect(fake.isSupported)
        let id = try await fake.keyID()
        #expect(id == "fake-key-1")
        await #expect(throws: AppAttestError.keyInvalidated) { _ = try await fake.assertion(for: Data("r".utf8)) }
        let challenge = Data("challenge".utf8)
        let attestation = try await fake.attest(challenge: challenge)
        let challengeHex = SHA256.hash(data: challenge).map { String(format: "%02x", $0) }.joined()
        #expect(attestation.attestationObject == Data("fake-attestation:fake-key-1:\(challengeHex)".utf8))
        let assertion = try await fake.assertion(for: Data("r".utf8))
        #expect(String(decoding: assertion.assertionObject, as: UTF8.self).hasPrefix("fake-assertion:fake-key-1:"))

        fake.nextError = .temporarilyUnavailable
        await #expect(throws: AppAttestError.temporarilyUnavailable) { _ = try await fake.assertion(for: Data("r".utf8)) }
        #expect(try await fake.keyID() == "fake-key-1")
        fake.nextError = .keyInvalidated
        await #expect(throws: AppAttestError.keyInvalidated) { _ = try await fake.assertion(for: Data("r".utf8)) }
        #expect(try await fake.keyID() == "fake-key-2")

        let unsupported = FakeAppAttestClient(isSupported: false)
        await #expect(throws: AppAttestError.unsupported) { _ = try await unsupported.keyID() }

        #expect(!"\(attestation)".contains("fake-attestation"))
        #expect(!"\(assertion)".contains("fake-assertion"))
    }
}
