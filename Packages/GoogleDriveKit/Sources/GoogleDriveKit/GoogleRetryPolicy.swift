import Foundation

/// How Drive requests are retried after a 429, a 5xx, a 403 rate-limit reason or a dropped
/// connection: truncated exponential backoff with jitter, as Drive's usage-limits guide describes
/// (`min(2^n + random_ms, maximum_backoff)`), for a bounded number of attempts.
public struct GoogleRetryPolicy: Sendable {
    /// Total attempts per request (or, for uploads and downloads, consecutive attempts without
    /// progress) before the error is thrown. At least 1.
    public var maxAttempts: Int
    /// The wait before the first retry; doubled for each further retry.
    public var baseDelay: TimeInterval
    /// Up to this much random extra wait is added to each retry.
    public var maxJitter: TimeInterval
    /// The longest single wait.
    public var maxDelay: TimeInterval
    /// How many times an upload may start a new session after the old one expired.
    public var maxSessionRestarts: Int
    /// Waits; injected so tests do not sleep.
    public var sleep: @Sendable (Duration) async throws -> Void
    /// A random number in `0..<1`; injected so tests are deterministic.
    public var random: @Sendable () -> Double

    public init(
        maxAttempts: Int = 6,
        baseDelay: TimeInterval = 1,
        maxJitter: TimeInterval = 1,
        maxDelay: TimeInterval = 32,
        maxSessionRestarts: Int = 2,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxJitter = maxJitter
        self.maxDelay = maxDelay
        self.maxSessionRestarts = max(0, maxSessionRestarts)
        self.sleep = sleep
        self.random = random
    }

    public static let `default` = GoogleRetryPolicy()

    /// The wait before retry number `retry` (1 for the first retry).
    public func delay(beforeRetry retry: Int) -> TimeInterval {
        let exponent = Double(max(0, retry - 1))
        return min(baseDelay * pow(2, exponent) + random() * maxJitter, maxDelay)
    }

    func backoff(beforeRetry retry: Int) async throws {
        try await sleep(.milliseconds(Int64((delay(beforeRetry: retry) * 1000).rounded())))
        try Task.checkCancellation()
    }
}
