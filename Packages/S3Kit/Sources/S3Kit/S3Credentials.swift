import Foundation

/// The keys one request is signed with: a long-lived access key, or temporary credentials with a
/// session token and an expiry (Cloudflare R2 "Temporary credentials", AWS STS).
///
/// No value here ever appears in a description, debug description or mirror: the access key ID,
/// secret and session token are all shown as `<redacted>`, so credentials can be logged or
/// interpolated safely.
public struct S3Credentials: Hashable, Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String
    /// Sent with every request as `X-Amz-Security-Token` (and signed); `nil` for a long-lived key.
    public var sessionToken: String?
    /// When the service stops accepting these credentials; `nil` when they don't expire.
    public var expiration: Date?

    /// A session token that is empty after trimming whitespace counts as none.
    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil, expiration: Date? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        let token = sessionToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionToken = token?.isEmpty == false ? token : nil
        self.expiration = expiration
    }

    /// The values a service error message must never carry: the secret and the session token.
    var redactions: [String] { [secretAccessKey, sessionToken ?? ""].filter { !$0.isEmpty } }
}

extension S3Credentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "S3Credentials(accessKeyID: <redacted>, secretAccessKey: <redacted>, "
            + "sessionToken: \(sessionToken == nil ? "<none>" : "<redacted>"), "
            + "expiration: \(expiration.map { "\($0)" } ?? "<none>"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["accessKeyID": "<redacted>", "secretAccessKey": "<redacted>",
                                "sessionToken": sessionToken == nil ? "<none>" : "<redacted>",
                                "expiration": expiration as Any], displayStyle: .struct)
    }
}

/// Where `S3Client` gets the credentials for each request.
///
/// The client asks before **every** request (each part of a multipart upload, each list page,
/// each ranged download request), so a long transfer keeps working while the credentials change
/// underneath it. When the service says the session token has expired or is invalid, the client
/// calls `credentialsRejected(_:)` with the credentials it used, asks again, and retries that
/// request once.
public protocol S3CredentialsProvider: Sendable {
    /// The credentials to sign the next request with. Errors thrown here are passed through by
    /// `S3Client` unchanged (they are the provider's own, for example "not subscribed").
    func credentials() async throws -> S3Credentials

    /// The service rejected `credentials`: forget them, so the next `credentials()` call fetches
    /// new ones rather than handing them back.
    func credentialsRejected(_ credentials: S3Credentials) async
}

/// Always the same credentials: a long-lived key, as `S3Configuration` supplies. A rejection
/// changes nothing (there is nothing to refresh).
public struct S3StaticCredentialsProvider: S3CredentialsProvider, CustomStringConvertible, CustomReflectable {
    private let value: S3Credentials

    public init(_ credentials: S3Credentials) {
        value = credentials
    }

    public func credentials() async throws -> S3Credentials { value }

    public func credentialsRejected(_ credentials: S3Credentials) async {}

    public var description: String { "S3StaticCredentialsProvider(\(value))" }

    public var customMirror: Mirror { Mirror(self, children: ["credentials": value], displayStyle: .struct) }
}

/// Temporary credentials fetched on demand and cached until they are close to expiring.
///
/// - Credentials are reused until they are within `refreshMargin` of their `expiration` (by the
///   injected clock); credentials without an expiry are reused until rejected.
/// - Callers that ask while a fetch is under way wait for that same fetch: eight concurrent
///   callers cause one fetch.
/// - A fetch that throws is not cached: every waiting caller gets its error, and the next call
///   fetches again.
/// - `credentialsRejected(_:)` drops the cached credentials if they are the rejected ones, so the
///   next call fetches fresh ones instead of handing them back.
public actor S3RefreshingCredentialsProvider: S3CredentialsProvider {
    /// 60 seconds.
    public static let defaultRefreshMargin: Duration = .seconds(60)

    public nonisolated let refreshMargin: Duration
    private let fetch: @Sendable () async throws -> S3Credentials
    private let now: @Sendable () -> Date
    private var cached: S3Credentials?
    private var inFlight: (id: UUID, task: Task<S3Credentials, any Error>)?
    private var fetchCount = 0

    /// - Parameters:
    ///   - refreshMargin: how long before `expiration` credentials are replaced.
    ///   - now: the clock expiry is judged by (injected for tests).
    ///   - fetch: gets fresh credentials, for example from the backup service.
    public init(refreshMargin: Duration = defaultRefreshMargin, now: @escaping @Sendable () -> Date = { Date() },
                fetch: @escaping @Sendable () async throws -> S3Credentials) {
        self.refreshMargin = refreshMargin
        self.now = now
        self.fetch = fetch
    }

    public func credentials() async throws -> S3Credentials {
        if let cached, isFresh(cached) { return cached }
        let task: Task<S3Credentials, any Error>
        if let inFlight {
            task = inFlight.task
        } else {
            let id = UUID(), fetch = self.fetch
            fetchCount += 1
            // The task runs on this actor and stores its own result before any caller sees it, so
            // a rejection reported by a caller always comes after the cache was filled and can
            // clear it.
            task = Task {
                do {
                    let fresh = try await fetch()
                    self.finish(id, with: fresh)
                    return fresh
                } catch {
                    self.finish(id, with: nil)
                    throw error
                }
            }
            inFlight = (id, task)
        }
        let fresh = try await task.value
        try Task.checkCancellation()
        return fresh
    }

    public func credentialsRejected(_ credentials: S3Credentials) {
        if cached == credentials { cached = nil }
    }

    /// How many fetches have been started (for diagnostics and tests).
    public var fetches: Int { fetchCount }

    private func finish(_ id: UUID, with credentials: S3Credentials?) {
        guard inFlight?.id == id else { return }
        inFlight = nil
        cached = credentials
    }

    private func isFresh(_ credentials: S3Credentials) -> Bool {
        guard let expiration = credentials.expiration else { return true }
        let parts = refreshMargin.components
        let margin = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return expiration.timeIntervalSince(now()) > margin
    }
}

extension S3RefreshingCredentialsProvider: CustomStringConvertible, CustomReflectable {
    public nonisolated var description: String { "S3RefreshingCredentialsProvider(refreshMargin: \(refreshMargin))" }

    /// Nothing cached is reflected, so `dump(_:)` shows no credential.
    public nonisolated var customMirror: Mirror {
        Mirror(self, children: ["refreshMargin": refreshMargin], displayStyle: .class)
    }
}
