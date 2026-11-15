import Foundation
import ReaderBackup
import ReaderCore

// The merge engine: restoring a book that is already in the Library by merging the backup's copy
// into the local one (plan "Merge on restore", Engine). Driven by `performRestore` for each book
// whose action is `.merge`:
//
// 1. **Staging** (as for every restored book): the backup's copy is extracted and verified, then
//    set aside to `merge-incoming/<backupID>` (`MergeFiles.setIncomingAside`).
// 2. After open editors have saved, the books are paused at `BookWriteGate` and the safety copy
//    (which protects the local book) is made, **`prepareMerge`** reads the local records, runs
//    `BookMerge.merge`, and builds the merged directory `staged/<localID>`: page ink and note ink
//    combined (`MergeFiles`, `NoteInkMerging`), the local cover and hash sidecar, and the
//    backup's PDF only when the local book has none.
// 3. **`commitMerge`**, on the main actor with no suspension point: the local records are read
//    again and the merge re-run (it is deterministic, fresh IDs included), so highlights,
//    bookmarks and headings saved meanwhile are included; if the notes it produces are not the
//    ones the ink was built for, the book fails with `libraryChanged` and nothing changes. The
//    result is committed with the existing `RestoreCommit.perform` as
//    `replaceBook(merged, removing: [localID])`, so the journal, launch recovery and the stale-save
//    guards apply unchanged.
//
// **Nothing local is lost:** every local record is in the merged archive with its ID
// (`BookMerge`), every local stroke is in the merged ink (union), ink that cannot be decoded is
// kept exactly as it was, the local PDF is moved across by the commit, and the local book is in
// the restore's safety copy, so Undo Last Restore puts it back.

/// One merged book, prepared and waiting for its commit.
struct PreparedMerge {
    /// The `hasInk` and `bandLayout` a merged note gets from the ink written for it.
    struct NoteInkRecord: Equatable {
        var hasInk: Bool
        var bandLayout: NoteBandLayout?
    }

    var item: RestorePlan.Item
    /// The local book merged into (it keeps its ID).
    var localBookID: UUID
    /// The backup's records, as staged (note `hasInk` reconciled to the ink files present).
    var incoming: BookArchive
    /// The merge the ink was built for.
    var result: BookMergeResult
    /// Per merged note whose ink file was kept, copied or written: what its record must say.
    var noteInk: [UUID: NoteInkRecord]
    var ink: MergeInkCounts
    var combinedInkAlreadyPresent: Int
    var unreadable: [UnreadableInk]
    var tookBackupPDF: Bool
    var droppedEmptyNotes: Int

    /// `archive` with the merged notes' `hasInk` and `bandLayout` set from the ink written.
    func applyingNoteInk(to archive: BookArchive) -> BookArchive {
        var archive = archive
        for index in archive.notes.indices {
            guard let record = noteInk[archive.notes[index].id] else { continue }
            archive.notes[index].hasInk = record.hasInk
            archive.notes[index].bandLayout = record.bandLayout
        }
        return archive
    }
}

extension BackupService {
    /// The local book a merge of `item` goes into: the one with the backup book's ID, else the
    /// one with its fingerprint. `nil` when the book is not in the Library (a merge then restores
    /// it as a new book). Any other match is left alone.
    nonisolated static func mergeTargetID(for item: RestorePlan.Item) -> UUID? {
        item.localMatches.first(where: { $0.book.id == item.id })?.book.id ?? item.localMatches.first?.book.id
    }

    /// Where the backup's PDF comes from for a merge: nowhere when the local book has its PDF (it
    /// keeps it); otherwise the archive or the destination, when `restorePDFs`.
    func mergePDFSource(for item: RestorePlan.Item, target: UUID, session: RestoreSession,
                        restorePDFs: Bool) throws -> RestoreStaging.PDFSource {
        guard let local = try store.books.book(id: target), !store.hasDocument(local), restorePDFs else { return .none }
        let entry = item.entry
        if entry.pdf.embedded, session.reader.embeddedPDFHashes.contains(entry.pdf.sha256) { return .embedded }
        if session.destination != nil, session.destinationPDFHashes.contains(entry.pdf.sha256) { return .destination }
        return .none
    }

    /// Step 2 (see above). Call after the safety copy. Throws on a file error (that book then
    /// fails; nothing in the Library has changed) and `CancellationError`.
    func prepareMerge(of item: RestorePlan.Item, staged: RestoreStaging.Output, into localBookID: UUID,
                      sessionDirectory: URL) async throws -> PreparedMerge {
        guard let local = try store.archive(bookID: localBookID) else {
            throw BackupServiceError.libraryChanged(bookTitle: item.entry.book.title)
        }
        let incoming = staged.archive
        let result = BookMerge.merge(local: local, incoming: incoming)
        let localNotes = Dictionary(local.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incomingNotes = Dictionary(incoming.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var plans: [MergeFiles.NotePlan] = []
        for (note, decision) in zip(result.archive.notes, result.noteDecisions) {
            plans.append(MergeFiles.NotePlan(
                noteID: note.id, localNoteID: decision.localNoteID, incomingNoteID: decision.incomingNoteID,
                localTextIsMerged: decision.localNoteID.flatMap { localNotes[$0]?.text } == note.text,
                incomingTextIsMerged: decision.incomingNoteID.flatMap { incomingNotes[$0]?.text } == note.text))
        }
        let incomingDirectory = MergeFiles.incomingDirectory(session: sessionDirectory, bookID: item.id)
        let input = MergeFiles.DirectoryInput(
            session: sessionDirectory, localDirectory: store.bookDirectoryURL(bookID: localBookID), localBookID: localBookID,
            localPDFFileName: local.book.fileName, incomingDirectory: incomingDirectory,
            incomingPDFFileName: item.entry.book.fileName, takeIncomingPDF: !store.hasDocument(local.book),
            incomingPDFDigest: item.entry.pdf.digest, notes: plans)
        let built = try await MergeFiles.buildDirectory(input)

        // Note ink that must be decoded, relaid and combined (layouts need the main actor).
        var ink = built.ink
        var alreadyPresent = built.combinedInkAlreadyPresent
        var unreadable = built.unreadable
        var records: [UUID: PreparedMerge.NoteInkRecord] = [:]
        var writes: [UUID: Data] = [:]
        var copies: [(incomingNoteID: UUID, noteID: UUID)] = []
        let textIsLocal = Dictionary(uniqueKeysWithValues: plans.map { ($0.noteID, $0.localTextIsMerged) })
        for (note, decision) in zip(result.archive.notes, result.noteDecisions) {
            try Task.checkCancellation()
            let localNote = decision.localNoteID.flatMap { localNotes[$0] }
            let incomingNote = decision.incomingNoteID.flatMap { incomingNotes[$0] }
            let keptLocal = PreparedMerge.NoteInkRecord(hasInk: true, bandLayout: localNote?.bandLayout)
            let keptIncoming = PreparedMerge.NoteInkRecord(hasInk: true, bandLayout: incomingNote?.bandLayout)
            switch built.notes[note.id] ?? .none {
            case .none:
                continue
            case .keptLocal:
                records[note.id] = keptLocal
            case .copiedIncoming:
                records[note.id] = keptIncoming
            case .combine(let localData, let incomingData):
                var localSide: NoteInkMerging.Side?
                if let localData, let localNote {
                    localSide = NoteInkMerging.Side(data: localData, text: localNote.text, recordLayout: localNote.bandLayout,
                                                    paragraphMap: decision.localParagraphMap ?? [])
                }
                var incomingSide: NoteInkMerging.Side?
                if let incomingData, let incomingNote {
                    incomingSide = NoteInkMerging.Side(data: incomingData, text: incomingNote.text,
                                                       recordLayout: incomingNote.bandLayout,
                                                       paragraphMap: decision.incomingParagraphMap ?? [])
                }
                let outcome = NoteInkMerging.merge(local: localSide, incoming: incomingSide, mergedText: note.text,
                                                   layout: { NotePageLayoutEngine.shared.bandLayout(for: $0) })
                switch outcome {
                case .merged(let merged, let incomingAddedStrokes):
                    if localData != nil, incomingData != nil, localData != incomingData {
                        ink.notesCombined += 1
                        if !incomingAddedStrokes { alreadyPresent += 1 }
                    } else if localData == nil {
                        ink.notesAdded += 1
                    }
                    if merged.isEmpty, localData == nil {
                        // Two empty drawings: the backup's file as it is.
                        copies.append((decision.incomingNoteID!, note.id))
                        records[note.id] = keptIncoming
                    } else if merged.isEmpty || (!incomingAddedStrokes && textIsLocal[note.id] == true) {
                        records[note.id] = keptLocal   // nothing new for the local file: it stays as it is
                    } else {
                        writes[note.id] = try NoteInkArchive.encode(merged)
                        records[note.id] = PreparedMerge.NoteInkRecord(hasInk: true, bandLayout: merged.layout)
                    }
                case .unreadable(let side):
                    unreadable.append(UnreadableInk(location: .note(note.id), side: side))
                    if localData != nil {
                        records[note.id] = keptLocal   // the local file, copied as it is
                    } else {
                        copies.append((decision.incomingNoteID!, note.id))
                        records[note.id] = keptIncoming
                        ink.notesAdded += 1
                    }
                }
            }
        }
        for copy in copies {
            try await MergeFiles.copyIncomingNoteInk(from: incomingDirectory, incomingNoteID: copy.incomingNoteID,
                                                     to: built.directory, as: copy.noteID)
        }
        try await MergeFiles.writeNoteInk(writes, into: built.directory)

        return PreparedMerge(item: item, localBookID: localBookID, incoming: incoming, result: result, noteInk: records,
                             ink: ink, combinedInkAlreadyPresent: alreadyPresent, unreadable: unreadable,
                             tookBackupPDF: built.tookBackupPDF, droppedEmptyNotes: staged.droppedEmptyNotes)
    }

    enum MergeCommitOutcome {
        case committed
        case failed
        /// Stopped after a commit step on request (tests), as a crash would.
        case stopped
    }

    /// Step 3 (see above). On the main actor with no suspension point; call inside the restore's
    /// commit loop.
    func commitMerge(_ prepared: PreparedMerge, sessionDirectory: URL, safetyCopy: RestoreSafetyCopy?,
                     summary: inout RestoreSummary) -> MergeCommitOutcome {
        let item = prepared.item
        let localID = prepared.localBookID
        let title = (try? store.books.book(id: localID))?.title ?? item.entry.book.title
        func fail(_ message: String) -> MergeCommitOutcome {
            summary.failures.append(.init(id: item.id, title: title, message: message))
            return .failed
        }
        let changed = BackupServiceError.libraryChanged(bookTitle: title).localizedDescription

        // The Library still holds the books the preview saw, and the local book.
        let current = currentMatches(for: item.entry.book)
        guard current.contains(localID), Set(current).isSubset(of: Set(item.replacedBookIDs)),
              let localNow = try? store.archive(bookID: localID) else { return fail(changed) }

        // The merge again, over the records as they are now: what was saved meanwhile (highlights,
        // bookmarks, headings) is included; notes and their ink must be what the ink was built for.
        let rerun = BookMerge.merge(local: localNow, incoming: prepared.incoming)
        guard rerun.noteDecisions == prepared.result.noteDecisions, rerun.archive.notes == prepared.result.archive.notes else {
            return fail(changed)
        }
        // The safety copy must hold what an undo puts back: a book changed only in highlights,
        // bookmarks or headings since the copy was made has those recorded beside the copy.
        if let safetyCopy, !safetyCopy.isUnchanged(localID, store: store) {
            guard safetyCopy.differsOnlyInMergeableRecords(localNow) else { return fail(changed) }
            do {
                try safetyCopy.amend(localNow)
            } catch {
                return fail("“\(title)” couldn’t be merged (\(error.localizedDescription)). It is unchanged.")
            }
        }

        let archive = prepared.applyingNoteInk(to: rerun.archive)
        do {
            try RestoreDurability.writeDurably(try BackupCoding.makeEncoder().encode(archive),
                                               to: RestoreLayout.archiveFile(session: sessionDirectory, bookID: localID))
        } catch {
            return fail("“\(title)” couldn’t be merged (\(error.localizedDescription)). It is unchanged.")
        }
        var localPDF: RestoreJournal.LocalPDF?
        if store.hasDocument(localNow.book) {
            localPDF = RestoreJournal.LocalPDF(bookID: localID, fileName: localNow.book.fileName)
        }
        let plan = RestoreCommit.Plan(sessionDirectory: sessionDirectory, archive: archive, replacedBookIDs: [localID],
                                      localPDF: localPDF)
        safetyCopy?.willCommit(archive.book, replacing: [localID])
        do {
            let outcome = try RestoreCommit.perform(plan, store: store, origin: origin, stopAfter: stopCommitAfter)
            if case .stopped = outcome { return .stopped }
        } catch {
            safetyCopy?.commitFailed(archive.book, replacing: [localID])
            return fail("“\(title)” couldn’t be merged (\(error.localizedDescription)). It is unchanged.")
        }
        CoverCache.shared.remove(at: store.url(forRelativePath: ImportService.coverRelativePath(bookID: localID)))
        let hasPDF = store.hasDocument(archive.book)
        summary.restored.append(.init(id: localID, title: archive.book.title, hasPDF: hasPDF))
        summary.merged.append(.init(id: localID, backupBookID: item.id, title: archive.book.title, report: rerun.report,
                                    ink: prepared.ink, combinedInkAlreadyPresent: prepared.combinedInkAlreadyPresent,
                                    unreadableInk: prepared.unreadable, tookPDFFromBackup: prepared.tookBackupPDF && hasPDF))
        summary.droppedEmptyNotes += prepared.droppedEmptyNotes
        return .committed
    }
}

extension MergeFiles {
    /// Bytes of a book's files other than its PDF (what a merge copies into the session).
    @concurrent
    static func bookFilesSize(_ directory: URL, pdfFileName: String) async -> Int64 {
        BackupWork.bookFiles(in: directory, excluding: [pdfFileName]).reduce(0) { $0 + $1.size }
    }
}
