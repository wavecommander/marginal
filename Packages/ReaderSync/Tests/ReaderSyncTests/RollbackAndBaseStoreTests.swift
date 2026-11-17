import CoreGraphics
import Foundation
import ReaderBackup
import ReaderCore
import Testing
@testable import ReaderSync

struct SyncRollbackGuardTests {
    static let bookKey = String(repeating: "ab", count: 32)
    static let otherBook = String(repeating: "cd", count: 32)

    @Test func aLowerVersionIsRefusedAndTheRecordPersists() throws {
        let dir = try TemporaryDirectory()
        let directory = dir.url.appendingPathComponent("versions")
        let guardrail = SyncRollbackGuard(directory: directory)
        #expect(try guardrail.highestVersion(bookKey: Self.bookKey) == nil)
        try guardrail.check(bookKey: Self.bookKey, version: 1)
        try guardrail.accept(bookKey: Self.bookKey, version: 5)
        try guardrail.accept(bookKey: Self.bookKey, version: 5) // the same head read again
        #expect(throws: SyncError.rollback(bookKey: Self.bookKey, highestSeen: 5, offered: 4)) {
            try guardrail.accept(bookKey: Self.bookKey, version: 4)
        }
        #expect(throws: SyncError.rollback(bookKey: Self.bookKey, highestSeen: 5, offered: 1)) {
            try guardrail.check(bookKey: Self.bookKey, version: 1)
        }
        try guardrail.record(bookKey: Self.bookKey, version: 3) // never lowers
        try guardrail.accept(bookKey: Self.bookKey, version: 9)
        // Another book is separate.
        try guardrail.accept(bookKey: Self.otherBook, version: 1)

        // A new value over the same directory (a relaunch) remembers.
        let relaunched = SyncRollbackGuard(directory: directory)
        #expect(try relaunched.highestVersion(bookKey: Self.bookKey) == 9)
        #expect(throws: SyncError.rollback(bookKey: Self.bookKey, highestSeen: 9, offered: 8)) {
            try relaunched.check(bookKey: Self.bookKey, version: 8)
        }
        #expect(try String(contentsOf: directory.appendingPathComponent(Self.bookKey), encoding: .utf8) == "9\n")
        #expect(dir.files(under: "versions") == [Self.bookKey, Self.otherBook].sorted(), "nothing left over from atomic writes")

        try relaunched.remove(bookKey: Self.bookKey)
        #expect(try relaunched.highestVersion(bookKey: Self.bookKey) == nil)
        try relaunched.removeAll()
        #expect(try relaunched.highestVersion(bookKey: Self.otherBook) == nil)
    }

    @Test func anUnreadableRecordStopsRatherThanAccepts() throws {
        let dir = try TemporaryDirectory()
        let guardrail = SyncRollbackGuard(directory: dir.url)
        _ = try dir.file(Self.bookKey, Data("seven".utf8))
        #expect(throws: SyncError.rollbackRecordUnreadable(bookKey: Self.bookKey)) {
            try guardrail.accept(bookKey: Self.bookKey, version: 1)
        }
        #expect(throws: SyncError.invalidName("../escape")) { try guardrail.check(bookKey: "../escape", version: 1) }
    }

    @Test func concurrentAcceptsKeepTheHighest() async throws {
        let dir = try TemporaryDirectory()
        let guardrail = SyncRollbackGuard(directory: dir.url)
        await withTaskGroup(of: Void.self) { group in
            for version in 1...40 {
                group.addTask { try? guardrail.record(bookKey: Self.bookKey, version: version) }
            }
        }
        #expect(try guardrail.highestVersion(bookKey: Self.bookKey) == 40)
    }

    @Test func anEncryptedStoreHeadFeedsTheGuard() async throws {
        // How the engine composes the two: read a head, then accept its version.
        let dir = try TemporaryDirectory()
        let objects = InMemorySyncObjectStore()
        let sync = Sample.store(objects: objects, temporary: dir.url.appendingPathComponent("tmp"))
        let guardrail = SyncRollbackGuard(directory: dir.url.appendingPathComponent("versions"))
        let bookKey = try sync.bookKey(pdfSHA256: sha256(Sample.pdf))
        try await sync.writeHead(Sample.head(version: 1), bookKey: bookKey, condition: .ifAbsent)
        let oldHead = try #require(objects.object("Sync/v1/books/\(bookKey)"))
        let e1 = oldHead.eTag
        try await sync.writeHead(Sample.head(version: 2, previous: 1), bookKey: bookKey, condition: .ifMatch(eTag: e1))
        try guardrail.accept(bookKey: bookKey, version: try #require(try await sync.readHead(bookKey: bookKey)).head.version)
        // The operator puts the old (authentic) head back.
        objects.setObject(oldHead.data, at: "Sync/v1/books/\(bookKey)")
        let replayed = try #require(try await sync.readHead(bookKey: bookKey))
        #expect(throws: SyncError.rollback(bookKey: bookKey, highestSeen: 2, offered: 1)) {
            try guardrail.accept(bookKey: bookKey, version: replayed.head.version)
        }
    }
}

struct SyncBaseStoreTests {
    static func base(bookID: UUID = UUID(), version: Int = 3, note: String = "A note") -> SyncBase {
        let book = Book(id: bookID, title: "Base Book", fingerprint: "fp", fileName: "Base Book.pdf", pageCount: 20, fileSize: 1234,
                        addedAt: Sample.date, lastReadPageIndex: 4)
        let archive = BookArchive(book: book, notes: [Note(bookID: bookID, target: .page(4), text: note, createdAt: Sample.date)],
                                  highlights: [Highlight(bookID: bookID, pageIndex: 2, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)],
                                                         color: .pink, text: "h", createdAt: Sample.date)],
                                  bookmarks: [Bookmark(bookID: bookID, pageIndex: 7, createdAt: Sample.date)])
        return SyncBase(bookKey: String(repeating: "0f", count: 32), headVersion: version, headETag: "\"etag-\(version)\"",
                        archive: archive,
                        files: SyncBaseFiles(pageInk: [SyncPageInkReference(pageIndex: 2, content: digest("ink 2"))],
                                             noteInk: [SyncNoteInkReference(noteID: archive.notes[0].id, content: digest("note ink"))],
                                             cover: digest("cover"), conversion: nil))
    }

    @Test func aBaseRoundTripsAndIsReplacedWhole() throws {
        let dir = try TemporaryDirectory()
        let store = SyncBaseStore(root: dir.url.appendingPathComponent("bases"))
        let first = Self.base()
        let bookID = first.archive.book.id
        #expect(try store.base(bookID: bookID) == nil)
        #expect(try store.bookIDs().isEmpty)
        try store.replace(first)
        #expect(try store.base(bookID: bookID) == first)
        var second = Self.base(bookID: bookID, version: 4, note: "Edited")
        second.files.cover = nil
        try store.replace(second)
        #expect(try store.base(bookID: bookID) == second)
        #expect(dir.files(under: "bases") == ["\(bookID.uuidString)/base.json"], "no ink bytes, nothing left over")

        let other = Self.base()
        try store.replace(other)
        #expect(Set(try store.bookIDs()) == [bookID, other.archive.book.id])
        try store.remove(bookID: bookID)
        #expect(try store.base(bookID: bookID) == nil)
        #expect(try store.bookIDs() == [other.archive.book.id])
        try store.remove(bookID: bookID) // already gone
        try store.removeAll()
        #expect(try store.bookIDs().isEmpty)
        try store.removeAll()
    }

    @Test func aFailedReplaceLeavesTheOldBase() throws {
        let dir = try TemporaryDirectory()
        let store = SyncBaseStore(root: dir.url)
        let good = Self.base()
        try store.replace(good)
        // JSON cannot hold a non-finite number, so this replace fails while encoding.
        var bad = good
        bad.archive.highlights[0].rects = [CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)]
        #expect(throws: (any Error).self) { try store.replace(bad) }
        #expect(try store.base(bookID: good.archive.book.id) == good)
        #expect(dir.files() == ["\(good.archive.book.id.uuidString)/base.json"])
    }

    @Test func anUnreadableBaseSaysSo() throws {
        let dir = try TemporaryDirectory()
        let store = SyncBaseStore(root: dir.url)
        let good = Self.base()
        let id = good.archive.book.id
        _ = try dir.file("\(id.uuidString)/base.json", Data("{ cut short".utf8))
        #expect(throws: SyncError.baseUnreadable(bookID: id)) { try store.base(bookID: id) }
        // From a newer app.
        try store.replace(good)
        let url = dir.url.appendingPathComponent("\(id.uuidString)/base.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["formatVersion"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: SyncError.baseUnreadable(bookID: id)) { try store.base(bookID: id) }
        // Filed under another book.
        let elsewhere = UUID()
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent(elsewhere.uuidString), withIntermediateDirectories: true)
        try BackupCoding.makeEncoder().encode(good).write(to: dir.url.appendingPathComponent("\(elsewhere.uuidString)/base.json"))
        #expect(throws: SyncError.baseUnreadable(bookID: elsewhere)) { try store.base(bookID: elsewhere) }
        // Stray entries are not books.
        _ = try dir.file("notes.txt", Data())
        _ = try dir.file("\(UUID().uuidString.lowercased())/base.json", Data())
        #expect(Set(try store.bookIDs()) == [id, elsewhere])
    }
}
