import Foundation
import CoreGraphics
import Testing
import ReaderCore
@testable import ReaderBackup

/// Pins backup format v1: `Fixtures/v1-sample.ttbackup` was written once by
/// `GoldenFixtureGenerator` and is checked in. `readsTheV1Fixture` reads it with the current
/// code and compares against values written out here, so a model or format change that would
/// stop old backups restoring fails this test. Never regenerate the fixture; when the format
/// version rises, add a new fixture and a new test beside this one.
struct GoldenFixtureTests {
    static func id(_ suffix: String) -> UUID { UUID(uuidString: "6A1C0000-0000-4000-8000-\(suffix)")! }
    static func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    @Test func readsTheV1Fixture() throws {
        let url = try #require(Bundle.module.url(forResource: "v1-sample", withExtension: "ttbackup", subdirectory: "Fixtures"))
        let reader = try BackupArchiveReader(url: url)
        let manifest = reader.manifest

        #expect(manifest.format == "tactile-texts-backup")
        #expect(manifest.formatVersion == 1)
        #expect(manifest.createdAt == Self.date(784_200_000.5))
        #expect(manifest.appVersion == "1.0")
        #expect(manifest.appBuild == "1")
        #expect(manifest.deviceName == "Fixture iPad")
        #expect(manifest.includesPDFs)
        #expect(manifest.books.count == 2)

        // Book 1: embedded PDF, every kind of record, page and note ink.
        let first = manifest.books[0]
        let pdfBytes = Data("%PDF-1.4\n%Tactile Texts fixture\n1 0 obj << >> endobj\n%%EOF\n".utf8)
        #expect(first.book == Book(id: Self.id("000000000001"), title: "Linear Algebra Done Right", fingerprint: "fixture-fingerprint-1",
                                   fileName: "Linear Algebra Done Right.pdf", pageCount: 12, fileSize: 59,
                                   addedAt: Self.date(784_000_000.25), lastOpenedAt: Self.date(784_086_400.123_456),
                                   lastReadPageIndex: 3))
        #expect(first.pdf == .init(sha256: "c429926878becee779fcc3cb897277eea8356b0c2d9f37bc491e8f11450e2557", size: 59, embedded: true))
        #expect(first.counts == .init(notes: 3, highlights: 1, bookmarks: 1, userHeadings: 2, inkedPages: 2))
        #expect(first.lastModifiedAt == Self.date(784_000_800))
        let noteInkName = "notes/6A1C0000-0000-4000-8000-000000000101.drawing"
        let files: [(String, Data)] = [
            ("cover.jpg", Data("cover-jpeg-bytes".utf8)),
            ("ink/10.drawing", Data("page-10-ink".utf8)),
            ("ink/2.drawing", Data("page-2-ink".utf8)),
            (noteInkName, Data("note-1-ink".utf8)),
        ]
        #expect(first.files == files.map { .init(path: $0.0, size: Int64($0.1.count), sha256: ContentHash.sha256(of: $0.1)) })

        let h1 = Self.id("000000000401"), h2 = Self.id("000000000402")
        let bookID = first.book.id
        let expectedRecords = BookArchive(
            book: first.book,
            notes: [
                Note(id: Self.id("000000000101"), bookID: bookID, target: .page(2), text: "Eigenvalues first.\nThen eigenvectors.",
                     hasInk: true,
                     bandLayout: NoteBandLayout(pageWidth: 612, paragraphs: [NoteParagraphBand(text: "Eigenvalues first.", top: 0, height: 22.5),
                                                                             NoteParagraphBand(text: "Then eigenvectors.", top: 22.5, height: 22.5)],
                                                trailingTop: 45),
                     createdAt: Self.date(784_000_100.000_000_5), modifiedAt: Self.date(784_000_200.987_654_3)),
                Note(id: Self.id("000000000102"), bookID: bookID,
                     target: .heading(HeadingAnchor(rawValue: "pdf1/4.1/7/5.2 The Characteristic Equation")!),
                     text: "Check the proof of 5.6.", createdAt: Self.date(784_000_300.5)),
                Note(id: Self.id("000000000103"), bookID: bookID,
                     target: .heading(HeadingAnchor(rawValue: "user1/6A1C0000-0000-4000-8000-000000000402")!),
                     text: "My own section note.", createdAt: Self.date(784_000_400)),
            ],
            highlights: [Highlight(id: Self.id("000000000201"), bookID: bookID, pageIndex: 2,
                                   rects: [CGRect(x: 72, y: 600.5, width: 300, height: 14), CGRect(x: 72, y: 585.25, width: 120.125, height: 14)],
                                   color: .green, text: "an eigenvalue of T", createdAt: Self.date(784_000_500))],
            bookmarks: [Bookmark(id: Self.id("000000000301"), bookID: bookID, pageIndex: 5, createdAt: Self.date(784_000_600))],
            userHeadings: [
                UserHeading(id: h1, bookID: bookID, title: "Part One (mine)", pageIndex: 1, parent: nil, createdAt: Self.date(784_000_700)),
                UserHeading(id: h2, bookID: bookID, title: "Section 1.1 (mine)", pageIndex: 2,
                            parent: HeadingAnchor(rawValue: "user1/6A1C0000-0000-4000-8000-000000000401")!, createdAt: Self.date(784_000_800)),
            ])
        let records = try reader.bookArchive(for: bookID)
        #expect(records == expectedRecords)
        #expect(records.notes[1].target.headingAnchor?.kind == .pdf(path: [4, 1], pageIndex: 7, title: "5.2 The Characteristic Equation"))
        #expect(records.userHeadings[1].parent == HeadingAnchor(userHeadingID: h1))

        let dir = try TemporaryDirectory()
        let out = dir.url.appendingPathComponent("book1", isDirectory: true)
        try reader.extractFiles(ofBook: bookID, into: out)
        for (path, data) in files { #expect(try Data(contentsOf: out.appendingPathComponent(path)) == data, "\(path)") }
        let pdf = dir.url.appendingPathComponent("restored.pdf")
        try reader.extractPDF(sha256: first.pdf.sha256, to: pdf)
        #expect(try Data(contentsOf: pdf) == pdfBytes)

        // Book 2: PDF absent when backed up, so not embedded; no files.
        let second = manifest.books[1]
        #expect(second.book == Book(id: Self.id("000000000002"), title: "Notes Without A PDF", fingerprint: "fixture-fingerprint-2",
                                    fileName: "absent.pdf", pageCount: 40, fileSize: 2048, addedAt: Self.date(784_100_000),
                                    lastOpenedAt: nil, lastReadPageIndex: 0))
        #expect(second.pdf == .init(sha256: ContentHash.sha256(of: Data("absent pdf".utf8)), size: 2048, embedded: false))
        #expect(second.counts == .init(notes: 1, bookmarks: 1))
        #expect(second.files.isEmpty)
        #expect(try reader.bookArchive(for: second.book.id) == BookArchive(
            book: second.book,
            notes: [Note(id: Self.id("000000000104"), bookID: second.book.id, target: .page(0), text: "Only text.",
                         createdAt: Self.date(784_100_050))],
            bookmarks: [Bookmark(id: Self.id("000000000302"), bookID: second.book.id, pageIndex: 10, createdAt: Self.date(784_100_100))]))
        #expect(reader.embeddedPDFHashes == [first.pdf.sha256])
    }

    /// Writes the fixture once, when `READERBACKUP_FIXTURE_OUTPUT` names a path that does not
    /// exist yet. Not part of normal runs.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["READERBACKUP_FIXTURE_OUTPUT"] != nil))
    func generateFixture() throws {
        let path = try #require(ProcessInfo.processInfo.environment["READERBACKUP_FIXTURE_OUTPUT"])
        let url = URL(fileURLWithPath: path)
        try #require(!FileManager.default.fileExists(atPath: url.path), "never overwrite a fixture")
        try GoldenFixtureGenerator.write(to: url)
    }
}

/// How `v1-sample.ttbackup` was made (kept for reference; the fixture is never regenerated).
enum GoldenFixtureGenerator {
    static func write(to url: URL) throws {
        let id = GoldenFixtureTests.id, date = GoldenFixtureTests.date
        let dir = try TemporaryDirectory()

        let pdfBytes = Data("%PDF-1.4\n%Tactile Texts fixture\n1 0 obj << >> endobj\n%%EOF\n".utf8)
        let book1 = Book(id: id("000000000001"), title: "Linear Algebra Done Right", fingerprint: "fixture-fingerprint-1",
                         fileName: "Linear Algebra Done Right.pdf", pageCount: 12, fileSize: Int64(pdfBytes.count),
                         addedAt: date(784_000_000.25), lastOpenedAt: date(784_086_400.123_456), lastReadPageIndex: 3)
        let h1 = UserHeading(id: id("000000000401"), bookID: book1.id, title: "Part One (mine)", pageIndex: 1, parent: nil,
                             createdAt: date(784_000_700))
        let h2 = UserHeading(id: id("000000000402"), bookID: book1.id, title: "Section 1.1 (mine)", pageIndex: 2, parent: h1.anchor,
                             createdAt: date(784_000_800))
        let note1 = Note(id: id("000000000101"), bookID: book1.id, target: .page(2), text: "Eigenvalues first.\nThen eigenvectors.",
                         hasInk: true,
                         bandLayout: NoteBandLayout(pageWidth: 612, paragraphs: [NoteParagraphBand(text: "Eigenvalues first.", top: 0, height: 22.5),
                                                                                 NoteParagraphBand(text: "Then eigenvectors.", top: 22.5, height: 22.5)],
                                                    trailingTop: 45),
                         createdAt: date(784_000_100.000_000_5), modifiedAt: date(784_000_200.987_654_3))
        let archive1 = BookArchive(
            book: book1,
            notes: [note1,
                    Note(id: id("000000000102"), bookID: book1.id,
                         target: .heading(HeadingAnchor(pdfPath: [4, 1], pageIndex: 7, title: "5.2 The Characteristic Equation")),
                         text: "Check the proof of 5.6.", createdAt: date(784_000_300.5)),
                    Note(id: id("000000000103"), bookID: book1.id, target: .heading(h2.anchor), text: "My own section note.",
                         createdAt: date(784_000_400))],
            highlights: [Highlight(id: id("000000000201"), bookID: book1.id, pageIndex: 2,
                                   rects: [CGRect(x: 72, y: 600.5, width: 300, height: 14), CGRect(x: 72, y: 585.25, width: 120.125, height: 14)],
                                   color: .green, text: "an eigenvalue of T", createdAt: date(784_000_500))],
            bookmarks: [Bookmark(id: id("000000000301"), bookID: book1.id, pageIndex: 5, createdAt: date(784_000_600))],
            userHeadings: [h1, h2])
        let root1 = BookStorageLayout.bookDirectory(bookID: book1.id)
        try dir.file(BookStorageLayout.documentPath(bookID: book1.id, fileName: book1.fileName), pdfBytes)
        try dir.file("\(root1)/cover.jpg", Data("cover-jpeg-bytes".utf8))
        try dir.file(BookStorageLayout.pageInkPath(bookID: book1.id, pageIndex: 2), Data("page-2-ink".utf8))
        try dir.file(BookStorageLayout.pageInkPath(bookID: book1.id, pageIndex: 10), Data("page-10-ink".utf8))
        try dir.file(BookStorageLayout.noteInkPath(bookID: book1.id, noteID: note1.id), Data("note-1-ink".utf8))
        try dir.file(BookStorageLayout.contentHashPath(bookID: book1.id),
                     Data(#"{"sha256":"\#(ContentHash.sha256(of: pdfBytes))","size":\#(pdfBytes.count)}"#.utf8))

        let book2 = Book(id: id("000000000002"), title: "Notes Without A PDF", fingerprint: "fixture-fingerprint-2", fileName: "absent.pdf",
                         pageCount: 40, fileSize: 2048, addedAt: date(784_100_000))
        let archive2 = BookArchive(
            book: book2,
            notes: [Note(id: id("000000000104"), bookID: book2.id, target: .page(0), text: "Only text.", createdAt: date(784_100_050))],
            bookmarks: [Bookmark(id: id("000000000302"), bookID: book2.id, pageIndex: 10, createdAt: date(784_100_100))])

        let sources = [
            BackupBookSource(archive: archive1, directory: dir.url.appendingPathComponent(root1), pdfDigest: .compute),
            BackupBookSource(archive: archive2, directory: dir.url.appendingPathComponent(BookStorageLayout.bookDirectory(bookID: book2.id)),
                             pdfDigest: .known(ContentDigest(sha256: ContentHash.sha256(of: Data("absent pdf".utf8)), size: 2048))),
        ]
        try BackupArchiveWriter.write(books: sources,
                                      metadata: BackupMetadata(createdAt: date(784_200_000.5), appVersion: "1.0", appBuild: "1",
                                                               deviceName: "Fixture iPad"),
                                      includePDFs: true, to: url)
    }
}
