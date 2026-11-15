import Foundation
import CoreGraphics

/// How the app produces one merged note's ink, and where each side's paragraphs went.
///
/// The record merge cannot touch ink (it is PencilKit data, and laying text out needs TextKit),
/// so it says, for every note of the merged archive, which notes' ink to combine and how the
/// text moved. The app relays each side's strokes to the merged text with the paragraph maps,
/// so handwriting stays with the paragraph it was written on.
public struct NoteMergeDecision: Hashable, Sendable {
    /// Where the merged note came from.
    public enum Source: Hashable, Sendable {
        /// Only the local book has a note on this target; it is kept as it is.
        case localOnly
        /// Only the incoming archive has a note on this target; it is added.
        case incomingOnly
        /// Both have one and the merged text is the local text (equal texts, or every incoming
        /// paragraph is already in the local text in order).
        case unchangedText
        /// Both have one and the texts were combined with `ParagraphMerge`; the merged text
        /// differs from the local text.
        case combined
    }

    /// The merged note's ID (`BookMergeResult.archive.notes`).
    public var noteID: UUID
    /// The merged note's target (incoming heading targets after `BookMergeResult.headingIDRemap`).
    public var target: NoteTarget
    public var source: Source
    /// The local note whose ink file contributes, `nil` when the local book had no note here.
    /// Equal to `noteID` when present.
    public var localNoteID: UUID?
    /// The incoming note whose ink file contributes, by its ID in the incoming archive (which is
    /// what keys its ink there), `nil` when the incoming archive had no note here. It differs
    /// from `noteID` for a combined note and for an added note whose ID was taken locally.
    public var incomingNoteID: UUID?
    /// `true` when the merged text differs from the local note's text. Always `false` for a note
    /// on one side only (its text is that side's).
    public var textChanged: Bool
    /// For each paragraph of the local note's text (`NoteBandLayout.paragraphs(of:)`), its index
    /// in the merged text's paragraphs; `nil` without a local note.
    public var localParagraphMap: [Int]?
    /// The same for the incoming note's text; `nil` without an incoming note.
    public var incomingParagraphMap: [Int]?
    /// `true` when the merged note has ink but no `bandLayout`: the text changed, or the ink
    /// came only from the incoming side of a note whose local copy had none. The app lays the
    /// merged text out and stores the layout with the merged ink.
    public var needsBandLayout: Bool

    public init(noteID: UUID, target: NoteTarget, source: Source, localNoteID: UUID?, incomingNoteID: UUID?,
                textChanged: Bool, localParagraphMap: [Int]?, incomingParagraphMap: [Int]?, needsBandLayout: Bool) {
        self.noteID = noteID
        self.target = target
        self.source = source
        self.localNoteID = localNoteID
        self.incomingNoteID = incomingNoteID
        self.textChanged = textChanged
        self.localParagraphMap = localParagraphMap
        self.incomingParagraphMap = incomingParagraphMap
        self.needsBandLayout = needsBandLayout
    }
}

/// What a merge adds and combines, for the restore preview and summary.
public struct BookMergeReport: Hashable, Sendable {
    /// Incoming notes on a target the local book had no note on.
    public var notesAdded = 0
    /// Notes on both sides whose text the merge changed (`NoteMergeDecision.Source.combined`).
    public var notesCombined = 0
    /// Notes on both sides whose merged text is the local text
    /// (`NoteMergeDecision.Source.unchangedText`): identical texts, or an incoming text the
    /// local one already contains, as on a second merge of the same backup.
    public var notesIdentical = 0
    /// Incoming highlights added.
    public var highlightsAdded = 0
    /// Incoming highlights with an ID the local book does not have that duplicate a local one
    /// (same page, text and rects within `BookMerge.rectTolerance`), left out.
    public var duplicatesSkipped = 0
    /// Incoming bookmarks on a page the local book had no bookmark on.
    public var bookmarksAdded = 0
    /// Incoming reader-made headings added.
    public var headingsAdded = 0
    /// Incoming reader-made headings found to be local ones, by ID or by title, page and parent.
    public var headingsMatched = 0

    public init() {}

    /// `true` when the merge adds or combines nothing (no new records, no note text changed).
    /// Dates and ink flags of notes and bookmarks on both sides may still change.
    public var addsNothing: Bool {
        notesAdded == 0 && notesCombined == 0 && highlightsAdded == 0 && bookmarksAdded == 0 && headingsAdded == 0
    }
}

/// The result of `BookMerge.merge(local:incoming:)`.
public struct BookMergeResult: Hashable, Sendable {
    /// The merged book: the local `Book` and the union of the records, in
    /// `BookMerge.canonicalOrder`. Passes `validateForReplacement()` when the local archive does.
    public var archive: BookArchive
    /// One decision per note of `archive`, in the same order.
    public var noteDecisions: [NoteMergeDecision]
    /// Incoming reader-made heading IDs that became a local heading (matched by title, page and
    /// parent), to the local ID. Headings matched by ID and headings added keep their ID and are
    /// not listed.
    public var headingIDRemap: [UUID: UUID]
    public var report: BookMergeReport

    public init(archive: BookArchive, noteDecisions: [NoteMergeDecision], headingIDRemap: [UUID: UUID], report: BookMergeReport) {
        self.archive = archive
        self.noteDecisions = noteDecisions
        self.headingIDRemap = headingIDRemap
        self.report = report
    }
}

/// The record half of merging a restored book into the one already in the Library: value types
/// in, value types out, no files and no ink.
///
/// **Owner decisions this implements:** a merge brings in everything the incoming (backed-up)
/// archive has that the local book lacks, including things deleted locally after the backup (no
/// deletion tracking), and never removes anything local. A note on both sides with different
/// text is combined paragraph by paragraph (`ParagraphMerge`).
///
/// **Rules:**
/// - *Book.* The local `Book` is kept exactly (ID, title, file, fingerprint, reading position,
///   dates). Every incoming record is re-keyed to its ID, because the backup's copy of the same
///   PDF may have been imported separately under another ID.
/// - *Reader-made headings.* Same ID: one heading, the local fields win (headings carry no edit
///   date). Otherwise an incoming heading with the same `OutlineText.normalizedTitle`, page and
///   parent as a local heading is that heading: the local one is kept and the incoming ID maps
///   to it (`BookMergeResult.headingIDRemap`). The parent is compared after mapping, so a parent
///   is resolved before its children and chains of matches follow; a PDF heading's anchor
///   compares as it is. Each local heading absorbs at most one incoming heading; candidates are
///   taken in canonical order. A match is refused when the incoming archive has notes both on
///   the incoming heading and on the local one (an orphaned note), since the two notes would
///   then land on one target. Any other incoming heading is added, its parent mapped. A parent
///   cycle in the input is cut where the walk first meets it (that parent compares as it is), and
///   a parent that resolves nowhere compares as it is, so bad input neither loops nor traps.
/// - *Notes,* by target, after mapping incoming heading targets. One side only: kept or added.
///   Both: one note with the local ID, the earlier `createdAt`, the later `modifiedAt`, and
///   `hasInk` if either has ink; its text is the local text when equal, otherwise
///   `ParagraphMerge.mergeText(local:incoming:)`. `bandLayout` needs text layout, so it stays the
///   local note's when the text is unchanged and becomes `nil` when the text changed (see
///   `NoteMergeDecision.needsBandLayout`). An added note whose ID a local note already uses gets
///   a fresh ID (see `freshID`).
/// - *Highlights.* Same ID: the local one. Another ID but the same page, the same text and the
///   same rects within `rectTolerance`: a duplicate, the local one kept. Otherwise added.
///   Duplicates are looked for among local highlights only, so the outcome for one incoming
///   highlight never depends on the others.
/// - *Bookmarks.* Union by page: on a page both have, the local record's ID with the earlier
///   `createdAt`. An added bookmark whose ID a local one already uses gets a fresh ID.
///
/// **Properties** (tested over generated archives): every local record is in the result with
/// its ID; merging the same incoming archive into the result again gives the same archive and
/// adds nothing; merging an empty incoming archive gives the local archive in canonical order;
/// the result does not depend on the order of any input array.
///
/// **Input:** both archives are expected to pass `validateForReplacement()` apart from the
/// incoming records' book IDs (the store and a verified backup produce such archives). Incoming
/// records that would break it anyway are left out: an empty note, and after the first in
/// canonical order, a repeated ID, note target or bookmark page.
public enum BookMerge {
    /// How far apart two highlight rects' edges may be, in PDF page-space points, for the
    /// highlights to be duplicates. Each of `minX`, `minY`, `maxX` and `maxY` is compared. Half a
    /// point absorbs rounding in the same selection made on two devices, and is well below the
    /// gap between two lines or two words, so distinct highlights never fall within it.
    public static let rectTolerance: CGFloat = 0.5

    /// Merges `incoming` into `local`; see the type's rules.
    public static func merge(local: BookArchive, incoming: BookArchive) -> BookMergeResult {
        var merger = Merger(local: canonicalOrder(local), incoming: canonicalOrder(incoming))
        return merger.run()
    }

    /// The archive with each record array in the order the merge produces:
    /// - notes: page notes by page, then heading notes by anchor `rawValue`, then by ID;
    /// - highlights: `Highlight.readingOrder`;
    /// - bookmarks: by page, then by ID;
    /// - user headings: by page, then `createdAt`, then ID.
    ///
    /// The store returns records in no particular order, so the merge sorts its inputs and its
    /// output: the same records always give the same result.
    public static func canonicalOrder(_ archive: BookArchive) -> BookArchive {
        var result = archive
        result.notes.sort(by: noteOrder)
        result.highlights.sort(by: Highlight.readingOrder)
        result.bookmarks.sort { ($0.pageIndex, $0.id.uuidString) < ($1.pageIndex, $1.id.uuidString) }
        result.userHeadings.sort(by: headingOrder)
        return result
    }

    /// A deterministic replacement ID for an incoming record whose ID the merged archive already
    /// uses: derived from the local book's ID, the record's ID and `attempt` by a fixed hash, so
    /// running the same merge again (as the app does at commit time) gives the same ID. Callers
    /// try `attempt` 0, 1, … until the ID is unused.
    public static func freshID(for recordID: UUID, in bookID: UUID, attempt: Int) -> UUID {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: bookID.uuid) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: recordID.uuid) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(truncatingIfNeeded: attempt).littleEndian) { bytes.append(contentsOf: $0) }
        // Two FNV-1a 64-bit hashes with different offsets, finished with a SplitMix64 mix.
        func hash(_ seed: UInt64) -> UInt64 {
            var h = seed
            for byte in bytes { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
            h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
            h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
            return h ^ (h >> 31)
        }
        let high = hash(0xCBF2_9CE4_8422_2325), low = hash(0x8422_2325_CBF2_9CE4)
        var out = [UInt8](repeating: 0, count: 16)
        for k in 0..<8 {
            out[k] = UInt8(truncatingIfNeeded: high >> (56 - 8 * k))
            out[8 + k] = UInt8(truncatingIfNeeded: low >> (56 - 8 * k))
        }
        out[6] = (out[6] & 0x0F) | 0x40   // version 4
        out[8] = (out[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (out[0], out[1], out[2], out[3], out[4], out[5], out[6], out[7],
                           out[8], out[9], out[10], out[11], out[12], out[13], out[14], out[15]))
    }

    /// `true` when two highlights cover the same place: same page, same text, the same number of
    /// rects, and each rect's edges within `rectTolerance` of the other's, in order. IDs and
    /// colours are not compared.
    public static func isDuplicate(_ a: Highlight, _ b: Highlight) -> Bool {
        guard a.pageIndex == b.pageIndex, a.text == b.text, a.rects.count == b.rects.count else { return false }
        return zip(a.rects, b.rects).allSatisfy { r, s in
            abs(r.minX - s.minX) <= rectTolerance && abs(r.minY - s.minY) <= rectTolerance
                && abs(r.maxX - s.maxX) <= rectTolerance && abs(r.maxY - s.maxY) <= rectTolerance
        }
    }

    static func noteOrder(_ a: Note, _ b: Note) -> Bool {
        switch (a.target, b.target) {
        case (.page(let x), .page(let y)) where x != y: return x < y
        case (.page, .heading): return true
        case (.heading, .page): return false
        case (.heading(let x), .heading(let y)) where x != y: return x.rawValue < y.rawValue
        default: return a.id.uuidString < b.id.uuidString
        }
    }

    static func headingOrder(_ a: UserHeading, _ b: UserHeading) -> Bool {
        if a.pageIndex != b.pageIndex { return a.pageIndex < b.pageIndex }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }
}

// MARK: - Implementation

private struct Merger {
    let local: BookArchive
    let incoming: BookArchive
    var bookID: UUID { local.book.id }
    var report = BookMergeReport()
    /// Every incoming user heading ID to its merged ID (identity for matched-by-ID and added).
    var headingMap: [UUID: UUID] = [:]

    init(local: BookArchive, incoming: BookArchive) {
        self.local = local
        // Drop incoming records that would make the merged archive invalid (see `BookMerge`).
        var archive = incoming
        archive.userHeadings = Self.unique(incoming.userHeadings, by: \.id)
        archive.highlights = Self.unique(incoming.highlights, by: \.id)
        archive.bookmarks = Self.unique(Self.unique(incoming.bookmarks, by: \.id), by: \.pageIndex)
        archive.notes = Self.unique(Self.unique(incoming.notes.filter { !$0.isEmpty }, by: \.id), by: \.target)
        self.incoming = archive
    }

    static func unique<T, K: Hashable>(_ records: [T], by key: KeyPath<T, K>) -> [T] {
        var seen = Set<K>()
        return records.filter { seen.insert($0[keyPath: key]).inserted }
    }

    mutating func run() -> BookMergeResult {
        let headings = mergeHeadings()
        let (notes, decisions) = mergeNotes()
        let highlights = mergeHighlights()
        let bookmarks = mergeBookmarks()
        let archive = BookMerge.canonicalOrder(BookArchive(book: local.book, notes: notes, highlights: highlights,
                                                           bookmarks: bookmarks, userHeadings: headings))
        let decisionByID = Dictionary(uniqueKeysWithValues: decisions.map { ($0.noteID, $0) })
        let remap = headingMap.filter { $0.key != $0.value }
        return BookMergeResult(archive: archive, noteDecisions: archive.notes.map { decisionByID[$0.id]! },
                               headingIDRemap: remap, report: report)
    }

    // MARK: Headings

    mutating func mergeHeadings() -> [UserHeading] {
        let localIDs = Set(local.userHeadings.map(\.id))
        let incomingByID = Dictionary(uniqueKeysWithValues: incoming.userHeadings.map { ($0.id, $0) })
        var claimed = Set<UUID>()
        for heading in incoming.userHeadings where localIDs.contains(heading.id) {
            headingMap[heading.id] = heading.id
            claimed.insert(heading.id)
            report.headingsMatched += 1
        }

        struct Key: Hashable { let title: String; let page: Int; let parent: String? }
        var candidates: [Key: [UUID]] = [:]
        for heading in local.userHeadings {   // canonical order
            let key = Key(title: OutlineText.normalizedTitle(heading.title), page: heading.pageIndex, parent: heading.parent?.rawValue)
            candidates[key, default: []].append(heading.id)
        }
        let noteTargets = Set(incoming.notes.map(\.target))

        // Walk each incoming heading's parent chain iteratively (no recursion depth limit),
        // deciding parents before children. `visiting` cuts cycles.
        var visiting = Set<UUID>()
        func incomingParentID(_ heading: UserHeading) -> UUID? {
            guard let id = heading.parent?.userHeadingID, incomingByID[id] != nil else { return nil }
            return id
        }
        for root in incoming.userHeadings where headingMap[root.id] == nil {
            var stack = [root.id]
            visiting.insert(root.id)
            while let top = stack.last {
                let heading = incomingByID[top]!
                if let parentID = incomingParentID(heading), headingMap[parentID] == nil, !visiting.contains(parentID) {
                    visiting.insert(parentID)
                    stack.append(parentID)
                    continue
                }
                var parent = heading.parent
                if let parentID = incomingParentID(heading), let mapped = headingMap[parentID] {
                    parent = HeadingAnchor(userHeadingID: mapped)
                }
                let key = Key(title: OutlineText.normalizedTitle(heading.title), page: heading.pageIndex, parent: parent?.rawValue)
                let ownTarget = NoteTarget.heading(heading.anchor)
                let match = candidates[key]?.first { id in
                    !claimed.contains(id)
                        && !(noteTargets.contains(ownTarget) && noteTargets.contains(.heading(HeadingAnchor(userHeadingID: id))))
                }
                if let match {
                    claimed.insert(match)
                    headingMap[top] = match
                    report.headingsMatched += 1
                } else {
                    headingMap[top] = top
                }
                visiting.remove(top)
                stack.removeLast()
            }
        }

        var result = local.userHeadings
        for heading in incoming.userHeadings where headingMap[heading.id] == heading.id && !localIDs.contains(heading.id) {
            var added = heading
            added.bookID = bookID
            added.parent = mapped(heading.parent)
            result.append(added)
            report.headingsAdded += 1
        }
        return result
    }

    /// An incoming anchor with incoming user heading IDs replaced by their merged IDs.
    func mapped(_ anchor: HeadingAnchor?) -> HeadingAnchor? {
        guard let anchor, let id = anchor.userHeadingID, let target = headingMap[id], target != id else { return anchor }
        return HeadingAnchor(userHeadingID: target)
    }

    // MARK: Notes

    mutating func mergeNotes() -> ([Note], [NoteMergeDecision]) {
        var usedIDs = Set(local.notes.map(\.id))
        let incomingIDs = Set(incoming.notes.map(\.id))
        var incomingByTarget: [NoteTarget: Note] = [:]
        for note in incoming.notes {
            var moved = note
            if case .heading(let anchor) = note.target, let target = mapped(anchor) { moved.target = .heading(target) }
            incomingByTarget[moved.target] = moved   // targets stay unique: see the heading match guard
        }

        var notes: [Note] = []
        var decisions: [NoteMergeDecision] = []
        for localNote in local.notes {
            let identity = Array(NoteBandLayout.paragraphs(of: localNote.text).indices)
            guard let other = incomingByTarget.removeValue(forKey: localNote.target) else {
                notes.append(localNote)
                decisions.append(NoteMergeDecision(noteID: localNote.id, target: localNote.target, source: .localOnly,
                                                   localNoteID: localNote.id, incomingNoteID: nil, textChanged: false,
                                                   localParagraphMap: identity, incomingParagraphMap: nil,
                                                   needsBandLayout: localNote.hasInk && localNote.bandLayout == nil))
                continue
            }
            let text = ParagraphMerge.mergeText(local: localNote.text, incoming: other.text)
            let changed = text.text != localNote.text
            var merged = localNote
            merged.text = text.text
            merged.createdAt = min(localNote.createdAt, other.createdAt)
            merged.modifiedAt = max(localNote.modifiedAt, other.modifiedAt)
            merged.hasInk = localNote.hasInk || other.hasInk
            if changed { merged.bandLayout = nil }
            notes.append(merged)
            if changed { report.notesCombined += 1 } else { report.notesIdentical += 1 }
            decisions.append(NoteMergeDecision(noteID: merged.id, target: merged.target, source: changed ? .combined : .unchangedText,
                                               localNoteID: localNote.id, incomingNoteID: other.id, textChanged: changed,
                                               localParagraphMap: text.localIndices, incomingParagraphMap: text.incomingIndices,
                                               needsBandLayout: merged.hasInk && merged.bandLayout == nil))
        }

        // Added notes, in canonical order of their (mapped) targets so fresh IDs are stable.
        let added = incomingByTarget.values.sorted(by: BookMerge.noteOrder)
        // An added note keeps its ID unless a local note uses it; fresh IDs avoid every ID in
        // play so they can never collide with a later added note's own ID.
        var reserved = usedIDs.union(incomingIDs)
        for note in added {
            var copy = note
            copy.bookID = bookID
            if usedIDs.contains(note.id) {
                var attempt = 0
                repeat {
                    copy.id = BookMerge.freshID(for: note.id, in: bookID, attempt: attempt)
                    attempt += 1
                } while reserved.contains(copy.id)
                reserved.insert(copy.id)
            }
            usedIDs.insert(copy.id)
            notes.append(copy)
            report.notesAdded += 1
            decisions.append(NoteMergeDecision(noteID: copy.id, target: copy.target, source: .incomingOnly,
                                               localNoteID: nil, incomingNoteID: note.id, textChanged: false,
                                               localParagraphMap: nil,
                                               incomingParagraphMap: Array(NoteBandLayout.paragraphs(of: note.text).indices),
                                               needsBandLayout: copy.hasInk && copy.bandLayout == nil))
        }
        return (notes, decisions)
    }

    // MARK: Highlights and bookmarks

    mutating func mergeHighlights() -> [Highlight] {
        let localIDs = Set(local.highlights.map(\.id))
        var byPage: [Int: [Highlight]] = [:]
        for highlight in local.highlights { byPage[highlight.pageIndex, default: []].append(highlight) }
        var result = local.highlights
        for highlight in incoming.highlights where !localIDs.contains(highlight.id) {
            if byPage[highlight.pageIndex]?.contains(where: { BookMerge.isDuplicate($0, highlight) }) == true {
                report.duplicatesSkipped += 1
                continue
            }
            var added = highlight
            added.bookID = bookID
            result.append(added)
            report.highlightsAdded += 1
        }
        return result
    }

    mutating func mergeBookmarks() -> [Bookmark] {
        var result = local.bookmarks
        let indexByPage = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($1.pageIndex, $0) })
        let localIDs = Set(local.bookmarks.map(\.id))
        var reserved = localIDs.union(incoming.bookmarks.map(\.id))
        for bookmark in incoming.bookmarks {   // canonical order: by page
            if let index = indexByPage[bookmark.pageIndex] {
                result[index].createdAt = min(result[index].createdAt, bookmark.createdAt)
                continue
            }
            var added = bookmark
            added.bookID = bookID
            if localIDs.contains(bookmark.id) {
                var attempt = 0
                repeat {
                    added.id = BookMerge.freshID(for: bookmark.id, in: bookID, attempt: attempt)
                    attempt += 1
                } while reserved.contains(added.id)
                reserved.insert(added.id)
            }
            result.append(added)
            report.bookmarksAdded += 1
        }
        return result
    }
}
