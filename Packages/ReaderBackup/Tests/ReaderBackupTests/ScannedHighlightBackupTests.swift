import Foundation
import CoreGraphics
import Testing
import ReaderCore
@testable import ReaderBackup

/// Scanned-page highlights (`Highlight.textSource == .liveText`) are backed up, merged and
/// restored like any other highlight, and keep their source all the way through.
struct ScannedHighlightBackupTests {
    static let date = Date(timeIntervalSinceReferenceDate: 785_000_000.25)
    static let bookID = UUID(uuidString: "5C000000-0000-4000-8000-000000000001")!

    static func book(_ id: UUID = bookID) -> Book {
        Book(id: id, title: "The Scanned Fixture Book", fingerprint: "fp-scanned", fileName: "scanned.pdf", pageCount: 30,
             fileSize: 7_600_000, addedAt: date)
    }

    static func highlight(_ n: Int, page: Int, text: String, source: HighlightTextSource?, color: HighlightColor = .green,
                          book: UUID = bookID) -> Highlight {
        Highlight(id: UUID(uuidString: String(format: "5C000000-0000-4000-8000-%012d", n))!, bookID: book, pageIndex: page,
                  rects: [CGRect(x: 72, y: 693, width: 159, height: 12)], color: color, text: text,
                  createdAt: date.addingTimeInterval(Double(n)), textSource: source)
    }

    @MainActor
    @Test func backupMergeAndRestoreKeepTheTextSource() throws {
        let dir = try TemporaryDirectory()
        let backedUp = BookArchive(book: Self.book(), highlights: [
            Self.highlight(1, page: 16, text: "The quiet heron measures tidewater.", source: .liveText),
            Self.highlight(2, page: 17, text: "", source: .liveText),
            Self.highlight(3, page: 0, text: "The Scanned Fixture Book", source: nil),
            Self.highlight(4, page: 0, text: "A typed cover", source: .textLayer),
        ])
        // The backup is made from the book's directory, as the app makes it.
        let root = BookStorageLayout.bookDirectory(bookID: Self.bookID)
        try dir.file("\(root)/cover.jpg", Data("cover".utf8))
        let url = dir.url.appendingPathComponent("scanned.ttbackup")
        try BackupArchiveWriter.write(
            books: [BackupBookSource(archive: backedUp, directory: dir.url.appendingPathComponent(root),
                                     pdfDigest: .known(ContentDigest(sha256: String(repeating: "ab", count: 32), size: 7_600_000)))],
            metadata: BackupMetadata(createdAt: Self.date, appVersion: "1.0", appBuild: "1", deviceName: "Test iPad"),
            includePDFs: false, to: url)

        // Backup: read back exactly, source and all.
        let reader = try BackupArchiveReader(url: url)
        let restored = try reader.bookArchive(for: Self.bookID)
        #expect(restored == backedUp)
        #expect(restored.highlights.map(\.textSource) == [.liveText, .liveText, nil, .textLayer])

        // Merge into this iPad's copy of the book (another ID): the same highlight on both sides
        // keeps this iPad's version (here recoloured, with no source), the rest is added as it is.
        let localID = UUID(uuidString: "5C000000-0000-4000-8000-0000000000AA")!
        let mine = Self.highlight(1, page: 16, text: "The quiet heron measures tidewater.", source: nil, color: .pink, book: localID)
        let local = BookArchive(book: Self.book(localID), highlights: [mine])
        let merged = BookMerge.merge(local: local, incoming: restored)
        #expect(merged.report.highlightsAdded == 3)
        let byID = Dictionary(uniqueKeysWithValues: merged.archive.highlights.map { ($0.id, $0) })
        #expect(byID[mine.id] == mine)
        for original in restored.highlights.dropFirst() {
            var expected = original
            expected.bookID = localID
            #expect(byID[original.id] == expected)
        }

        // Restore: the merged archive goes into the store whole, and reads back unchanged.
        let store = InMemoryRecordStore()
        try store.save(local.book)
        try store.save(mine)
        try store.replaceBook(merged.archive, removing: [])
        #expect(try store.highlights(bookID: localID) == merged.archive.highlights)
        #expect(try store.highlight(id: restored.highlights[1].id)?.textSource == .liveText)

        // A second backup of the merged book carries the same values again.
        let second = dir.url.appendingPathComponent("merged.ttbackup")
        try BackupArchiveWriter.write(
            books: [BackupBookSource(archive: merged.archive, directory: dir.url.appendingPathComponent(root),
                                     pdfDigest: .known(ContentDigest(sha256: String(repeating: "ab", count: 32), size: 7_600_000)))],
            metadata: BackupMetadata(createdAt: Self.date, appVersion: "1.0", appBuild: "1", deviceName: "Test iPad"),
            includePDFs: false, to: second)
        #expect(try BackupArchiveReader(url: second).bookArchive(for: localID) == merged.archive)
    }
}
