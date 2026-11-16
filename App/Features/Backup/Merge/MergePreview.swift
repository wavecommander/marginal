import Foundation
import ReaderBackup
import ReaderCore

extension BackupService {
    /// What merging would do, for every book of the session's backup that is already in the
    /// Library (`RestorePlan.Item.status == .inLibrary`), keyed by the backed-up book's ID.
    /// Changes nothing, and is not a job (it can run while the preview is shown).
    ///
    /// Per book: the `BookMergeReport` of the backup's `records.json` merged into the local
    /// book's records (the book `mergeTargetID(for:)` names), and ink counts from comparing the
    /// manifest's per-file SHA-256 with the local ink files (`MergeInkCounts`). The local records
    /// are read on the main actor in one pass; the backup's records are read, and local ink files
    /// hashed (only those whose size matches), off the main actor.
    ///
    /// A book whose backed-up records cannot be read, or whose local book is gone, is left out
    /// (restoring it reports why). Returns an empty result for a closed session.
    func mergePreview(for session: RestoreSession) async -> [UUID: BookMergePreview] {
        guard !session.isClosed else { return [:] }
        var inputs: [MergePreviewWork.Input] = []
        for item in session.plan.items {
            guard let target = Self.mergeTargetID(for: item), let local = try? store.archive(bookID: target) else { continue }
            inputs.append(MergePreviewWork.Input(entry: item.entry, local: local,
                                                 localDirectory: store.bookDirectoryURL(bookID: target)))
        }
        guard !inputs.isEmpty else { return [:] }
        return await MergePreviewWork.previews(inputs, reader: session.reader)
    }
}

/// The off-main work of `BackupService.mergePreview(for:)`.
nonisolated enum MergePreviewWork {
    struct Input: Sendable {
        var entry: BackupManifest.BookEntry
        var local: BookArchive
        var localDirectory: URL
    }

    @concurrent
    static func previews(_ inputs: [Input], reader: BackupArchiveReader) async -> [UUID: BookMergePreview] {
        var result: [UUID: BookMergePreview] = [:]
        for input in inputs {
            if Task.isCancelled { break }
            guard let records = try? reader.bookArchive(for: input.entry.book.id) else { continue }
            let incoming = reconciled(records, entry: input.entry)
            let merge = BookMerge.merge(local: input.local, incoming: incoming)
            let ink = inkCounts(entry: input.entry, localDirectory: input.localDirectory, decisions: merge.noteDecisions)
            result[input.entry.book.id] = BookMergePreview(id: input.entry.book.id, localBookID: input.local.book.id,
                                                           report: merge.report, ink: ink)
        }
        return result
    }

    /// The backup's records as staging makes them (`RestoreStaging.stage`): each note's `hasInk`
    /// follows whether the manifest lists its ink file, and notes left empty by that are dropped.
    static func reconciled(_ archive: BookArchive, entry: BackupManifest.BookEntry) -> BookArchive {
        let inked = Set(entry.files.compactMap { noteID(fromPath: $0.path) })
        var archive = archive
        archive.notes = archive.notes.compactMap { note in
            var note = note
            let hasFile = inked.contains(note.id)
            if note.hasInk != hasFile {
                note.hasInk = hasFile
                if !hasFile { note.bandLayout = nil }
            }
            return note.isEmpty ? nil : note
        }
        return archive
    }

    /// Pages and notes whose ink a merge adds or combines (see `MergeInkCounts`): the backup's ink
    /// files (the manifest's paths and SHA-256) against the local book's.
    static func inkCounts(entry: BackupManifest.BookEntry, localDirectory: URL, decisions: [NoteMergeDecision]) -> MergeInkCounts {
        var counts = MergeInkCounts()
        var incomingPages: [Int: BackupManifest.FileInfo] = [:]
        var incomingNotes: [UUID: BackupManifest.FileInfo] = [:]
        for file in entry.files {
            if file.path.hasPrefix("ink/"), let page = BookStorageLayout.pageIndex(fromPageInkFileName: String(file.path.dropFirst(4))) {
                incomingPages[page] = file
            } else if let id = noteID(fromPath: file.path) {
                incomingNotes[id] = file
            }
        }
        let localPages = MergeFiles.pageFiles(in: localDirectory.appendingPathComponent("ink", isDirectory: true))
        for (page, file) in incomingPages {
            guard let local = localPages[page] else {
                counts.pagesAdded += 1
                continue
            }
            if !matches(local, file) { counts.pagesCombined += 1 }
        }
        let localNotes = localDirectory.appendingPathComponent("notes", isDirectory: true)
        for decision in decisions {
            guard let incomingID = decision.incomingNoteID, let file = incomingNotes[incomingID] else { continue }
            let local = decision.localNoteID.map { localNotes.appendingPathComponent(MergeFiles.noteFileName($0)) }
            guard let local, FileManager.default.fileExists(atPath: local.path) else {
                counts.notesAdded += 1
                continue
            }
            if !matches(local, file) { counts.notesCombined += 1 }
        }
        return counts
    }

    /// `notes/<UUID>.drawing` → the UUID.
    static func noteID(fromPath path: String) -> UUID? {
        guard path.hasPrefix("notes/"), path.hasSuffix(".drawing") else { return nil }
        let name = path.dropFirst("notes/".count).dropLast(".drawing".count)
        guard !name.contains("/") else { return nil }
        return UUID(uuidString: String(name))
    }

    /// Whether the local file has the manifest's size and SHA-256 (hashed only when sizes match).
    private static func matches(_ url: URL, _ file: BackupManifest.FileInfo) -> Bool {
        guard DocumentDigest.regularFileSize(url) == file.size,
              let digest = try? ContentHash.digest(ofFileAt: url) else { return false }
        return digest == file.digest
    }
}
