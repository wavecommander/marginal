import Foundation
import Testing
import SwiftData
import ReaderCore
@testable import ReaderStore

/// A schema newer than any this build ships, the way the next real version will look: one model
/// gains an optional column and a new model appears. Its `HighlightModel` keeps the entity name.
enum FutureSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(99, 0, 0)

    static var models: [any PersistentModel.Type] {
        [MarginalSchemaV2.BookModel.self, MarginalSchemaV1.NoteModel.self, HighlightModel.self,
         MarginalSchemaV1.BookmarkModel.self, MarginalSchemaV1.UserHeadingModel.self, ShelfModel.self]
    }

    @Model
    final class HighlightModel {
        @Attribute(.unique) var id: UUID
        var bookID: UUID
        var pageIndex: Int
        var rectsData: Data
        var colorRaw: String
        var text: String
        var createdAt: Date
        var sortRank: Int
        var sortMaxY: Double
        var sortMinX: Double
        var idString: String
        var textSourceRaw: String?

        init(id: UUID, bookID: UUID, pageIndex: Int, text: String, createdAt: Date, textSourceRaw: String?) {
            self.id = id
            self.bookID = bookID
            self.pageIndex = pageIndex
            self.rectsData = try! JSONEncoder().encode([CGRect(x: 10, y: 20, width: 30, height: 12)])
            self.colorRaw = HighlightColor.yellow.rawValue
            self.text = text
            self.createdAt = createdAt
            self.sortRank = 0
            self.sortMaxY = 32
            self.sortMinX = 10
            self.idString = id.uuidString
            self.textSourceRaw = textSourceRaw
        }
    }

    @Model
    final class ShelfModel {
        @Attribute(.unique) var id: UUID
        var name: String
        init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }
}

enum FuturePlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MarginalSchemaV1.self, MarginalSchemaV2.self, FutureSchema.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: MarginalSchemaV1.self, toVersion: MarginalSchemaV2.self),
         .lightweight(fromVersion: MarginalSchemaV2.self, toVersion: FutureSchema.self)]
    }
}

/// What a test wrote into a store, to check it survives.
struct WrittenLibrary {
    let book: Book
    let noteID: UUID
    let highlightID: UUID
    let headingID: UUID
}

@MainActor
@Suite struct LibraryDatabaseTests {
    // MARK: Helpers

    private func storeURL(_ root: TempRoot) -> URL {
        LibraryDatabase.storeURL(rootDirectory: root.url)
    }

    /// Writes a store with `schema` (migrating through `plan`) holding one book and one of each
    /// record, and closes it.
    @discardableResult
    private func writeStore(_ schema: any VersionedSchema.Type, plan: any SchemaMigrationPlan.Type,
                            at url: URL, title: String = "Kept") throws -> WrittenLibrary {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let written = WrittenLibrary(
            book: Book(title: title, fingerprint: "fp-\(title)", fileName: "kept.pdf", pageCount: 40, fileSize: 9,
                       addedAt: Date(timeIntervalSince1970: 1_700_000_000), lastReadPageIndex: 6),
            noteID: UUID(), highlightID: UUID(), headingID: UUID())
        let date = Date(timeIntervalSince1970: 1_700_000_100)
        let swiftDataSchema = Schema(versionedSchema: schema)
        let container = try ModelContainer(for: swiftDataSchema, migrationPlan: plan,
                                           configurations: [ModelConfiguration(schema: swiftDataSchema, url: url)])
        let context = ModelContext(container)
        let bookID = written.book.id
        if ObjectIdentifier(schema) == ObjectIdentifier(MarginalSchemaV1.self) {
            context.insert(MarginalSchemaV1.BookModel(written.book))
        } else {
            context.insert(MarginalSchemaV2.BookModel(written.book))
        }
        context.insert(MarginalSchemaV1.NoteModel(id: written.noteID, bookID: bookID, targetKey: NoteTarget.page(3).storageKey,
                                                  pageIndex: 3, text: "a note", hasInk: true, bandLayoutData: nil,
                                                  createdAt: date, modifiedAt: date))
        if ObjectIdentifier(schema) == ObjectIdentifier(FutureSchema.self) {
            context.insert(FutureSchema.HighlightModel(id: written.highlightID, bookID: bookID, pageIndex: 2,
                                                       text: "scanned words", createdAt: date, textSourceRaw: "liveText"))
            context.insert(FutureSchema.ShelfModel(id: UUID(), name: "Not in this version"))
        } else {
            context.insert(MarginalSchemaV1.HighlightModel(
                id: written.highlightID, bookID: bookID, pageIndex: 2,
                rectsData: try JSONEncoder().encode([CGRect(x: 10, y: 20, width: 30, height: 12)]),
                colorRaw: HighlightColor.yellow.rawValue, text: "scanned words", createdAt: date,
                sortRank: 0, sortMaxY: 32, sortMinX: 10))
        }
        context.insert(MarginalSchemaV1.BookmarkModel(id: UUID(), bookID: bookID, pageIndex: 5, createdAt: date))
        context.insert(MarginalSchemaV1.UserHeadingModel(id: written.headingID, bookID: bookID, title: "Part One",
                                                         pageIndex: 1, parentRaw: nil, createdAt: date))
        try context.save()
        return written
    }

    /// Opens the library at `root` the way the app does and checks every record in `written`.
    private func expectLibraryHolds(_ written: WrittenLibrary, root: TempRoot) throws {
        let store = try LibraryStore.live(rootDirectory: root.url)
        let books = try store.books.allBooks()
        #expect(books.map(\.id) == [written.book.id])
        #expect(books.first?.title == written.book.title)
        #expect(books.first?.lastReadPageIndex == written.book.lastReadPageIndex)
        #expect(try store.notes.note(id: written.noteID)?.text == "a note")
        #expect(try store.highlights.highlight(id: written.highlightID)?.text == "scanned words")
        #expect(try store.bookmarks.isBookmarked(bookID: written.book.id, pageIndex: 5))
        #expect(try store.headings.userHeading(id: written.headingID)?.title == "Part One")
    }

    private func fileData(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    // MARK: Version check

    @Test func stateOfEachKindOfStore() throws {
        let root = TempRoot(); defer { root.cleanup() }
        let url = storeURL(root)
        #expect(LibraryDatabase.state(rootDirectory: root.url) == .empty)

        try writeStore(MarginalSchemaV1.self, plan: MarginalMigrationPlan.self, at: url)
        #expect(LibraryDatabase.state(rootDirectory: root.url) == .earlier)

        _ = try SchemaFactory.makeContainer(storeURL: url)
        #expect(LibraryDatabase.state(rootDirectory: root.url) == .current)

        let other = TempRoot(); defer { other.cleanup() }
        try writeStore(FutureSchema.self, plan: FuturePlan.self, at: storeURL(other))
        #expect(LibraryDatabase.state(rootDirectory: other.url) == .newer)

        let junk = TempRoot(); defer { junk.cleanup() }
        try FileManager.default.createDirectory(at: storeURL(junk).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: storeURL(junk))
        guard case .unreadable = LibraryDatabase.state(rootDirectory: junk.url) else {
            Issue.record("a file that is not a store should be unreadable")
            return
        }
    }

    // MARK: Opening

    @Test func liveLeavesANewerLibraryAlone() throws {
        let root = TempRoot(); defer { root.cleanup() }
        try writeStore(FutureSchema.self, plan: FuturePlan.self, at: storeURL(root))
        let before = fileData(storeURL(root))
        #expect(throws: ReaderStoreError.libraryFromNewerVersion) { try LibraryStore.live(rootDirectory: root.url) }
        #expect(fileData(storeURL(root)) == before)
        #expect(LibraryDatabase.copies(rootDirectory: root.url).isEmpty)
    }

    @Test func anUpdateCopiesTheLibraryBeforeMigrating() throws {
        let root = TempRoot(); defer { root.cleanup() }
        let written = try writeStore(MarginalSchemaV1.self, plan: MarginalMigrationPlan.self, at: storeURL(root))
        try expectLibraryHolds(written, root: root)
        #expect(LibraryDatabase.state(rootDirectory: root.url) == .current)

        let copies = LibraryDatabase.copies(rootDirectory: root.url)
        #expect(copies.map(\.reason) == [.beforeUpdate])
        #expect(copies.first?.state == .earlier)
        #expect(copies.first?.canBeUsed == true)
        // A copy is one file: the log is folded in. (Reading its metadata may leave a `-shm`
        // index, which SQLite ignores without a log.)
        let folder = try #require(copies.first?.folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasSuffix("-shm") }.sorted()
        #expect(names == ["Marginal.store", "copy.json"], "\(names)")

        // Opening again (already current) makes no further copy.
        try expectLibraryHolds(written, root: root)
        #expect(LibraryDatabase.copies(rootDirectory: root.url).count == 1)
    }

    // MARK: Open in this version

    @Test func aNewerLibraryOpensInThisVersionWithEveryRecord() throws {
        let root = TempRoot(); defer { root.cleanup() }
        let written = try writeStore(FutureSchema.self, plan: FuturePlan.self, at: storeURL(root))

        try LibraryDatabase.openInThisVersion(rootDirectory: root.url)

        #expect(LibraryDatabase.state(rootDirectory: root.url) == .current)
        try expectLibraryHolds(written, root: root)
        let copies = LibraryDatabase.copies(rootDirectory: root.url)
        #expect(copies.map(\.reason) == [.beforeOpeningInThisVersion])
        #expect(copies.first?.state == .newer)
        #expect(copies.first?.canBeUsed == false)
        // No scratch folder is left behind.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: LibraryDatabase.copiesDirectory(rootDirectory: root.url).path)
        #expect(entries.allSatisfy { !$0.hasPrefix(".") })
    }

    @Test func theKeptCopyOfANewerLibraryStillOpensInTheNewerVersion() throws {
        let root = TempRoot(); defer { root.cleanup() }
        try writeStore(FutureSchema.self, plan: FuturePlan.self, at: storeURL(root))
        try LibraryDatabase.openInThisVersion(rootDirectory: root.url)
        let copy = try #require(LibraryDatabase.copies(rootDirectory: root.url).first)

        let schema = Schema(versionedSchema: FutureSchema.self)
        let container = try ModelContainer(for: schema, migrationPlan: FuturePlan.self,
                                           configurations: [ModelConfiguration(schema: schema, url: copy.storeURL)])
        let highlights = try ModelContext(container).fetch(FetchDescriptor<FutureSchema.HighlightModel>())
        #expect(highlights.map(\.textSourceRaw) == ["liveText"])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<FutureSchema.ShelfModel>()) == 1)
    }

    @Test func onlyANewerLibraryIsConverted() throws {
        let root = TempRoot(); defer { root.cleanup() }
        _ = try SchemaFactory.makeContainer(storeURL: {
            try? FileManager.default.createDirectory(at: storeURL(root).deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            return storeURL(root)
        }())
        #expect(throws: ReaderStoreError.self) { try LibraryDatabase.openInThisVersion(rootDirectory: root.url) }
        #expect(LibraryDatabase.copies(rootDirectory: root.url).isEmpty)
    }

    /// The schema rule: every version converts down to the version before it, so a build can
    /// always open what the next build wrote. Add a pair here with each new version.
    @Test func everyVersionConvertsDownToTheOneBefore() throws {
        let schemas = MarginalMigrationPlan.schemas
        for (older, newer) in zip(schemas, schemas.dropFirst()) {
            let root = TempRoot(); defer { root.cleanup() }
            try writeStore(newer, plan: MarginalMigrationPlan.self, at: storeURL(root))
            let olderOnly = Array(schemas.prefix { ObjectIdentifier($0) != ObjectIdentifier(newer) })
            #expect(LibraryDatabase.state(ofStoreAt: storeURL(root), schemas: olderOnly, current: older) == .newer)

            try LibraryDatabase.convertNewerStore(rootDirectory: root.url, to: older, schemas: olderOnly)

            #expect(LibraryDatabase.state(ofStoreAt: storeURL(root), schemas: olderOnly, current: older) == .current)
            let schema = Schema(versionedSchema: older)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL(root))])
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<MarginalSchemaV1.NoteModel>()) == 1)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<MarginalSchemaV1.HighlightModel>()) == 1)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<MarginalSchemaV1.UserHeadingModel>()) == 1)
        }
    }

    // MARK: Copies

    @Test func puttingBackACopySetsTheLibraryAside() throws {
        let root = TempRoot(); defer { root.cleanup() }
        let written = try writeStore(MarginalSchemaV1.self, plan: MarginalMigrationPlan.self, at: storeURL(root))
        do {
            // Opening migrates (copy: before an update); then a book is added after the copy.
            let store = try LibraryStore.live(rootDirectory: root.url)
            try store.books.save(Book(title: "Added later", fingerprint: "later", fileName: "l.pdf", pageCount: 1, fileSize: 1))
            #expect(try store.books.allBooks().count == 2)
        }
        let copy = try #require(LibraryDatabase.copies(rootDirectory: root.url).first)

        try LibraryDatabase.putBack(copy, rootDirectory: root.url)

        // The library is the copy again: an earlier version, which the next open migrates.
        #expect(LibraryDatabase.state(rootDirectory: root.url) == .earlier)
        #expect(!FileManager.default.fileExists(atPath: storeURL(root).path + "-wal"))
        try expectLibraryHolds(written, root: root)
        // Kept: the set-aside library (with the later book), the update copy put back, and the
        // copy the reopening just made.
        let copies = LibraryDatabase.copies(rootDirectory: root.url)
        #expect(copies.map(\.reason) == [.beforeUpdate, .setAside, .beforeUpdate])
        let setAside = try #require(copies.first { $0.reason == .setAside })
        let aside = SwiftDataRecordStore(container: try SchemaFactory.makeContainer(storeURL: setAside.storeURL))
        #expect(try aside.allBooks().map(\.title).sorted() == ["Added later", "Kept"])
    }

    @Test func aCopyThisVersionCannotOpenIsRefused() throws {
        let root = TempRoot(); defer { root.cleanup() }
        try writeStore(FutureSchema.self, plan: FuturePlan.self, at: storeURL(root))
        try LibraryDatabase.openInThisVersion(rootDirectory: root.url)
        let newer = try #require(LibraryDatabase.copies(rootDirectory: root.url).first)
        let before = fileData(storeURL(root))
        #expect(throws: ReaderStoreError.copyCannotBeUsed) { try LibraryDatabase.putBack(newer, rootDirectory: root.url) }
        #expect(fileData(storeURL(root)) == before)
    }

    @Test func onlyTheNewestCopiesAreKept() throws {
        let root = TempRoot(); defer { root.cleanup() }
        try writeStore(MarginalSchemaV2.self, plan: MarginalMigrationPlan.self, at: storeURL(root))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for minute in 0..<5 {
            try LibraryDatabase.makeCopy(rootDirectory: root.url, reason: .setAside, now: start.addingTimeInterval(Double(minute) * 60))
        }
        let copies = LibraryDatabase.copies(rootDirectory: root.url)
        #expect(copies.count == LibraryDatabase.copiesKept)
        #expect(copies.map(\.date) == (2..<5).reversed().map { start.addingTimeInterval(Double($0) * 60) })
    }

    @Test func resetRemovesTheCopies() throws {
        let root = TempRoot(); defer { root.cleanup() }
        try writeStore(MarginalSchemaV1.self, plan: MarginalMigrationPlan.self, at: storeURL(root))
        _ = try LibraryStore.live(rootDirectory: root.url)
        #expect(!LibraryDatabase.copies(rootDirectory: root.url).isEmpty)
        _ = try LibraryStore.live(rootDirectory: root.url, reset: true)
        #expect(LibraryDatabase.copies(rootDirectory: root.url).isEmpty)
    }
}

/// Rows a newer version wrote with values this version has no case for, as found after Open in
/// This Version: they read as defaults or are left out, never fail the book.
@MainActor
@Suite struct NewerVersionRowTests {
    @Test func unknownValuesReadAsDefaultsAndUnknownNotesAreLeftOut() throws {
        let container = try SchemaFactory.makeContainer(storeURL: nil)
        let store = SwiftDataRecordStore(container: container)
        let book = Book(title: "B", fingerprint: "f", fileName: "b.pdf", pageCount: 10, fileSize: 1)
        try store.save(book)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let pageNoteID = UUID(), figureNoteID = UUID(), highlightID = UUID(), headingID = UUID()
        let context = ModelContext(container)
        context.insert(NoteModel(id: pageNoteID, bookID: book.id, targetKey: NoteTarget.page(1).storageKey, pageIndex: 1,
                                 text: "readable", hasInk: false, bandLayoutData: nil, createdAt: date, modifiedAt: date))
        context.insert(NoteModel(id: figureNoteID, bookID: book.id, targetKey: "figure:3", pageIndex: 3,
                                 text: "a newer kind of note", hasInk: false, bandLayoutData: nil, createdAt: date, modifiedAt: date))
        context.insert(HighlightModel(id: highlightID, bookID: book.id, pageIndex: 2, rectsData: try JSONEncoder().encode([CGRect]()),
                                      colorRaw: "ultraviolet", text: "t", createdAt: date, sortRank: 1, sortMaxY: 0, sortMinX: 0))
        context.insert(UserHeadingModel(id: headingID, bookID: book.id, title: "H", pageIndex: 4, parentRaw: "figure1/3/Figure 2",
                                        createdAt: date))
        try context.save()

        #expect(try store.notes(bookID: book.id).map(\.id) == [pageNoteID])
        #expect(try store.pageNotes(bookID: book.id, in: 0...9).map(\.id) == [pageNoteID])
        #expect(try store.note(id: figureNoteID) == nil)
        #expect(try store.highlight(id: highlightID)?.color == HighlightColor.fallback)
        #expect(try store.highlights(bookID: book.id).count == 1)
        #expect(try store.userHeading(id: headingID)?.parent == nil)

        // The unknown note stays in the database for the newer version, and is never overwritten.
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<NoteModel>()) == 2)
        #expect(throws: ReaderStoreError.self) { try store.removeNote(id: figureNoteID) }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<NoteModel>()) == 2)
    }
}
