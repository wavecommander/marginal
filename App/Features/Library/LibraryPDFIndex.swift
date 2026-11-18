import Foundation
import ReaderBackup
import ReaderCore

/// One book per PDF (owner decision 8, 17 November 2026): two PDFs with the same full SHA-256
/// never appear as two books. This finds the books that hold a PDF, by the `document.sha256`
/// sidecar (`DocumentDigest`), hashing a PDF only when it may be the one looked for.
///
/// A book's sidecar is written when its PDF is first hashed: at import (every import and
/// conversion writes it from this version on), by a backup, a restore (from the manifest, also
/// for a book without its PDF), a link, sync. A book imported by an earlier version may have
/// none yet; such a PDF is hashed (once, then cached) only when its size is the size of the PDF
/// looked for, since only a PDF of the same size can have the same SHA-256.
@MainActor
enum LibraryPDFIndex {
    /// What is known about one book's PDF without reading it.
    nonisolated struct Known: Sendable {
        var sidecar: ContentDigest?
        /// The PDF's size on disk, `nil` when it is absent.
        var pdfSize: Int64?
    }

    /// The books whose sidecar names this SHA-256, oldest first. Reads only the small sidecars
    /// and never suspends, so an import's or a restore's commit can call it.
    static func bookIDs(withSidecarSHA256 sha256: String, in store: LibraryStore) -> [UUID] {
        let hash = sha256.lowercased()
        let books = (try? store.books.allBooks()) ?? []
        return books.filter { store.storedContentDigest(bookID: $0.id)?.sha256 == hash }.sorted(by: isOlder).map(\.id)
    }

    /// The book, other than those in `excluding`, that holds the PDF `digest`: one whose sidecar
    /// names it, else one without a sidecar whose PDF has the same size and, hashed now, the same
    /// SHA-256. The oldest when there are several. Throws only `CancellationError`.
    static func book(holding digest: ContentDigest, in store: LibraryStore, excluding: Set<UUID> = []) async throws -> Book? {
        let hash = digest.sha256.lowercased()
        let books = ((try? store.books.allBooks()) ?? []).filter { !excluding.contains($0.id) }.sorted(by: isOlder)
        let known = await probe(books, in: store)
        if let byHash = books.first(where: { known[$0.id]?.sidecar?.sha256 == hash }) { return byHash }
        for book in books where known[book.id]?.sidecar == nil && known[book.id]?.pdfSize == digest.size {
            try Task.checkCancellation()
            guard let current = try? store.books.book(id: book.id) else { continue }
            if (try? await store.contentDigest(of: current))?.sha256 == hash { return current }
        }
        return nil
    }

    /// Every group of two or more books that hold one PDF, each group oldest first. Books with no
    /// sidecar are hashed only when another book's PDF has the same size. Throws only
    /// `CancellationError`.
    static func duplicateGroups(in store: LibraryStore) async throws -> [[Book]] {
        let books = ((try? store.books.allBooks()) ?? []).sorted(by: isOlder)
        let known = await probe(books, in: store)
        var sizes: [Int64: Int] = [:]
        for book in books {
            if let size = known[book.id]?.sidecar?.size ?? known[book.id]?.pdfSize { sizes[size, default: 0] += 1 }
        }
        var byHash: [String: [Book]] = [:]
        for book in books {
            try Task.checkCancellation()
            var digest = known[book.id]?.sidecar
            if digest == nil, let size = known[book.id]?.pdfSize, sizes[size, default: 0] > 1 {
                digest = try? await store.contentDigest(of: book)
            }
            if let digest { byHash[digest.sha256.lowercased(), default: []].append(book) }
        }
        return byHash.values.filter { $0.count > 1 }.map { $0.sorted(by: isOlder) }
            .sorted { isOlder($0[0], $1[0]) }
    }

    /// The order of "older": added first, then by ID.
    nonisolated static func isOlder(_ a: Book, _ b: Book) -> Bool {
        (a.addedAt, a.id.uuidString) < (b.addedAt, b.id.uuidString)
    }

    /// Sidecars and PDF sizes, read off the main actor.
    static func probe(_ books: [Book], in store: LibraryStore) async -> [UUID: Known] {
        let probes = books.map { ($0.id, store.documentURL(for: $0), store.contentHashURL(bookID: $0.id)) }
        return await readKnown(probes)
    }

    @concurrent
    nonisolated private static func readKnown(_ probes: [(UUID, URL, URL)]) async -> [UUID: Known] {
        var result: [UUID: Known] = [:]
        for (id, document, sidecar) in probes {
            result[id] = Known(sidecar: DocumentDigest.readSidecar(at: sidecar), pdfSize: DocumentDigest.regularFileSize(document))
        }
        return result
    }
}
