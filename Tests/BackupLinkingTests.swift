import Foundation
import ReaderBackup
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// Linking a PDF to a book restored without it (B3): through the normal import path and through
/// `ImportService.linkPDF`, refusing a different PDF and a same-fingerprint, different-content
/// copy of `large.pdf`.
@MainActor
struct BackupLinkingTests {
    typealias Support = BackupTestSupport

    struct Restored {
        let store: LibraryStore
        let book: Book
        let expected: ContentDigest
        let cleanup: [URL]
    }

    /// `pdf` imported into a source library, backed up without PDFs, restored into a fresh one.
    private func restoredWithoutPDF(_ pdf: URL) async throws -> Restored {
        let scratch = try Support.scratch("BackupLink")
        let source = try LibraryStore.ephemeral()
        let book = try #require(try await ImportService(store: source).importPDF(at: pdf).book)
        try source.notes.save(Note(bookID: book.id, target: .page(1), text: "made on this PDF"))
        let file = try await Support.makeService(source, scratch: scratch).backUpToFile(includePDFs: false)
        let target = try LibraryStore.ephemeral()
        let service = Support.makeService(target, scratch: scratch)
        let session = try await service.openBackup(at: file.url)
        let summary = try await service.restore([book.id], from: session, restorePDFs: true)
        session.close()
        #expect(summary.needingPDF.map(\.id) == [book.id])
        let restored = try #require(try target.books.book(id: book.id))
        #expect(!target.hasDocument(restored))
        let expected = try #require(target.storedContentDigest(bookID: book.id))
        #expect(expected == (try ContentHash.digest(ofFileAt: pdf)))
        return Restored(store: target, book: restored, expected: expected,
                        cleanup: [scratch, source.rootDirectory, target.rootDirectory])
    }

    private func stagingIsEmpty(_ store: LibraryStore) -> Bool {
        let imports = store.rootDirectory.appendingPathComponent("Imports", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []).isEmpty
    }

    // MARK: Linking

    @Test func importingTheRightPDFLinksTheBook() async throws {
        let restored = try await restoredWithoutPDF(Support.small)
        defer { for url in restored.cleanup { try? FileManager.default.removeItem(at: url) } }
        let store = restored.store
        let importer = ImportService(store: store)
        // The restored cover is shown (and cached) before linking; linking must drop the cache.
        let cover = importer.coverURL(for: restored.book)
        #expect(await CoverCache.shared.image(at: cover) != nil)
        #expect(CoverCache.shared.cached(at: cover) != nil)
        var events: [StoreChangeEvent] = []
        let token = store.hub.observe { events.append($0) }

        let outcome = try await importer.importPDF(at: Support.small)
        token.cancel()
        #expect(outcome == .existing(restored.book))
        #expect(try store.books.allBooks().count == 1)
        #expect(store.hasDocument(restored.book))
        #expect(try Data(contentsOf: store.documentURL(for: restored.book)) == (try Data(contentsOf: Support.small)))
        #expect(store.storedContentDigest(bookID: restored.book.id) == restored.expected)
        #expect(events.map(\.change).contains(.bookSaved(bookID: restored.book.id)))
        #expect(CoverCache.shared.cached(at: cover) == nil)
        #expect(stagingIsEmpty(store))
        #expect(try store.notes.noteCount(bookID: restored.book.id) == 1)
    }

    @Test func linkPDFLinksTheRightFileAndRendersAMissingCover() async throws {
        let restored = try await restoredWithoutPDF(Support.noOutline)
        defer { for url in restored.cleanup { try? FileManager.default.removeItem(at: url) } }
        let store = restored.store
        let importer = ImportService(store: store)
        let cover = importer.coverURL(for: restored.book)
        try FileManager.default.removeItem(at: cover)
        // A copy under another name: "Locate PDF…" does not care about the name.
        let copy = restored.cleanup[0].appendingPathComponent("Renamed.pdf")
        try FileManager.default.copyItem(at: Support.noOutline, to: copy)

        let linked = try await importer.linkPDF(at: copy, to: restored.book)
        #expect(linked == restored.book)
        #expect(store.hasDocument(restored.book))
        #expect(store.documentURL(for: restored.book).lastPathComponent == restored.book.fileName)
        #expect(UIImage(contentsOfFile: cover.path) != nil)
        #expect(store.storedContentDigest(bookID: restored.book.id) == restored.expected)
        #expect(stagingIsEmpty(store))
        #expect(importer.jobs.isEmpty)
        // Linking again with the same file is accepted and changes nothing.
        #expect(try await importer.linkPDF(at: copy, to: restored.book) == restored.book)
    }

    @Test func linkPDFWritesTheSidecarWhenTheBookHasNone() async throws {
        let restored = try await restoredWithoutPDF(Support.small)
        defer { for url in restored.cleanup { try? FileManager.default.removeItem(at: url) } }
        let store = restored.store
        try FileManager.default.removeItem(at: store.contentHashURL(bookID: restored.book.id))
        _ = try await ImportService(store: store).linkPDF(at: Support.small, to: restored.book)
        #expect(store.hasDocument(restored.book))
        #expect(store.storedContentDigest(bookID: restored.book.id) == restored.expected)
    }

    // MARK: Refusing

    @Test func aDifferentPDFIsRefused() async throws {
        let restored = try await restoredWithoutPDF(Support.small)
        defer { for url in restored.cleanup { try? FileManager.default.removeItem(at: url) } }
        let store = restored.store
        let before = Support.files(in: store.bookDirectoryURL(bookID: restored.book.id))
        let importer = ImportService(store: store)
        await #expect(throws: ImportError.pdfMismatch(bookTitle: restored.book.title)) {
            _ = try await importer.linkPDF(at: Support.noOutline, to: restored.book)
        }
        #expect(!store.hasDocument(restored.book))
        #expect(Support.files(in: store.bookDirectoryURL(bookID: restored.book.id)) == before)
        #expect(try store.books.allBooks().count == 1)  // never imported as another book
        #expect(stagingIsEmpty(store))
        let message = ImportError.pdfMismatch(bookTitle: restored.book.title).errorDescription ?? ""
        #expect(message.contains(restored.book.title) && message.contains("notes"))
    }

    @Test func aCopyWithTheSameFingerprintButDifferentBytesIsRefused() async throws {
        let restored = try await restoredWithoutPDF(Support.large)
        defer { for url in restored.cleanup { try? FileManager.default.removeItem(at: url) } }
        let store = restored.store
        // Flip one byte between two sampled chunks: the fingerprint never reads it.
        var bytes = try Data(contentsOf: Support.large)
        let offsets = BookFingerprint.sampleOffsets(forSize: Int64(bytes.count))
        #expect(offsets.count == BookFingerprint.sampleCount)
        let gapStart = offsets[10] + Int64(BookFingerprint.chunkSize)
        #expect(offsets[11] > gapStart)
        let position = Int(gapStart + (offsets[11] - gapStart) / 2)
        #expect(!offsets.contains { Int64(position) >= $0 && Int64(position) < $0 + Int64(BookFingerprint.chunkSize) })
        bytes[position] ^= 0x20
        let forged = restored.cleanup[0].appendingPathComponent("large-copy.pdf")
        try bytes.write(to: forged)
        #expect(try BookFingerprint.fingerprint(ofFileAt: forged) == restored.book.fingerprint)
        #expect(try ContentHash.digest(ofFileAt: forged) != restored.expected)

        let before = Support.files(in: store.bookDirectoryURL(bookID: restored.book.id))
        let importer = ImportService(store: store)
        await #expect(throws: ImportError.pdfMismatch(bookTitle: restored.book.title)) {
            _ = try await importer.linkPDF(at: forged, to: restored.book)
        }
        // The normal import path matches it by fingerprint and refuses it the same way.
        await #expect(throws: ImportError.pdfMismatch(bookTitle: restored.book.title)) {
            _ = try await importer.importPDF(at: forged)
        }
        #expect(!store.hasDocument(restored.book))
        #expect(Support.files(in: store.bookDirectoryURL(bookID: restored.book.id)) == before)
        #expect(try store.books.allBooks().count == 1)
        #expect(stagingIsEmpty(store))

        // The real file still links.
        _ = try await importer.linkPDF(at: Support.large, to: restored.book)
        #expect(store.hasDocument(restored.book))
    }
}
