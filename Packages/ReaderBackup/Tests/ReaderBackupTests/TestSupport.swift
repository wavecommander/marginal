import Foundation
import Testing
@testable import ReaderBackup

/// A fresh directory under the system temporary directory, removed when released.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// `url/<path>`; with `contents`, writes the file (creating parents).
    @discardableResult
    func file(_ path: String, _ contents: Data? = nil) throws -> URL {
        let file = url.appendingPathComponent(path, isDirectory: false)
        if let contents {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file)
        }
        return file
    }

    /// Every name under `url`, recursively, including hidden ones, as relative paths, sorted.
    func allPaths(under path: String = "") -> [String] {
        let base = path.isEmpty ? url : url.appendingPathComponent(path)
        guard let enumerator = FileManager.default.enumerator(atPath: base.path) else { return [] }
        return (enumerator.allObjects as? [String] ?? []).sorted()
    }
}

/// Deterministic pseudo-random bytes.
func pseudoRandomData(count: Int, seed: UInt64) -> Data {
    var state = seed
    var data = Data(count: count)
    data.withUnsafeMutableBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        for index in 0..<count {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            bytes[index] = UInt8(truncatingIfNeeded: z ^ (z >> 31))
        }
    }
    return data
}

/// 9 MiB + 123 bytes: more than two 4 MiB chunks, with a ragged last chunk.
let multiChunkSize = 9 * 1024 * 1024 + 123

/// Replaces every occurrence of `old` with `new` (same length) in the file at `url`; returns
/// how many were replaced.
@discardableResult
func patchFile(_ url: URL, replacing old: Data, with new: Data) throws -> Int {
    precondition(old.count == new.count)
    var data = try Data(contentsOf: url)
    var count = 0
    var searchStart = data.startIndex
    while let range = data.range(of: old, in: searchStart..<data.endIndex) {
        data.replaceSubrange(range, with: new)
        searchStart = range.upperBound
        count += 1
    }
    try data.write(to: url)
    return count
}

/// Flips every bit of the byte at `offset` in the file at `url`.
func flipByte(_ url: URL, at offset: Int) throws {
    var data = try Data(contentsOf: url)
    data[data.startIndex + offset] ^= 0xFF
    try data.write(to: url)
}

/// Offset of the central directory of a ZIP written by `ZipArchiveWriter` (first central
/// header signature).
func centralDirectoryOffset(of url: URL) throws -> Int {
    let data = try Data(contentsOf: url)
    let signature = Data([0x50, 0x4b, 0x01, 0x02])
    return try #require(data.range(of: signature)).lowerBound
}

/// Runs a closure inside a separate task that cancels itself the first time `shouldCancel`
/// says so; returns the thrown error (or `nil`).
func runCancelling(_ body: @escaping @Sendable (_ cancel: @escaping @Sendable () -> Void) throws -> Void) async -> (any Error)? {
    let task = Task<Void, any Error> {
        try body { withUnsafeCurrentTask { $0?.cancel() } }
    }
    do {
        try await task.value
        return nil
    } catch {
        return error
    }
}

/// Collects progress values.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] { lock.withLock { storage } }

    var callback: BackupProgress {
        { [self] value in lock.withLock { storage.append(value) } }
    }

    /// Non-decreasing, within 0...1, ending at 1.
    var isWellFormed: Bool {
        let values = values
        guard let last = values.last, last == 1 else { return false }
        return zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } && values.allSatisfy { (0...1).contains($0) }
    }
}

#if os(macOS)
/// Runs a command-line tool; returns its exit status and combined output.
@discardableResult
func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}
#endif
