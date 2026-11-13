import Foundation
import SwiftData
import ReaderCore

// The SwiftData schema. Everything here is iOS 17 / macOS 14 API: no `#Unique`, no `#Index`.
//
// Design notes (see the repository for behaviour):
// - Child records carry a plain `bookID` column instead of a relationship. Per-book queries are
//   one predicate, and deleting a book is a handful of predicate batch deletes in one transaction.
// - "One note per (book, target)" and "one bookmark per (book, page)" are enforced by the
//   repository checking before it writes. `compositeKey` is `@Attribute(.unique)` as a backstop
//   and as the lookup index for `note(bookID:target:)`; the repository never inserts a row that
//   would collide, so SwiftData's silent upsert-on-conflict is never exercised.
// - Models are internal. Value types from ReaderCore are the only thing that crosses the boundary.

/// Version 1 of the on-disk schema.
enum MarginalSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [BookModel.self, NoteModel.self, HighlightModel.self, BookmarkModel.self, UserHeadingModel.self]
    }

    @Model
    final class BookModel {
        @Attribute(.unique) var id: UUID
        var title: String
        var fingerprint: String
        var fileName: String
        var pageCount: Int
        var fileSize: Int64
        var addedAt: Date
        var lastOpenedAt: Date?
        var lastReadPageIndex: Int

        init(_ book: Book) {
            id = book.id
            title = book.title
            fingerprint = book.fingerprint
            fileName = book.fileName
            pageCount = book.pageCount
            fileSize = book.fileSize
            addedAt = book.addedAt
            lastOpenedAt = book.lastOpenedAt
            lastReadPageIndex = book.lastReadPageIndex
        }
    }

    @Model
    final class NoteModel {
        @Attribute(.unique) var id: UUID
        var bookID: UUID
        /// `NoteTarget.storageKey`.
        var targetKey: String
        /// Page index of a page note, `nil` for a heading note (drives `pageNotes(bookID:in:)`).
        var pageIndex: Int?
        /// `"<bookID>|<targetKey>"`, unique.
        @Attribute(.unique) var compositeKey: String
        var text: String
        var hasInk: Bool
        /// JSON of `NoteBandLayout`, `nil` when there is none.
        var bandLayoutData: Data?
        var createdAt: Date
        var modifiedAt: Date

        init(id: UUID, bookID: UUID, targetKey: String, pageIndex: Int?, text: String, hasInk: Bool,
             bandLayoutData: Data?, createdAt: Date, modifiedAt: Date) {
            self.id = id
            self.bookID = bookID
            self.targetKey = targetKey
            self.pageIndex = pageIndex
            self.compositeKey = NoteModel.compositeKey(bookID: bookID, targetKey: targetKey)
            self.text = text
            self.hasInk = hasInk
            self.bandLayoutData = bandLayoutData
            self.createdAt = createdAt
            self.modifiedAt = modifiedAt
        }

        static func compositeKey(bookID: UUID, targetKey: String) -> String {
            "\(bookID.uuidString)|\(targetKey)"
        }
    }

    @Model
    final class HighlightModel {
        @Attribute(.unique) var id: UUID
        var bookID: UUID
        var pageIndex: Int
        /// JSON of `[CGRect]`.
        var rectsData: Data
        /// `HighlightColor.rawValue`.
        var colorRaw: String
        var text: String
        var createdAt: Date
        // Denormalised `Highlight.readingOrder` keys so the database can sort: `sortRank` is 0
        // when the highlight has rects (sorts first) and 1 when it has none.
        var sortRank: Int
        var sortMaxY: Double
        var sortMinX: Double
        var idString: String

        init(id: UUID, bookID: UUID, pageIndex: Int, rectsData: Data, colorRaw: String, text: String,
             createdAt: Date, sortRank: Int, sortMaxY: Double, sortMinX: Double) {
            self.id = id
            self.bookID = bookID
            self.pageIndex = pageIndex
            self.rectsData = rectsData
            self.colorRaw = colorRaw
            self.text = text
            self.createdAt = createdAt
            self.sortRank = sortRank
            self.sortMaxY = sortMaxY
            self.sortMinX = sortMinX
            self.idString = id.uuidString
        }
    }

    @Model
    final class BookmarkModel {
        @Attribute(.unique) var id: UUID
        var bookID: UUID
        var pageIndex: Int
        /// `"<bookID>|<pageIndex>"`, unique.
        @Attribute(.unique) var compositeKey: String
        var createdAt: Date

        init(id: UUID, bookID: UUID, pageIndex: Int, createdAt: Date) {
            self.id = id
            self.bookID = bookID
            self.pageIndex = pageIndex
            self.compositeKey = BookmarkModel.compositeKey(bookID: bookID, pageIndex: pageIndex)
            self.createdAt = createdAt
        }

        static func compositeKey(bookID: UUID, pageIndex: Int) -> String {
            "\(bookID.uuidString)|\(pageIndex)"
        }
    }

    @Model
    final class UserHeadingModel {
        @Attribute(.unique) var id: UUID
        var bookID: UUID
        var title: String
        var pageIndex: Int
        /// `HeadingAnchor.rawValue` of the parent, `nil` for top level.
        var parentRaw: String?
        var createdAt: Date

        init(id: UUID, bookID: UUID, title: String, pageIndex: Int, parentRaw: String?, createdAt: Date) {
            self.id = id
            self.bookID = bookID
            self.title = title
            self.pageIndex = pageIndex
            self.parentRaw = parentRaw
            self.createdAt = createdAt
        }
    }
}

typealias BookModel = MarginalSchemaV1.BookModel
typealias NoteModel = MarginalSchemaV1.NoteModel
typealias HighlightModel = MarginalSchemaV1.HighlightModel
typealias BookmarkModel = MarginalSchemaV1.BookmarkModel
typealias UserHeadingModel = MarginalSchemaV1.UserHeadingModel

/// Migration plan: one version so far. Add a `VersionedSchema` and a stage here for the next change.
enum MarginalMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MarginalSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// Errors specific to this store (the contract's errors are `RepositoryError`).
public enum ReaderStoreError: Error, Hashable, Sendable {
    /// A stored row could not be turned back into its value type.
    case corruptRecord(String)
    /// The store files could not be reset or the directory prepared.
    case resetFailed(String)
}

enum SchemaFactory {
    static var schema: Schema { Schema(versionedSchema: MarginalSchemaV1.self) }

    /// A container for the store file at `storeURL`, or in memory when `nil`.
    static func makeContainer(storeURL: URL?) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(schema: schema, url: storeURL)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        return try ModelContainer(for: schema, migrationPlan: MarginalMigrationPlan.self, configurations: [configuration])
    }
}
