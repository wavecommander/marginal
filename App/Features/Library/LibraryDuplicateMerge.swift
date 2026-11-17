import Foundation
import OSLog
import ReaderBackup
import ReaderCore
import ReaderSync

/// One book per PDF (owner decision 8, 17 November 2026), for a library that already holds two
/// books with one PDF (a converted book and its generated PDF imported directly, or two
/// conversions that made identical bytes, from before this version checked): at launch, before
/// sync can run, each such pair is merged into one with the existing add-only book merge
/// (`BookMerge.merge(local:remote:base: nil)`: nothing removed, notes on one target combined
/// paragraph by paragraph, ink unioned with handwriting kept on its paragraph), keeping the
/// older book's ID, title and reading position; then the newer book is deleted, which closes its
/// windows as a delete does. Windows on the kept book stay open and reload what changed: the
/// merge is written record by record and file by file (`LibraryChangeWriter`).
///
/// **Crash-safe without a journal: it is idempotent.** Nothing is removed from either book until
/// the kept book holds everything. Notes the newer book contributes get IDs derived from the
/// kept book's ID and their own (`BookMerge.freshID`), so the same merge run again (after a crash
/// part-way, or at every launch) finds them already there, combines nothing twice and adds no
/// stroke twice; highlights, bookmarks and headings move across by their IDs. The newer book is
/// deleted last. A pair whose ink this system cannot read in full is left as it is (and logged),
/// never merged at the cost of a stroke.
@MainActor
enum LibraryDuplicateMerge {
    struct Merged: Hashable, Sendable {
        var kept: UUID
        var absorbed: UUID
    }

    struct Outcome: Sendable {
        var merged: [Merged] = []
        /// Books left as they were, by ID, with what stopped them (never note text).
        var failures: [UUID: String] = [:]
    }

    private static let log = Logger(subsystem: "software.tactile.texts", category: "DuplicateBooks")

    /// Finds every group of books with one PDF and merges each into its oldest book.
    static func run(store: LibraryStore, origin: ChangeOrigin, inkMerger: any SyncInkMerger = AppSyncInkMerger()) async -> Outcome {
        var outcome = Outcome()
        let groups: [[Book]]
        do {
            groups = try await LibraryPDFIndex.duplicateGroups(in: store)
        } catch {
            return outcome
        }
        for group in groups {
            let kept = group[0]
            for other in group.dropFirst() {
                do {
                    try await merge(other.id, into: kept.id, store: store, origin: origin, inkMerger: inkMerger)
                    outcome.merged.append(Merged(kept: kept.id, absorbed: other.id))
                } catch {
                    outcome.failures[other.id] = String(describing: type(of: error))
                    log.error("left two books with one PDF as they were: \(String(describing: type(of: error)), privacy: .public)")
                }
            }
        }
        if !outcome.merged.isEmpty { log.notice("merged \(outcome.merged.count) books into the book with the same PDF") }
        return outcome
    }

    /// Merges book `absorbedID` into book `keptID` (see the type), then deletes it.
    static func merge(_ absorbedID: UUID, into keptID: UUID, store: LibraryStore, origin: ChangeOrigin,
                      inkMerger: any SyncInkMerger = AppSyncInkMerger()) async throws {
        let pause = await BookWriteGate.shared.pause([keptID, absorbedID])
        defer { BookWriteGate.shared.resume(pause) }
        guard let local = try store.archive(bookID: keptID), let incoming = try store.archive(bookID: absorbedID) else { return }
        let writer = LibraryChangeWriter(store: store, origin: origin)

        // The records, the newer book's notes under IDs of the kept book.
        let result = BookMerge.merge(local: local, remote: incoming, base: nil)
        var archive = result.archive
        var decisions = result.noteDecisions
        let localNoteIDs = Set(local.notes.map(\.id))
        var used = Set(archive.notes.map(\.id)).union(incoming.notes.map(\.id))
        for index in archive.notes.indices where !localNoteIDs.contains(archive.notes[index].id) {
            let old = archive.notes[index].id
            var attempt = 0
            var fresh = BookMerge.freshID(for: old, in: keptID, attempt: attempt)
            while used.contains(fresh) {
                attempt += 1
                fresh = BookMerge.freshID(for: old, in: keptID, attempt: attempt)
            }
            used.insert(fresh)
            archive.notes[index].id = fresh
            for k in decisions.indices where decisions[k].noteID == old { decisions[k].noteID = fresh }
        }

        // The files, all in hand before anything is written.
        var write: [SyncFileKey: Data] = [:]
        let localPages = try await store.inkedPageIndices(bookID: keptID)
        let incomingPages = try await store.inkedPageIndices(bookID: absorbedID)
        for page in Set(localPages).union(incomingPages).sorted() {
            let mine = try await store.pageInk(bookID: keptID, pageIndex: page)
            let theirs = try await store.pageInk(bookID: absorbedID, pageIndex: page)
            guard let theirs, theirs != mine else { continue }
            guard mine != nil else { write[.pageInk(page)] = theirs; continue }
            let merged = try await inkMerger.merge(SyncInkMergeRequest(kind: .page(page), local: mine, remote: theirs, base: .unavailable))
            if let merged, merged != mine { write[.pageInk(page)] = merged }
        }
        let localNotes = Dictionary(local.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let incomingNotes = Dictionary(incoming.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (note, decision) in zip(archive.notes, decisions) where decision.source != .local {
            func ink(_ source: NoteSyncDecision.InkSource?) async throws -> Data? {
                guard let source else { return nil }
                switch source.side {
                case .local: return try await store.noteInk(bookID: keptID, noteID: source.noteID)
                case .remote: return try await store.noteInk(bookID: absorbedID, noteID: source.noteID)
                case .base: return nil
                }
            }
            func record(_ source: NoteSyncDecision.InkSource?) -> Note? {
                guard let source else { return nil }
                return source.side == .local ? localNotes[source.noteID] : incomingNotes[source.noteID]
            }
            let mine = try await ink(decision.local)
            let theirs = try await ink(decision.remote)
            var absorbedInk: [Data?] = []
            for source in decision.absorbed { absorbedInk.append(try await ink(source)) }
            if mine == nil && theirs == nil && absorbedInk.allSatisfy({ $0 == nil }) { continue }
            if decision.source == .remote && decision.absorbed.isEmpty {
                if let theirs { write[.noteInk(note.id)] = theirs }
                continue
            }
            let notes = SyncInkNotes(merged: note, local: record(decision.local), remote: record(decision.remote), base: nil,
                                     absorbed: decision.absorbed.map(record))
            let merged = try await inkMerger.merge(SyncInkMergeRequest(kind: .note(decision), local: mine, remote: theirs,
                                                                       base: .unavailable, absorbed: absorbedInk, notes: notes))
            if let merged, merged != mine { write[.noteInk(note.id)] = merged }
        }
        let keptDirectory = store.bookDirectoryURL(bookID: keptID)
        let absorbedDirectory = store.bookDirectoryURL(bookID: absorbedID)
        for (key, name) in [(SyncFileKey.cover, ImportPipeline.coverFileName),
                            (SyncFileKey.conversion, ImportPipeline.conversionRecordFileName)] {
            if await read(keptDirectory.appendingPathComponent(name)) == nil,
               let theirs = await read(absorbedDirectory.appendingPathComponent(name)) {
                write[key] = theirs
            }
        }

        // Write: records, files, the notes after their ink; then the PDF if the kept book lacks
        // it; then the newer book goes.
        try writer.writeRecords(BookArchiveDiff(from: local, to: archive), target: archive, current: local)
        try await writer.writeFiles(bookID: keptID, write: write, remove: [])
        try await writer.settleNotes(bookID: keptID, noteIDs: Set(archive.notes.map(\.id)))
        try await adoptPDF(of: incoming.book, into: local.book, store: store, origin: origin)
        do {
            try await store.deleteBook(id: absorbedID, origin: origin)
        } catch LibraryStoreError.bookFilesNotRemoved {
            // Gone from the Library; the launch sweep removes what is left of its directory.
        }
        BookDeletion.removeWindowPreferences(bookID: absorbedID)
    }

    /// The newer book's PDF, moved to the kept book when that has none (same SHA-256 by
    /// construction), with the kept book's file name; its hash sidecar written if missing.
    private static func adoptPDF(of absorbed: Book, into kept: Book, store: LibraryStore, origin: ChangeOrigin) async throws {
        guard !store.hasDocument(kept), store.hasDocument(absorbed) else { return }
        let digest = try await store.contentDigest(of: absorbed)
        let destination = store.documentURL(for: kept)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: store.documentURL(for: absorbed), to: destination)
        if store.storedContentDigest(bookID: kept.id) == nil, let digest {
            try? DocumentDigest.writeSidecar(digest, to: store.contentHashURL(bookID: kept.id))
        }
        CoverCache.shared.remove(at: store.url(forRelativePath: ImportService.coverRelativePath(bookID: kept.id)))
        store.hub.post(.bookSaved(bookID: kept.id), origin: origin)
    }

    @concurrent
    nonisolated private static func read(_ url: URL) async -> Data? {
        try? Data(contentsOf: url)
    }
}
