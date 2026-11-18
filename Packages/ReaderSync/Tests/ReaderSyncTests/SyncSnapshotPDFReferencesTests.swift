import Foundation
import ReaderBackup
import ReaderCore
import Testing
@testable import ReaderSync

@Suite("Sync: the PDFs snapshot backups refer to")
struct SyncSnapshotPDFReferencesTests {
    /// Writes a snapshot of one empty book whose PDF has `pdf`'s digest, and uploads it.
    private func backUp(_ destination: EncryptedBackupDestination, pdf: Data, at date: Date, scratch: TemporaryDirectory) async throws {
        let id = UUID()
        let directory = scratch.url.appendingPathComponent("book-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = BookArchive(book: Book(id: id, title: "B", fingerprint: "f", fileName: "b.pdf", pageCount: 1, fileSize: 1,
                                             addedAt: date))
        let metadata = BackupMetadata(createdAt: date, appVersion: "1", appBuild: "1", deviceName: "Test iPad")
        let name = SnapshotName.make(createdAt: date, deviceName: "Test iPad")
        let file = scratch.url.appendingPathComponent(name)
        try BackupArchiveWriter.write(books: [BackupBookSource(archive: archive, directory: directory,
                                                               pdfDigest: .known(ContentDigest(of: pdf)))],
                                      metadata: metadata, includePDFs: false, to: file, progress: nil)
        try await destination.uploadSnapshot(from: file, name: name, progress: nil)
    }

    @Test func everySnapshotsPDFsAreReadOnceAndAnUnreadableSnapshotRefusesAll() async throws {
        let scratch = try TemporaryDirectory()
        let store = FolderBackupBlobStore(root: scratch.url.appendingPathComponent("account", isDirectory: true))
        let destination = EncryptedBackupDestination(id: "test", displayName: "Test", store: store, key: simulationKey,
                                                     temporaryDirectory: scratch.url.appendingPathComponent("tmp"))
        let references = SyncSnapshotPDFReferences(destination: destination,
                                                   cacheDirectory: scratch.url.appendingPathComponent("cache", isDirectory: true))
        #expect(try await references.referencedPDFs().isEmpty)
        let one = Data("%PDF one".utf8), two = Data("%PDF two".utf8)
        try await backUp(destination, pdf: one, at: Date(timeIntervalSince1970: 1_790_000_000), scratch: scratch)
        try await backUp(destination, pdf: two, at: Date(timeIntervalSince1970: 1_790_000_100), scratch: scratch)
        #expect(try await references.referencedPDFs() == [ContentDigest(of: one).sha256, ContentDigest(of: two).sha256])
        // Read again from the cache, even with the snapshots' bytes made unreadable meanwhile.
        let backups = scratch.url.appendingPathComponent("account/Backups", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path).filter { !$0.hasPrefix(".") }
        #expect(names.count == 2)
        #expect(try await references.referencedPDFs().count == 2)
        // An object under Backups/ that is not a snapshot of this key: refuse.
        try Data("stranger".utf8).write(to: backups.appendingPathComponent("2026-11-01T00-00-00Z.stranger.ttenc"))
        await #expect(throws: SyncSnapshotReferenceError.self) { try await references.referencedPDFs() }
        try FileManager.default.removeItem(at: backups.appendingPathComponent("2026-11-01T00-00-00Z.stranger.ttenc"))
        // A snapshot that does not open (not cached): refuse.
        let fresh = SyncSnapshotPDFReferences(destination: destination,
                                              cacheDirectory: scratch.url.appendingPathComponent("cache2", isDirectory: true))
        let victim = backups.appendingPathComponent(names[0])
        var bytes = try Data(contentsOf: victim)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: victim)
        await #expect(throws: (any Error).self) { try await fresh.referencedPDFs() }
    }
}
