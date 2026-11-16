import Foundation
import ReaderBackup
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import TactileTexts

/// Helpers for the backup engine tests (B3): fixtures, a seeded library, store and directory
/// comparisons, and a service with its own temporary directory and defaults.
@MainActor
enum BackupTestSupport {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out", isDirectory: true)
    static var small: URL { fixtures.appendingPathComponent("small.pdf") }
    static var noOutline: URL { fixtures.appendingPathComponent("no-outline.pdf") }
    static var large: URL { fixtures.appendingPathComponent("large.pdf") }

    /// A scratch directory for one test.
    static func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A service on `store` with its own temporary directory and defaults. Snapshot names get
    /// increasing timestamps (one second apart), so consecutive backups never share a name.
    static func makeService(_ store: LibraryStore, scratch: URL) -> BackupService {
        let defaults = UserDefaults(suiteName: "BackupTests-\(UUID().uuidString)")!
        let service = BackupService(store: store, temporaryRoot: scratch.appendingPathComponent("tmp", isDirectory: true),
                                    defaults: defaults)
        let counter = Counter()
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        service.makeMetadata = {
            counter.value += 1
            return BackupMetadata(createdAt: base.addingTimeInterval(Double(counter.value)), appVersion: "test", appBuild: "1",
                                  deviceName: "Test iPad")
        }
        return service
    }

    // MARK: Seeding

    struct Seeded {
        var small: Book
        var noOutline: Book
    }

    /// Recognisable ink bytes (the ink store treats ink as opaque data).
    static func inkData(_ label: String, size: Int = 3000) -> Data {
        var data = Data("INK:\(label):".utf8)
        var byte: UInt8 = UInt8(truncatingIfNeeded: label.hashValue)
        while data.count < size {
            byte = byte &* 31 &+ 7
            data.append(byte)
        }
        return data
    }

    /// Imports `small.pdf` and `no-outline.pdf` through the real pipeline and gives them page and
    /// heading notes with and without note ink, highlights, bookmarks, user headings with
    /// parents, page ink, and a reading position.
    static func seedLibrary(_ store: LibraryStore) async throws -> Seeded {
        let importer = ImportService(store: store)
        let small = try #require(try await importer.importPDF(at: Self.small).book)
        let noOutline = try #require(try await importer.importPDF(at: Self.noOutline).book)
        try await seedRecords(store, book: small, label: "S")
        try await seedRecords(store, book: noOutline, label: "N")
        var a = try #require(try store.books.book(id: small.id))
        a.lastReadPageIndex = 7
        a.lastOpenedAt = Date(timeIntervalSinceReferenceDate: 790_000_123.456789)
        try store.books.save(a)
        var b = try #require(try store.books.book(id: noOutline.id))
        b.lastReadPageIndex = 21
        try store.books.save(b)
        return Seeded(small: a, noOutline: b)
    }

    static func seedRecords(_ store: LibraryStore, book: Book, label: String) async throws {
        let date = Date(timeIntervalSinceReferenceDate: 780_000_000.123456)
        let chapter = UserHeading(bookID: book.id, title: "\(label) chapter", pageIndex: 2, parent: nil, createdAt: date)
        let section = UserHeading(bookID: book.id, title: "\(label) section", pageIndex: 3, parent: chapter.anchor,
                                  createdAt: date.addingTimeInterval(1))
        try store.headings.save(chapter)
        try store.headings.save(section)

        let inkNote = Note(bookID: book.id, target: .page(1), text: "\(label) page note with ink\nsecond line", hasInk: true,
                           createdAt: date, modifiedAt: date.addingTimeInterval(10.5))
        try store.notes.save(inkNote)
        try await store.saveNoteInk(inkData("\(label)-note-1"), bookID: book.id, noteID: inkNote.id, origin: nil)
        try store.notes.save(Note(bookID: book.id, target: .page(4), text: "\(label) plain page note", createdAt: date))
        let headingNote = Note(bookID: book.id, target: .heading(section.anchor), text: "\(label) heading note",
                               hasInk: true, createdAt: date.addingTimeInterval(2))
        try store.notes.save(headingNote)
        try await store.saveNoteInk(inkData("\(label)-heading"), bookID: book.id, noteID: headingNote.id, origin: nil)
        try store.notes.save(Note(bookID: book.id, target: .heading(chapter.anchor), text: "\(label) chapter note",
                                  createdAt: date.addingTimeInterval(3)))

        try store.highlights.save(Highlight(bookID: book.id, pageIndex: 2, rects: [CGRect(x: 10, y: 20, width: 100.25, height: 12)],
                                            color: .yellow, text: "\(label) highlighted", createdAt: date))
        try store.highlights.save(Highlight(bookID: book.id, pageIndex: 5, rects: [CGRect(x: 1, y: 2, width: 3, height: 4),
                                                                                  CGRect(x: 5, y: 6, width: 7, height: 8)],
                                            color: .pink, text: "\(label) two lines", createdAt: date.addingTimeInterval(4)))
        try store.bookmarks.setBookmarked(true, bookID: book.id, pageIndex: 0)
        try store.bookmarks.setBookmarked(true, bookID: book.id, pageIndex: 6)
        try await store.savePageInk(inkData("\(label)-page-2"), bookID: book.id, pageIndex: 2, origin: nil)
        try await store.savePageInk(inkData("\(label)-page-9", size: 9000), bookID: book.id, pageIndex: 9, origin: nil)
    }

    // MARK: Comparing

    /// The archive with every record list sorted by ID (repositories return some in no order).
    static func normalized(_ archive: BookArchive?) -> BookArchive? {
        guard var archive else { return nil }
        archive.notes.sort { $0.id.uuidString < $1.id.uuidString }
        archive.highlights.sort { $0.id.uuidString < $1.id.uuidString }
        archive.bookmarks.sort { $0.id.uuidString < $1.id.uuidString }
        archive.userHeadings.sort { $0.id.uuidString < $1.id.uuidString }
        return archive
    }

    static func archive(_ store: LibraryStore, _ id: UUID) throws -> BookArchive? {
        normalized(try store.archive(bookID: id))
    }

    /// Every regular file under `directory`: relative path → bytes (hidden files skipped).
    static func files(in directory: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return result
        }
        let base = directory.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  !url.lastPathComponent.hasPrefix(".") else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            result[path] = try? Data(contentsOf: url)
        }
        return result
    }

    /// Everything under `Books/` plus every book's records: the whole library state.
    struct LibraryState: Equatable {
        var archives: [UUID: BookArchive]
        var files: [String: Data]
    }

    static func libraryState(_ store: LibraryStore) throws -> LibraryState {
        var archives: [UUID: BookArchive] = [:]
        for book in try store.books.allBooks() { archives[book.id] = try archive(store, book.id) }
        return LibraryState(archives: archives,
                            files: files(in: store.rootDirectory.appendingPathComponent("Books", isDirectory: true)))
    }

    static func restoresDirectoryIsGone(_ store: LibraryStore) -> Bool {
        let root = RestoreLayout.root(storeRoot: store.rootDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return entries.isEmpty
    }

    static func temporaryEntries(_ service: BackupService) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: service.temporaryRoot.path)) ?? []
    }

    /// Polls `condition` on the main actor.
    static func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

@MainActor
final class Counter {
    var value = 0
}

/// Strings appended in order, shared between a test and the tasks it starts.
@MainActor
final class TestLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
    func contains(_ entry: String) -> Bool { entries.contains(entry) }
}

/// A one-shot gate a test opens to let a suspended job continue.
@MainActor
final class TestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}
