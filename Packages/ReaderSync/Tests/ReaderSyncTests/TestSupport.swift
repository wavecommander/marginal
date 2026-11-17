import CryptoKit
import Foundation
import ReaderBackup
import ReaderCore
@testable import ReaderSync

/// A key with bytes 0, 1, 2, … 31 (the same fixed key as ReaderBackup's tests).
let sequentialKey = try! BackupEncryptionKey(rawBytes: (0..<32).map { UInt8($0) })

func sha256(_ data: Data) -> String { ContentHash.sha256(of: data) }

func digest(_ data: Data) -> ContentDigest { ContentDigest(sha256: sha256(data), size: Int64(data.count)) }

func digest(_ text: String) -> ContentDigest { digest(Data(text.utf8)) }

/// A directory under the system's temporary directory, removed when the value is released.
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderSyncTests-\(UUID().uuidString)",
                                                                           isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, _ data: Data) throws -> URL {
        let file = url.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    /// Paths of every regular file under `sub`, relative to it, sorted.
    func files(under sub: String = "") -> [String] {
        let base = sub.isEmpty ? url : url.appendingPathComponent(sub, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var result: [String] = []
        let prefix = base.standardizedFileURL.path + "/"
        for case let item as URL in enumerator where (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            result.append(String(item.standardizedFileURL.path.dropFirst(prefix.count)))
        }
        return result.sorted()
    }
}

/// Builders for heads and stores.
enum Sample {
    static let pdf = Data("%PDF-1.7\n%Tactile Texts sync sample\n%%EOF\n".utf8)
    static let deviceID = UUID(uuidString: "5A1C0000-0000-4000-8000-0000000000D1")!
    static let date = Date(timeIntervalSinceReferenceDate: 784_000_000)

    static func head(version: Int = 1, previous: Int? = nil, pdf: Data = Sample.pdf, records: Data = Data("{}".utf8),
                     writeID: String = SyncHead.makeWriteID(), deletedAt: Date? = nil) -> SyncHead {
        SyncHead(version: version, previousVersion: previous, writeID: writeID, deviceID: deviceID, deviceName: "Test iPad",
                 modifiedAt: date, deletedAt: deletedAt,
                 book: SyncBookInfo(title: "Sample Book", pageCount: 12, fingerprint: "fp-sample",
                                    readingPosition: SyncReadingPosition(pageIndex: 3, date: date)),
                 references: SyncReferences(records: digest(records), pdf: digest(pdf),
                                            pageInk: [SyncPageInkReference(pageIndex: 2, content: digest("page-2"))],
                                            noteInk: [SyncNoteInkReference(noteID: UUID(uuidString: "5A1C0000-0000-4000-8000-000000000101")!,
                                                                           content: digest("note-ink"))]))
    }

    static func store(key: BackupEncryptionKey = sequentialKey, objects: InMemorySyncObjectStore = InMemorySyncObjectStore(),
                      temporary: URL) -> EncryptedSyncStore {
        EncryptedSyncStore(store: objects, key: key, temporaryDirectory: temporary)
    }
}

/// Collects values from concurrent tasks.
final class Collected<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}
