import Foundation
import CoreGraphics
import Testing
import ReaderCore
@testable import ReaderBackup

/// A store root laid out by `BookStorageLayout` with two books: one with a PDF, cover, page
/// ink, note ink, a sidecar and junk files; one whose PDF is absent.
struct SampleLibrary {
    let dir: TemporaryDirectory
    let withPDF: BookArchive
    let withoutPDF: BookArchive
    let pdfBytes: Data
    let missingPDFDigest: ContentDigest
    /// Files that must be backed up for `withPDF`, by relative path.
    let expectedFiles: [String: Data]
    let noteID: UUID

    init() throws {
        dir = try TemporaryDirectory()
        let date = Date(timeIntervalSinceReferenceDate: 780_000_000.123_456)
        let bookID = UUID(uuidString: "0A000000-0000-0000-0000-000000000001")!
        noteID = UUID(uuidString: "0B000000-0000-0000-0000-000000000001")!
        pdfBytes = pseudoRandomData(count: multiChunkSize, seed: 99)
        let book = Book(id: bookID, title: "Linear Algebra", fingerprint: "fp-linear", fileName: "Linear Algebra.pdf",
                        pageCount: 300, fileSize: Int64(pdfBytes.count), addedAt: date, lastOpenedAt: date.addingTimeInterval(5),
                        lastReadPageIndex: 41)
        let heading = UserHeading(bookID: bookID, title: "Mine", pageIndex: 3, parent: nil, createdAt: date.addingTimeInterval(1))
        withPDF = BookArchive(
            book: book,
            notes: [Note(id: noteID, bookID: bookID, target: .page(12), text: "ink here", hasInk: true, createdAt: date,
                         modifiedAt: date.addingTimeInterval(9.000_000_5)),
                    Note(bookID: bookID, target: .heading(heading.anchor), text: "on my heading", createdAt: date)],
            highlights: [Highlight(bookID: bookID, pageIndex: 12, rects: [CGRect(x: 10, y: 700.5, width: 200, height: 12)],
                                   color: .yellow, text: "eigen", createdAt: date)],
            bookmarks: [Bookmark(bookID: bookID, pageIndex: 12, createdAt: date)],
            userHeadings: [heading])
        let other = Book(id: UUID(uuidString: "0A000000-0000-0000-0000-000000000002")!, title: "Lost PDF", fingerprint: "fp-lost",
                         fileName: "lost.pdf", pageCount: 5, fileSize: 1234, addedAt: date)
        withoutPDF = BookArchive(book: other, bookmarks: [Bookmark(bookID: other.id, pageIndex: 1, createdAt: date)])
        missingPDFDigest = ContentDigest(sha256: String(repeating: "5e", count: 32), size: 1234)

        let root = BookStorageLayout.bookDirectory(bookID: bookID)
        try dir.file(BookStorageLayout.documentPath(bookID: bookID, fileName: book.fileName), pdfBytes)
        var files: [String: Data] = [
            "cover.jpg": Data("JPEG".utf8),
            "ink/0.drawing": pseudoRandomData(count: 5000, seed: 1),
            "ink/12.drawing": pseudoRandomData(count: multiChunkSize, seed: 2),
            "notes/\(noteID.uuidString).drawing": Data("note ink".utf8),
            "ink/empty.drawing": Data(),
            "extra/deeper/notes.txt": Data("kept".utf8),
        ]
        for (path, data) in files { try dir.file("\(root)/\(path)", data) }
        // Never backed up: the sidecar, hidden and temporary files.
        try dir.file(BookStorageLayout.contentHashPath(bookID: bookID), Data(#"{"sha256":"x","size":1}"#.utf8))
        try dir.file("\(root)/.DS_Store", Data("x".utf8))
        try dir.file("\(root)/ink/.12.drawing.sb-1234", Data("x".utf8))
        try dir.file("\(root)/ink/3.drawing.tmp", Data("x".utf8))
        try dir.file("\(root)/cover.jpg~", Data("x".utf8))
        try dir.file("\(root)/.hidden/inside.drawing", Data("x".utf8))
        // A symbolic link is not followed.
        try FileManager.default.createSymbolicLink(at: dir.file("\(root)/link.pdf"), withDestinationURL: dir.file("\(root)/cover.jpg"))
        files["ink/empty.drawing"] = Data()
        expectedFiles = files
        // The other book's directory has only a sidecar (no PDF).
        try dir.file(BookStorageLayout.contentHashPath(bookID: other.id), Data("{}".utf8))
    }

    func directory(_ archive: BookArchive) -> URL {
        dir.url.appendingPathComponent(BookStorageLayout.bookDirectory(bookID: archive.book.id), isDirectory: true)
    }

    func sources(computeHash: Bool = false) -> [BackupBookSource] {
        [BackupBookSource(archive: withPDF, directory: directory(withPDF),
                          pdfDigest: computeHash ? .compute
                              : .known(ContentDigest(sha256: ContentHash.sha256(of: pdfBytes), size: Int64(pdfBytes.count)))),
         BackupBookSource(archive: withoutPDF, directory: directory(withoutPDF), pdfDigest: .known(missingPDFDigest))]
    }

    static let metadata = BackupMetadata(createdAt: Date(timeIntervalSinceReferenceDate: 784_000_000.5), appVersion: "1.0",
                                         appBuild: "7", deviceName: "Test iPad")

    func write(includePDFs: Bool, computeHash: Bool = false, to name: String = "backup.ttbackup", progress: BackupProgress? = nil) throws -> URL {
        let url = dir.url.appendingPathComponent(name)
        try BackupArchiveWriter.write(books: sources(computeHash: computeHash), metadata: Self.metadata, includePDFs: includePDFs,
                                      to: url, progress: progress)
        return url
    }
}

/// Rewrites a (small or large) archive entry by entry through `transform`, which returns the
/// new data for an entry (`nil` drops it). Extra entries are appended.
func rewriteArchive(_ source: URL, to destination: URL, adding extra: [String: Data] = [:],
                    _ transform: (String, Data) throws -> Data?) throws {
    let reader = try ZipArchiveReader(url: source)
    let writer = try ZipArchiveWriter(url: destination)
    for entry in reader.entries {
        if let data = try transform(entry.name, reader.data(of: entry, maximumSize: .max)) {
            try writer.addEntry(named: entry.name, data: data)
        }
    }
    for (name, data) in extra.sorted(by: { $0.key < $1.key }) { try writer.addEntry(named: name, data: data) }
    try writer.finish()
}

/// Rewrites the manifest of an archive.
func rewriteManifest(_ source: URL, to destination: URL, _ change: (inout BackupManifest) -> Void) throws {
    try rewriteArchive(source, to: destination) { name, data in
        guard name == BackupArchiveLayout.manifestPath else { return data }
        var manifest = try BackupManifest.decode(data)
        change(&manifest)
        return try manifest.encoded()
    }
}

struct BackupArchiveTests {
    @Test func roundTripWithoutPDFs() throws {
        let library = try SampleLibrary()
        let log = ProgressLog()
        let url = try library.write(includePDFs: false, progress: log.callback)
        #expect(log.isWellFormed)

        let reader = try BackupArchiveReader(url: url)
        let manifest = reader.manifest
        #expect(manifest.format == BackupFormat.name)
        #expect(manifest.formatVersion == 1)
        #expect(manifest.createdAt == SampleLibrary.metadata.createdAt)
        #expect(manifest.deviceName == "Test iPad")
        #expect(manifest.appVersion == "1.0" && manifest.appBuild == "7")
        #expect(!manifest.includesPDFs)
        #expect(manifest.books.map(\.book) == [library.withPDF.book, library.withoutPDF.book])

        let first = manifest.books[0]
        #expect(first.pdf == .init(sha256: ContentHash.sha256(of: library.pdfBytes), size: Int64(library.pdfBytes.count), embedded: false))
        #expect(first.counts == .init(notes: 2, highlights: 1, bookmarks: 1, userHeadings: 1, inkedPages: 2))
        #expect(first.lastModifiedAt == library.withPDF.lastModifiedAt)
        #expect(first.files.map(\.path) == library.expectedFiles.keys.sorted())
        for file in first.files {
            let data = try #require(library.expectedFiles[file.path])
            #expect(file.size == Int64(data.count) && file.sha256 == ContentHash.sha256(of: data), "\(file.path)")
        }
        let second = manifest.books[1]
        #expect(second.pdf == .init(sha256: library.missingPDFDigest.sha256, size: 1234, embedded: false))
        #expect(second.files.isEmpty)
        #expect(second.counts == .init(bookmarks: 1))

        // No PDF and no sidecar anywhere in the archive.
        let names = try ZipArchiveReader(url: url).entries.map(\.name)
        #expect(!names.contains { $0.hasPrefix("pdfs/") || $0.hasSuffix(".pdf") || $0.hasSuffix(BookStorageLayout.contentHashFileName) })
        #expect(reader.embeddedPDFHashes.isEmpty)

        #expect(try reader.bookArchive(for: library.withPDF.book.id) == library.withPDF)
        #expect(try reader.bookArchive(for: library.withoutPDF.book.id) == library.withoutPDF)

        let out = library.dir.url.appendingPathComponent("restore/one", isDirectory: true)
        let extractLog = ProgressLog()
        try reader.extractFiles(ofBook: library.withPDF.book.id, into: out, progress: extractLog.callback)
        #expect(extractLog.isWellFormed)
        #expect(library.dir.allPaths(under: "restore/one").filter { !$0.hasSuffix("ink") && !$0.hasSuffix("notes") && $0 != "extra" && $0 != "extra/deeper" }
                == library.expectedFiles.keys.sorted())
        for (path, data) in library.expectedFiles {
            #expect(try Data(contentsOf: out.appendingPathComponent(path)) == data, "\(path)")
        }
        let empty = library.dir.url.appendingPathComponent("restore/two", isDirectory: true)
        try reader.extractFiles(ofBook: library.withoutPDF.book.id, into: empty)
        #expect(library.dir.allPaths(under: "restore/two").isEmpty)
        #expect(FileManager.default.fileExists(atPath: empty.path))

        #expect(throws: BackupError.pdfNotInBackup(sha256: first.pdf.sha256)) {
            try reader.extractPDF(sha256: first.pdf.sha256, to: library.dir.url.appendingPathComponent("p.pdf"))
        }
        #expect(throws: BackupError.bookNotInBackup(UUID(uuidString: "0A000000-0000-0000-0000-000000000009")!)) {
            try reader.bookArchive(for: UUID(uuidString: "0A000000-0000-0000-0000-000000000009")!)
        }
    }

    @Test func roundTripWithPDFs() throws {
        let library = try SampleLibrary()
        let url = try library.write(includePDFs: true, computeHash: true)
        let reader = try BackupArchiveReader(url: url)
        #expect(reader.manifest.includesPDFs)
        let first = reader.manifest.books[0], second = reader.manifest.books[1]
        #expect(first.pdf == .init(sha256: ContentHash.sha256(of: library.pdfBytes), size: Int64(library.pdfBytes.count), embedded: true))
        #expect(second.pdf.embedded == false, "absent PDF is not embedded")
        #expect(reader.embeddedPDFHashes == [first.pdf.sha256])
        let names = try ZipArchiveReader(url: url).entries.map(\.name)
        #expect(names.filter { $0.hasPrefix("pdfs/") } == ["pdfs/\(first.pdf.sha256).pdf"])
        #expect(!names.contains { $0.hasSuffix(BookStorageLayout.contentHashFileName) })

        let pdf = library.dir.url.appendingPathComponent("restored.pdf")
        let log = ProgressLog()
        try reader.extractPDF(sha256: first.pdf.sha256.uppercased(), to: pdf, progress: log.callback)
        #expect(try Data(contentsOf: pdf) == library.pdfBytes)
        #expect(log.isWellFormed)
        #expect(throws: BackupError.pdfNotInBackup(sha256: library.missingPDFDigest.sha256)) {
            try reader.extractPDF(sha256: library.missingPDFDigest.sha256, to: pdf)
        }
        #expect(try reader.bookArchive(for: library.withPDF.book.id) == library.withPDF)
    }

    @Test func aBookWithAnAbsentPDFNeedsItsHash() throws {
        let library = try SampleLibrary()
        let url = library.dir.url.appendingPathComponent("x.ttbackup")
        let source = BackupBookSource(archive: library.withoutPDF, directory: library.directory(library.withoutPDF), pdfDigest: .compute)
        #expect(throws: BackupError.pdfHashUnavailable(bookTitle: "Lost PDF")) {
            try BackupArchiveWriter.write(books: [source], metadata: SampleLibrary.metadata, includePDFs: true, to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aBookWithNoDirectoryIsBackedUp() throws {
        let library = try SampleLibrary()
        let url = library.dir.url.appendingPathComponent("x.ttbackup")
        let source = BackupBookSource(archive: library.withoutPDF, directory: library.dir.url.appendingPathComponent("nowhere"),
                                      pdfDigest: .known(library.missingPDFDigest))
        let manifest = try BackupArchiveWriter.write(books: [source], metadata: SampleLibrary.metadata, includePDFs: true, to: url)
        #expect(manifest.books[0].files.isEmpty && !manifest.books[0].pdf.embedded)
    }

    @Test func inconsistentAndDuplicateBooksAreRefused() throws {
        let library = try SampleLibrary()
        let url = library.dir.url.appendingPathComponent("x.ttbackup")
        var bad = library.withoutPDF
        bad.bookmarks.append(Bookmark(bookID: library.withPDF.book.id, pageIndex: 0))
        let source = BackupBookSource(archive: bad, directory: library.directory(bad), pdfDigest: .known(library.missingPDFDigest))
        #expect(throws: BackupError.inconsistentBook(bookTitle: "Lost PDF")) {
            try BackupArchiveWriter.write(books: [source], metadata: SampleLibrary.metadata, includePDFs: false, to: url)
        }
        let good = library.sources()[1]
        #expect(throws: BackupError.duplicateBook(bookTitle: "Lost PDF")) {
            try BackupArchiveWriter.write(books: [good, good], metadata: SampleLibrary.metadata, includePDFs: false, to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aWrongSuppliedHashIsCaughtWhenEmbedding() throws {
        let library = try SampleLibrary()
        let url = library.dir.url.appendingPathComponent("x.ttbackup")
        let source = BackupBookSource(archive: library.withPDF, directory: library.directory(library.withPDF),
                                      pdfDigest: .known(ContentDigest(sha256: String(repeating: "0", count: 64), size: Int64(library.pdfBytes.count))))
        #expect(throws: BackupError.contentMismatch(name: "Linear Algebra.pdf")) {
            try BackupArchiveWriter.write(books: [source], metadata: SampleLibrary.metadata, includePDFs: true, to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cancellationRemovesThePartialBackup() async throws {
        let library = try SampleLibrary()
        let url = library.dir.url.appendingPathComponent("cancelled.ttbackup")
        let sources = library.sources()
        let error = await runCancelling { cancel in
            try BackupArchiveWriter.write(books: sources, metadata: SampleLibrary.metadata, includePDFs: true, to: url,
                                          progress: { if $0 > 0.2 { cancel() } })
        }
        #expect(error is CancellationError)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func forcedZIP64BackupReadsBack() throws {
        let library = try SampleLibrary()
        let url = library.dir.url.appendingPathComponent("z64.ttbackup")
        try BackupArchiveWriter.write(books: library.sources(), metadata: SampleLibrary.metadata, includePDFs: true, to: url,
                                      forceZIP64: true, progress: nil)
        let reader = try BackupArchiveReader(url: url)
        #expect(try reader.bookArchive(for: library.withPDF.book.id) == library.withPDF)
        let out = library.dir.url.appendingPathComponent("out", isDirectory: true)
        try reader.extractFiles(ofBook: library.withPDF.book.id, into: out)
        #expect(try Data(contentsOf: out.appendingPathComponent("ink/12.drawing")) == library.expectedFiles["ink/12.drawing"])
    }

    // MARK: - Tampering

    @Test func aChangedFileIsDetectedOnExtract() throws {
        let library = try SampleLibrary()
        let original = try library.write(includePDFs: false)
        let tampered = library.dir.url.appendingPathComponent("tampered.ttbackup")
        // Rewritten with a valid CRC, so only the manifest's SHA-256 can catch it.
        try rewriteArchive(original, to: tampered) { name, data in
            guard name.hasSuffix("ink/0.drawing") else { return data }
            var changed = data
            changed[100] ^= 1
            return changed
        }
        let reader = try BackupArchiveReader(url: tampered)
        let out = library.dir.url.appendingPathComponent("restore", isDirectory: true)
        #expect(throws: BackupError.contentMismatch(name: "ink/0.drawing")) {
            try reader.extractFiles(ofBook: library.withPDF.book.id, into: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path), "nothing partial is left")
    }

    @Test func aFlippedByteInTheArchiveIsDetectedOnExtract() throws {
        let library = try SampleLibrary()
        let url = try library.write(includePDFs: false)
        let note = "notes/\(library.noteID.uuidString).drawing"
        try patchFile(url, replacing: Data("note ink".utf8), with: Data("note inK".utf8))
        let reader = try BackupArchiveReader(url: url)
        let out = library.dir.url.appendingPathComponent("restore", isDirectory: true)
        #expect(throws: BackupError.contentMismatch(name: note)) {
            try reader.extractFiles(ofBook: library.withPDF.book.id, into: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func tamperedManifestHashesAndSizesAreDetected() throws {
        let library = try SampleLibrary()
        let original = try library.write(includePDFs: true)
        let id = library.withPDF.book.id
        let out = library.dir.url.appendingPathComponent("restore", isDirectory: true)

        let wrongHash = library.dir.url.appendingPathComponent("hash.ttbackup")
        try rewriteManifest(original, to: wrongHash) { manifest in
            manifest.books[0].files[1].sha256 = String(repeating: "0", count: 64)
        }
        let path = try BackupArchiveReader(url: original).manifest.books[0].files[1].path
        #expect(throws: BackupError.contentMismatch(name: path)) { try BackupArchiveReader(url: wrongHash).extractFiles(ofBook: id, into: out) }
        #expect(!FileManager.default.fileExists(atPath: out.path))

        let wrongSize = library.dir.url.appendingPathComponent("size.ttbackup")
        try rewriteManifest(original, to: wrongSize) { manifest in manifest.books[0].files[0].size += 1 }
        #expect(throws: BackupError.contentMismatch(name: "cover.jpg")) { try BackupArchiveReader(url: wrongSize).extractFiles(ofBook: id, into: out) }

        let wrongPDF = library.dir.url.appendingPathComponent("pdf.ttbackup")
        try rewriteArchive(original, to: wrongPDF) { name, data in
            guard name.hasPrefix("pdfs/") else { return data }
            var changed = data
            changed[changed.count - 1] ^= 1
            return changed
        }
        let pdf = library.dir.url.appendingPathComponent("restored.pdf")
        let reader = try BackupArchiveReader(url: wrongPDF)
        #expect(throws: BackupError.contentMismatch(name: "Linear Algebra.pdf")) {
            try reader.extractPDF(sha256: reader.manifest.books[0].pdf.sha256, to: pdf)
        }
        #expect(!FileManager.default.fileExists(atPath: pdf.path))
        #expect(library.dir.allPaths().filter { $0.hasSuffix(".partial") }.isEmpty)
    }

    @Test func theArchiveMustHoldExactlyTheListedFiles() throws {
        let library = try SampleLibrary()
        let original = try library.write(includePDFs: false)
        let id = library.withPDF.book.id
        let out = library.dir.url.appendingPathComponent("restore", isDirectory: true)

        let extra = library.dir.url.appendingPathComponent("extra.ttbackup")
        try rewriteArchive(original, to: extra, adding: [BackupArchiveLayout.bookFilePath(bookID: id, relativePath: "ink/99.drawing"): Data("x".utf8)]) { _, data in data }
        #expect(throws: BackupError.unexpectedFile(name: "ink/99.drawing")) { try BackupArchiveReader(url: extra).extractFiles(ofBook: id, into: out) }

        let missing = library.dir.url.appendingPathComponent("missing.ttbackup")
        try rewriteArchive(original, to: missing) { name, data in name.hasSuffix("/cover.jpg") ? nil : data }
        #expect(throws: BackupError.missingFile(name: "cover.jpg")) { try BackupArchiveReader(url: missing).extractFiles(ofBook: id, into: out) }

        let unlisted = library.dir.url.appendingPathComponent("unlisted.ttbackup")
        try rewriteManifest(original, to: unlisted) { manifest in manifest.books[0].files.removeAll { $0.path == "cover.jpg" } }
        #expect(throws: BackupError.unexpectedFile(name: "cover.jpg")) { try BackupArchiveReader(url: unlisted).extractFiles(ofBook: id, into: out) }
        #expect(!FileManager.default.fileExists(atPath: out.path))

        // A non-empty target directory is refused before anything is written.
        try library.dir.file("restore/keep.txt", Data("mine".utf8))
        #expect(throws: BackupError.self) { try BackupArchiveReader(url: original).extractFiles(ofBook: id, into: out) }
        #expect(library.dir.allPaths(under: "restore") == ["keep.txt"])
    }

    @Test func recordsOfAnotherBookAreRefused() throws {
        let library = try SampleLibrary()
        let original = try library.write(includePDFs: false)
        let id = library.withPDF.book.id
        let tampered = library.dir.url.appendingPathComponent("records.ttbackup")
        try rewriteArchive(original, to: tampered) { name, data in
            guard name == BackupArchiveLayout.recordsPath(bookID: id) else { return data }
            var records = try BackupCoding.makeDecoder().decode(BookRecordsFile.self, from: data)
            records.bookmarks[0].bookID = library.withoutPDF.book.id
            return try BackupCoding.makeEncoder().encode(records)
        }
        #expect(throws: BackupError.recordsInvalid(bookTitle: "Linear Algebra")) { try BackupArchiveReader(url: tampered).bookArchive(for: id) }

        let garbage = library.dir.url.appendingPathComponent("garbage.ttbackup")
        try rewriteArchive(original, to: garbage) { name, data in
            name == BackupArchiveLayout.recordsPath(bookID: id) ? Data("{".utf8) : data
        }
        #expect(throws: BackupError.recordsInvalid(bookTitle: "Linear Algebra")) { try BackupArchiveReader(url: garbage).bookArchive(for: id) }
    }

    @Test func archivesWithoutAManifestAreNotBackups() throws {
        let dir = try TemporaryDirectory()
        let url = dir.url.appendingPathComponent("plain.zip")
        let writer = try ZipArchiveWriter(url: url)
        try writer.addEntry(named: "readme.txt", data: Data("hi".utf8))
        try writer.finish()
        #expect(throws: BackupError.notABackup) { try BackupArchiveReader(url: url) }
    }

    @Test func aNewerBackupIsRefusedOnOpen() throws {
        let library = try SampleLibrary()
        let original = try library.write(includePDFs: false)
        let newer = library.dir.url.appendingPathComponent("newer.ttbackup")
        try rewriteArchive(original, to: newer) { name, data in
            name == BackupArchiveLayout.manifestPath ? Data(#"{"format":"tactile-texts-backup","formatVersion":2}"#.utf8) : data
        }
        #expect(throws: BackupError.newerFormatVersion(2)) { try BackupArchiveReader(url: newer) }
    }

    @Test func temporaryAndHiddenNamesAreSkipped() {
        for name in [".DS_Store", ".x.drawing", "a.tmp", "a.TEMP", "b.partial", "c~"] {
            #expect(BackupArchiveWriter.isTemporaryOrHidden(name), "\(name)")
        }
        for name in ["cover.jpg", "12.drawing", "tmp", "a.tmp.drawing"] {
            #expect(!BackupArchiveWriter.isTemporaryOrHidden(name), "\(name)")
        }
    }

    #if os(macOS)
    @Test func backupsOpenWithSystemUnzip() throws {
        let library = try SampleLibrary()
        let url = try library.write(includePDFs: true)
        let test = try run("/usr/bin/unzip", ["-t", url.path])
        #expect(test.status == 0, "\(test.output)")
    }
    #endif
}
