import Foundation
import Testing
import ReaderCore
@testable import ReaderBackup

/// A scanned book's recognised text (`text/`) and recognition state (`recognition.json`) are
/// derived from its PDF and never written to a backup (S4); everything else in the book's
/// directory is, including files that merely share those names deeper down.
struct RecognisedTextBackupTests {
    static let bookID = UUID(uuidString: "5C000000-0000-4000-8000-000000000042")!

    @Test func theWriterLeavesOutRecognisedTextAndState() throws {
        let dir = try TemporaryDirectory()
        let root = BookStorageLayout.bookDirectory(bookID: Self.bookID)
        try dir.file("\(root)/cover.jpg", Data("cover".utf8))
        try dir.file("\(root)/ink/16.drawing", Data("ink".utf8))
        try dir.file("\(root)/notes/text", Data("not recognised text: a deeper file of that name".utf8))
        try dir.file(BookStorageLayout.recognisedPagePath(bookID: Self.bookID, pageIndex: 16), Data("{}".utf8))
        try dir.file(BookStorageLayout.recognisedPagePath(bookID: Self.bookID, pageIndex: 17), Data("{}".utf8))
        try dir.file(BookStorageLayout.recognitionStatePath(bookID: Self.bookID), Data("{\"state\":\"complete\"}".utf8))
        let book = Book(id: Self.bookID, title: "Scanned", fingerprint: "fp", fileName: "scanned.pdf", pageCount: 30,
                        fileSize: 10, addedAt: Date(timeIntervalSinceReferenceDate: 785_000_000))
        let url = dir.url.appendingPathComponent("scanned.ttbackup")
        let manifest = try BackupArchiveWriter.write(
            books: [BackupBookSource(archive: BookArchive(book: book), directory: dir.url.appendingPathComponent(root),
                                     pdfDigest: .known(ContentDigest(sha256: String(repeating: "cd", count: 32), size: 10)))],
            metadata: BackupMetadata(createdAt: book.addedAt, appVersion: "1.0", appBuild: "1", deviceName: "Test iPad"),
            includePDFs: false, to: url)
        #expect(manifest.books.first?.files.map(\.path) == ["cover.jpg", "ink/16.drawing", "notes/text"])
        let names = try ZipArchiveReader(url: url).entries.map(\.name)
        #expect(!names.contains { $0.contains("/text/") || $0.hasSuffix("recognition.json") })

        #expect(BackupDerivedFiles.topLevelNames == ["text", "recognition.json"])
        #expect(BackupDerivedFiles.isDerived(relativePath: "text/16.json"))
        #expect(BackupDerivedFiles.isDerived(relativePath: "recognition.json"))
        #expect(!BackupDerivedFiles.isDerived(relativePath: "notes/text"))
        #expect(!BackupDerivedFiles.isDerived(relativePath: "textual.json"))
    }
}
