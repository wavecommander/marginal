import Foundation
import Testing
import ReaderCore
@testable import ReaderBackup

/// A backup from a newer version of the app at the same format version restores here (docs/DESIGN.md
/// "Keeping data openable across versions"). A newer app adds a field to a record as an optional
/// key without raising the format version; this version must ignore the key and restore
/// everything else. If a change cannot be read that way, the format version rises instead, and
/// this version says the backup is from a newer version (`newerFormatVersion`).
///
/// The test takes the checked-in v1 fixture's manifest and records, adds keys this version has
/// never seen to every manifest entry, book and record, and checks they decode to the same values.
struct NewerAppBackupTests {
    @Test func unknownFieldsFromANewerAppAreIgnored() throws {
        let url = try #require(Bundle.module.url(forResource: "v1-sample", withExtension: "ttbackup", subdirectory: "Fixtures"))
        let reader = try BackupArchiveReader(url: url)
        let encoder = BackupCoding.makeEncoder()
        let decoder = BackupCoding.makeDecoder()

        // The manifest: its top level, each book entry, and each entry's book.
        var manifest = try jsonObject(encoder.encode(reader.manifest))
        addFutureKeys(&manifest)
        manifest["books"] = try #require(manifest["books"] as? [[String: Any]]).map { entry in
            var entry = entry
            addFutureKeys(&entry)
            if var book = entry["book"] as? [String: Any] { addFutureKeys(&book); entry["book"] = book }
            return entry
        }
        let decodedManifest = try BackupManifest.decode(JSONSerialization.data(withJSONObject: manifest))
        #expect(decodedManifest == reader.manifest)

        // Each book's records: the archive, its book, and every record.
        for entry in reader.manifest.books {
            let original = try reader.bookArchive(for: entry.book.id)
            var archive = try jsonObject(encoder.encode(original))
            addFutureKeys(&archive)
            if var book = archive["book"] as? [String: Any] { addFutureKeys(&book); archive["book"] = book }
            for (key, value) in archive {
                guard let records = value as? [[String: Any]] else { continue }
                archive[key] = records.map { record in
                    var record = record
                    addFutureKeys(&record)
                    return record
                }
            }
            let decoded = try decoder.decode(BookArchive.self, from: JSONSerialization.data(withJSONObject: archive))
            #expect(decoded == original, "\(entry.book.title)")
        }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Keys of every JSON kind a newer app might add.
    private func addFutureKeys(_ object: inout [String: Any]) {
        object["futureString"] = "added by a newer version"
        object["futureNumber"] = 42
        object["futureFlag"] = true
        object["futureList"] = [1, 2, 3]
        object["futureObject"] = ["nested": "value"]
    }
}
