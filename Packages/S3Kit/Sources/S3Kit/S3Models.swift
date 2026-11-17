import Foundation

/// One object from `S3Client.list(prefix:)`.
public struct S3ObjectSummary: Sendable, Hashable {
    /// The key relative to the configured prefix (`Backups/Monday.ttbackup`).
    public var key: String
    public var size: Int64
    public var lastModified: Date?
    /// As the service sent it, quotes included.
    public var eTag: String?

    public init(key: String, size: Int64, lastModified: Date?, eTag: String?) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.eTag = eTag
    }
}

/// What `S3Client.head(key:)` reports about an existing object.
public struct S3ObjectHead: Sendable, Hashable {
    public var size: Int64
    /// User metadata (`x-amz-meta-*`), names lowercased and without the prefix.
    public var metadata: [String: String]
    public var eTag: String?
    public var lastModified: Date?

    public init(size: Int64, metadata: [String: String], eTag: String?, lastModified: Date?) {
        self.size = size
        self.metadata = metadata
        self.eTag = eTag
        self.lastModified = lastModified
    }
}

/// Transfer progress: bytes done so far and the total.
public typealias S3Progress = @Sendable (_ completedBytes: Int64, _ totalBytes: Int64) -> Void

/// Bounded exponential backoff with jitter, for transient failures (transport errors, HTTP 5xx
/// and 429, `RequestTimeout`, `SlowDown`, ...).
///
/// The delay before retry `n` (1-based) is `min(maximumDelay, initialDelay * 2^(n-1))` scaled by
/// a jitter factor in `0.5...1.0` ("equal jitter"), so retries never hammer the service in step.
public struct S3RetryPolicy: Sendable {
    /// Attempts in all, the first included (1 means no retries).
    public var maxAttempts: Int
    public var initialDelay: Duration
    public var maximumDelay: Duration
    /// Waits between attempts; throws `CancellationError` when the task is cancelled.
    public var sleep: @Sendable (Duration) async throws -> Void
    /// A random number in `0...1`.
    public var random: @Sendable () -> Double

    public init(maxAttempts: Int = 5, initialDelay: Duration = .milliseconds(500), maximumDelay: Duration = .seconds(20),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.sleep = sleep
        self.random = random
    }

    public static let standard = S3RetryPolicy()

    /// The wait before retry number `retry` (1 for the second attempt).
    public func delay(beforeRetry retry: Int) -> Duration {
        let base = Self.seconds(initialDelay) * pow(2, Double(max(0, retry - 1)))
        let capped = min(base, Self.seconds(maximumDelay))
        let factor = 0.5 + 0.5 * min(1, max(0, random()))
        return .seconds(capped * factor)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// The condition of a conditional `PutObject` (`S3Client.putObject(data:key:metadata:condition:)`).
public enum S3PutCondition: Sendable, Hashable {
    /// `If-Match: <eTag>`: replace the object only while its ETag is still `eTag` (as the service
    /// sent it, quotes included). Refused when the object changed or does not exist.
    case ifMatch(eTag: String)
    /// `If-None-Match: *`: create the object only if there is none with that key.
    case ifAbsent
}

/// A small object read into memory by `S3Client.getObject(key:maxBytes:)`.
public struct S3Object: Sendable, Hashable {
    public var data: Data
    /// As the service sent it, quotes included.
    public var eTag: String?
    /// User metadata (`x-amz-meta-*`), names lowercased and without the prefix.
    public var metadata: [String: String]
    public var lastModified: Date?

    public init(data: Data, eTag: String?, metadata: [String: String], lastModified: Date?) {
        self.data = data
        self.eTag = eTag
        self.metadata = metadata
        self.lastModified = lastModified
    }
}

/// What a conditional small-object read (`S3Client.getObject(key:maxBytes:ifNoneMatch:)`) found.
public enum S3ObjectRead: Sendable, Hashable {
    /// The object, which differs from the ETag given (or no ETag was given).
    case found(S3Object)
    /// The object's ETag is still the one given (HTTP 304); nothing was transferred.
    case notModified
    /// There is no object with that key.
    case notFound
}
