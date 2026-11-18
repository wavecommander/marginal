import Foundation
import ReaderBackup
import ReaderCore

/// A book's records and files at one moment, as the intent record keeps them.
struct SyncContent: Codable, Hashable, Sendable {
    var archive: BookArchive
    var files: SyncBaseFiles

    init(archive: BookArchive, files: SyncFileDigests) {
        self.archive = archive
        self.files = SyncBaseFiles(digests: files)
    }

    var digests: SyncFileDigests { files.digests }
}

/// The durable record of a round that has started to change a book, kept from before its head
/// write until its base has moved. With it, a round interrupted anywhere in between (a crash, a
/// refused or partial apply) is finished correctly by the next one:
///
/// - Before the head write is known to have won (`committedETag == nil`), the next round
///   reconciles `writeID`: if the head is not ours, nothing here changed and the record is
///   dropped; if it is, it carries on below.
/// - Once the head is ours, the history write is repeated (it is idempotent) and the base is set
///   record by record and file by file: where this device's copy is now as the round meant to
///   leave it, the new base (`newBase`); anywhere else (not applied, or edited since), the old
///   one (`oldBase`). So a change that was applied is never merged against the base it was
///   merged from (which would repeat paragraphs both sides added), and one that was not applied
///   is merged again from scratch, as after a lost race. Where the two cannot be told apart, the
///   old base keeps the reader's work.
struct SyncApplyIntent: Codable, Hashable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion = Self.currentFormatVersion
    var bookKey: String
    var bookID: UUID
    /// The head written, until the write is known to have won.
    var writeID: String?
    /// The ETag of the head the new base corresponds to, once known.
    var committedETag: String?
    var headVersion: Int
    /// The head ours replaced, still to go into history.
    var supersededHead: SyncHead?
    var oldBase: SyncBase?
    var newBase: SyncContent
    /// The book as the round read it here.
    var oldLocal: SyncContent
    /// The book as the round means to leave it here.
    var target: SyncContent
    /// `true` when `newBase` keeps a busy surface as the old base had it, so it is not the
    /// head's as a whole (absent, in records written before it existed: whole).
    var newBaseIsPartial: Bool? = nil
}

/// The engine's own small files in its directory, beside the bases and version records:
///
///     <directory>/intents/<book key>.json   a `SyncApplyIntent` per book mid-round
///     <directory>/seen.json                  heads that need nothing here (deleted books never
///                                            on this device), by ETag
///     <directory>/joined                     present once the reader confirmed the join
struct SyncEngineState: Sendable {
    let directory: URL

    var intentsDirectory: URL { directory.appendingPathComponent("intents", isDirectory: true) }
    var seenFile: URL { directory.appendingPathComponent("seen.json", isDirectory: false) }
    var joinedFile: URL { directory.appendingPathComponent("joined", isDirectory: false) }

    // MARK: Intents

    /// The book keys that have an intent record.
    func intentKeys() throws -> Set<String> {
        let dir = intentsDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let names = try mappingFileErrors(dir) { try FileManager.default.contentsOfDirectory(atPath: dir.path) }
        return Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.filter(SyncLayout.isValidName))
    }

    /// The book's intent record, if it has one.
    func intent(bookKey: String) throws -> SyncApplyIntent? {
        let url = intentsDirectory.appendingPathComponent(try SyncLayout.validName(bookKey) + ".json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try mappingFileErrors(url) { try Data(contentsOf: url) }
        // A record that cannot be read is dropped: the base it guards is then the old one, which
        // never loses the reader's work (at worst paragraphs both sides added repeat).
        guard let intent = try? BackupCoding.makeDecoder().decode(SyncApplyIntent.self, from: data),
              intent.formatVersion == SyncApplyIntent.currentFormatVersion, intent.bookKey == bookKey else {
            try removeIntent(bookKey: bookKey)
            return nil
        }
        return intent
    }

    func save(_ intent: SyncApplyIntent) throws {
        let url = intentsDirectory.appendingPathComponent(try SyncLayout.validName(intent.bookKey) + ".json", isDirectory: false)
        let data = try BackupCoding.makeEncoder().encode(intent)
        try mappingFileErrors(url) {
            try FileManager.default.createDirectory(at: intentsDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    func removeIntent(bookKey: String) throws {
        let url = intentsDirectory.appendingPathComponent(try SyncLayout.validName(bookKey) + ".json", isDirectory: false)
        try mappingFileErrors(url) {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Seen heads

    func seen() -> [String: String] {
        guard let data = try? Data(contentsOf: seenFile),
              let seen = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return seen
    }

    func saveSeen(_ seen: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(seen)
        try mappingFileErrors(seenFile) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: seenFile, options: .atomic)
        }
    }

    // MARK: Join

    var hasJoined: Bool { FileManager.default.fileExists(atPath: joinedFile.path) }

    func markJoined() throws {
        try mappingFileErrors(joinedFile) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("1\n".utf8).write(to: joinedFile, options: .atomic)
        }
    }
}
