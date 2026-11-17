import CoreGraphics
import CryptoKit
import Foundation
@testable import ReaderBackup
import ReaderCore
import Testing
@testable import ReaderSync

/// Pins the `Sync/v1` format: `Fixtures/sync-v1/` is a folder of objects as they lie under an
/// account's folder, written once by `writeTheFixture` (with the fixed key `sequentialKey` and
/// fixed salts, nonces and write IDs) and checked in. `readsTheV1Fixture` reads it with the
/// current code and compares against `SyncFixtureV1`'s values, so a change that would stop
/// existing synced data from being read fails here. Never regenerate it; when the format version
/// rises, add a new fixture folder and a new test beside this one (see `Fixtures/README.md`).
struct SyncFixtureTests {
    static var folder: URL {
        get throws {
            try #require(Bundle.module.url(forResource: "sync-v1", withExtension: nil, subdirectory: "Fixtures"))
        }
    }

    /// Every file under the fixture folder as an object (key = path relative to the folder).
    static func loadFixture() throws -> InMemorySyncObjectStore {
        let root = try folder.standardizedFileURL
        let store = InMemorySyncObjectStore()
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let key = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            store.setObject(try Data(contentsOf: url), at: key)
        }
        return store
    }

    @Test func readsTheV1Fixture() async throws {
        let dir = try TemporaryDirectory()
        let objects = try Self.loadFixture()
        let sync = EncryptedSyncStore(store: objects, key: sequentialKey, temporaryDirectory: dir.url)
        let f = SyncFixtureV1.self

        // The layout, exactly.
        let bookKeyA = try sync.bookKey(pdfSHA256: sha256(f.pdfA))
        let bookKeyB = try sync.bookKey(pdfSHA256: sha256(f.pdfB))
        var expectedKeys = ["Sync/v1/books/\(bookKeyA)", "Sync/v1/books/\(bookKeyB)",
                            "Sync/v1/history/\(bookKeyA)/1",
                            try sync.pdfKey(sha256: sha256(f.pdfA)), try sync.pdfKey(sha256: sha256(f.pdfB))]
        for blob in f.headA.references.blobs + f.headB.references.blobs + f.historyA1.references.blobs {
            expectedKeys.append(try sync.blobKey(sha256: blob.sha256))
        }
        #expect(objects.keys == Set(expectedKeys).sorted())

        // Heads.
        #expect(Set(try await sync.listHeads().map(\.bookKey)) == [bookKeyA, bookKeyB])
        let headA = try #require(try await sync.readHead(bookKey: bookKeyA)).head
        #expect(headA == f.headA)
        #expect(headA.formatVersion == 1 && headA.writerLevel == 1 && headA.version == 2 && headA.previousVersion == 1)
        #expect(headA.writeID == "0123456789abcdef0123456789abcdef")
        #expect(headA.book.title == "Linear Algebra Done Right")
        #expect(headA.references.pageInk.map(\.pageIndex) == [2, 10])
        #expect(headA.access() == .readAndPush)
        let headB = try #require(try await sync.readHead(bookKey: bookKeyB)).head
        #expect(headB == f.headB)
        #expect(headB.isDeleted && headB.book.importFormat == .epub)

        // History.
        #expect(try await sync.historyVersions(bookKey: bookKeyA) == [1])
        let historyA1 = try #require(try await sync.readHistory(bookKey: bookKeyA, version: 1))
        #expect(historyA1 == f.historyA1)
        #expect(try SyncRecords.decode(try await sync.blob(historyA1.references.records), key: "records")
                == BookArchive(book: f.bookA))

        // Blobs: the records are the books' archives, the files their bytes.
        #expect(try SyncRecords.decode(try await sync.blob(headA.references.records), key: "records") == f.recordsA)
        #expect(try SyncRecords.decode(try await sync.blob(headB.references.records), key: "records") == f.recordsB)
        #expect(try await sync.blob(headA.references.pageInk[0].content) == f.pageInk2)
        #expect(try await sync.blob(headA.references.pageInk[1].content) == f.pageInk10)
        #expect(try await sync.blob(headA.references.noteInk[0].content) == f.noteInk)
        #expect(try await sync.blob(try #require(headA.references.cover)) == f.cover)
        #expect(try await sync.blob(try #require(headB.references.conversion)) == f.conversion)

        // PDFs, as backups store them.
        let pdf = dir.url.appendingPathComponent("a.pdf")
        try await sync.downloadPDF(headA.references.pdf, to: pdf)
        #expect(try Data(contentsOf: pdf) == f.pdfA)
        try await sync.downloadPDF(headB.references.pdf, to: pdf)
        #expect(try Data(contentsOf: pdf) == f.pdfB)

        // The pinned sub-keys' names, written out (computed when the fixture was made).
        #expect(bookKeyA == SyncFixtureV1.pinnedBookKeyA)
    }

    /// Writes the fixture into the folder named by `TACTILE_WRITE_SYNC_FIXTURE`. Run once, when a
    /// new fixture is added; never over an existing one.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TACTILE_WRITE_SYNC_FIXTURE"] != nil))
    func writeTheFixture() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TACTILE_WRITE_SYNC_FIXTURE"]),
                         isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: output.path), "never write over an existing fixture")
        let dir = try TemporaryDirectory()
        let objects = InMemorySyncObjectStore()
        let random = FixedRandomness()
        let randomness = SyncRandomness { random.next($0) }
        let sync = EncryptedSyncStore(store: objects, key: sequentialKey, temporaryDirectory: dir.url, randomness: randomness,
                                      encryptFile: { source, destination, key, metadata in
            try BackupFileEncryption.encrypt(source, to: destination, key: key, metadata: metadata, progress: nil,
                                             chunkSize: BackupFileEncryption.chunkSize, salt: random.next(32),
                                             noncePrefix: random.next(7))
        })
        let f = SyncFixtureV1.self
        for data in [try SyncRecords.encode(f.recordsA), try SyncRecords.encode(f.recordsB),
                     try SyncRecords.encode(BookArchive(book: f.bookA)), f.pageInk2, f.pageInk10, f.noteInk, f.cover, f.conversion] {
            try await sync.putBlob(data)
        }
        for pdf in [f.pdfA, f.pdfB] {
            try await sync.uploadPDF(fileAt: try dir.file("pdf-\(UUID().uuidString)", pdf), content: digest(pdf))
        }
        let bookKeyA = try sync.bookKey(pdfSHA256: sha256(f.pdfA))
        let bookKeyB = try sync.bookKey(pdfSHA256: sha256(f.pdfB))
        try await sync.writeHistory(f.historyA1, bookKey: bookKeyA)
        try await sync.writeHead(f.headA, bookKey: bookKeyA, condition: .ifAbsent)
        try await sync.writeHead(f.headB, bookKey: bookKeyB, condition: .ifAbsent)
        for (key, data) in objects.contents {
            let url = output.appendingPathComponent(key, isDirectory: false)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        print("book key A: \(bookKeyA)")
    }
}

/// A fixed byte stream: SHA-256 of `"tactile-texts.sync.v1.fixture" ‖ counter`, block after block.
final class FixedRandomness: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt32 = 0

    func next(_ count: Int) -> [UInt8] {
        lock.withLock {
            var out: [UInt8] = []
            while out.count < count {
                var input = Data("tactile-texts.sync.v1.fixture".utf8)
                withUnsafeBytes(of: counter.bigEndian) { input.append(contentsOf: $0) }
                counter += 1
                out += SHA256.hash(data: input)
            }
            return Array(out.prefix(count))
        }
    }
}

/// The values the `Sync/v1` fixture holds. Frozen with the fixture: never edit them.
enum SyncFixtureV1 {
    static func id(_ suffix: String) -> UUID { UUID(uuidString: "5C1F0000-0000-4000-8000-\(suffix)")! }
    static func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    /// The book key of book A under `sequentialKey`.
    static let pinnedBookKeyA = "8290067c0c6b12299d6a46b33c5207b674a630f553895fa0433af50fa08cde38"

    static let pdfA = Data("%PDF-1.4\n%Tactile Texts sync fixture A\n1 0 obj << >> endobj\n%%EOF\n".utf8)
    static let pdfB = Data("%PDF-1.4\n%Tactile Texts sync fixture B (converted)\n%%EOF\n".utf8)
    static let pageInk2 = Data("page-2-ink-drawing-bytes".utf8)
    static let pageInk10 = Data("page-10-ink-drawing-bytes".utf8)
    static let noteInk = Data("note-ink-drawing-bytes".utf8)
    static let cover = Data("cover-jpeg-bytes".utf8)
    static let conversion = Data("{\"converterVersion\":2,\"sourceFormat\":\"epub\"}".utf8)
    static let deviceA = id("0000000000D1")
    static let deviceB = id("0000000000D2")

    static let bookA = Book(id: id("000000000001"), title: "Linear Algebra Done Right", fingerprint: "fixture-fingerprint-a",
                            fileName: "Linear Algebra Done Right.pdf", pageCount: 12, fileSize: Int64(pdfA.count),
                            addedAt: date(784_000_000.25), lastOpenedAt: date(784_086_400.5), lastReadPageIndex: 3)
    static let recordsA = BookArchive(
        book: bookA,
        notes: [Note(id: id("000000000101"), bookID: bookA.id, target: .page(2), text: "Eigenvalues first.\nThen eigenvectors.",
                     hasInk: true, createdAt: date(784_000_100.5), modifiedAt: date(784_000_200.75)),
                Note(id: id("000000000102"), bookID: bookA.id,
                     target: .heading(HeadingAnchor(rawValue: "pdf1/4.1/7/5.2 The Characteristic Equation")!),
                     text: "Check the proof of 5.6.", createdAt: date(784_000_300.5))],
        highlights: [Highlight(id: id("000000000201"), bookID: bookA.id, pageIndex: 2,
                               rects: [CGRect(x: 72, y: 600.5, width: 300, height: 14)], color: .green, text: "an eigenvalue of T",
                               createdAt: date(784_000_500))],
        bookmarks: [Bookmark(id: id("000000000301"), bookID: bookA.id, pageIndex: 5, createdAt: date(784_000_600))],
        userHeadings: [UserHeading(id: id("000000000401"), bookID: bookA.id, title: "Part One (mine)", pageIndex: 1, parent: nil,
                                   createdAt: date(784_000_700))])

    static let bookB = Book(id: id("000000000002"), title: "Middlemarch", fingerprint: "fixture-fingerprint-b",
                            fileName: "Middlemarch.pdf", pageCount: 40, fileSize: Int64(pdfB.count), addedAt: date(784_100_000),
                            lastReadPageIndex: 0, sourceFormat: .epub, originalFileName: "Middlemarch.epub", converterVersion: 2)
    static let recordsB = BookArchive(book: bookB)

    static func digest(_ data: Data) -> ContentDigest { ContentDigest(sha256: ContentHash.sha256(of: data), size: Int64(data.count)) }

    static let historyA1 = SyncHead(
        version: 1, previousVersion: nil, writeID: "00000000000000000000000000000001", deviceID: deviceB, deviceName: "Fixture iPad B",
        modifiedAt: date(784_000_050),
        book: SyncBookInfo(title: "Linear Algebra Done Right", pageCount: 12, fingerprint: "fixture-fingerprint-a",
                           readingPosition: SyncReadingPosition(pageIndex: 0, date: date(784_000_050))),
        references: SyncReferences(records: digest(try! SyncRecords.encode(BookArchive(book: bookA))), pdf: digest(pdfA)))

    static let headA = SyncHead(
        version: 2, previousVersion: 1, writeID: "0123456789abcdef0123456789abcdef", deviceID: deviceA, deviceName: "Fixture iPad A",
        modifiedAt: date(784_086_401.125),
        book: SyncBookInfo(title: "Linear Algebra Done Right", pageCount: 12, fingerprint: "fixture-fingerprint-a",
                           readingPosition: SyncReadingPosition(pageIndex: 3, date: date(784_086_400.5))),
        references: SyncReferences(records: digest(try! SyncRecords.encode(recordsA)), pdf: digest(pdfA),
                                   pageInk: [SyncPageInkReference(pageIndex: 2, content: digest(pageInk2)),
                                             SyncPageInkReference(pageIndex: 10, content: digest(pageInk10))],
                                   noteInk: [SyncNoteInkReference(noteID: id("000000000101"), content: digest(noteInk))],
                                   cover: digest(cover)))

    static let headB = SyncHead(
        version: 1, previousVersion: nil, writeID: "fedcba9876543210fedcba9876543210", deviceID: deviceB, deviceName: "Fixture iPad B",
        modifiedAt: date(784_200_000), deletedAt: date(784_200_000),
        book: SyncBookInfo(title: "Middlemarch", pageCount: 40, fingerprint: "fixture-fingerprint-b", sourceFormat: "epub",
                           originalFileName: "Middlemarch.epub", converterVersion: 2),
        references: SyncReferences(records: digest(try! SyncRecords.encode(recordsB)), pdf: digest(pdfB),
                                   conversion: digest(conversion)))
}
