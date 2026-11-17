import Foundation
import CoreGraphics

/// How the app produces one note's ink after a sync merge, and where each side's paragraphs went.
///
/// The three-way counterpart of `NoteMergeDecision`: it names the local, remote and base notes
/// whose ink takes part, each with a map from its paragraphs to the merged text's, so the app can
/// relay each side's strokes to the merged text and merge them by stroke (`StrokeMerge`): three-way
/// against `base` when it is set, else as a union.
public struct NoteSyncDecision: Hashable, Sendable {
    /// Where the merged note came from, which says what the app does with its ink.
    public enum Source: Hashable, Sendable {
        /// The local note as it is (only this device changed it, or nobody did, or only this
        /// device has it). The local ink file stays as it is.
        case local
        /// The remote note as it is (only the account's copy changed it, or only it has it). The
        /// note's ink is the remote note's ink file, in place of any local one.
        case remote
        /// Both sides changed the note, or two notes on one target were combined: the ink is
        /// merged from `local`, `remote` (three-way against `base` when set, else the union), and
        /// then everything in `absorbed` added.
        case merged
    }

    /// Which archive a contributing note is in.
    public enum Side: Hashable, Sendable {
        case local, remote, base
    }

    /// One note whose ink contributes to the merged note.
    public struct InkSource: Hashable, Sendable {
        public var side: Side
        /// The note's ID in its archive, which keys its ink there.
        public var noteID: UUID
        /// For each paragraph of that note's text (`NoteBandLayout.paragraphs(of:)`), its index in
        /// the merged text's paragraphs, or `nil` where the merge removed the paragraph (ink
        /// anchored there is placed by its position, as for a paragraph a map does not cover).
        public var paragraphMap: [Int?]

        public init(side: Side, noteID: UUID, paragraphMap: [Int?]) {
            self.side = side
            self.noteID = noteID
            self.paragraphMap = paragraphMap
        }
    }

    /// The merged note's ID (`BookSyncMergeResult.archive.notes`).
    public var noteID: UUID
    public var target: NoteTarget
    public var source: Source
    /// The local note whose ink contributes (`nil` for `.remote`, or when no local note does).
    public var local: InkSource?
    /// The remote note whose ink contributes (`nil` for `.local`, or when no remote note does).
    public var remote: InkSource?
    /// The base note to merge `local` and `remote` against; `nil` merges them as a union.
    public var base: InkSource?
    /// Further notes combined into this one because they landed on its target (rare: see
    /// `BookMerge.merge(local:remote:base:)`, notes). Their ink is added as a union after the
    /// three-way merge.
    public var absorbed: [InkSource]
    /// `true` when the merged text differs from the `local` note's text; `false` without one.
    public var textChanged: Bool
    /// `true` when the merged note has ink but no `bandLayout`: the app lays the merged text out
    /// and stores the layout with the merged ink.
    public var needsBandLayout: Bool

    public init(noteID: UUID, target: NoteTarget, source: Source, local: InkSource?, remote: InkSource?,
                base: InkSource?, absorbed: [InkSource], textChanged: Bool, needsBandLayout: Bool) {
        self.noteID = noteID
        self.target = target
        self.source = source
        self.local = local
        self.remote = remote
        self.base = base
        self.absorbed = absorbed
        self.textChanged = textChanged
        self.needsBandLayout = needsBandLayout
    }

    /// The decision for a note of a join (`BookMerge.merge(local:incoming:)`): `localOnly` is
    /// `.local`, `incomingOnly` is `.remote`, a note on both sides is `.merged` with no base.
    public init(joining decision: NoteMergeDecision) {
        let source: Source = switch decision.source {
        case .localOnly: .local
        case .incomingOnly: .remote
        case .unchangedText, .combined: .merged
        }
        self.init(noteID: decision.noteID, target: decision.target, source: source,
                  local: decision.localNoteID.map {
                      InkSource(side: .local, noteID: $0, paragraphMap: (decision.localParagraphMap ?? []).map { $0 })
                  },
                  remote: decision.incomingNoteID.map {
                      InkSource(side: .remote, noteID: $0, paragraphMap: (decision.incomingParagraphMap ?? []).map { $0 })
                  },
                  base: nil, absorbed: [], textChanged: decision.textChanged, needsBandLayout: decision.needsBandLayout)
    }
}

/// The result of `BookMerge.merge(local:remote:base:)`.
public struct BookSyncMergeResult: Hashable, Sendable {
    /// The merged book: the local `Book` with the merged title and reading position, and the
    /// merged records, in `BookMerge.canonicalOrder`, every record keyed to the local book.
    /// Passes `validateForReplacement()` when the inputs do.
    public var archive: BookArchive
    /// One decision per note of `archive`, in the same order.
    public var noteDecisions: [NoteSyncDecision]
    /// Reader-made heading IDs that were found to be another heading and absorbed into it, to
    /// the ID kept. With a base: local headings to the remote heading they matched. Without
    /// (a join): `BookMergeResult.headingIDRemap`, remote headings to local ones.
    public var headingIDRemap: [UUID: UUID]
    /// What applying the merge changes on this device: `BookArchiveDiff(from: local, to:
    /// archive)`, the records to insert, update and delete one by one.
    public var localChanges: BookArchiveDiff
    /// How the merged book differs from the account's copy: `BookArchiveDiff(from: remote, to:
    /// archive)`.
    public var remoteChanges: BookArchiveDiff

    public init(archive: BookArchive, noteDecisions: [NoteSyncDecision], headingIDRemap: [UUID: UUID],
                localChanges: BookArchiveDiff, remoteChanges: BookArchiveDiff) {
        self.archive = archive
        self.noteDecisions = noteDecisions
        self.headingIDRemap = headingIDRemap
        self.localChanges = localChanges
        self.remoteChanges = remoteChanges
    }

    /// `true` when the account's copy lacks something the merged book has, so it must be pushed.
    public var needsPush: Bool { !remoteChanges.isEmpty }

    /// The decisions whose note needs ink work here: `.remote` (take the remote ink file) and
    /// `.merged` (merge the inks). `.local` notes keep their ink file as it is.
    public var inkDecisions: [NoteSyncDecision] { noteDecisions.filter { $0.source != .local } }
}

extension BookMerge {
    /// Merges the account's copy of a book (`remote`) into this device's (`local`), given what
    /// this device last agreed with the account (`base`); the record half of a sync round.
    ///
    /// **No base** (a device joining): exactly `merge(local:incoming:)`, add-only, nothing
    /// removed; its decisions translated by `NoteSyncDecision.init(joining:)`.
    ///
    /// **With a base**, every record is compared with the base by ID, after the remote and base
    /// records are re-keyed to the local book's ID (the copies may have been imported apart):
    /// - *Changed on one side only:* that side's version. *Changed on both the same way:* it.
    /// - *In the base and gone from one side:* deleted there, so removed, unless the other side
    ///   changed it since the base: the edit wins and the record is kept as that side has it.
    ///   A record gone from both is gone.
    /// - *Changed on both sides,* field by field, a field changed on one side only taking that
    ///   side's value, and where both changed it:
    ///   - *Highlights:* the remote colour; its place (page, rects, text and text source) as one.
    ///   - *Reader-made headings:* the remote title, page and parent, each on its own.
    ///   - *Notes:* the text merged by `ParagraphMerge.mergeText(local:remote:base:)`, the
    ///     earlier `createdAt`, the later `modifiedAt`, `hasInk` when either has ink (the app sets
    ///     it from the merged drawing), the remote target. `bandLayout` is that of a side whose
    ///     text is the merged text, else `nil`.
    ///   So the account's version wins a real conflict and every device settles on the version
    ///   that synced first; a note's text keeps both versions.
    /// - *Added on both sides with the same ID* (no base entry): as changed on both.
    /// - *Bookmarks* are a set of pages: a page is kept when both sides have it or a side added
    ///   it since the base, and removed when either side removed it. On a page both sides have,
    ///   the record changed since the base; the remote record, with the earlier `createdAt`,
    ///   when both did.
    /// - *Book:* the title three-way as above. The reading position (`lastReadPageIndex` with
    ///   `lastOpenedAt`) from the side that changed it; when both did, the later `lastOpenedAt`,
    ///   the remote one on a tie. Every other `Book` field is the local one.
    ///
    /// **Records each side added on its own** (an ID neither the base nor the other side has)
    /// are matched as `merge(local:incoming:)` matches them, the account's record kept:
    /// - a local heading with the same normalised title, page and parent (after mapping) as a
    ///   remote one becomes it: local notes on it and local children of it follow
    ///   (`headingIDRemap`), each remote heading absorbing at most one, parents resolved before
    ///   children, cycles cut, and refused where local notes sit on both headings;
    /// - a local highlight that duplicates a remote one by place (`isDuplicate`) is dropped;
    /// - bookmarks fall out of the page rule.
    /// Only new-against-new records are matched, so records both sides already share are never
    /// folded together.
    ///
    /// **Notes on one target.** After the above, notes that land on the same target (a note
    /// each side added on a page, a note kept by an edit beside one the other side re-created,
    /// a target moved by a heading match) are combined into one: the remote note's ID (else
    /// the first in ID order), the texts joined with `ParagraphMerge.mergeText(local:incoming:)`
    /// (a two-way union: different notes share no base), local first, the earliest `createdAt`,
    /// the latest `modifiedAt`, `hasInk` if any has ink. A merged note that ends up empty (no
    /// text, no ink) is removed, as the store would.
    ///
    /// **Properties** (tested over generated archives): with `local` equal to `base`, the result
    /// is `remote` (with the local book identity), so a device that changed nothing adopts the
    /// account's copy and pushes nothing; with `remote` equal to `base`, the result is `local`;
    /// merging the result with itself as base and remote changes nothing; any number of devices
    /// syncing through one remote in any order end equal, and a further round changes nothing.
    /// The result depends on which device synced first (the account's version wins), not only on
    /// the edits made.
    ///
    /// **Input:** archives are expected to pass `validateForReplacement()` apart from the book IDs
    /// of remote and base records. Records that would break it are left out of all three first
    /// (an empty note, then after the first in canonical order a repeated ID, note target or
    /// bookmark page), so bad input neither loops nor traps.
    public static func merge(local: BookArchive, remote: BookArchive, base: BookArchive?) -> BookSyncMergeResult {
        let localBefore = canonicalOrder(local)
        let remoteBefore = canonicalOrder(rekeyed(remote, to: local.book.id))
        let archive: BookArchive
        let decisions: [NoteSyncDecision]
        let remap: [UUID: UUID]
        if let base {
            var merger = ThreeWayMerger(local: local, remote: remote, base: base)
            (archive, decisions, remap) = merger.run()
        } else {
            let joined = merge(local: local, incoming: remote)
            archive = joined.archive
            decisions = joined.noteDecisions.map(NoteSyncDecision.init(joining:))
            remap = joined.headingIDRemap
        }
        return BookSyncMergeResult(archive: archive, noteDecisions: decisions, headingIDRemap: remap,
                                   localChanges: BookArchiveDiff(from: localBefore, to: archive),
                                   remoteChanges: BookArchiveDiff(from: remoteBefore, to: archive))
    }

    /// The archive with every record's `bookID` set to `bookID` (the `Book` itself unchanged).
    public static func rekeyed(_ archive: BookArchive, to bookID: UUID) -> BookArchive {
        var result = archive
        for k in result.notes.indices { result.notes[k].bookID = bookID }
        for k in result.highlights.indices { result.highlights[k].bookID = bookID }
        for k in result.bookmarks.indices { result.bookmarks[k].bookID = bookID }
        for k in result.userHeadings.indices { result.userHeadings[k].bookID = bookID }
        return result
    }
}

// MARK: - Implementation

private func unique<T, K: Hashable>(_ records: [T], by key: KeyPath<T, K>) -> [T] {
    var seen = Set<K>()
    return records.filter { seen.insert($0[keyPath: key]).inserted }
}

private func firstByID<R: Identifiable>(_ records: [R]) -> [R.ID: R] {
    var result: [R.ID: R] = [:]
    for record in records where result[record.id] == nil { result[record.id] = record }
    return result
}

/// A field's merged value: the local one when only the local side changed it, else the remote
/// one (changed only there, changed on both, or no base to tell).
private func pick<T: Equatable>(_ local: T, _ remote: T, _ base: T?) -> T {
    if let base, remote == base { return local }
    return remote
}

/// A record on both sides: unchanged, changed on one side, or `both` to merge field by field.
private func resolve<R: Equatable>(_ local: R, _ remote: R, _ base: R?, _ both: (R, R, R?) -> R) -> R {
    if local == remote { return local }
    if let base {
        if local == base { return remote }
        if remote == base { return local }
    }
    return both(local, remote, base)
}

private struct ThreeWayMerger {
    let bookID: UUID
    let localBook: Book
    var local: BookArchive
    let remote: BookArchive
    let base: BookArchive
    /// Local heading ID to the remote heading it was matched with.
    var remap: [UUID: UUID] = [:]

    init(local: BookArchive, remote: BookArchive, base: BookArchive) {
        bookID = local.book.id
        localBook = local.book
        self.local = Self.prepared(local, bookID: bookID)
        self.remote = Self.prepared(remote, bookID: bookID)
        self.base = Self.prepared(base, bookID: bookID)
    }

    /// Re-keyed, in canonical order, without the records that would make the result invalid.
    static func prepared(_ archive: BookArchive, bookID: UUID) -> BookArchive {
        var a = BookMerge.canonicalOrder(BookMerge.rekeyed(archive, to: bookID))
        a.userHeadings = unique(a.userHeadings, by: \.id)
        a.highlights = unique(a.highlights, by: \.id)
        a.bookmarks = unique(unique(a.bookmarks, by: \.id), by: \.pageIndex)
        a.notes = unique(unique(a.notes.filter { !$0.isEmpty }, by: \.id), by: \.target)
        return a
    }

    mutating func run() -> (BookArchive, [NoteSyncDecision], [UUID: UUID]) {
        absorbNewLocalHeadings()
        dropNewLocalDuplicateHighlights()
        let headings = Self.threeWay(local.userHeadings, remote.userHeadings, base.userHeadings, both: Self.mergeHeading)
        let highlights = Self.threeWay(local.highlights, remote.highlights, base.highlights, both: Self.mergeHighlight)
        let (notes, decisions) = mergeNotes()
        let bookmarks = mergeBookmarks()
        let archive = BookMerge.canonicalOrder(BookArchive(book: mergedBook(), notes: notes, highlights: highlights,
                                                           bookmarks: bookmarks, userHeadings: headings))
        let decisionByID = Dictionary(decisions.map { ($0.noteID, $0) }, uniquingKeysWith: { a, _ in a })
        return (archive, archive.notes.map { decisionByID[$0.id]! }, remap)
    }

    // MARK: Generic

    /// Records by ID, three-way (see `BookMerge.merge(local:remote:base:)`).
    static func threeWay<R: Identifiable & Equatable>(_ local: [R], _ remote: [R], _ base: [R],
                                                      both: (R, R, R?) -> R) -> [R] where R.ID == UUID {
        let remoteByID = firstByID(remote), baseByID = firstByID(base)
        let localIDs = Set(local.map(\.id))
        var result: [R] = []
        for record in local {
            let old = baseByID[record.id]
            if let other = remoteByID[record.id] {
                result.append(resolve(record, other, old, both))
            } else if old == nil || old != record {
                result.append(record)   // added here, or deleted there but edited here
            }
        }
        for record in remote where !localIDs.contains(record.id) {
            let old = baseByID[record.id]
            if old == nil || old != record { result.append(record) }
        }
        return result
    }

    static func mergeHeading(_ l: UserHeading, _ r: UserHeading, _ b: UserHeading?) -> UserHeading {
        var merged = r
        merged.title = pick(l.title, r.title, b.map(\.title))
        merged.pageIndex = pick(l.pageIndex, r.pageIndex, b.map(\.pageIndex))
        merged.parent = pick(l.parent, r.parent, b.map(\.parent))
        merged.createdAt = pick(l.createdAt, r.createdAt, b.map(\.createdAt))
        return merged
    }

    private struct Placement: Equatable {
        var pageIndex: Int
        var rects: [CGRect]
        var text: String
        var textSource: HighlightTextSource?
        init(_ h: Highlight) { pageIndex = h.pageIndex; rects = h.rects; text = h.text; textSource = h.textSource }
    }

    static func mergeHighlight(_ l: Highlight, _ r: Highlight, _ b: Highlight?) -> Highlight {
        var merged = r
        let place = pick(Placement(l), Placement(r), b.map(Placement.init))
        merged.pageIndex = place.pageIndex
        merged.rects = place.rects
        merged.text = place.text
        merged.textSource = place.textSource
        merged.color = pick(l.color, r.color, b.map(\.color))
        merged.createdAt = pick(l.createdAt, r.createdAt, b.map(\.createdAt))
        return merged
    }

    // MARK: Records added on both sides

    /// Matches headings only the local side has with headings only the remote side has (by
    /// normalised title, page and parent) and folds each match into the remote heading.
    mutating func absorbNewLocalHeadings() {
        let remoteIDs = Set(remote.userHeadings.map(\.id)), baseIDs = Set(base.userHeadings.map(\.id))
        let localIDs = Set(local.userHeadings.map(\.id))
        let newLocal = local.userHeadings.filter { !remoteIDs.contains($0.id) && !baseIDs.contains($0.id) }
        let newRemote = remote.userHeadings.filter { !localIDs.contains($0.id) && !baseIDs.contains($0.id) }
        guard !newLocal.isEmpty, !newRemote.isEmpty else { return }

        struct Key: Hashable { let title: String; let page: Int; let parent: String? }
        var candidates: [Key: [UUID]] = [:]
        for heading in newRemote {   // canonical order
            let key = Key(title: OutlineText.normalizedTitle(heading.title), page: heading.pageIndex, parent: heading.parent?.rawValue)
            candidates[key, default: []].append(heading.id)
        }
        let noteTargets = Set(local.notes.map(\.target))
        let byID = Dictionary(uniqueKeysWithValues: newLocal.map { ($0.id, $0) })
        func newParentID(_ heading: UserHeading) -> UUID? {
            guard let id = heading.parent?.userHeadingID, byID[id] != nil else { return nil }
            return id
        }
        // Parents before children, iteratively; `visiting` cuts cycles.
        var decided = Set<UUID>(), visiting = Set<UUID>(), claimed = Set<UUID>()
        for root in newLocal where !decided.contains(root.id) {
            var stack = [root.id]
            visiting.insert(root.id)
            while let top = stack.last {
                let heading = byID[top]!
                if let parentID = newParentID(heading), !decided.contains(parentID), !visiting.contains(parentID) {
                    visiting.insert(parentID)
                    stack.append(parentID)
                    continue
                }
                let parent = mapped(heading.parent)
                let key = Key(title: OutlineText.normalizedTitle(heading.title), page: heading.pageIndex, parent: parent?.rawValue)
                let own = NoteTarget.heading(heading.anchor)
                let match = candidates[key]?.first { id in
                    !claimed.contains(id)
                        && !(noteTargets.contains(own) && noteTargets.contains(.heading(HeadingAnchor(userHeadingID: id))))
                }
                if let match {
                    claimed.insert(match)
                    remap[top] = match
                }
                decided.insert(top)
                visiting.remove(top)
                stack.removeLast()
            }
        }
        guard !remap.isEmpty else { return }
        local.userHeadings = local.userHeadings.filter { remap[$0.id] == nil }.map { heading in
            var moved = heading
            moved.parent = mapped(heading.parent)
            return moved
        }
        local.notes = local.notes.map { note in
            var moved = note
            if case .heading(let anchor) = note.target, let target = mapped(anchor) { moved.target = .heading(target) }
            return moved
        }
    }

    /// A local anchor with matched local heading IDs replaced by the remote ones.
    func mapped(_ anchor: HeadingAnchor?) -> HeadingAnchor? {
        guard let anchor, let id = anchor.userHeadingID, let target = remap[id] else { return anchor }
        return HeadingAnchor(userHeadingID: target)
    }

    /// Drops highlights only the local side has that duplicate, by place, one only the remote
    /// side has.
    mutating func dropNewLocalDuplicateHighlights() {
        let remoteIDs = Set(remote.highlights.map(\.id)), baseIDs = Set(base.highlights.map(\.id))
        let localIDs = Set(local.highlights.map(\.id))
        var newRemote: [Int: [Highlight]] = [:]
        for highlight in remote.highlights where !localIDs.contains(highlight.id) && !baseIDs.contains(highlight.id) {
            newRemote[highlight.pageIndex, default: []].append(highlight)
        }
        guard !newRemote.isEmpty else { return }
        local.highlights.removeAll { highlight in
            !remoteIDs.contains(highlight.id) && !baseIDs.contains(highlight.id)
                && newRemote[highlight.pageIndex]?.contains { BookMerge.isDuplicate($0, highlight) } == true
        }
    }

    // MARK: Notes

    /// A note after the by-ID merge, with the versions it came from.
    struct Member {
        var note: Note
        var source: NoteSyncDecision.Source
        var local: NoteSyncDecision.InkSource?
        var remote: NoteSyncDecision.InkSource?
        var base: NoteSyncDecision.InkSource?
        var localNote: Note?
        var remoteNote: Note?
        var absorbed: [NoteSyncDecision.InkSource] = []

        static func identity(_ note: Note) -> [Int?] { NoteBandLayout.paragraphs(of: note.text).indices.map { $0 } }

        static func local(_ note: Note) -> Member {
            Member(note: note, source: .local, local: .init(side: .local, noteID: note.id, paragraphMap: identity(note)),
                   localNote: note)
        }

        static func remote(_ note: Note) -> Member {
            Member(note: note, source: .remote, remote: .init(side: .remote, noteID: note.id, paragraphMap: identity(note)),
                   remoteNote: note)
        }
    }

    func mergeNotes() -> ([Note], [NoteSyncDecision]) {
        let remoteByID = firstByID(remote.notes), baseByID = firstByID(base.notes)
        let localIDs = Set(local.notes.map(\.id))
        var members: [Member] = []
        for note in local.notes {
            let old = baseByID[note.id]
            if let other = remoteByID[note.id] {
                if note == other || (old != nil && other == old) {
                    members.append(.local(note))
                } else if old == note {
                    members.append(.remote(other))
                } else {
                    members.append(Self.bothChanged(note, other, old))
                }
            } else if old == nil || old != note {
                members.append(.local(note))
            }
        }
        for note in remote.notes where !localIDs.contains(note.id) {
            let old = baseByID[note.id]
            if old == nil || old != note { members.append(.remote(note)) }
        }

        // Combine notes that landed on one target.
        var groups: [NoteTarget: [Member]] = [:]
        for member in members { groups[member.note.target, default: []].append(member) }
        var notes: [Note] = []
        var decisions: [NoteSyncDecision] = []
        for group in groups.values {
            let member = group.count == 1 ? group[0] : Self.combined(group)
            guard !member.note.isEmpty else { continue }
            let note = member.note
            notes.append(note)
            decisions.append(NoteSyncDecision(noteID: note.id, target: note.target, source: member.source,
                                              local: member.local, remote: member.remote, base: member.base,
                                              absorbed: member.absorbed,
                                              textChanged: member.localNote.map { $0.text != note.text } ?? false,
                                              needsBandLayout: note.hasInk && note.bandLayout == nil))
        }
        return (notes, decisions)
    }

    /// One note both sides changed since the base (or both added under one ID).
    static func bothChanged(_ l: Note, _ r: Note, _ b: Note?) -> Member {
        var merged = l
        merged.target = pick(l.target, r.target, b.map(\.target))
        var member = Member(note: merged, source: .merged, localNote: l, remoteNote: r)
        if let b {
            let text = ParagraphMerge.mergeText(local: l.text, remote: r.text, base: b.text)
            merged.text = text.text
            member.local = .init(side: .local, noteID: l.id, paragraphMap: text.localIndices)
            member.remote = .init(side: .remote, noteID: r.id, paragraphMap: text.remoteIndices)
            member.base = .init(side: .base, noteID: b.id, paragraphMap: text.baseIndices)
        } else {
            let text = ParagraphMerge.mergeText(local: l.text, incoming: r.text)
            merged.text = text.text
            member.local = .init(side: .local, noteID: l.id, paragraphMap: text.localIndices.map { $0 })
            member.remote = .init(side: .remote, noteID: r.id, paragraphMap: text.incomingIndices.map { $0 })
        }
        merged.createdAt = min(l.createdAt, r.createdAt)
        merged.modifiedAt = max(l.modifiedAt, r.modifiedAt)
        merged.hasInk = l.hasInk || r.hasInk
        merged.bandLayout = layout(for: merged.text, from: [l, r])
        member.note = merged
        return member
    }

    /// The layout of a side whose text is `text`, else `nil` (the app lays the text out).
    static func layout(for text: String, from notes: [Note?]) -> NoteBandLayout? {
        notes.lazy.compactMap { $0 }.first { $0.text == text && $0.bandLayout != nil }?.bandLayout
    }

    /// Notes on one target folded into one: see `BookMerge.merge(local:remote:base:)`, notes.
    static func combined(_ unsorted: [Member]) -> Member {
        let group = unsorted.sorted { $0.note.id.uuidString < $1.note.id.uuidString }
        let primaryIndex = group.firstIndex { $0.remoteNote != nil && $0.localNote != nil }
            ?? group.firstIndex { $0.remoteNote != nil } ?? 0
        var result = group[primaryIndex]
        result.source = .merged
        var rest = group
        rest.remove(at: primaryIndex)

        func compose(_ source: NoteSyncDecision.InkSource?, _ indices: [Int]) -> NoteSyncDecision.InkSource? {
            guard var source else { return nil }
            source.paragraphMap = source.paragraphMap.map { $0.map { indices[$0] } }
            return source
        }
        // A local-only partner of a remote primary takes the local slot, its text first.
        if result.localNote == nil, let partnerIndex = rest.firstIndex(where: { $0.localNote != nil }) {
            let partner = rest.remove(at: partnerIndex)
            let text = ParagraphMerge.mergeText(local: partner.note.text, incoming: result.note.text)
            result.remote = compose(result.remote, text.incomingIndices)
            result.base = compose(result.base, text.incomingIndices)
            result.absorbed = result.absorbed.compactMap { compose($0, text.incomingIndices) }
            result.local = compose(partner.local, text.localIndices)
            result.absorbed += [partner.remote, partner.base].compactMap { compose($0, text.localIndices) }
            result.absorbed += partner.absorbed.compactMap { compose($0, text.localIndices) }
            result.localNote = partner.localNote
            result.note = folded(result.note, partner.note, text: text.text)
        }
        for other in rest {
            let text = ParagraphMerge.mergeText(local: result.note.text, incoming: other.note.text)
            result.local = compose(result.local, text.localIndices)
            result.remote = compose(result.remote, text.localIndices)
            result.base = compose(result.base, text.localIndices)
            result.absorbed = result.absorbed.compactMap { compose($0, text.localIndices) }
            // Without its base: an absorbed note's ink is added as a union.
            result.absorbed += [other.local, other.remote].compactMap { compose($0, text.incomingIndices) }
            result.absorbed += other.absorbed.compactMap { compose($0, text.incomingIndices) }
            result.note = folded(result.note, other.note, text: text.text)
        }
        result.note.bandLayout = layout(for: result.note.text, from: [result.localNote, result.remoteNote])
        return result
    }

    static func folded(_ kept: Note, _ other: Note, text: String) -> Note {
        var note = kept
        note.text = text
        note.createdAt = min(kept.createdAt, other.createdAt)
        note.modifiedAt = max(kept.modifiedAt, other.modifiedAt)
        note.hasInk = kept.hasInk || other.hasInk
        return note
    }

    // MARK: Bookmarks and book

    func mergeBookmarks() -> [Bookmark] {
        func byPage(_ records: [Bookmark]) -> [Int: Bookmark] {
            Dictionary(records.map { ($0.pageIndex, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let l = byPage(local.bookmarks), r = byPage(remote.bookmarks), b = byPage(base.bookmarks)
        let reserved = Set((local.bookmarks + remote.bookmarks + base.bookmarks).map(\.id))
        var used = Set<UUID>()
        var result: [Bookmark] = []
        for page in Set(l.keys).union(r.keys).sorted() {
            var chosen: Bookmark?
            switch (l[page], r[page]) {
            case (let mine?, let theirs?):
                chosen = resolve(mine, theirs, b[page]) { mine, theirs, _ in
                    var merged = theirs
                    merged.createdAt = min(mine.createdAt, theirs.createdAt)
                    return merged
                }
            case (let only?, nil), (nil, let only?):
                chosen = b[page] == nil ? only : nil   // added on one side, or removed on the other
            case (nil, nil):
                chosen = nil
            }
            guard var bookmark = chosen else { continue }
            if used.contains(bookmark.id) {
                let original = bookmark.id
                var attempt = 0
                repeat {
                    bookmark.id = BookMerge.freshID(for: original, in: bookID, attempt: attempt)
                    attempt += 1
                } while used.contains(bookmark.id) || reserved.contains(bookmark.id)
            }
            used.insert(bookmark.id)
            result.append(bookmark)
        }
        return result
    }

    func mergedBook() -> Book {
        var book = localBook
        book.title = pick(localBook.title, remote.book.title, base.book.title)
        struct Position: Equatable { var page: Int; var opened: Date? }
        let l = Position(page: localBook.lastReadPageIndex, opened: localBook.lastOpenedAt)
        let r = Position(page: remote.book.lastReadPageIndex, opened: remote.book.lastOpenedAt)
        let b = Position(page: base.book.lastReadPageIndex, opened: base.book.lastOpenedAt)
        let position: Position
        if l == r || r == b {
            position = l
        } else if l == b {
            position = r
        } else {
            // Both moved: the later opening, the remote one on a tie (nil is never opened).
            position = (l.opened ?? .distantPast) > (r.opened ?? .distantPast) ? l : r
        }
        book.lastReadPageIndex = position.page
        book.lastOpenedAt = position.opened
        return book
    }
}
