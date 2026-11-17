import Foundation
import ReaderBackup
import ReaderCore

/// The notes a round leaves alone because the reader is working on one of them: every note, on
/// any side, that shares an ID or a target with a busy note, closed under both. Leaving out the
/// whole group keeps the rest of the merge from combining another note into one that is busy.
struct SyncNoteSlice: Hashable, Sendable {
    var ids: Set<UUID> = []
    var targets: Set<NoteTarget> = []

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ note: Note) -> Bool { ids.contains(note.id) || targets.contains(note.target) }

    init() {}

    init(busyNotes: Set<UUID>, in archives: [BookArchive]) {
        guard !busyNotes.isEmpty else { return }
        ids = busyNotes
        var changed = true
        while changed {
            changed = false
            for archive in archives {
                for note in archive.notes where contains(note) {
                    if ids.insert(note.id).inserted { changed = true }
                    if targets.insert(note.target).inserted { changed = true }
                }
            }
        }
    }
}

/// The records half of one book's round.
struct SyncRecordPlan {
    /// The merge of the inputs with the busy notes set back to the base on both sides.
    var merge: BookSyncMergeResult
    /// The inputs that merge saw, re-keyed to the local book.
    var neutralLocal: BookArchive
    var neutralRemote: BookArchive
    var base: BookArchive?
    var slice: SyncNoteSlice
    /// What this device's records become: the merge, with the busy notes as they are here.
    var target: BookArchive
    /// What the account's records become if this round pushes: the merge, with the busy notes
    /// as the account has them.
    var push: BookArchive
}

/// The file half: how each file of the merged book is made.
enum SyncFileResolution: Hashable, Sendable {
    /// This content as it is (`nil`: no file).
    case content(ContentDigest?)
    /// An ink merge.
    case merge(SyncInkJob)
}

/// An ink merge to run, by content.
struct SyncInkJob: Hashable, Sendable {
    enum Base: Hashable, Sendable {
        case unavailable
        case none
        case content(ContentDigest)
    }

    /// A note absorbed into the merged one, by the side it is on and its ink.
    struct Absorbed: Hashable, Sendable {
        var side: NoteSyncDecision.Side
        var content: ContentDigest?
    }

    var kind: SyncInkMergeRequest.Kind
    var local: ContentDigest?
    var remote: ContentDigest?
    var base: Base
    /// For a note: the ink of each of the decision's absorbed notes, in order.
    var absorbed: [Absorbed]
    /// For a note: the notes the inks belong to.
    var notes: SyncInkNotes? = nil
}

/// The pure parts of a round, apart from the engine's I/O.
enum SyncPlanning {
    /// Whether two archives carry the same content for sync: the same records by ID (book IDs
    /// aside) and the same title and reading position.
    static func sameContent(_ a: BookArchive, _ b: BookArchive) -> Bool {
        BookArchiveDiff(from: a, to: b).isEmpty
    }

    /// `archive` with the notes of `slice` replaced by those of `source` (re-keyed), or removed
    /// when there is no source.
    static func replacingSlice(_ archive: BookArchive, _ slice: SyncNoteSlice, with source: BookArchive?) -> BookArchive {
        guard !slice.isEmpty else { return archive }
        var result = archive
        result.notes.removeAll(where: slice.contains)
        if let source {
            for var note in source.notes where slice.contains(note) {
                note.bookID = archive.book.id
                result.notes.append(note)
            }
        }
        return BookMerge.canonicalOrder(result)
    }

    /// Plans the records of a round. `nil` when the busy notes cannot be held apart from the
    /// merge this round (a heading one of them is on was folded into another): the whole book
    /// then waits.
    static func recordPlan(local: BookArchive, remote: BookArchive, base: BookArchive?,
                           busy: Set<SyncSurface>) -> SyncRecordPlan? {
        let id = local.book.id
        let remote = BookMerge.rekeyed(remote, to: id)
        let base = base.map { BookMerge.rekeyed($0, to: id) }
        let busyNotes = Set(busy.compactMap { surface -> UUID? in if case .note(let id) = surface { id } else { nil } })
        let slice = SyncNoteSlice(busyNotes: busyNotes, in: [local, remote] + (base.map { [$0] } ?? []))
        let neutralLocal = replacingSlice(local, slice, with: base)
        let neutralRemote = replacingSlice(remote, slice, with: base)
        let merge = BookMerge.merge(local: neutralLocal, remote: neutralRemote, base: base)
        if !slice.isEmpty {
            // The merge must have left the busy notes exactly as the base has them ...
            let merged = Set(merge.archive.notes.filter(slice.contains))
            let inBase = Set((base?.notes ?? []).filter(slice.contains))
            guard merged == inBase else { return nil }
            // ... and not folded a heading a busy note here is on into another.
            for note in local.notes where slice.contains(note) {
                if case .heading(let anchor) = note.target, let heading = anchor.userHeadingID,
                   merge.headingIDRemap[heading] != nil { return nil }
            }
        }
        return SyncRecordPlan(merge: merge, neutralLocal: neutralLocal, neutralRemote: neutralRemote, base: base,
                              slice: slice,
                              target: replacingSlice(merge.archive, slice, with: local),
                              push: replacingSlice(merge.archive, slice, with: remote))
    }

    /// The base a round leaves: the account's records as they are after it (`accountAfter`), but
    /// with the busy notes as the old base had them, so the next round still sees what either
    /// side did to them. Keyed to the local book, whose identity it takes.
    static func baseArchive(accountAfter: BookArchive, oldBase: BookArchive?, slice: SyncNoteSlice,
                            localBook: Book) -> BookArchive {
        var result = BookMerge.rekeyed(accountAfter, to: localBook.id)
        var book = localBook
        book.title = accountAfter.book.title
        book.lastReadPageIndex = accountAfter.book.lastReadPageIndex
        book.lastOpenedAt = accountAfter.book.lastOpenedAt
        result.book = book
        return BookMerge.canonicalOrder(replacingSlice(result, slice, with: oldBase.map { BookMerge.rekeyed($0, to: localBook.id) }))
    }

    /// `files` with the busy pages and the busy notes' ink taken from `source` (removed where it
    /// has none).
    static func replacingBusy(_ files: SyncFileDigests, pages: Set<Int>, notes: Set<UUID>,
                              with source: SyncFileDigests?) -> SyncFileDigests {
        var result = files
        for key in Set(files.keys).union(source.map { Array($0.keys) } ?? []) {
            let busy: Bool = switch key {
            case .pageInk(let page): pages.contains(page)
            case .noteInk(let id): notes.contains(id)
            case .cover, .conversion: false
            }
            if busy { result[key] = source?[key] }
        }
        return result
    }

    // MARK: Files

    /// How each file of the merged book (busy pages and busy notes aside) is made, three-way by
    /// content: changed on one side, that side's; on both, an ink merge (the cover and
    /// `conversion.json`: the account's, unless one side removed it, when the other's is kept).
    static func filePlan(_ plan: SyncRecordPlan, local: SyncFileDigests, remote: SyncFileDigests,
                         base: SyncFileDigests?, busyPages: Set<Int>) -> [SyncFileKey: SyncFileResolution] {
        var result: [SyncFileKey: SyncFileResolution] = [:]
        let hasBase = base != nil
        let base = base ?? [:]

        var pages = Set<Int>()
        for key in Set(local.keys).union(remote.keys).union(base.keys) {
            if case .pageInk(let page) = key, !busyPages.contains(page) { pages.insert(page) }
        }
        for page in pages {
            let key = SyncFileKey.pageInk(page)
            let (l, r, b) = (local[key], remote[key], base[key])
            if l == r { result[key] = .content(l); continue }
            if hasBase && r == b { result[key] = .content(l); continue }
            if hasBase && l == b { result[key] = .content(r); continue }
            result[key] = .merge(SyncInkJob(kind: .page(page), local: l, remote: r,
                                            base: hasBase ? (b.map { .content($0) } ?? .none) : .unavailable, absorbed: []))
        }

        for key in [SyncFileKey.cover, .conversion] {
            let (l, r, b) = (local[key], remote[key], base[key])
            if l == r { result[key] = .content(l) }
            else if hasBase && r == b { result[key] = .content(l) }
            else if hasBase && l == b { result[key] = .content(r) }
            else { result[key] = .content(r ?? l) }
        }

        let decisions = Dictionary(plan.merge.noteDecisions.map { ($0.noteID, $0) }, uniquingKeysWith: { a, _ in a })
        for note in plan.merge.archive.notes where !plan.slice.contains(note) {
            guard let decision = decisions[note.id] else { continue }
            result[.noteInk(note.id)] = noteInk(note, decision, plan, local: local, remote: remote,
                                                base: hasBase ? base : nil)
        }
        return result
    }

    /// One merged note's ink.
    static func noteInk(_ note: Note, _ decision: NoteSyncDecision, _ plan: SyncRecordPlan, local: SyncFileDigests,
                        remote: SyncFileDigests, base: SyncFileDigests?) -> SyncFileResolution {
        func content(_ side: NoteSyncDecision.Side, _ id: UUID) -> ContentDigest? {
            switch side {
            case .local: local[.noteInk(id)]
            case .remote: remote[.noteInk(id)]
            case .base: base?[.noteInk(id)]
            }
        }
        func baseFor(_ source: NoteSyncDecision.InkSource?) -> SyncInkJob.Base {
            guard base != nil, let source else { return .unavailable }
            return content(.base, source.noteID).map { .content($0) } ?? .none
        }

        if decision.source == .merged || !decision.absorbed.isEmpty {
            let l = decision.local.flatMap { content(.local, $0.noteID) }
            let r = decision.remote.flatMap { content(.remote, $0.noteID) }
            let absorbed = decision.absorbed.map { SyncInkJob.Absorbed(side: $0.side, content: content($0.side, $0.noteID)) }
            if l == nil && r == nil && absorbed.allSatisfy({ $0.content == nil }) {
                // Nothing on either side has ink; erasing it all on both is no ink.
                return .content(nil)
            }
            return .merge(SyncInkJob(kind: .note(decision), local: l, remote: r, base: baseFor(decision.base),
                                     absorbed: absorbed, notes: inkNotes(note, decision, plan)))
        }

        // The note is one side's as it is. Its ink is that side's too, unless the other side
        // (which has the note under the same ID) changed the ink since the base.
        let chosen: NoteSyncDecision.Side = decision.source == .local ? .local : .remote
        let other: NoteSyncDecision.Side = chosen == .local ? .remote : .local
        let mine = content(chosen, note.id)
        let otherArchive = other == .local ? plan.neutralLocal : plan.neutralRemote
        guard let otherNote = otherArchive.notes.first(where: { $0.id == note.id }) else { return .content(mine) }
        let theirs = content(other, note.id)
        if theirs == mine { return .content(mine) }
        let baseNote = plan.base?.notes.first(where: { $0.id == note.id })
        let inBase = baseNote == nil ? nil : content(.base, note.id)
        if baseNote != nil && theirs == inBase { return .content(mine) }
        if baseNote != nil && mine == inBase && otherNote.text == note.text && otherNote.bandLayout == note.bandLayout {
            return .content(theirs)
        }
        // Both changed the ink (or the other side's must move to this text): merge it.
        let mineSource = NoteSyncDecision.InkSource(side: chosen, noteID: note.id, paragraphMap: identity(note.text))
        let theirSource = NoteSyncDecision.InkSource(side: other, noteID: note.id,
                                                     paragraphMap: alignment(of: otherNote.text, onto: note.text))
        let baseSource = baseNote.map {
            NoteSyncDecision.InkSource(side: .base, noteID: note.id, paragraphMap: alignment(of: $0.text, onto: note.text))
        }
        let localNote = plan.neutralLocal.notes.first(where: { $0.id == note.id })
        let synthesized = NoteSyncDecision(noteID: note.id, target: note.target, source: .merged,
                                           local: chosen == .local ? mineSource : theirSource,
                                           remote: chosen == .remote ? mineSource : theirSource,
                                           base: baseSource, absorbed: [],
                                           textChanged: localNote.map { $0.text != note.text } ?? false,
                                           needsBandLayout: note.hasInk && note.bandLayout == nil)
        let jobBase: SyncInkJob.Base = base == nil ? .unavailable : (baseNote == nil ? .none : (inBase.map { .content($0) } ?? .none))
        return .merge(SyncInkJob(kind: .note(synthesized), local: content(.local, note.id), remote: content(.remote, note.id),
                                 base: jobBase, absorbed: [], notes: inkNotes(note, synthesized, plan)))
    }

    /// The notes behind a note ink merge, from the archives the merge saw.
    static func inkNotes(_ merged: Note, _ decision: NoteSyncDecision, _ plan: SyncRecordPlan) -> SyncInkNotes {
        func note(_ source: NoteSyncDecision.InkSource?) -> Note? {
            guard let source else { return nil }
            let archive: BookArchive? = switch source.side {
            case .local: plan.neutralLocal
            case .remote: plan.neutralRemote
            case .base: plan.base
            }
            return archive?.notes.first { $0.id == source.noteID }
        }
        return SyncInkNotes(merged: merged, local: note(decision.local), remote: note(decision.remote),
                            base: note(decision.base), absorbed: decision.absorbed.map { note($0) })
    }

    static func identity(_ text: String) -> [Int?] {
        NoteBandLayout.paragraphs(of: text).indices.map { $0 }
    }

    /// For each paragraph of `from`, the paragraph of `to` it lines up with (`nil` for none).
    static func alignment(of from: String, onto to: String) -> [Int?] {
        // A three-way merge whose local side is its base returns the remote text, with the local
        // paragraphs aligned onto it.
        ParagraphMerge.mergeText(local: from, remote: to, base: from).localIndices
    }

    // MARK: Recovery

    /// The base to continue from after a round that wrote its head (or decided to apply without
    /// one) but may not have finished applying here: see `SyncApplyIntent`. Record by record and
    /// file by file, the new base where this device's copy is as the round meant to leave it,
    /// else the old base. `nil` when the book is gone here and had no old base.
    static func effectiveBase(_ intent: SyncApplyIntent, local: SyncLocalSnapshot?) -> SyncBase? {
        guard let eTag = intent.committedETag else { return intent.oldBase }
        guard let local else { return intent.oldBase }
        let id = local.archive.book.id
        let here = local.archive
        let target = BookMerge.rekeyed(intent.target.archive, to: id)
        let newBase = BookMerge.rekeyed(intent.newBase.archive, to: id)
        let oldBase = intent.oldBase.map { BookMerge.rekeyed($0.archive, to: id) }

        func pick<R: Identifiable & Hashable>(_ records: (BookArchive) -> [R]) -> [R] where R.ID == UUID {
            func byID(_ list: [R]) -> [UUID: R] {
                var map: [UUID: R] = [:]
                for record in list where map[record.id] == nil { map[record.id] = record }
                return map
            }
            let h = byID(records(here)), t = byID(records(target)), n = byID(records(newBase))
            let o = byID(oldBase.map(records) ?? [])
            let ids = Set(h.keys).union(t.keys).union(n.keys).union(o.keys).sorted { $0.uuidString < $1.uuidString }
            return ids.compactMap { id in h[id] == t[id] ? n[id] : o[id] }
        }

        var book = here.book
        if here.book.title == target.book.title {
            book.title = newBase.book.title
        } else if let oldBase {
            book.title = oldBase.book.title
        }
        if here.book.lastReadPageIndex == target.book.lastReadPageIndex && here.book.lastOpenedAt == target.book.lastOpenedAt {
            book.lastReadPageIndex = newBase.book.lastReadPageIndex
            book.lastOpenedAt = newBase.book.lastOpenedAt
        } else if let oldBase {
            book.lastReadPageIndex = oldBase.book.lastReadPageIndex
            book.lastOpenedAt = oldBase.book.lastOpenedAt
        }
        let archive = BookMerge.canonicalOrder(BookArchive(book: book, notes: pick(\.notes), highlights: pick(\.highlights),
                                                           bookmarks: pick(\.bookmarks), userHeadings: pick(\.userHeadings)))

        let targetFiles = intent.target.digests, newFiles = intent.newBase.digests
        let oldFiles = intent.oldBase?.files.digests ?? [:]
        var files: SyncFileDigests = [:]
        for key in Set(local.files.keys).union(targetFiles.keys).union(newFiles.keys).union(oldFiles.keys) {
            files[key] = local.files[key] == targetFiles[key] ? newFiles[key] : oldFiles[key]
        }
        // Only a base that is wholly the new one may say it is the head's: one that is partly the
        // old base must not let the next round skip the book as up to date.
        let whole = files == newFiles && sameContent(archive, newBase)
        return SyncBase(bookKey: intent.bookKey, headVersion: intent.headVersion, headETag: whole ? eTag : unmatchedETag,
                        archive: archive, files: SyncBaseFiles(digests: files))
    }

    /// An ETag no head has (a store's ETags are quoted), for a base that agrees with no head as a
    /// whole: the next round reads the head and merges.
    static let unmatchedETag = ""
}

extension ContentDigest {
    /// The SHA-256 and size of `data`.
    init(of data: Data) {
        self.init(sha256: ContentHash.sha256(of: data), size: Int64(data.count))
    }
}
