import Foundation
import PencilKit
import ReaderBackup
import ReaderCore

/// The file work of merging one book, off the main actor. Nothing here touches `Books/` or the
/// database: it reads the local book's directory and the backup's extracted copy, and writes the
/// merged directory inside the restore session.
///
///     Restores/<session>/merge-incoming/<backupBookID>/   the backup's copy, extracted and verified
///     Restores/<session>/staged/<localBookID>/            the merged directory the commit moves in
///
/// The merged directory starts as a copy of the local book's directory without its PDF (cover,
/// hash sidecar, page ink, note ink, a scanned book's recognised text and recognition state, and
/// anything else stay as they are; the backup holds no recognised text); then page ink and note
/// ink are combined as `BookMergeEngine` describes. The local PDF is moved across by the commit's
/// local-PDF step; when the local book has no PDF the backup's, if it was extracted, is moved in.
nonisolated enum MergeFiles {
    static let incomingDirectoryName = "merge-incoming"

    /// `Restores/<session>/merge-incoming/<bookID>`
    static func incomingDirectory(session: URL, bookID: UUID) -> URL {
        session.appendingPathComponent(incomingDirectoryName, isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    /// After staging the backup's copy of a book that is to be merged: moves `staged/<bookID>`
    /// to `merge-incoming/<bookID>` (the staged path is where the merged directory is built when
    /// the local book has the same ID) and removes `commit-<bookID>`, which holds the backup's
    /// records only (the merge writes its own at commit time).
    @concurrent
    static func setIncomingAside(session: URL, bookID: UUID) async throws -> URL {
        let manager = FileManager.default
        let target = incomingDirectory(session: session, bookID: bookID)
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        try manager.moveItem(at: RestoreLayout.stagedDirectory(session: session, bookID: bookID), to: target)
        try? manager.removeItem(at: RestoreLayout.commitDirectory(session: session, bookID: bookID))
        return target
    }

    // MARK: Building the merged directory

    /// What `buildDirectory` needs about one merged note.
    struct NotePlan: Sendable {
        /// The merged note's ID (its ink file name in the merged directory).
        var noteID: UUID
        /// The local note's ID (equal to `noteID` when present).
        var localNoteID: UUID?
        /// The backup's note ID, which keys its ink file in the backup's copy.
        var incomingNoteID: UUID?
        /// Whether the merged text is the local / the backup's note text exactly, so that side's
        /// ink file needs no relayout.
        var localTextIsMerged: Bool
        var incomingTextIsMerged: Bool
    }

    struct DirectoryInput: Sendable {
        var session: URL
        /// `Books/<localBookID>`
        var localDirectory: URL
        var localBookID: UUID
        var localPDFFileName: String
        /// `merge-incoming/<backupBookID>`
        var incomingDirectory: URL
        var incomingPDFFileName: String
        /// The local book had no PDF when the merge was prepared: use the backup's if extracted.
        var takeIncomingPDF: Bool
        /// The backup's PDF hash (the manifest's).
        var incomingPDFDigest: ContentDigest
        var notes: [NotePlan]
    }

    /// What happens to one merged note's ink file.
    enum NoteFile: Sendable {
        /// No ink file on either side.
        case none
        /// The local file is kept as it is (under the same ID).
        case keptLocal
        /// The backup's file is copied as it is under the merged note's ID.
        case copiedIncoming
        /// The ink must be decoded, relaid and combined (`NoteInkMerging`, main actor). `nil`:
        /// that side has no file.
        case combine(local: Data?, incoming: Data?)
    }

    struct DirectoryOutput: Sendable {
        /// `staged/<localBookID>`
        var directory: URL
        /// Page counts, and the notes copied from the backup as they are.
        var ink = MergeInkCounts()
        var combinedInkAlreadyPresent = 0
        var unreadable: [UnreadableInk] = []
        var notes: [UUID: NoteFile] = [:]
        var tookBackupPDF = false
    }

    /// Builds `staged/<localBookID>`: the local directory without its PDF, the combined page ink,
    /// note-ink files that need no decoding, and the backup's PDF and cover when the local book
    /// has none. Note ink that must be combined is returned as data (`NoteFile.combine`) and
    /// written by `writeNoteInk` once combined.
    @concurrent
    static func buildDirectory(_ input: DirectoryInput) async throws -> DirectoryOutput {
        let manager = FileManager.default
        let merged = RestoreLayout.stagedDirectory(session: input.session, bookID: input.localBookID)
        if manager.fileExists(atPath: merged.path) { try manager.removeItem(at: merged) }
        try manager.createDirectory(at: merged, withIntermediateDirectories: true)
        var output = DirectoryOutput(directory: merged)

        // The local directory, without its PDF.
        if manager.fileExists(atPath: input.localDirectory.path) {
            for name in try manager.contentsOfDirectory(atPath: input.localDirectory.path) {
                if name == input.localPDFFileName || BackupArchiveWriterNames.isTemporaryOrHidden(name) { continue }
                try manager.copyItem(at: input.localDirectory.appendingPathComponent(name),
                                     to: merged.appendingPathComponent(name))
            }
        }
        try Task.checkCancellation()

        try mergePageInk(input, into: merged, output: &output)
        try Task.checkCancellation()

        // Note ink that needs no decoding; the rest is handed back.
        let mergedNotes = merged.appendingPathComponent("notes", isDirectory: true)
        let incomingNotes = input.incomingDirectory.appendingPathComponent("notes", isDirectory: true)
        let localNotes = input.localDirectory.appendingPathComponent("notes", isDirectory: true)
        for plan in input.notes {
            let localURL = plan.localNoteID.map { localNotes.appendingPathComponent(noteFileName($0)) }
                .flatMap { manager.fileExists(atPath: $0.path) ? $0 : nil }
            let incomingURL = plan.incomingNoteID.map { incomingNotes.appendingPathComponent(noteFileName($0)) }
                .flatMap { manager.fileExists(atPath: $0.path) ? $0 : nil }
            let file: NoteFile
            switch (localURL, incomingURL) {
            case (nil, nil):
                file = .none
            case (let localURL?, nil):
                file = plan.localTextIsMerged ? .keptLocal : .combine(local: try Data(contentsOf: localURL), incoming: nil)
            case (nil, let incomingURL?):
                if plan.incomingTextIsMerged {
                    try manager.createDirectory(at: mergedNotes, withIntermediateDirectories: true)
                    try replaceFile(at: mergedNotes.appendingPathComponent(noteFileName(plan.noteID)), withCopyOf: incomingURL)
                    output.ink.notesAdded += 1
                    file = .copiedIncoming
                } else {
                    file = .combine(local: nil, incoming: try Data(contentsOf: incomingURL))
                }
            case (let localURL?, let incomingURL?):
                let localData = try Data(contentsOf: localURL)
                let incomingData = try Data(contentsOf: incomingURL)
                if localData == incomingData && plan.localTextIsMerged {
                    file = .keptLocal
                } else {
                    file = .combine(local: localData, incoming: incomingData)
                }
            }
            output.notes[plan.noteID] = file
        }
        try Task.checkCancellation()

        // The cover and the PDF: the local ones; the backup's only when the local book has none.
        let cover = merged.appendingPathComponent(ImportPipeline.coverFileName, isDirectory: false)
        let incomingCover = input.incomingDirectory.appendingPathComponent(ImportPipeline.coverFileName, isDirectory: false)
        if !manager.fileExists(atPath: cover.path), manager.fileExists(atPath: incomingCover.path) {
            try manager.copyItem(at: incomingCover, to: cover)
        }
        if input.takeIncomingPDF {
            let incomingPDF = input.incomingDirectory.appendingPathComponent(input.incomingPDFFileName, isDirectory: false)
            let sidecar = merged.appendingPathComponent(BookStorageLayout.contentHashFileName, isDirectory: false)
            let localDigest = DocumentDigest.readSidecar(at: sidecar)
            // The local sidecar is the hash a PDF must match to be linked to this book: a backup
            // PDF with another hash is not taken (the book stays as it was, without one).
            if manager.fileExists(atPath: incomingPDF.path), localDigest == nil || localDigest == input.incomingPDFDigest {
                let target = merged.appendingPathComponent(input.localPDFFileName, isDirectory: false)
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.moveItem(at: incomingPDF, to: target)
                if localDigest == nil { try DocumentDigest.writeSidecar(input.incomingPDFDigest, to: sidecar) }
                output.tookBackupPDF = true
            }
        }
        return output
    }

    /// Writes the combined note ink files, then syncs the whole merged directory to disk.
    @concurrent
    static func writeNoteInk(_ files: [UUID: Data], into merged: URL) async throws {
        let notes = merged.appendingPathComponent("notes", isDirectory: true)
        if !files.isEmpty { try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true) }
        for (noteID, data) in files.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            try data.write(to: notes.appendingPathComponent(noteFileName(noteID)), options: .atomic)
        }
        try RestoreDurability.syncTree(merged)
    }

    /// Copies a note's ink file from the backup's copy as it is (an unreadable drawing, kept).
    @concurrent
    static func copyIncomingNoteInk(from incomingDirectory: URL, incomingNoteID: UUID, to merged: URL, as noteID: UUID) async throws {
        let notes = merged.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try replaceFile(at: notes.appendingPathComponent(noteFileName(noteID)),
                        withCopyOf: incomingDirectory.appendingPathComponent("notes", isDirectory: true)
                            .appendingPathComponent(noteFileName(incomingNoteID)))
    }

    static func noteFileName(_ noteID: UUID) -> String { "\(noteID.uuidString).drawing" }

    // MARK: Page ink

    /// Per page: on one side only, that file; byte-equal, that file; otherwise the union of the
    /// two drawings' strokes (`PageInkMerge`, no base). A page whose local drawing already holds
    /// every stroke of the backup's keeps its file as it is. A drawing that cannot be decoded
    /// leaves the local file as it is, and is reported.
    private static func mergePageInk(_ input: DirectoryInput, into merged: URL, output: inout DirectoryOutput) throws {
        let manager = FileManager.default
        let incomingInk = input.incomingDirectory.appendingPathComponent("ink", isDirectory: true)
        let localInk = input.localDirectory.appendingPathComponent("ink", isDirectory: true)
        let mergedInk = merged.appendingPathComponent("ink", isDirectory: true)
        let incomingPages = pageFiles(in: incomingInk)
        let localPages = pageFiles(in: localInk)
        for page in incomingPages.keys.sorted() {
            try Task.checkCancellation()
            let incomingURL = incomingPages[page]!
            let target = mergedInk.appendingPathComponent(incomingURL.lastPathComponent)
            guard let localURL = localPages[page] else {
                try manager.createDirectory(at: mergedInk, withIntermediateDirectories: true)
                try replaceFile(at: target, withCopyOf: incomingURL)
                output.ink.pagesAdded += 1
                continue
            }
            let localData = try Data(contentsOf: localURL)
            let incomingData = try Data(contentsOf: incomingURL)
            if localData == incomingData { continue }
            guard let local = readableDrawing(localData) else {
                output.unreadable.append(UnreadableInk(location: .page(page), side: .local))
                continue
            }
            guard let incoming = readableDrawing(incomingData) else {
                output.unreadable.append(UnreadableInk(location: .page(page), side: .backup))
                continue
            }
            output.ink.pagesCombined += 1
            let combined = PageInkMerge.merge(local: local, remote: incoming, base: nil)
            if combined.strokes.count == local.strokes.count {
                output.combinedInkAlreadyPresent += 1   // nothing new: the local file stays
                continue
            }
            try combined.dataRepresentation().write(to: target, options: .atomic)
        }
    }

    /// The drawing in a page-ink file, or `nil` when it cannot be read. PencilKit reads some
    /// damaged data as an empty drawing, and the app never stores an empty drawing (it deletes
    /// the file instead), so a file that decodes to no strokes counts as unreadable too: it is
    /// kept as it is rather than replaced by the other side's strokes.
    static func readableDrawing(_ data: Data) -> PKDrawing? {
        guard let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return nil }
        return drawing
    }

    /// `<n>.drawing` files of an ink directory by page index.
    static func pageFiles(in directory: URL) -> [Int: URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var result: [Int: URL] = [:]
        for name in names {
            guard let page = BookStorageLayout.pageIndex(fromPageInkFileName: name) else { continue }
            result[page] = directory.appendingPathComponent(name, isDirectory: false)
        }
        return result
    }

    private static func replaceFile(at target: URL, withCopyOf source: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        try manager.copyItem(at: source, to: target)
    }
}

/// The names the archive writer leaves out of a book's files (hidden and temporary leftovers of
/// atomic writes); a merged directory leaves them out too.
nonisolated enum BackupArchiveWriterNames {
    static func isTemporaryOrHidden(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.hasSuffix("~") { return true }
        let lower = name.lowercased()
        return lower.hasSuffix(".tmp") || lower.hasSuffix(".temp") || lower.hasSuffix(".partial")
    }
}
