import CryptoKit
import Foundation

/// A `SyncObjectStore` in memory, for tests: real compare-and-swap semantics (each call is
/// atomic under one lock), faults injected per call, and a log of every call.
///
/// ETags are like S3's for a single `PutObject`: a quoted hash of the bytes, so writing equal
/// bytes again keeps the ETag and any change of bytes changes it.
///
/// **Time.** Every write stamps the object with the store's clock (`now`, settable, starting at
/// a fixed date), and `list` and `head` report it as `lastModified`, as S3 does. Tests move the
/// clock with `advance(by:)` to make objects old.
///
/// **Faults.** `injectFault(_:on:keyPrefix:count:error:)` makes the next matching call(s) throw:
/// `.beforeEffect` throws without doing anything (a request that never arrived), `.afterEffect`
/// does the call (a write takes effect) and then throws (an answer that was lost, as with a put
/// that timed out but committed). Faults match in the order they were injected.
public final class InMemorySyncObjectStore: SyncObjectStore, @unchecked Sendable {
    /// One stored object.
    public struct StoredObject: Hashable, Sendable {
        public var data: Data
        public var eTag: String
        public var metadata: [String: String]
        /// The store's clock when it was last written.
        public var lastModified: Date = InMemorySyncObjectStore.epoch
    }

    /// Where the clock starts: 1 November 2026, 00:00 UTC.
    public static let epoch = Date(timeIntervalSince1970: 1_793_491_200)

    /// The store's operations, for faults and the call log.
    public enum Operation: String, Hashable, Sendable, CaseIterable {
        case list, get, put, upload, download, head, delete
    }

    /// When an injected fault strikes.
    public enum FaultTiming: Hashable, Sendable {
        /// Before the call has any effect.
        case beforeEffect
        /// After the call took effect (a write is stored), in place of its answer.
        case afterEffect
    }

    /// How a call ended.
    public enum Outcome: Hashable, Sendable {
        case succeeded
        case preconditionFailed
        case notFound
        case tooLarge
        case faultBeforeEffect
        case faultAfterEffect
    }

    /// One call, as the store saw it.
    public struct Call: Hashable, Sendable {
        public var operation: Operation
        /// The key, or the prefix for `list`.
        public var key: String
        public var condition: SyncWriteCondition?
        public var outcome: Outcome
    }

    /// The error an injected fault throws unless another is given.
    public struct InjectedFault: Error, Hashable, Sendable {
        public init() {}
    }

    private struct PendingFault {
        var timing: FaultTiming
        var operation: Operation
        var keyPrefix: String
        var remaining: Int
        var error: any Error
    }

    /// A step another test actor takes just before a matching call takes effect.
    private struct PendingHook {
        var operation: Operation
        var keyPrefix: String
        var action: @Sendable () async throws -> Void
    }

    private let lock = NSLock()
    private var objects: [String: StoredObject] = [:]
    private var faults: [PendingFault] = []
    private var hooks: [PendingHook] = []
    private var log: [Call] = []
    private var clock = InMemorySyncObjectStore.epoch

    /// A store holding `objects` (key → bytes, no metadata).
    public init(objects: [String: Data] = [:]) {
        for (key, data) in objects { self.objects[key] = Self.stored(data, metadata: [:], at: clock) }
    }

    // MARK: Test controls

    /// The store's clock: what the next write is stamped with.
    public var now: Date {
        get { lock.withLock { clock } }
        set { lock.withLock { clock = newValue } }
    }

    /// Moves the clock on.
    public func advance(by interval: TimeInterval) {
        lock.withLock { clock = clock.addingTimeInterval(interval) }
    }

    /// Makes the next `count` calls of `operation` on a key starting with `keyPrefix` throw
    /// `error` at `timing`.
    public func injectFault(_ timing: FaultTiming, on operation: Operation, keyPrefix: String = "", count: Int = 1,
                            error: any Error = InjectedFault()) {
        lock.withLock {
            faults.append(PendingFault(timing: timing, operation: operation, keyPrefix: keyPrefix,
                                       remaining: max(1, count), error: error))
        }
    }

    /// Runs `action` once, just before the next call of `operation` on a key starting with
    /// `keyPrefix` takes effect (the call waits for it). For deterministic interleavings: another
    /// device's work slipped in between two calls of the one under test. An error `action`
    /// throws is ignored.
    public func beforeNextCall(_ operation: Operation, keyPrefix: String = "",
                               _ action: @escaping @Sendable () async throws -> Void) {
        lock.withLock { hooks.append(PendingHook(operation: operation, keyPrefix: keyPrefix, action: action)) }
    }

    /// Every call so far, in order.
    public var calls: [Call] { lock.withLock { log } }

    /// Forgets the call log.
    public func clearCalls() { lock.withLock { log = [] } }

    /// Every key, sorted.
    public var keys: [String] { lock.withLock { objects.keys.sorted() } }

    /// The stored object, without logging a call.
    public func object(_ key: String) -> StoredObject? { lock.withLock { objects[key] } }

    /// Every object's bytes, without logging a call.
    public var contents: [String: Data] { lock.withLock { objects.mapValues(\.data) } }

    /// Stores bytes directly (seeding, tampering, renaming), without conditions or logging,
    /// stamped `lastModified` (default: the clock).
    public func setObject(_ data: Data, at key: String, metadata: [String: String] = [:], lastModified: Date? = nil) {
        lock.withLock { objects[key] = Self.stored(data, metadata: metadata, at: lastModified ?? clock) }
    }

    /// Changes an object's last-modified time directly (making it older or newer).
    public func setLastModified(_ date: Date, of key: String) {
        lock.withLock { objects[key]?.lastModified = date }
    }

    /// Removes an object directly, without logging a call.
    public func removeObject(_ key: String) {
        lock.withLock { _ = objects.removeValue(forKey: key) }
    }

    // MARK: SyncObjectStore

    public func list(prefix: String) async throws -> [SyncObjectInfo] {
        try await perform(.list, key: prefix) {
            .init(objects.filter { $0.key.hasPrefix(prefix) }
                .map { SyncObjectInfo(key: $0.key, eTag: $0.value.eTag, size: Int64($0.value.data.count),
                                      lastModified: $0.value.lastModified) }
                .sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) })
        }
    }

    public func get(_ key: String, maxBytes: Int) async throws -> SyncObjectData? {
        try await perform(.get, key: key) {
            guard let object = objects[key] else { return .init(nil, .notFound) }
            guard object.data.count <= maxBytes else {
                return .init(failure: SyncError.objectTooLarge(key: key, limit: maxBytes), .tooLarge)
            }
            return .init(SyncObjectData(data: object.data, eTag: object.eTag, metadata: object.metadata))
        }
    }

    public func put(_ data: Data, at key: String, metadata: [String: String],
                    condition: SyncWriteCondition?) async throws -> String {
        try await perform(.put, key: key, condition: condition) {
            switch condition {
            case .ifMatch(let eTag):
                guard objects[key]?.eTag == eTag else {
                    return .init(failure: SyncError.preconditionFailed(key: key), .preconditionFailed)
                }
            case .ifAbsent:
                guard objects[key] == nil else {
                    return .init(failure: SyncError.preconditionFailed(key: key), .preconditionFailed)
                }
            case nil:
                break
            }
            let stored = Self.stored(data, metadata: metadata, at: clock)
            objects[key] = stored
            return .init(stored.eTag)
        }
    }

    public func upload(fileAt file: URL, to key: String, metadata: [String: String]) async throws {
        let data = try Data(contentsOf: file)
        try await perform(.upload, key: key) {
            objects[key] = Self.stored(data, metadata: metadata, at: clock)
            return .init(())
        }
    }

    public func download(_ key: String, to file: URL) async throws {
        let data: Data = try await perform(.download, key: key) {
            guard let object = objects[key] else {
                return .init(failure: SyncError.objectNotFound(key: key), .notFound)
            }
            return .init(object.data)
        }
        try data.write(to: file, options: .atomic)
    }

    public func head(_ key: String) async throws -> SyncObjectHead? {
        try await perform(.head, key: key) {
            guard let object = objects[key] else { return .init(nil, .notFound) }
            return .init(SyncObjectHead(size: Int64(object.data.count), eTag: object.eTag, metadata: object.metadata,
                                        lastModified: object.lastModified))
        }
    }

    public func delete(_ key: String) async throws {
        try await perform(.delete, key: key) {
            objects.removeValue(forKey: key)
            return .init(())
        }
    }

    // MARK: Internals

    /// What one call's body decided, under the lock.
    private struct CallResult<T> {
        var value: T?
        var failure: (any Error)?
        var outcome: Outcome

        init(_ value: T, _ outcome: Outcome = .succeeded) {
            self.value = value
            self.outcome = outcome
        }

        init(failure: any Error, _ outcome: Outcome) {
            self.failure = failure
            self.outcome = outcome
        }
    }

    /// Runs `body` atomically under the lock, applying the first matching fault and logging the call.
    private func perform<T>(_ operation: Operation, key: String, condition: SyncWriteCondition? = nil,
                            _ body: () -> CallResult<T>) async throws -> T {
        // Lets concurrent callers interleave between calls, as requests to a real service do.
        await Task.yield()
        let hook: PendingHook? = lock.withLock {
            guard let index = hooks.firstIndex(where: { $0.operation == operation && key.hasPrefix($0.keyPrefix) }) else {
                return nil
            }
            return hooks.remove(at: index)
        }
        if let hook { try? await hook.action() }
        try Task.checkCancellation()
        let (result, fault): (CallResult<T>?, PendingFault?) = lock.withLock {
            var fault: PendingFault?
            if let index = faults.firstIndex(where: { $0.operation == operation && key.hasPrefix($0.keyPrefix) }) {
                fault = faults[index]
                faults[index].remaining -= 1
                if faults[index].remaining == 0 { faults.remove(at: index) }
            }
            if let fault, fault.timing == .beforeEffect {
                log.append(Call(operation: operation, key: key, condition: condition, outcome: .faultBeforeEffect))
                return (nil, fault)
            }
            let result = body()
            log.append(Call(operation: operation, key: key, condition: condition,
                            outcome: fault == nil ? result.outcome : .faultAfterEffect))
            return (result, fault)
        }
        if let fault { throw fault.error }
        guard let result else { throw InjectedFault() }
        if let failure = result.failure { throw failure }
        return result.value!
    }

    private static func stored(_ data: Data, metadata: [String: String], at date: Date) -> StoredObject {
        let hex = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        return StoredObject(data: data, eTag: "\"\(hex)\"", metadata: metadata, lastModified: date)
    }
}
