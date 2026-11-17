import Foundation
import ReaderCore
import Testing
@testable import TactileTexts

/// The app's marked-up PDF exports (`MarkedUpExportLibrary`, `MarkedUpExportArchive`): finished
/// files are kept until the user deletes them, nothing implicit removes them (leaving the book,
/// sharing, putting away the reader's notice, a relaunch), and cancelling keeps nothing.
@Suite(.serialized)
@MainActor
struct MarkedUpExportLibraryTests {
    private static func makeArchive() -> MarkedUpExportArchive {
        MarkedUpExportArchive(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkedUpExportLibraryTests-\(UUID().uuidString)", isDirectory: true))
    }

    private static func waitUntilEnded(_ library: MarkedUpExportLibrary, _ id: UUID) async throws {
        for _ in 0..<600 where library.record(id)?.isRunning == true {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(library.record(id)?.isRunning != true, "the export ended")
    }

    @Test func aFinishedExportIsKeptAfterSharingHidingAndRelaunching() async throws {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("small.pdf"), pageCount: 12)
        defer { NotebookTestSupport.cleanUp(store) }
        let archive = Self.makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.root) }
        let library = MarkedUpExportLibrary(archive: archive)
        library.isApplicationActive = { true }
        let window = UUID()

        let id = try #require(library.start(book: book, store: store, includeNotes: false, cardOwner: window))
        #expect(library.isRunning(bookID: book.id))
        #expect(library.start(book: book, store: store, includeNotes: false, cardOwner: window) == nil,
                "one running export per book")
        try await Self.waitUntilEnded(library, id)

        let record = try #require(library.record(id))
        #expect(record.isFinished)
        #expect(record.fileName == "Ink (Marked Up).pdf")
        let file = library.fileURL(for: record)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect((record.byteCount ?? 0) > 0)
        // Finished in front of the user, in the window showing its card: that window shares it.
        #expect(library.shareRequests[window] == id)
        #expect(record.acknowledged)

        // Closing the share sheet, closing the window and hiding the notice keep the file.
        library.shareDidFinish(in: window)
        library.readerClosed(window)
        library.acknowledge(id)
        #expect(FileManager.default.fileExists(atPath: file.path))

        // A relaunch finds it again.
        let relaunched = MarkedUpExportLibrary(archive: archive)
        #expect(relaunched.records(for: book.id).map(\.id) == [id])
        #expect(relaunched.record(id)?.isFinished == true)

        // Only Delete removes it.
        relaunched.delete(id)
        #expect(relaunched.records(for: book.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(MarkedUpExportLibrary(archive: archive).records.isEmpty)
    }

    @Test func anExportKeepsRunningWhenItsReaderClosesAndIsLeftForTheUser() async throws {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("small.pdf"), pageCount: 12)
        defer { NotebookTestSupport.cleanUp(store) }
        let archive = Self.makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.root) }
        let library = MarkedUpExportLibrary(archive: archive)
        library.isApplicationActive = { true }
        let window = UUID()

        let id = try #require(library.start(book: book, store: store, includeNotes: false, cardOwner: window))
        library.readerClosed(window)
        #expect(library.cardOwners[id] == nil)
        try await Self.waitUntilEnded(library, id)

        let record = try #require(library.record(id))
        #expect(record.isFinished, "closing the reader did not stop it")
        #expect(!record.acknowledged, "ended out of sight: the reader shows it until the user sees it")
        #expect(library.notice(for: book.id)?.id == id)
        #expect(library.shareRequests.isEmpty)
        library.acknowledge(id)
        #expect(library.notice(for: book.id) == nil)
        #expect(library.records(for: book.id).count == 1, "still listed in the Notebook")
    }

    @Test func cancellingKeepsNothing() async throws {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("small.pdf"), pageCount: 12)
        defer { NotebookTestSupport.cleanUp(store) }
        let archive = Self.makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.root) }
        let library = MarkedUpExportLibrary(archive: archive)

        let id = try #require(library.start(book: book, store: store, includeNotes: false, cardOwner: nil))
        library.cancel(id)
        for _ in 0..<600 where library.record(id) != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(library.record(id) == nil)
        #expect(!FileManager.default.fileExists(atPath: archive.directory(for: id).path))
    }

    @Test func deletingTheBookDeletesItsExportsOnly() throws {
        let archive = Self.makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.root) }
        let mine = UUID(), other = UUID()
        for (bookID, name) in [(mine, "A"), (mine, "B"), (other, "C")] {
            let record = MarkedUpExportRecord(id: UUID(), bookID: bookID, bookTitle: name, includesNotes: false,
                                              fileName: "\(name).pdf", startedAt: Date(), status: .finished(byteCount: 3))
            try archive.save(record)
            try Data("pdf".utf8).write(to: archive.fileURL(for: record))
        }
        let library = MarkedUpExportLibrary(archive: archive)
        #expect(library.records.count == 3)
        library.deleteAll(bookID: mine)
        #expect(library.records.map(\.bookTitle) == ["C"])
        #expect(MarkedUpExportLibrary(archive: archive).records.map(\.bookTitle) == ["C"])
    }

    @Test func anExportCutShortByQuittingIsListedAsUnfinished() throws {
        let archive = Self.makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.root) }
        let running = MarkedUpExportRecord(id: UUID(), bookID: UUID(), bookTitle: "T", includesNotes: true,
                                           fileName: "T (Marked Up with Notes).pdf", startedAt: Date(), status: .running)
        try archive.save(running)
        // The exporter's partial file, in its work folder.
        let work = archive.directory(for: running.id).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: work.appendingPathComponent(running.fileName))
        // A finished export whose file is gone.
        let lost = MarkedUpExportRecord(id: UUID(), bookID: UUID(), bookTitle: "L", includesNotes: false,
                                        fileName: "L.pdf", startedAt: Date(), status: .finished(byteCount: 1))
        try archive.save(lost)

        let records = archive.load()
        #expect(records.map(\.id) == [running.id])
        #expect(records.first?.unfinishedReason == MarkedUpExportArchive.reasonAppClosed)
        #expect(records.first?.acknowledged == false)
        #expect(!FileManager.default.fileExists(atPath: work.path), "the partial file is removed")
        #expect(archive.load().first?.unfinishedReason == MarkedUpExportArchive.reasonAppClosed, "saved as unfinished")
    }
}
