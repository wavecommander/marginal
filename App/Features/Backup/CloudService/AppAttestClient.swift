import CryptoKit
import DeviceCheck
import Foundation

/// Proves to the backup service that requests come from this app on a real Apple device (App
/// Attest): one key per installation, attested once against a server challenge, then used to
/// sign each request.
///
/// The client data hash is always the SHA-256 of the bytes given (the challenge for an
/// attestation, the request's bytes for an assertion), which is what the server recomputes.
nonisolated protocol AppAttestClient: Sendable {
    /// Whether this device and build can attest. `false` in the simulator, on a Mac, and in
    /// most app extensions; the service must then be asked without App Attest (only its
    /// development deployment allows that).
    var isSupported: Bool { get }

    /// The remembered key's identifier, creating (and remembering) a key the first time.
    func keyID() async throws -> String

    /// Asks Apple to attest the key against `challenge` (a one-time value from the server).
    /// The result goes to the server, which keeps the key's public key.
    func attest(challenge: Data) async throws -> AppAttestation

    /// Signs `clientData` (the request's bytes, including the server's challenge) with the
    /// attested key.
    func assertion(for clientData: Data) async throws -> AppAttestAssertion

    /// Forgets the key, so the next `keyID()` creates a new one (after the server refused it,
    /// for example).
    func reset() async
}

/// An attestation of `keyID`, to send to the server once.
nonisolated struct AppAttestation: Hashable, Sendable, CustomStringConvertible {
    let keyID: String
    let attestationObject: Data
    var description: String { "AppAttestation(\(attestationObject.count) bytes)" }
}

/// An assertion made with `keyID`, to send with one request.
nonisolated struct AppAttestAssertion: Hashable, Sendable, CustomStringConvertible {
    let keyID: String
    let assertionObject: Data
    var description: String { "AppAttestAssertion(\(assertionObject.count) bytes)" }
}

/// What can go wrong with App Attest, as the reader can be told.
nonisolated enum AppAttestError: LocalizedError, Hashable, Sendable {
    /// This device or build cannot use App Attest (the simulator, a Mac, an unsupported
    /// device, or an app not registered for it). Asking again will not help.
    case unsupported
    /// Apple's App Attest service could not be reached, or the system failed for now. Try again
    /// later with the same key.
    case temporarilyUnavailable
    /// The key is no longer valid (the app was reinstalled or the iPad restored, or Apple
    /// rejected it). The client has forgotten it; start over with a new key.
    case keyInvalidated
    /// Anything else (`DCError` or other code, for diagnostics).
    case failed(code: Int)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "This device can’t confirm that it’s running the genuine Tactile Texts app, which the backup service requires."
        case .temporarilyUnavailable:
            "Couldn’t confirm with Apple that this is the genuine Tactile Texts app. Try again in a few minutes."
        case .keyInvalidated:
            "This iPad needs to confirm again that it’s running the genuine Tactile Texts app. Try again."
        case .failed(let code):
            "Couldn’t confirm that this is the genuine Tactile Texts app (error \(code)). Try again later."
        }
    }

    /// The step a DeviceCheck error came from: Apple's guidance differs for attestation.
    enum Step: Sendable { case generateKey, attest, assert }

    /// Maps an error from `DCAppAttestService`.
    ///
    /// - `featureUnsupported` → `unsupported`.
    /// - `serverUnavailable` → `temporarilyUnavailable` ("try attestation again later with the
    ///   same key", Apple's "Establishing your app's integrity").
    /// - `invalidKey` → `keyInvalidated` (an already attested key attested again, an unattested
    ///   key used for an assertion, or a key Apple rejects).
    /// - `unknownSystemFailure`: during attestation `keyInvalidated` (the same article: "for
    ///   any other error, discard the key identifier and create a new key"); otherwise
    ///   `temporarilyUnavailable`.
    /// - `invalidInput` and anything else → `failed(code:)`.
    static func mapping(_ error: any Error, step: Step) -> AppAttestError {
        if let attest = error as? AppAttestError { return attest }
        let nsError = error as NSError
        guard nsError.domain == DCErrorDomain, let code = DCError.Code(rawValue: nsError.code) else {
            return .failed(code: nsError.code)
        }
        switch code {
        case .featureUnsupported: return .unsupported
        case .serverUnavailable: return .temporarilyUnavailable
        case .invalidKey: return .keyInvalidated
        case .unknownSystemFailure: return step == .attest ? .keyInvalidated : .temporarilyUnavailable
        case .invalidInput: return .failed(code: code.rawValue)
        @unknown default: return .failed(code: code.rawValue)
        }
    }
}

// MARK: - The system service

/// The calls `DeviceAppAttestClient` makes, so tests can script the service.
nonisolated protocol AppAttestService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// `DCAppAttestService.shared`.
nonisolated struct SystemAppAttestService: AppAttestService {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

/// App Attest with `DCAppAttestService`.
///
/// The key ID and whether it has been attested are kept in `UserDefaults` (an identifier, not a
/// secret: the private key never leaves the Secure Enclave). App Attest keys do not survive
/// reinstalling the app, moving to a new device or restoring from a backup, so a remembered ID
/// can outlive its key; the service then answers `invalidKey`, and the client forgets the ID
/// (`keyInvalidated`) so the next call starts over. Calls are serialised, so concurrent callers
/// never create two keys.
///
/// The App Attest environment entitlement is optional: without it a development build uses
/// Apple's sandbox servers, and a TestFlight or App Store build always uses production
/// (`com.apple.developer.devicecheck.appattest-environment` documentation).
actor DeviceAppAttestClient: AppAttestClient {
    static let defaultsKey = "software.tactile.texts.cloud-backup.app-attest-key"

    private struct Record: Codable {
        var keyID: String
        var attested: Bool
    }

    private let service: any AppAttestService
    private let defaults: UserDefaults
    private let defaultsKey: String

    /// - Parameters:
    ///   - defaultsSuiteName: the `UserDefaults` suite the key ID is kept in; `nil` for the
    ///     app's standard defaults (tests pass their own).
    init(service: any AppAttestService = SystemAppAttestService(), defaultsSuiteName: String? = nil,
         defaultsKey: String = DeviceAppAttestClient.defaultsKey) {
        self.service = service
        defaults = defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.defaultsKey = defaultsKey
    }

    nonisolated var isSupported: Bool { service.isSupported }

    func keyID() async throws -> String {
        try await currentRecord().keyID
    }

    func attest(challenge: Data) async throws -> AppAttestation {
        let record = try await currentRecord()
        do {
            let object = try await service.attestKey(record.keyID, clientDataHash: Self.hash(challenge))
            save(Record(keyID: record.keyID, attested: true))
            return AppAttestation(keyID: record.keyID, attestationObject: object)
        } catch {
            throw failure(error, step: .attest)
        }
    }

    func assertion(for clientData: Data) async throws -> AppAttestAssertion {
        let record = try await currentRecord()
        guard record.attested else { throw AppAttestError.keyInvalidated }
        do {
            let object = try await service.generateAssertion(record.keyID, clientDataHash: Self.hash(clientData))
            return AppAttestAssertion(keyID: record.keyID, assertionObject: object)
        } catch {
            throw failure(error, step: .assert)
        }
    }

    func reset() {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Whether the remembered key has been attested (for diagnostics and tests).
    var hasAttestedKey: Bool { load()?.attested ?? false }

    // MARK: Internals

    private func currentRecord() async throws -> Record {
        guard service.isSupported else { throw AppAttestError.unsupported }
        if let record = load() { return record }
        do {
            let record = Record(keyID: try await service.generateKey(), attested: false)
            // An actor is re-entrant across the await: keep a key another caller saved meanwhile.
            if let existing = load() { return existing }
            save(record)
            return record
        } catch {
            throw AppAttestError.mapping(error, step: .generateKey)
        }
    }

    private func failure(_ error: any Error, step: AppAttestError.Step) -> AppAttestError {
        let mapped = AppAttestError.mapping(error, step: step)
        if mapped == .keyInvalidated { reset() }
        return mapped
    }

    private func load() -> Record? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    private func save(_ record: Record) {
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: defaultsKey) }
    }

    private static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

// MARK: - Fake

/// An `AppAttestClient` that makes recognisable fake objects, for tests and for the simulator
/// against a development deployment of the service that accepts them. Never use it against
/// production: the server rejects its objects.
///
/// Objects are `fake-attestation:<keyID>:<hex SHA-256 of the challenge>` and
/// `fake-assertion:<keyID>:<hex SHA-256 of the client data>` in UTF-8. Setting `nextError`
/// makes the next call throw it.
nonisolated final class FakeAppAttestClient: AppAttestClient, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var attested = false
    private var counter = 0
    private var pendingError: AppAttestError?
    let isSupported: Bool

    init(isSupported: Bool = true) {
        self.isSupported = isSupported
    }

    /// Thrown (once) by the next call.
    var nextError: AppAttestError? {
        get { lock.withLock { pendingError } }
        set { lock.withLock { pendingError = newValue } }
    }

    func keyID() async throws -> String {
        try lock.withLock { try currentKeyLocked() }
    }

    func attest(challenge: Data) async throws -> AppAttestation {
        try lock.withLock {
            let keyID = try currentKeyLocked()
            attested = true
            return AppAttestation(keyID: keyID, attestationObject: Data("fake-attestation:\(keyID):\(Self.hex(challenge))".utf8))
        }
    }

    func assertion(for clientData: Data) async throws -> AppAttestAssertion {
        try lock.withLock {
            let keyID = try currentKeyLocked()
            guard attested else { throw AppAttestError.keyInvalidated }
            return AppAttestAssertion(keyID: keyID, assertionObject: Data("fake-assertion:\(keyID):\(Self.hex(clientData))".utf8))
        }
    }

    func reset() async {
        lock.withLock {
            key = nil
            attested = false
        }
    }

    private func currentKeyLocked() throws -> String {
        guard isSupported else { throw AppAttestError.unsupported }
        if let error = pendingError {
            pendingError = nil
            if error == .keyInvalidated {
                key = nil
                attested = false
            }
            throw error
        }
        if let key { return key }
        counter += 1
        let new = "fake-key-\(counter)"
        key = new
        return new
    }

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
