import Foundation
import PencilKit
import ReaderCore

/// Combines the two sides' ink of one note a merge produces (design: "Ink follows the text it
/// annotates"; plan: "Merge on restore", Ink).
///
/// **Rule.** Each side's stored ink is decoded (`NoteInkArchive`, with that side's `bandLayout`
/// as the fallback for foreign data), relaid to the layout of that side's own text exactly as the
/// note editor does when it loads a note (`NoteInk.relayout(to:)`, which also absorbs font-metric
/// changes), and then moved onto the merged text with the merge's paragraph map
/// (`NoteMergeDecision.localParagraphMap` / `incomingParagraphMap`): a stroke anchored to
/// paragraph `i` of its side's text is anchored to paragraph `map[i]` of the merged text, its
/// band-local position unchanged, so it sits on the same paragraph it was drawn on. Trailing
/// strokes stay in the trailing band, which follows the end of the merged text. The two inks are
/// then combined with `NoteInk.merge(local:remote:base: nil)`: the union by stroke identity, the
/// local version of a stroke both sides have, local strokes first.
///
/// **Trailing space.** Strokes both sides drew in the blank space after the text would land on top
/// of each other. The backup's trailing strokes that the local ink does not already have (by
/// stroke identity, as the merge matches them) are moved down together, keeping their own
/// arrangement, so that their top is `trailingGap` below the lowest local stroke that reaches
/// below the text. A stroke the local ink already has (from an earlier merge of the same backup)
/// is matched by identity and neither moved nor duplicated, so merging the same backup again
/// changes nothing.
///
/// **Unreadable ink.** A side whose data cannot be decoded, or decodes to no strokes (PencilKit
/// reads some damaged data as an empty drawing; the editor never stores empty ink), is
/// `unreadable`: the caller keeps the local file exactly as it is.
@MainActor
enum NoteInkMerging {
    /// Space left between the local trailing ink and the backup's trailing ink moved below it.
    static var trailingGap: CGFloat { NotePageStyle.lineHeight }

    /// One side's stored ink of the note.
    struct Side: Sendable {
        /// The stored ink (`NoteInkArchive` data, or a plain drawing from older data).
        var data: Data
        /// That side's note text.
        var text: String
        /// That side's `Note.bandLayout` (fallback layout for data without its own).
        var recordLayout: NoteBandLayout?
        /// For each paragraph of `text`, its index in the merged text's paragraphs.
        var paragraphMap: [Int]
    }

    enum Outcome {
        /// The combined ink, anchored to the merged text's layout. `incomingAddedStrokes` is
        /// `false` when the backup's side added no stroke the local ink did not already have.
        case merged(NoteInk, incomingAddedStrokes: Bool)
        /// This side's ink could not be decoded; nothing was combined.
        case unreadable(UnreadableInk.Side)
    }

    /// Combines `local` and `incoming` onto `mergedText`. At least one side must be given.
    /// `layout` returns a note page's band layout for a text (the app passes
    /// `NotePageLayoutEngine.shared.bandLayout(for:)`).
    static func merge(local: Side?, incoming: Side?, mergedText: String,
                      layout: (String) -> NoteBandLayout) -> Outcome {
        let mergedLayout = layout(mergedText)
        func prepare(_ side: Side) -> NoteInk? {
            let ownLayout = layout(side.text)
            // As for page ink (`MergeFiles.readableDrawing`): ink that decodes to no strokes is
            // damaged data PencilKit read as empty (the editor never stores empty ink).
            guard let decoded = try? NoteInkArchive.decode(side.data, fallbackLayout: side.recordLayout ?? ownLayout),
                  !decoded.isEmpty else {
                return nil
            }
            return mapped(decoded.relaid(to: ownLayout), onto: mergedLayout, paragraphMap: side.paragraphMap)
        }
        var localInk: NoteInk?
        if let local {
            guard let ink = prepare(local) else { return .unreadable(.local) }
            localInk = ink
        }
        var incomingInk: NoteInk?
        if let incoming {
            guard let ink = prepare(incoming) else { return .unreadable(.backup) }
            incomingInk = ink
        }
        switch (localInk, incomingInk) {
        case (let localInk?, let incomingInk?):
            let placed = placingNewTrailingStrokes(of: incomingInk, below: localInk)
            let merged = NoteInk.merge(local: localInk, remote: placed, base: nil)
            return .merged(merged, incomingAddedStrokes: merged.strokes.count > localInk.strokes.count)
        case (let localInk?, nil):
            return .merged(localInk, incomingAddedStrokes: false)
        case (nil, let incomingInk?):
            return .merged(incomingInk, incomingAddedStrokes: !incomingInk.isEmpty)
        case (nil, nil):
            return .merged(NoteInk(layout: mergedLayout), incomingAddedStrokes: false)
        }
    }

    /// `ink` (anchored to the layout of its own text) re-anchored to `layout` through
    /// `paragraphMap`: paragraph `i` becomes paragraph `paragraphMap[i]`, band-local positions
    /// unchanged; trailing stays trailing. A paragraph reference the map does not cover (only
    /// from damaged data) keeps its page position and is anchored by geometry.
    nonisolated static func mapped(_ ink: NoteInk, onto layout: NoteBandLayout, paragraphMap: [Int]) -> NoteInk {
        let strokes = ink.strokes.map { stroke -> NoteInkStroke in
            switch stroke.band {
            case .trailing:
                return stroke
            case .paragraph(let index):
                if paragraphMap.indices.contains(index), layout.paragraphs.indices.contains(paragraphMap[index]) {
                    return NoteInkStroke(uid: stroke.uid, band: .paragraph(paragraphMap[index]), local: stroke.local)
                }
                let page = ink.pageStroke(stroke)
                let band = layout.band(for: page.renderBounds)
                return NoteInkStroke(uid: stroke.uid, band: band,
                                     local: page.translatedVertically(by: -(layout.top(of: band) ?? 0)))
            }
        }
        return NoteInk(layout: layout, strokes: strokes)
    }

    /// `incoming` with its trailing strokes that `local` does not have moved below `local`'s ink
    /// in the trailing space (see the type). Both must be anchored to the same layout.
    static func placingNewTrailingStrokes(of incoming: NoteInk, below local: NoteInk) -> NoteInk {
        let localKeys = Set(keys(of: local.strokes))
        let incomingKeys = keys(of: incoming.strokes)
        let fresh = incoming.strokes.indices.filter {
            incoming.strokes[$0].band == .trailing && !localKeys.contains(incomingKeys[$0])
        }
        guard !fresh.isEmpty else { return incoming }
        let trailingTop = local.layout.trailingTop
        let localBottom = local.strokes
            .map { local.pageStroke($0).renderBounds }
            .filter { !$0.isNull && $0.maxY > trailingTop }
            .map(\.maxY)
            .max()
        guard let localBottom else { return incoming }
        let groupTop = fresh
            .map { incoming.pageStroke(incoming.strokes[$0]).renderBounds }
            .filter { !$0.isNull }
            .map(\.minY)
            .min()
        guard let groupTop else { return incoming }
        let wanted = localBottom + trailingGap
        guard groupTop < wanted else { return incoming }
        var moved = incoming
        for index in fresh {
            moved.strokes[index].local = moved.strokes[index].local.translatedVertically(by: wanted - groupTop)
        }
        return moved
    }

    /// Identity keys as `NoteInk.merge` matches strokes: identity plus occurrence among strokes
    /// of equal identity, in z-order.
    private struct Key: Hashable {
        let identity: StrokeIdentity
        let occurrence: Int
    }

    private static func keys(of strokes: [NoteInkStroke]) -> [Key] {
        var seen: [StrokeIdentity: Int] = [:]
        return strokes.map { stroke in
            let identity = StrokeIdentity(stroke.local)
            let occurrence = seen[identity, default: 0]
            seen[identity] = occurrence + 1
            return Key(identity: identity, occurrence: occurrence)
        }
    }
}
