import Foundation
import ReaderBackup
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import TactileTexts

/// S4 · Backups and scanned books, end to end in the app:
/// - a scanned-page highlight's source survives backup, restore into a new library, merge and
///   replace;
/// - recognised text and the recognition state are in no backup (file, folder destination, the
///   safety copy kept for Undo Last Restore, the size estimate), a book restored fresh has none,
///   and a merge or replace of a book on this iPad keeps them (the PDF is the same one), also
///   through Undo Last Restore and an interrupted commit finished at launch.
@Suite(.serialized)
@MainActor
struct ScannedHighlightBackupTests {
    typealias Support = BackupTestSupport

    /// `scanned.pdf` imported through the real pipeline, with a scanned-page highlight, a typed
    /// one, two recognised pages and a recognition state.
    private struct Library {
        var store: LibraryStore
        var book: Book
        var scanned: Highlight
        var typed: Highlight
    }

    private static let state = RecognitionState.inProgress(RecognitionProgress(pagesDone: 2, totalPages: 29))

    private func makeLibrary(_ store: LibraryStore, recognised: Bool = true) async throws -> Library {
        let book = try #require(try await ImportService(store: store).importPDF(at: ScannedHighlightTestSupport.scannedPDF).book)
        let scanned = ScannedHighlightTestSupport.phraseHighlight(book)
        let typed = Highlight(bookID: book.id, pageIndex: 0, rects: [CGRect(x: 72, y: 600, width: 200, height: 20)],
                              color: .green, text: "The Scanned Fixture Book",
                              createdAt: Date(timeIntervalSinceReferenceDate: 800_000_100))
        try store.highlights.save(scanned)
        try store.highlights.save(typed)
        if recognised { try await recognise(store, book.id) }
        return Library(store: store, book: book, scanned: scanned, typed: typed)
    }

    private func recognise(_ store: LibraryStore, _ bookID: UUID, pages: [Int] = [15, 16]) async throws {
        for page in pages {
            let line: [RecognisedPage.Token] = [.init(text: "The", bounds: CGRect(x: 72, y: 693, width: 20, height: 12)),
                                                 .init(text: "quiet", bounds: CGRect(x: 95, y: 693, width: 25, height: 12)),
                                                 .init(text: "heron \(page)", bounds: CGRect(x: 123, y: 693, width: 40, height: 12))]
            try await store.saveRecognisedPage(RecognisedPage(pageIndex: page, lines: [line]), bookID: bookID, origin: nil)
        }
        try await store.saveRecognitionState(Self.state, bookID: bookID, origin: nil)
    }

    /// The book's recognised text and state as files (relative path → bytes).
    private func recognitionFiles(_ store: LibraryStore, _ bookID: UUID) -> [String: Data] {
        Support.files(in: store.bookDirectoryURL(bookID: bookID)).filter { BackupDerivedFiles.isDerived(relativePath: $0.key) }
    }

    private func derivedPaths(in manifest: BackupManifest) -> [String] {
        manifest.books.flatMap(\.files).map(\.path).filter { BackupDerivedFiles.isDerived(relativePath: $0) }
    }

    // MARK: The source field

    @Test func theSourceSurvivesBackupAndRestoreIntoANewLibrary() async throws {
        let scratch = try Support.scratch("ScannedHighlightBackup")
        let source = try LibraryStore.ephemeral()
        let target = try LibraryStore.ephemeral()
        defer { for url in [scratch, source.rootDirectory, target.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let library = try await makeLibrary(source)

        let backup = try await Support.makeService(source, scratch: scratch).backUpToFile(includePDFs: true).url
        // In the archive's records.
        let reader = try BackupArchiveReader(url: backup)
        let archived = try reader.bookArchive(for: library.book.id)
        #expect(archived.highlights.first { $0.id == library.scanned.id }?.textSource == .liveText)
        #expect(archived.highlights.first { $0.id == library.typed.id }?.textSource == nil)

        let service = Support.makeService(target, scratch: scratch)
        let session = try await service.openBackup(at: backup)
        let summary = try await service.restore(Set(session.plan.items.map(\.id)), from: session, restorePDFs: true)
        session.close()
        #expect(summary.failures.isEmpty)
        #expect(try target.highlights.highlight(id: library.scanned.id)?.textSource == .liveText)
        #expect(try target.highlights.highlight(id: library.scanned.id)?.isOnScannedPage == true)
        #expect(try target.highlights.highlight(id: library.typed.id)?.textSource == nil)
        #expect(try Support.archive(target, library.book.id) == (try Support.archive(source, library.book.id)))
        // A book restored onto another iPad has no recognised text and no state.
        #expect(recognitionFiles(target, library.book.id).isEmpty)
        #expect(try await target.recognitionState(bookID: library.book.id) == nil)
        #expect(try await target.recognisedPageIndices(bookID: library.book.id).isEmpty)
    }

    @Test func mergeAddsAScannedPageHighlightWithItsSource() async throws {
        let scratch = try Support.scratch("ScannedHighlightMerge")
        let store = try LibraryStore.ephemeral()
        defer { for url in [scratch, store.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let library = try await makeLibrary(store)
        let service = Support.makeService(store, scratch: scratch)
        let backup = try await service.backUpToFile(includePDFs: false).url
        // Gone here after the backup; the merge brings it back with its source.
        try store.highlights.deleteHighlight(id: library.scanned.id)
        let recognisedBefore = recognitionFiles(store, library.book.id)
        #expect(recognisedBefore.count == 3)

        let session = try await service.openBackup(at: backup)
        let summary = try await service.restore([library.book.id: .merge], from: session, restorePDFs: true)
        session.close()
        #expect(summary.failures.isEmpty)
        #expect(try store.highlights.highlight(id: library.scanned.id)?.textSource == .liveText)
        #expect(try store.highlights.highlights(bookID: library.book.id).count == 2)
        // The merged book keeps its recognised text and state: the PDF is the same one.
        #expect(recognitionFiles(store, library.book.id) == recognisedBefore)
        #expect(try await store.recognitionState(bookID: library.book.id) == Self.state)
    }

    // MARK: Recognised text is in no backup

    @Test func recognisedTextIsInNoBackup() async throws {
        let scratch = try Support.scratch("ScannedHighlightNoText")
        let store = try LibraryStore.ephemeral()
        defer { for url in [scratch, store.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let library = try await makeLibrary(store, recognised: false)
        let service = Support.makeService(store, scratch: scratch)
        let estimateBefore = try await service.estimateSizes()
        try await recognise(store, library.book.id, pages: Array(1..<30))
        #expect(recognitionFiles(store, library.book.id).count == 30)
        // The estimate does not count it.
        #expect(try await service.estimateSizes() == estimateBefore)

        // A single file, with and without PDFs.
        for includePDFs in [false, true] {
            let file = try await service.backUpToFile(includePDFs: includePDFs).url
            let manifest = try BackupArchiveReader(url: file).manifest
            #expect(derivedPaths(in: manifest).isEmpty, "includePDFs \(includePDFs)")
            #expect(manifest.books.map(\.book.id) == [library.book.id])
        }

        // A folder-like destination.
        let folder = FolderBackupDestination(root: scratch.appendingPathComponent("Folder", isDirectory: true))
        try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        _ = try await service.backUp(to: folder, includePDFs: true)
        let snapshot = try #require(try await folder.listSnapshots().first)
        let downloaded = scratch.appendingPathComponent("downloaded.ttbackup")
        try await folder.downloadSnapshot(snapshot, to: downloaded, progress: nil)
        #expect(derivedPaths(in: try BackupArchiveReader(url: downloaded).manifest).isEmpty)

        // The safety copy a restore keeps for Undo Last Restore (decided: like any backup, it
        // leaves recognised text out; an undo keeps the book's own, see below).
        let session = try await service.openBackup(at: downloaded)
        _ = try await service.restore([library.book.id: .replace], from: session, restorePDFs: false)
        session.close()
        let record = try #require(service.latestRestoreSafetyRecord())
        let safety = try BackupArchiveReader(url: RestoreSafetyStore.archiveURL(id: record.id, storeRoot: store.rootDirectory))
        #expect(safety.manifest.books.map(\.book.id) == [library.book.id])
        #expect(derivedPaths(in: safety.manifest).isEmpty)
        // …and the replace kept this iPad's recognised text.
        #expect(recognitionFiles(store, library.book.id).count == 30)
    }

    // MARK: A merge or replace on this iPad keeps it

    @Test func replaceOnThisIPadKeepsRecognisedTextWhateverThePDFSource() async throws {
        for includePDFs in [true, false] {
            let scratch = try Support.scratch("ScannedHighlightReplace")
            let store = try LibraryStore.ephemeral()
            defer { for url in [scratch, store.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
            let library = try await makeLibrary(store)
            let service = Support.makeService(store, scratch: scratch)
            let backup = try await service.backUpToFile(includePDFs: includePDFs).url
            // Recognition went on after the backup.
            try await recognise(store, library.book.id, pages: [15, 16, 17])
            try store.highlights.deleteHighlight(id: library.scanned.id)
            let before = recognitionFiles(store, library.book.id)
            #expect(before.count == 4)

            let session = try await service.openBackup(at: backup)
            // Embedded and restored: the PDF comes from the archive (same hash); otherwise this
            // iPad's PDF is reused.
            let summary = try await service.restore([library.book.id: .replace], from: session, restorePDFs: true)
            session.close()
            #expect(summary.failures.isEmpty, "includePDFs \(includePDFs)")
            #expect(summary.restored.map(\.id) == [library.book.id])
            #expect(recognitionFiles(store, library.book.id) == before, "includePDFs \(includePDFs)")
            #expect(try await store.recognitionState(bookID: library.book.id) == Self.state)
            #expect(try await store.recognisedPageIndices(bookID: library.book.id) == [15, 16, 17])
            // The backup's records: the scanned-page highlight is back, with its source.
            #expect(try store.highlights.highlight(id: library.scanned.id)?.textSource == .liveText)
            #expect(BackupTestSupport.restoresDirectoryIsGone(store))

            // Undo Last Restore puts the book back as it was and keeps the recognised text too.
            let undo = try await service.undoLastRestore()
            #expect(undo.failures.isEmpty)
            #expect(try store.highlights.highlight(id: library.scanned.id) == nil)
            #expect(recognitionFiles(store, library.book.id) == before, "after undo, includePDFs \(includePDFs)")
        }
    }

    @Test func aBookRestoredFreshFromAnOlderArchiveHoldingTextHasNone() async throws {
        // An archive written before recognised text was left out. The writer now leaves it out,
        // so it is made with same-length stand-in names, renamed in the archive's bytes after
        // (names are not covered by the entries' checksums or the manifest's file hashes).
        let scratch = try Support.scratch("ScannedHighlightOldArchive")
        let source = try LibraryStore.ephemeral()
        let target = try LibraryStore.ephemeral()
        defer { for url in [scratch, source.rootDirectory, target.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let library = try await makeLibrary(source)
        let directory = source.bookDirectoryURL(bookID: library.book.id)
        let manager = FileManager.default
        try manager.moveItem(at: directory.appendingPathComponent("text"), to: directory.appendingPathComponent("txet"))
        try manager.moveItem(at: directory.appendingPathComponent("recognition.json"),
                             to: directory.appendingPathComponent("recognitionAjson"))
        let backup = try await Support.makeService(source, scratch: scratch).backUpToFile(includePDFs: false).url
        var data = try Data(contentsOf: backup)
        for (from, to) in [("txet", "text"), ("recognitionAjson", "recognition.json")] {
            let fromData = Data(from.utf8), toData = Data(to.utf8)
            while let range = data.range(of: fromData) { data.replaceSubrange(range, with: toData) }
        }
        try Self.fixManifestChecksum(&data)
        let old = scratch.appendingPathComponent("old.ttbackup")
        try data.write(to: old)
        let manifest = try BackupArchiveReader(url: old).manifest
        #expect(derivedPaths(in: manifest).sorted() == ["recognition.json", "text/15.json", "text/16.json"])

        let service = Support.makeService(target, scratch: scratch)
        let session = try await service.openBackup(at: old)
        let summary = try await service.restore(Set(session.plan.items.map(\.id)), from: session, restorePDFs: true)
        session.close()
        #expect(summary.failures.isEmpty)
        #expect(summary.restored.map(\.id) == [library.book.id])
        #expect(recognitionFiles(target, library.book.id).isEmpty)
        #expect(try await target.recognitionState(bookID: library.book.id) == nil)
        #expect(try target.highlights.highlight(id: library.scanned.id)?.textSource == .liveText)

        #expect(BackupDerivedFiles.isDerived(relativePath: "text/3.json"))
        #expect(BackupDerivedFiles.isDerived(relativePath: "recognition.json"))
        #expect(!BackupDerivedFiles.isDerived(relativePath: "ink/3.drawing"))
        #expect(!BackupDerivedFiles.isDerived(relativePath: "notes/text"))
    }

    /// The manifest is the archive's last stored entry and lists every file's path, so renaming
    /// paths changes its bytes: recompute its CRC-32 in its local header (offset 14) and its
    /// central directory record (offset 16).
    private static func fixManifestChecksum(_ data: inout Data) throws {
        let name = Data(BackupArchiveLayout.manifestPath.utf8)
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func matches(_ signature: [UInt8], at offset: Int, nameAt: Int) -> Bool {
            offset >= 0 && offset + nameAt + name.count <= bytes.count
                && Array(bytes[offset..<offset + 4]) == signature
                && Data(bytes[offset + nameAt..<offset + nameAt + name.count]) == name
        }
        var local: Int?, central: Int?
        var search = data.startIndex..<data.endIndex
        while let range = data.range(of: name, in: search) {
            let at = range.lowerBound - data.startIndex
            if matches([0x50, 0x4B, 0x03, 0x04], at: at - 30, nameAt: 30) { local = at - 30 }
            if matches([0x50, 0x4B, 0x01, 0x02], at: at - 46, nameAt: 46) { central = at - 46 }
            search = range.upperBound..<data.endIndex
        }
        guard let local, let central else { throw CocoaError(.fileReadCorruptFile) }
        let start = local + 30 + u16(local + 26) + u16(local + 28)
        let end = try #require(data.range(of: Data([0x50, 0x4B, 0x01, 0x02]), in: (data.startIndex + start)..<data.endIndex))
            .lowerBound - data.startIndex
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes[start..<end] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        crc ^= 0xFFFF_FFFF
        let le = withUnsafeBytes(of: crc.littleEndian) { Data($0) }
        data.replaceSubrange((data.startIndex + local + 14)..<(data.startIndex + local + 18), with: le)
        data.replaceSubrange((data.startIndex + central + 16)..<(data.startIndex + central + 20), with: le)
    }

    @Test func keptRecognitionNeedsTheSamePDF() async throws {
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let library = try await makeLibrary(store)
        let digest = try #require(try await store.contentDigest(of: library.book))
        let session = store.rootDirectory.appendingPathComponent("Restores/test", isDirectory: true)
        let restored = library.book
        #expect(RestoreCommit.keptRecognition(for: restored, expected: digest, sessionDirectory: session,
                                              replacing: [library.book.id], store: store) == library.book.id)
        // Another PDF (a separately converted copy, say): not kept.
        let other = ContentDigest(sha256: String(repeating: "a", count: 64), size: digest.size)
        #expect(RestoreCommit.keptRecognition(for: restored, expected: other, sessionDirectory: session,
                                              replacing: [library.book.id], store: store) == nil)
        // Nothing to keep.
        try await store.removeRecognisedText(bookID: library.book.id, origin: nil)
        try await store.saveRecognitionState(nil, bookID: library.book.id, origin: nil)
        #expect(RestoreCommit.keptRecognition(for: restored, expected: digest, sessionDirectory: session,
                                              replacing: [library.book.id], store: store) == nil)
    }

    /// A replace interrupted after the book's directory was set aside, finished at the next
    /// launch: the journal carries the recognised text across.
    @Test func anInterruptedReplaceFinishedAtLaunchKeepsRecognisedText() async throws {
        let scratch = try Support.scratch("ScannedHighlightRecovery")
        let store = try LibraryStore.ephemeral()
        defer { for url in [scratch, store.rootDirectory] { try? FileManager.default.removeItem(at: url) } }
        let library = try await makeLibrary(store)
        let service = Support.makeService(store, scratch: scratch)
        let backup = try await service.backUpToFile(includePDFs: false).url
        let before = recognitionFiles(store, library.book.id)

        for step in [RestoreCommit.Step.allSetAside, .pdfMoved, .stagedMovedIn] {
            service.stopCommitAfter = step
            let session = try await service.openBackup(at: backup)
            _ = try await service.restore([library.book.id: .replace], from: session, restorePDFs: true)
            session.close()
            service.stopCommitAfter = nil
            let report = await RestoreRecovery.recover(store: store)
            #expect(report.rolledForward == [library.book.id], "\(step)")
            #expect(recognitionFiles(store, library.book.id) == before, "\(step)")
            #expect(try await store.recognitionState(bookID: library.book.id) == Self.state, "\(step)")
            #expect(store.hasDocument(try #require(try store.books.book(id: library.book.id))), "\(step)")
        }
    }
}
