import Foundation
import PencilKit
import ReaderBackup
import ReaderCore
import ReaderStore
import ReaderSync
import Testing
import UIKit
@testable import TactileTexts

/// Open editors as sync sees them, set by the test.
@MainActor
final class FakeSyncEditors: SyncEditorProbe {
    var busy: [UUID: SyncBusyEditors] = [:]
    private(set) var flushes = 0

    func flushForSync(store: LibraryStore) async { flushes += 1 }
    func syncBusySurfaces(bookID: UUID, store: LibraryStore) -> SyncBusyEditors { busy[bookID] ?? SyncBusyEditors() }
}

/// One device in a test: its own library (a real `LibraryStore` with its own directory), the
/// library side of sync over it, and a real `SyncEngine` on a store shared with other devices.
@MainActor
final class SyncTestDevice {
    let name: String
    let store: LibraryStore
    let editors = FakeSyncEditors()
    let core: LibrarySyncCore
    let directory: URL
    let engine: SyncEngine

    init(_ name: String, objects: any SyncObjectStore, key: BackupEncryptionKey = SyncTestSupport.key) throws {
        self.name = name
        store = try LibraryStore.ephemeral()
        core = LibrarySyncCore(store: store, editors: editors)
        directory = store.rootDirectory.appendingPathComponent("Sync/test-account", isDirectory: true)
        let encrypted = EncryptedSyncStore(store: objects, key: key,
                                           temporaryDirectory: store.rootDirectory.appendingPathComponent("tmp", isDirectory: true))
        engine = SyncEngine(store: encrypted, library: LibrarySyncSource(core: core), inkMerger: AppSyncInkMerger(),
                            directory: directory, device: SyncEngine.Device(id: UUID(), name: name))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: store.rootDirectory) }

    @discardableResult
    func sync(_ mode: SyncMode = .full) async throws -> SyncReport {
        try await engine.sync(mode: mode, joinConfirmed: true)
    }

    func importBook(_ url: URL = BackupTestSupport.small) async throws -> Book {
        try #require(try await ImportService(store: store).importPDF(at: url).book)
    }

    /// The book holding the PDF with this SHA-256.
    func book(sha256: String) -> Book? {
        LibraryPDFIndex.bookIDs(withSidecarSHA256: sha256, in: store).first.flatMap { try? store.books.book(id: $0) }
    }

    func archive(_ book: Book) throws -> BookArchive { try #require(try store.archive(bookID: book.id)) }

    func pageStrokes(_ bookID: UUID, page: Int) async throws -> [StrokeIdentity] {
        guard let data = try await store.pageInk(bookID: bookID, pageIndex: page) else { return [] }
        return try PKDrawing(data: data).strokes.map(StrokeIdentity.init)
    }
}

@MainActor
enum SyncTestSupport {
    typealias Merge = BackupMergeTestSupport

    static let key = try! BackupEncryptionKey(rawBytes: (0..<32).map { UInt8(0x5A ^ $0) })

    static func sha256(_ book: Book, in device: SyncTestDevice) -> String {
        device.store.storedContentDigest(bookID: book.id)!.sha256
    }

    /// Rounds on every device until a whole pass changes nothing, then one more round on each
    /// that must read but write nothing to the account.
    static func settle(_ devices: [SyncTestDevice], objects: InMemorySyncObjectStore, _ comment: Comment,
                       sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var quiet = false
        for _ in 0..<8 where !quiet {
            quiet = true
            for device in devices {
                let report = try await device.sync()
                for failure in report.failures {
                    Issue.record("\(comment): \(device.name) failed: \(failure.failure!.description)", sourceLocation: sourceLocation)
                }
                if report.changedAnything || report.isPending { quiet = false }
            }
        }
        #expect(quiet, "\(comment): never went quiet", sourceLocation: sourceLocation)
        objects.clearCalls()
        for device in devices {
            let report = try await device.sync()
            #expect(!report.changedAnything && !report.isPending, "\(comment): \(device.name) not quiet", sourceLocation: sourceLocation)
        }
        let writes = objects.calls.filter { [.put, .upload, .delete].contains($0.operation) }
        #expect(writes.isEmpty, "\(comment): a settled round wrote \(writes.count) objects", sourceLocation: sourceLocation)
    }

    /// The two devices hold the same books (by PDF), with the same records and the same files.
    static func expectEqual(_ a: SyncTestDevice, _ b: SyncTestDevice, _ comment: Comment,
                            sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let booksA = try a.store.books.allBooks(), booksB = try b.store.books.allBooks()
        #expect(booksA.count == booksB.count, "\(comment): book counts", sourceLocation: sourceLocation)
        for book in booksA {
            let sha = sha256(book, in: a)
            guard let other = b.book(sha256: sha) else {
                Issue.record("\(comment): \(b.name) lacks “\(book.title)”", sourceLocation: sourceLocation)
                continue
            }
            let diff = BookArchiveDiff(from: try a.archive(book), to: try b.archive(other))
            #expect(diff.isEmpty, "\(comment): records differ for “\(book.title)”: \(diff)", sourceLocation: sourceLocation)
            let filesA = try #require(try await a.core.snapshot(bookID: book.id)).files
            let filesB = try #require(try await b.core.snapshot(bookID: other.id)).files
            #expect(filesA == filesB, "\(comment): files differ for “\(book.title)”", sourceLocation: sourceLocation)
        }
    }

    // MARK: Ink

    static func stroke(_ y: CGFloat) -> PKStroke { Merge.stroke(y: y) }

    static func addPageInk(_ device: SyncTestDevice, _ bookID: UUID, page: Int, _ strokes: [PKStroke]) async throws {
        try await Merge.addPageInk(device.store, bookID, page: page, strokes)
    }

    /// The note's stored ink on `device`.
    static func noteInk(_ device: SyncTestDevice, _ note: Note) async throws -> NoteInk? {
        try await Merge.storedNoteInk(device.store, note)
    }

    /// The paragraph of `text` the stroke with `stroke`'s identity is anchored to in `ink`.
    static func paragraph(of stroke: PKStroke, in ink: NoteInk, text: String) -> String? {
        guard let placed = Merge.placed(stroke, in: ink), case .paragraph(let index) = placed.band else { return nil }
        let paragraphs = NoteBandLayout.paragraphs(of: text)
        return paragraphs.indices.contains(index) ? paragraphs[index] : nil
    }

    // MARK: A real drawing that needs a newer system

    /// A drawing whose ink needs content version 3 or later (the updated Fountain Pen of iOS
    /// 17.5), for the content-version rule.
    static func versionedStroke(_ y: CGFloat) -> PKStroke {
        let plain = stroke(y)
        return PKStroke(ink: PKInk(.fountainPen, color: .black), path: plain.path, transform: plain.transform, mask: nil)
    }
}

/// A value a test's closures share (on the main actor).
@MainActor
final class SyncTestBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
