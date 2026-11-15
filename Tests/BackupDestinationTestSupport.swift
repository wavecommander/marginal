import Foundation
import ReaderBackup
@testable import Marginal

/// A scratch directory removed by `cleanup()`.
nonisolated struct BackupDestinationScratch {
    let url: URL

    init(_ label: String = "BackupDestinationTests") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }

    /// A file named `name` holding `bytes`.
    func file(_ name: String, _ bytes: Data) throws -> URL {
        let file = url.appendingPathComponent(name, isDirectory: false)
        try bytes.write(to: file)
        return file
    }

    func directory(_ name: String) throws -> URL {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Deterministic bytes of a given length.
nonisolated func backupTestBytes(_ count: Int, seed: UInt8 = 7) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

/// A snapshot name `minutes` after a fixed date.
nonisolated func backupTestSnapshotName(minutes: Int, device: String = "Test iPad") -> String {
    SnapshotName.make(createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(minutes * 60)), deviceName: device)
}

/// A unique `UserDefaults` suite, removed by `cleanup()`.
nonisolated struct BackupTestDefaults: @unchecked Sendable {
    let name = "BackupDestinationTests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    func cleanup() { UserDefaults().removePersistentDomain(forName: name) }
}

/// A coordinator that records each access (path relative to `real`, and its coordination) and
/// runs it directly. When `nominal` is set, URLs under it are handed to the body under `real`
/// instead, so an access that bypassed the coordinator would hit a path that doesn't exist.
nonisolated final class RecordingCoordinator: BackupFileCoordinating, @unchecked Sendable {
    struct Access: Hashable { var path: String; var kind: BackupFileCoordination }

    let nominal: URL?
    let real: URL
    private let lock = NSLock()
    private var accesses: [Access] = []
    private var failure: (any Error)?

    init(real: URL, nominal: URL? = nil) {
        self.real = real
        self.nominal = nominal
    }

    var log: [Access] { lock.withLock { accesses } }
    func reset() { lock.withLock { accesses = [] } }
    /// Makes every later coordination fail with `error` before its body runs.
    func fail(with error: (any Error)?) { lock.withLock { failure = error } }

    func coordinate(_ url: URL, _ kind: BackupFileCoordination, _ body: (URL) throws -> Void) throws {
        let granted = redirect(url)
        let failure = lock.withLock { () -> (any Error)? in
            accesses.append(Access(path: relativePath(granted), kind: kind))
            return self.failure
        }
        if let failure { throw BackupFileCoordinationError.translate(failure, url: url) }
        try body(granted)
    }

    private func redirect(_ url: URL) -> URL {
        guard let nominal else { return url }
        let base = nominal.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else { return url }
        let rest = String(path.dropFirst(base.count))
        return URL(fileURLWithPath: real.standardizedFileURL.path + rest, isDirectory: url.hasDirectoryPath)
    }

    private func relativePath(_ url: URL) -> String {
        let base = real.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == base { return "" }
        guard path.hasPrefix(base + "/") else { return "OUTSIDE:" + path }
        return String(path.dropFirst(base.count + 1))
    }
}

/// Bookmarks that are just the path, with switches for staleness and failure.
nonisolated final class FakeBookmarking: BackupFolderBookmarking, @unchecked Sendable {
    private let lock = NSLock()
    private var _made = 0
    private var _staleData: Set<Data> = []
    private var _failResolving = false
    /// When set, every bookmark resolves to this URL.
    var resolvesTo: URL?

    var made: Int { lock.withLock { _made } }
    /// Bookmark `data` resolves as stale from now on.
    func markStale(_ data: Data) { lock.withLock { _ = _staleData.insert(data) } }
    func failResolving(_ fail: Bool) { lock.withLock { _failResolving = fail } }

    func bookmarkData(for url: URL) throws -> Data {
        lock.withLock {
            _made += 1
            return Data("\(_made)|\(url.path)".utf8)
        }
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        try lock.withLock {
            if _failResolving { throw CocoaError(.fileNoSuchFile) }
            let path = String(decoding: data, as: UTF8.self).split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""
            return (resolvesTo ?? URL(fileURLWithPath: path, isDirectory: true), _staleData.contains(data))
        }
    }
}

/// Stands in for iCloud: per-file status, and a hook run on each download request.
nonisolated final class FakeUbiquity: BackupUbiquitousItemControl, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: BackupUbiquitousItemStatus] = [:]
    private var _requested: [String] = []
    /// Runs on each download request (items with no status set are not iCloud items).
    var onStart: (@Sendable (URL) -> Void)?

    var requested: [String] { lock.withLock { _requested } }

    func set(_ status: BackupUbiquitousItemStatus?, for url: URL) {
        lock.withLock { statuses[url.standardizedFileURL.path] = status }
    }

    func status(of url: URL) -> BackupUbiquitousItemStatus? {
        lock.withLock { statuses[url.standardizedFileURL.path] }
    }

    func startDownloading(_ url: URL) throws {
        lock.withLock { _requested.append(url.lastPathComponent) }
        onStart?(url)
    }
}

/// Counts polls; `onPoll` runs on each.
nonisolated final class PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var onPoll: (@Sendable (Int) -> Void)?
    var count: Int { lock.withLock { _count } }

    /// A wait policy whose sleeps return at once and are counted.
    func policy(interval: Duration = .seconds(1), start: Duration, timeout: Duration) -> BackupDownloadWaitPolicy {
        BackupDownloadWaitPolicy(pollInterval: interval, startTimeout: start, timeout: timeout) { [self] _ in
            let n = lock.withLock { () -> Int in _count += 1; return _count }
            onPoll?(n)
        }
    }
}

/// Writes an iCloud placeholder for `name` (of `size` bytes) in `directory`.
nonisolated func writeICloudPlaceholder(name: String, size: Int64, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try BackupICloudPlaceholder.contents(name: name, size: size)
        .write(to: directory.appendingPathComponent(BackupICloudPlaceholder.placeholderName(for: name), isDirectory: false))
}

/// The error `body` throws, or `nil`.
nonisolated func thrownError(_ body: () async throws -> Void) async -> (any Error)? {
    do { try await body(); return nil } catch { return error }
}
