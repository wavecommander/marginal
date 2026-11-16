import Foundation
import CryptoKit
import CoreGraphics
import Testing
import ReaderCore
@testable import ReaderBackup

struct ContentHashTests {
    func cryptoKitHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func knownVector() {
        #expect(ContentHash.sha256(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ContentHash.sha256(of: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func fileDigestEqualsCryptoKitOneShot() throws {
        let dir = try TemporaryDirectory()
        for (index, size) in [0, 1, 4 * 1024 * 1024, multiChunkSize].enumerated() {
            let data = pseudoRandomData(count: size, seed: UInt64(index))
            let url = try dir.file("f\(index)", data)
            let log = ProgressLog()
            let digest = try ContentHash.digest(ofFileAt: url, progress: log.callback)
            #expect(digest == ContentDigest(sha256: cryptoKitHex(data), size: Int64(size)))
            #expect(ContentHash.sha256(of: data) == cryptoKitHex(data))
            #expect(try ContentHash.sha256(ofFileAt: url) == digest.sha256)
            #expect(log.isWellFormed)
        }
    }

    @Test func incrementalEqualsFileForm() throws {
        let dir = try TemporaryDirectory()
        let data = pseudoRandomData(count: multiChunkSize, seed: 11)
        let url = try dir.file("f", data)
        var hasher = ContentHasher()
        var offset = 0
        var step = 1
        while offset < data.count {
            let end = min(data.count, offset + step)
            if step % 2 == 0 {
                hasher.update(data.subdata(in: offset..<end))
            } else {
                data.subdata(in: offset..<end).withUnsafeBytes { hasher.update($0) }
            }
            offset = end
            step = step * 3 + 7
        }
        #expect(hasher.byteCount == Int64(data.count))
        #expect(hasher.finalize() == (try ContentHash.digest(ofFileAt: url)))
    }

    @Test func hashingIsCancellable() async throws {
        let dir = try TemporaryDirectory()
        let url = try dir.file("f", pseudoRandomData(count: multiChunkSize, seed: 1))
        let error = await runCancelling { cancel in
            _ = try ContentHash.digest(ofFileAt: url, progress: { if $0 > 0 { cancel() } })
        }
        #expect(error is CancellationError)
    }

    @Test func validHashShape() {
        #expect(ContentHash.isValidSHA256(String(repeating: "a", count: 64)))
        #expect(!ContentHash.isValidSHA256(String(repeating: "A", count: 64)))
        #expect(!ContentHash.isValidSHA256(String(repeating: "a", count: 63)))
        #expect(!ContentHash.isValidSHA256(String(repeating: "g", count: 64)))
        #expect(!ContentHash.isValidSHA256("../" + String(repeating: "a", count: 61)))
    }
}

struct BackupManifestTests {
    static let book = Book(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "Calculus", fingerprint: "fp",
                           fileName: "calc.pdf", pageCount: 10, fileSize: 100,
                           addedAt: Date(timeIntervalSinceReferenceDate: 784_000_000.000_123_4),
                           lastOpenedAt: Date(timeIntervalSinceReferenceDate: 784_000_001.987_654_321), lastReadPageIndex: 2)

    static func manifest(formatVersion: Int = 1) -> BackupManifest {
        BackupManifest(formatVersion: formatVersion, createdAt: Date(timeIntervalSinceReferenceDate: 784_123_456.000_000_7),
                       appVersion: "1.2", appBuild: "34", deviceName: "Ben’s iPad", includesPDFs: false,
                       books: [.init(book: book, pdf: .init(sha256: String(repeating: "ab", count: 32), size: 100, embedded: false),
                                     counts: .init(notes: 1, highlights: 2, bookmarks: 3, userHeadings: 4, inkedPages: 5),
                                     lastModifiedAt: Date(timeIntervalSinceReferenceDate: 784_000_002.000_000_3),
                                     files: [.init(path: "ink/3.drawing", size: 7, sha256: String(repeating: "cd", count: 32))])])
    }

    @Test func roundTripIsLosslessForSubMillisecondDates() throws {
        let manifest = Self.manifest()
        let data = try manifest.encoded()
        let decoded = try BackupManifest.decode(data)
        #expect(decoded == manifest)
        #expect(decoded.createdAt.timeIntervalSinceReferenceDate == 784_123_456.000_000_7)
        #expect(decoded.books[0].book.lastOpenedAt == Self.book.lastOpenedAt)
        // Sorted keys: encoding is deterministic.
        #expect(try manifest.encoded() == data)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""format" : "tactile-texts-backup""#))
        #expect(text.contains(#""path" : "ink/3.drawing""#), "slashes are not escaped")
    }

    @Test func recordsRoundTripLosslessly() throws {
        let id = Self.book.id
        let parent = UUID(uuidString: "99999999-0000-0000-0000-000000000001")!
        let archive = BookArchive(
            book: Self.book,
            notes: [Note(bookID: id, target: .page(3), text: "Hi", hasInk: true,
                         bandLayout: NoteBandLayout(pageWidth: 600.5, paragraphs: [NoteParagraphBand(text: "Hi", top: 0, height: 22.25)], trailingTop: 22.25),
                         createdAt: Date(timeIntervalSinceReferenceDate: 1.000_000_1), modifiedAt: Date(timeIntervalSinceReferenceDate: 2.000_000_2)),
                    Note(bookID: id, target: .heading(HeadingAnchor(pdfPath: [4, 1], pageIndex: 7, title: "5.2 Eigen/values")), text: "Sec")],
            highlights: [Highlight(bookID: id, pageIndex: 1, rects: [CGRect(x: 1.5, y: 2.25, width: 3.125, height: 4)], color: .pink, text: "t")],
            bookmarks: [Bookmark(bookID: id, pageIndex: 4)],
            userHeadings: [UserHeading(bookID: id, title: "Mine", pageIndex: 2, parent: HeadingAnchor(userHeadingID: parent))])
        let data = try BackupCoding.makeEncoder().encode(BookRecordsFile(archive))
        let decoded = try BackupCoding.makeDecoder().decode(BookRecordsFile.self, from: data)
        #expect(decoded.archive(for: Self.book) == archive)
    }

    @Test func newerFormatVersionIsRefused() throws {
        let data = try Self.manifest(formatVersion: 2).encoded()
        #expect(throws: BackupError.newerFormatVersion(2)) { try BackupManifest.decode(data) }
        #expect(BackupError.newerFormatVersion(2).localizedDescription.contains("made by a newer version of Tactile Texts"))
        #expect(throws: BackupError.newerFormatVersion(2)) { try Self.manifest(formatVersion: 2).validate() }
        // A newer manifest whose shape this version does not know is still reported as newer.
        let future = Data(#"{"format":"tactile-texts-backup","formatVersion":7,"books":{"shape":"changed"}}"#.utf8)
        #expect(throws: BackupError.newerFormatVersion(7)) { try BackupManifest.decode(future) }
    }

    @Test func aPDFFileNameThatLeavesTheBookDirectoryIsRefused() throws {
        for name in ["", "..", ".hidden.pdf", "a/b.pdf", "..\\b.pdf", "../../Database/TactileTexts.store", "x\u{0}.pdf",
                     "document.sha256", "records.json", String(repeating: "a", count: 256)] {
            var manifest = Self.manifest()
            manifest.books[0].book.fileName = name
            #expect(throws: BackupError.self, "\(name.debugDescription)") { try manifest.validate() }
            #expect(!BackupManifest.isSafeDocumentFileName(name), "\(name.debugDescription)")
        }
        for name in ["calc.pdf", "Linear Algebra (4th ed.).pdf", "Analyse réelle.pdf", "cover.pdf"] {
            var manifest = Self.manifest()
            manifest.books[0].book.fileName = name
            try manifest.validate()
        }
    }

    @Test func otherFilesAreNotBackups() throws {
        var manifest = Self.manifest()
        manifest.format = "something-else"
        #expect(throws: BackupError.notABackup) { try BackupManifest.decode(try manifest.encoded()) }
        #expect(throws: BackupError.notABackup) { try BackupManifest.decode(Data("[1,2]".utf8)) }
        #expect(throws: BackupError.notABackup) { try BackupManifest.decode(Data("not json".utf8)) }
    }

    @Test(arguments: ["../x", "/abs", "records.json", "calc.pdf", "document.sha256", "a\\b", "", "ink/"])
    func unsafeFilePathsAreInvalid(path: String) throws {
        var manifest = Self.manifest()
        manifest.books[0].files[0].path = path
        #expect(throws: BackupError.self) { try BackupManifest.decode(try manifest.encoded()) }
    }

    @Test func duplicateBooksAndBadHashesAreInvalid() throws {
        var manifest = Self.manifest()
        manifest.books.append(manifest.books[0])
        #expect(throws: BackupError.self) { try manifest.validate() }
        manifest = Self.manifest()
        manifest.books[0].pdf.sha256 = "ABC"
        #expect(throws: BackupError.self) { try manifest.validate() }
    }
}

struct LayoutTests {
    @Test func archivePaths() {
        let id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        #expect(BackupArchiveLayout.manifestPath == "manifest.json")
        #expect(BackupArchiveLayout.recordsPath(bookID: id) == "books/AAAAAAAA-0000-0000-0000-000000000001/records.json")
        #expect(BackupArchiveLayout.bookFilePath(bookID: id, relativePath: "ink/12.drawing")
                == "books/AAAAAAAA-0000-0000-0000-000000000001/ink/12.drawing")
        #expect(BackupArchiveLayout.embeddedPDFPath(sha256: "ab") == "pdfs/ab.pdf")
        #expect(BackupFolderLayout.snapshotPath(name: "x.ttbackup") == "Backups/x.ttbackup")
        #expect(BackupFolderLayout.pdfPath(sha256: "ab") == "PDFs/ab.pdf")
    }

    @Test func snapshotNameRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_763_199_005) // 2025-11-15 09:30:05 UTC
        let name = SnapshotName.make(createdAt: date.addingTimeInterval(0.75), deviceName: "Ben’s iPad")
        #expect(name == "2025-11-15T09-30-05Z Ben’s iPad.ttbackup")
        let parsed = try #require(SnapshotName.parse(name))
        #expect(parsed.createdAt == date)
        #expect(parsed.deviceName == "Ben’s iPad")
    }

    @Test func deviceNamesAreSanitised() throws {
        #expect(SnapshotName.sanitizedDeviceName("a/b\\c:d*e?f\"g<h>i|j") == "a-b-c-d-e-f-g-h-i-j")
        #expect(SnapshotName.sanitizedDeviceName("  ..hidden. ") == "hidden")
        #expect(SnapshotName.sanitizedDeviceName("tab\there") == "tab-here")
        #expect(SnapshotName.sanitizedDeviceName("") == "iPad")
        #expect(SnapshotName.sanitizedDeviceName("...") == "iPad")
        #expect(SnapshotName.sanitizedDeviceName(String(repeating: "x", count: 100)).count == 60)
        let name = SnapshotName.make(createdAt: Date(timeIntervalSince1970: 0), deviceName: "../../etc")
        #expect(!name.contains("/"))
        #expect(try #require(SnapshotName.parse(name)).deviceName == "-..-etc")
    }

    @Test(arguments: ["", "x.ttbackup", "2025-11-15T09-30-05Z.ttbackup", "2025-11-15T09-30-05Z iPad.zip",
                      "2025-13-15T09-30-05Z iPad.ttbackup", "2025-11-15T09:30:05Z iPad.ttbackup",
                      "2025-11-15T09-30-05Z .ttbackup", "2025-02-30T09-30-05Z iPad.ttbackup"])
    func invalidSnapshotNamesDoNotParse(name: String) {
        #expect(SnapshotName.parse(name) == nil)
    }

    @Test func namesSortByDate() {
        let dates = [0, 59, 3600, 86_400 * 400, 86_400 * 3650].map { Date(timeIntervalSince1970: 1_600_000_000 + Double($0)) }
        let names = dates.map { SnapshotName.make(createdAt: $0, deviceName: "iPad") }
        #expect(names.sorted() == names)
    }
}
