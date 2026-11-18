import Foundation
import Testing
import ReaderCore
@testable import ReaderBackup

/// Rich-text notes (`Note.richTextData`) round-trip through backup archives, merges and restores.
struct RichTextNoteBackupTests {
    static let date = Date(timeIntervalSinceReferenceDate: 786_000_000.5)
    static let bookID = UUID(uuidString: "6D000000-0000-4000-8000-000000000001")!

    @MainActor
    @Test func backupMergeAndRestoreKeepRichTextData() throws {
        let dir = try TemporaryDirectory()
        let book = Book(id: Self.bookID, title: "Rich Notes Book", fingerprint: "fp-rich",
                        fileName: "rich.pdf", pageCount: 20, fileSize: 1024, addedAt: Self.date)
        let richData = NoteRichText(spans: [
            NoteTextSpan(location: 0, length: 4, attributes: NoteTextAttributes(isBold: true, isUnderline: true)),
            NoteTextSpan(location: 5, length: 4, attributes: NoteTextAttributes(isItalic: true, isStrikethrough: true))
        ]).encoded()
        let richNote = Note(id: UUID(uuidString: "6D000000-0000-4000-8000-000000000010")!,
                            bookID: Self.bookID, target: .page(1), text: "bold text",
                            richTextData: richData, createdAt: Self.date, modifiedAt: Self.date)
        let plainNote = Note(id: UUID(uuidString: "6D000000-0000-4000-8000-000000000011")!,
                             bookID: Self.bookID, target: .page(2), text: "plain note",
                             richTextData: nil, createdAt: Self.date, modifiedAt: Self.date)

        let backedUp = BookArchive(book: book, notes: [richNote, plainNote])
        let root = BookStorageLayout.bookDirectory(bookID: Self.bookID)
        try dir.file("\(root)/cover.jpg", Data("cover".utf8))
        let url = dir.url.appendingPathComponent("rich-notes.ttbackup")
        try BackupArchiveWriter.write(
            books: [BackupBookSource(archive: backedUp, directory: dir.url.appendingPathComponent(root),
                                     pdfDigest: .known(ContentDigest(sha256: String(repeating: "cd", count: 32), size: 1024)))],
            metadata: BackupMetadata(createdAt: Self.date, appVersion: "1.0", appBuild: "1", deviceName: "Test iPad"),
            includePDFs: false, to: url)

        let reader = try BackupArchiveReader(url: url)
        let restored = try reader.bookArchive(for: Self.bookID)
        #expect(restored == backedUp)
        #expect(restored.notes.map(\.richTextData) == [richData, nil])

        // Merge into another iPad's copy of the book and store it.
        let localID = UUID(uuidString: "6D000000-0000-4000-8000-0000000000AA")!
        let localBook = Book(id: localID, title: book.title, fingerprint: book.fingerprint,
                             fileName: book.fileName, pageCount: book.pageCount, fileSize: book.fileSize,
                             addedAt: Self.date)
        let merged = BookMerge.merge(local: BookArchive(book: localBook), incoming: restored)
        #expect(merged.report.notesAdded == 2)
        let store = InMemoryRecordStore()
        try store.save(localBook)
        try store.replaceBook(merged.archive, removing: [])
        #expect(try store.note(bookID: localID, target: .page(1))?.richTextData == richData)
        #expect(try store.note(bookID: localID, target: .page(2))?.richTextData == nil)
    }
}
