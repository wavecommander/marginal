import Foundation
import Testing
@testable import S3Kit

/// A settable clock.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_767_225_600)) { current = start }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Hands out `temporaryCredentials(1)`, `(2)`, ... one per fetch, optionally expiring
/// `lifetime` seconds after the clock's time, and can be told to fail.
final class CredentialSource: @unchecked Sendable {
    struct Failure: Error, Equatable {}

    private let lock = NSLock()
    private var count = 0
    private var failuresLeft = 0
    let clock: TestClock
    let lifetime: TimeInterval?
    let delay: Duration?

    init(clock: TestClock = TestClock(), lifetime: TimeInterval? = nil, delay: Duration? = nil) {
        self.clock = clock
        self.lifetime = lifetime
        self.delay = delay
    }

    var fetches: Int { lock.withLock { count } }
    func failNext(_ times: Int = 1) { lock.withLock { failuresLeft = times } }

    func fetch() async throws -> S3Credentials {
        let (number, fails) = lock.withLock { () -> (Int, Bool) in
            count += 1
            let fails = failuresLeft > 0
            if fails { failuresLeft -= 1 }
            return (count, fails)
        }
        if let delay { try await Task.sleep(for: delay) }
        if fails { throw Failure() }
        return temporaryCredentials(number, expiration: lifetime.map { clock.now.addingTimeInterval($0) })
    }

    func provider(margin: Duration = S3RefreshingCredentialsProvider.defaultRefreshMargin) -> S3RefreshingCredentialsProvider {
        let clock = self.clock
        return S3RefreshingCredentialsProvider(refreshMargin: margin, now: { clock.now }) { try await self.fetch() }
    }
}

struct S3RefreshingCredentialsProviderTests {
    @Test func credentialsAreCachedUntilTheyNearExpiry() async throws {
        let source = CredentialSource(lifetime: 900)
        let provider = source.provider()
        let first = try await provider.credentials()
        #expect(first == temporaryCredentials(1, expiration: source.clock.now.addingTimeInterval(900)))
        #expect(try await provider.credentials() == first)
        source.clock.advance(by: 839) // 61 s left: still outside the 60 s margin
        #expect(try await provider.credentials() == first)
        #expect(source.fetches == 1)
        source.clock.advance(by: 2) // 59 s left: inside the margin
        let second = try await provider.credentials()
        #expect(second.sessionToken == temporaryCredentials(2).sessionToken)
        #expect(source.fetches == 2)
        #expect(try await provider.credentials() == second)
        #expect(await provider.fetches == 2)
    }

    @Test func theMarginIsConfigurable() async throws {
        let source = CredentialSource(lifetime: 900)
        let provider = source.provider(margin: .seconds(300))
        _ = try await provider.credentials()
        source.clock.advance(by: 599)
        _ = try await provider.credentials()
        #expect(source.fetches == 1)
        source.clock.advance(by: 2)
        _ = try await provider.credentials()
        #expect(source.fetches == 2)
    }

    @Test func credentialsWithoutAnExpiryAreKeptUntilRejected() async throws {
        let source = CredentialSource()
        let provider = source.provider()
        let first = try await provider.credentials()
        source.clock.advance(by: 86_400 * 365)
        #expect(try await provider.credentials() == first)
        #expect(source.fetches == 1)
    }

    @Test func eightConcurrentCallersShareOneFetch() async throws {
        let source = CredentialSource(lifetime: 900, delay: .milliseconds(100))
        let provider = source.provider()
        let results = try await withThrowingTaskGroup(of: S3Credentials.self) { group in
            for _ in 0..<8 { group.addTask { try await provider.credentials() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 8)
        #expect(Set(results).count == 1)
        #expect(source.fetches == 1)
    }

    @Test func aFailedFetchIsNotCachedAndEveryWaiterGetsItsError() async throws {
        let source = CredentialSource(lifetime: 900, delay: .milliseconds(200))
        let provider = source.provider()
        source.failNext()
        let outcomes = await withTaskGroup(of: String.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do { _ = try await provider.credentials(); return "credentials" } catch {
                        return error is CredentialSource.Failure ? "fetch failure" : "\(error)"
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outcomes == Array(repeating: "fetch failure", count: 4))
        #expect(source.fetches == 1)
        let credentials = try await provider.credentials()
        #expect(credentials.sessionToken == temporaryCredentials(2).sessionToken)
        #expect(source.fetches == 2)
    }

    @Test func theErrorOfAFailedFetchIsThrownAsItIs() async throws {
        let source = CredentialSource()
        let provider = source.provider()
        source.failNext()
        await #expect(throws: CredentialSource.Failure()) { try await provider.credentials() }
    }

    @Test func aRejectionForcesAFreshFetch() async throws {
        let source = CredentialSource(lifetime: 900)
        let provider = source.provider()
        let first = try await provider.credentials()
        await provider.credentialsRejected(first)
        let second = try await provider.credentials()
        #expect(second != first)
        #expect(second.sessionToken == temporaryCredentials(2).sessionToken)
        #expect(try await provider.credentials() == second)
        #expect(source.fetches == 2)
    }

    @Test func rejectingOlderCredentialsKeepsTheCurrentOnes() async throws {
        let source = CredentialSource(lifetime: 900)
        let provider = source.provider()
        let first = try await provider.credentials()
        await provider.credentialsRejected(first)
        let second = try await provider.credentials()
        // A request that was still using the first credentials reports them late.
        await provider.credentialsRejected(first)
        #expect(try await provider.credentials() == second)
        #expect(source.fetches == 2)
    }

    @Test func theStaticProviderAlwaysAnswersTheSame() async throws {
        let credentials = temporaryCredentials(3)
        let provider = S3StaticCredentialsProvider(credentials)
        #expect(try await provider.credentials() == credentials)
        await provider.credentialsRejected(credentials)
        #expect(try await provider.credentials() == credentials)
    }
}
