import Foundation
import PencilKit
import ReaderBackup
import ReaderCore
import ReaderStore
import ReaderSync
import Testing
import UIKit
@testable import TactileTexts

/// One book per PDF (owner decision 8, 17 November 2026): every road that adds a book checks the
/// PDF's full SHA-256 as well as the fingerprint and goes to the book that already holds it, and
/// a library that already holds two books with one PDF has them merged at launch.
@MainActor
@Suite(.serialized)
struct OneBookPerPDFTests {
    typealias Support = BackupTestSupport
    typealias Merge = BackupMergeTestSupport
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static var epub: URL { repo.appendingPathComponent("Tests/Fixtures/f3-small.epub") }

    /// A converter whose PDF is a copy of `pdf`.
    struct CopyingConverter: DocumentConverter {
        var version = 1
        var formats: Set<ImportFormat> = Set(ImportFormat.allCases.filter(\.isConverted))
        let pdf: URL

        func convert(_ input: ConversionInput, progress: @escaping @Sendable (Double) -> Void) async throws -> ConvertedDocument {
            try FileManager.default.copyItem(at: pdf, to: input.outputURL)
            progress(1)
            return ConvertedDocument(pdf: input.outputURL, pageCount: 1, title: nil, coverImage: nil)
        }
    }

    private func stubs() -> ConverterRegistry {
        var stub = StubDocumentConverter()
        stub.formats = Set(ImportFormat.allCases.filter(\.isConverted))
        return ConverterRegistry([stub])
    }

    private func copy(_ url: URL, to directory: URL, as name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    /// A converted book (the stub converter's PDF), its generated PDF copied to `scratch`.
    private func convertedBook(_ store: LibraryStore, scratch: URL) async throws -> (Book, URL) {
        let service = ImportService(store: store, converters: stubs())
        let book = try #require(try await service.importPDF(at: Self.epub, convertWithoutAsking: ConversionOptions()).book)
        #expect(book.isConverted)
        #expect(store.storedContentDigest(bookID: book.id) != nil, "a conversion records its PDF's hash")
        return (book, try copy(store.documentURL(for: book), to: scratch, as: "generated.pdf"))
    }

    // MARK: Import

    @Test func importingAConvertedBooksGeneratedPDFGoesToThatBook() async throws {
        let store = try LibraryStore.ephemeral()
        let scratch = try Support.scratch("OnePDF")
        defer { try? FileManager.default.removeItem(at: store.rootDirectory); try? FileManager.default.removeItem(at: scratch) }
        let (converted, generated) = try await convertedBook(store, scratch: scratch)
        let outcome = try await ImportService(store: store).importPDF(at: generated)
        #expect(outcome == .existing(converted))
        #expect(try store.books.allBooks().count == 1)

        // With the PDF gone from disk, the same file supplies it.
        try FileManager.default.removeItem(at: store.documentURL(for: converted))
        #expect(try await ImportService(store: store).importPDF(at: generated) == .existing(converted))
        #expect(store.hasDocument(converted))
        #expect(try store.books.allBooks().count == 1)
    }

    @Test func aPlainImportRecordsItsHash() async throws {
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let book = try #require(try await ImportService(store: store).importPDF(at: Support.small).book)
        let digest = try ContentHash.digest(ofFileAt: Support.small)
        #expect(store.storedContentDigest(bookID: book.id) == digest)
    }

    @Test func aConversionThatMakesAPDFAlreadyInTheLibraryGoesToThatBook() async throws {
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let plain = try #require(try await ImportService(store: store).importPDF(at: Support.small).book)
        let service = ImportService(store: store, converters: ConverterRegistry([CopyingConverter(pdf: Support.small)]))
        let outcome = try await service.importPDF(at: Self.epub, convertWithoutAsking: ConversionOptions())
        #expect(outcome == .existing(plain))
        #expect(try store.books.allBooks().count == 1)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: service.stagingRoot.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    // MARK: Restore

    @Test func restoringABookWhosePDFIsAlreadyHereGoesToThatBook() async throws {
        let here = try LibraryStore.ephemeral()
        let there = try LibraryStore.ephemeral()
        let scratch = try Support.scratch("OnePDFRestore")
        defer { for url in [here.rootDirectory, there.rootDirectory, scratch] { try? FileManager.default.removeItem(at: url) } }
        let (converted, generated) = try await convertedBook(here, scratch: scratch)
        // Elsewhere, the generated PDF was imported as a PDF (a different fingerprint), with a note.
        let direct = try #require(try await ImportService(store: there).importPDF(at: generated).book)
        #expect(direct.fingerprint != converted.fingerprint)
        try there.notes.save(Note(bookID: direct.id, target: .page(0), text: "From the backup", createdAt: Date(timeIntervalSinceReferenceDate: 1)))
        let backup = try await Support.makeService(there, scratch: scratch).backUpToFile(includePDFs: false).url

        let service = Support.makeService(here, scratch: scratch)
        let session = try await service.openBackup(at: backup)
        defer { session.close() }
        let item = try #require(session.plan.items.first)
        #expect(item.status == .inLibrary)
        #expect(item.replacedBookIDs == [converted.id])
        _ = try await service.restore([item.id: item.defaultAction], from: session, restorePDFs: false)
        let books = try here.books.allBooks()
        #expect(books.map(\.id) == [converted.id], "merged into the book holding the PDF")
        #expect(try here.notes.notes(bookID: converted.id).map(\.text) == ["From the backup"])
    }

    // MARK: Locate PDF

    @Test func locatePDFRefusesAPDFAnotherBookHolds() async throws {
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        _ = try #require(try await ImportService(store: store).importPDF(at: Support.small).book)
        // A book without its PDF that names the same PDF (only a library from before this rule
        // could hold one).
        let digest = try ContentHash.digest(ofFileAt: Support.small)
        let orphan = Book(title: "Orphan", fingerprint: try BookFingerprint.fingerprint(ofFileAt: Support.small) + "-old",
                          fileName: "small.pdf", pageCount: 1, fileSize: digest.size)
        try store.books.save(orphan)
        try FileManager.default.createDirectory(at: store.bookDirectoryURL(bookID: orphan.id), withIntermediateDirectories: true)
        try DocumentDigest.writeSidecar(digest, to: store.contentHashURL(bookID: orphan.id))
        var linkable = orphan
        linkable.fingerprint = try BookFingerprint.fingerprint(ofFileAt: Support.small)
        try store.books.save(linkable)
        await #expect(throws: ImportError.pdfInAnotherBook(bookTitle: "Orphan", otherTitle: "small")) {
            try await ImportService(store: store).linkPDF(at: Support.small, to: linkable)
        }
        #expect(!store.hasDocument(linkable))
    }

    // MARK: Sync

    @Test func aBookFromSyncWhosePDFIsAlreadyHereIsNotMadeAgain() async throws {
        let device = try SyncTestDevice("A", objects: InMemorySyncObjectStore())
        defer { device.cleanUp() }
        let book = try await device.importBook()
        let digest = try #require(device.store.storedContentDigest(bookID: book.id))
        var arriving = book
        arriving.id = UUID()
        arriving.fingerprint = "another-fingerprint"
        let new = SyncNewBook(archive: BookArchive(book: arriving), info: SyncBookInfo(title: "x", pageCount: 1, fingerprint: "x"),
                              pdf: digest, files: [:])
        await #expect(throws: SyncLibraryError.changedSinceSnapshot(bookID: arriving.id)) {
            try await device.core.createBook(new)
        }
        #expect(try device.store.books.allBooks().map(\.id) == [book.id])
    }

    @Test func aBookFromSyncIsMadeWithoutItsPDFAndItsHash() async throws {
        let device = try SyncTestDevice("A", objects: InMemorySyncObjectStore())
        defer { device.cleanUp() }
        let digest = ContentDigest(sha256: String(repeating: "c", count: 64), size: 1234)
        let book = Book(title: "From the account", fingerprint: "fp", fileName: "../escape.pdf", pageCount: 9, fileSize: 1234)
        let note = Note(bookID: book.id, target: .page(1), text: "Synced", createdAt: Date(timeIntervalSinceReferenceDate: 1))
        try await device.core.createBook(SyncNewBook(archive: BookArchive(book: book, notes: [note]),
                                                     info: SyncBookInfo(title: book.title, pageCount: 9, fingerprint: "fp"),
                                                     pdf: digest, files: [.pageInk(2): PKDrawing(strokes: [SyncTestSupport.stroke(40)]).dataRepresentation()]))
        let made = try #require(try device.store.books.book(id: book.id))
        #expect(!made.fileName.contains("/"))
        #expect(!device.store.hasDocument(made), "the existing PDF missing state")
        #expect(device.store.storedContentDigest(bookID: book.id) == digest)
        #expect(try device.store.notes.notes(bookID: book.id).map(\.text) == ["Synced"])
        #expect(try await device.pageStrokes(book.id, page: 2).count == 1)
    }

    // MARK: Two books with one PDF, merged at launch

    struct Duplicates {
        let store: LibraryStore
        let older: Book
        let newer: Book
        let strokes: [String: PKStroke]
    }

    /// The converted book from `f3-small.epub` (older) and, as a library from before this rule
    /// could hold, its generated PDF imported directly (newer, no hash recorded), each with notes,
    /// ink, a highlight and a bookmark.
    private func duplicates(scratch: URL) async throws -> Duplicates {
        let store = try LibraryStore.ephemeral()
        let (older, generated) = try await convertedBook(store, scratch: scratch)
        var newer = Book(title: "Direct", fingerprint: try BookFingerprint.fingerprint(ofFileAt: generated), fileName: "generated.pdf",
                         pageCount: older.pageCount, fileSize: 1, addedAt: older.addedAt.addingTimeInterval(60))
        newer.lastReadPageIndex = 2
        try store.books.save(newer)
        _ = try copy(generated, to: store.bookDirectoryURL(bookID: newer.id), as: "generated.pdf")
        var strokes: [String: PKStroke] = [:]
        strokes["older-note"] = try await Merge.writeNote(store, older.id, target: .page(1), text: "From the conversion", strokesOver: [0])[0]
        strokes["newer-note"] = try await Merge.writeNote(store, newer.id, target: .page(1), text: "From the copy", strokesOver: [0])[0]
        try await Merge.writeNote(store, newer.id, target: .page(2), text: "Only on the copy")
        strokes["older-page"] = Merge.stroke(y: 40)
        strokes["newer-page"] = Merge.stroke(y: 90)
        try await Merge.savePageInk(store, older.id, page: 0, [strokes["older-page"]!])
        try await Merge.savePageInk(store, newer.id, page: 0, [strokes["newer-page"]!])
        try store.highlights.save(Highlight(bookID: newer.id, pageIndex: 1, rects: [CGRect(x: 1, y: 2, width: 30, height: 10)],
                                            color: .green, text: "copy", createdAt: Date(timeIntervalSinceReferenceDate: 1)))
        try store.bookmarks.setBookmarked(true, bookID: newer.id, pageIndex: 2)
        try store.headings.save(UserHeading(bookID: newer.id, title: "Copy heading", pageIndex: 1, parent: nil,
                                            createdAt: Date(timeIntervalSinceReferenceDate: 1)))
        return Duplicates(store: store, older: older, newer: newer, strokes: strokes)
    }

    private func expectMerged(_ d: Duplicates, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let store = d.store
        #expect(try store.books.allBooks().map(\.id) == [d.older.id], "the older book's ID is kept", sourceLocation: sourceLocation)
        let archive = try #require(try store.archive(bookID: d.older.id))
        #expect(archive.book.title == d.older.title && archive.book.lastReadPageIndex == d.older.lastReadPageIndex,
                sourceLocation: sourceLocation)
        let page1 = try #require(archive.notes.first { $0.target == .page(1) })
        #expect(NoteBandLayout.paragraphs(of: page1.text).sorted() == ["From the conversion", "From the copy"], sourceLocation: sourceLocation)
        #expect(archive.notes.contains { $0.text == "Only on the copy" }, sourceLocation: sourceLocation)
        let ink = try #require(try await Merge.storedNoteInk(store, page1), sourceLocation: sourceLocation)
        for name in ["older-note", "newer-note"] {
            #expect(Merge.count(of: d.strokes[name]!, in: ink.strokes.map(\.local)) == 1, "\(name)", sourceLocation: sourceLocation)
        }
        #expect(SyncTestSupport.paragraph(of: d.strokes["newer-note"]!, in: ink, text: page1.text) == "From the copy",
                sourceLocation: sourceLocation)
        let page0 = try #require(try await Merge.pageDrawing(store, d.older.id, page: 0), sourceLocation: sourceLocation)
        #expect(Set(page0.strokes.map(StrokeIdentity.init)) == [StrokeIdentity(d.strokes["older-page"]!), StrokeIdentity(d.strokes["newer-page"]!)],
                sourceLocation: sourceLocation)
        #expect(archive.highlights.map(\.text) == ["copy"], sourceLocation: sourceLocation)
        #expect(archive.bookmarks.map(\.pageIndex) == [2], sourceLocation: sourceLocation)
        #expect(archive.userHeadings.map(\.title) == ["Copy heading"], sourceLocation: sourceLocation)
        #expect(store.hasDocument(archive.book), sourceLocation: sourceLocation)
    }

    @Test func twoBooksWithOnePDFAreMergedIntoTheOlderAtLaunch() async throws {
        let scratch = try Support.scratch("OnePDFMerge")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let d = try await duplicates(scratch: scratch)
        defer { try? FileManager.default.removeItem(at: d.store.rootDirectory) }
        var events: [StoreChangeEvent] = []
        let window = d.store.hub.observe { events.append($0) }
        let origin = ChangeOrigin(label: "test merge")
        let outcome = await LibraryDuplicateMerge.run(store: d.store, origin: origin)
        _ = window
        #expect(outcome.merged == [.init(kept: d.older.id, absorbed: d.newer.id)])
        try await expectMerged(d)
        #expect(events.contains { $0.change == .bookDeleted(bookID: d.newer.id) }, "windows on the newer book close")
        #expect(!events.contains { $0.change == .bookDeleted(bookID: d.older.id) }, "windows on the older book stay open")

        // Again (the next launch): nothing to do, nothing changes.
        let before = try d.store.archive(bookID: d.older.id)
        #expect(await LibraryDuplicateMerge.run(store: d.store, origin: origin).merged.isEmpty)
        #expect(try d.store.archive(bookID: d.older.id) == before)
    }

    @Test func aMergeCutOffBeforeTheNewerBookWentIsFinishedNextLaunch() async throws {
        let scratch = try Support.scratch("OnePDFMergeCrash")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let d = try await duplicates(scratch: scratch)
        defer { try? FileManager.default.removeItem(at: d.store.rootDirectory) }
        let origin = ChangeOrigin(label: "test merge")
        try await LibraryDuplicateMerge.merge(d.newer.id, into: d.older.id, store: d.store, origin: origin, stopBeforeDeleting: true)
        #expect(try d.store.books.allBooks().count == 2, "cut off before the delete")
        // The next launch finds the pair again and finishes, adding nothing twice.
        let outcome = await LibraryDuplicateMerge.run(store: d.store, origin: origin)
        #expect(outcome.merged.count == 1)
        try await expectMerged(d)
    }
}
