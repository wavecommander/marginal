import Foundation
import PencilKit
import ReaderCore
import ReaderSync

/// Ink one side holds that this system cannot read in full, so it cannot be merged without
/// losing strokes: the book waits (the round reports it as failed) until it can be.
nonisolated struct SyncInkUnreadable: Error, Hashable, Sendable, LocalizedError {
    enum Side: String, Hashable, Sendable { case local, remote, absorbed }
    var side: Side

    var errorDescription: String? {
        "Some handwriting in this book was made on a device with a newer system, so it can’t be combined here yet. Update this device to sync it."
    }
}

/// The app's `SyncInkMerger`: the existing three-way stroke merge (`StrokeMerge`) given the base.
///
/// - **Page ink**: `PageInkMerge.merge(local:remote:base:)`. A base the account no longer has
///   (`.unavailable`), or one this system cannot read, merges as the union.
/// - **Note ink**: each side's ink is read as the editor reads it (`NoteInkArchive`, with that
///   side's `bandLayout` as the fallback for data without its own, relaid to the layout of that
///   side's text) and moved onto the merged text with the decision's paragraph map, as the
///   restore merge does (`NoteInkMerging.mapped`): a stroke on paragraph `i` lands on paragraph
///   `map[i]`, band-local position unchanged; a paragraph the merge removed (`nil`) places its
///   strokes by their position, as for a paragraph a map does not cover. Local, remote and base
///   are mapped alike, then merged with `NoteInk.merge(local:remote:base:)`, and the absorbed
///   notes' ink added as a union. The result is anchored to the merged text's layout.
/// - No strokes: `nil` (no file).
/// - **Never erasing on unreadable ink** (`MergeFiles.readableDrawing`'s rule): a local, remote or
///   absorbed drawing that does not decode, decodes to no strokes, or needs a newer system
///   (`InkContentSupport`) throws `SyncInkUnreadable`, so nothing of the book changes this round
///   on either side. (Local ink of that kind never gets here: the library reports it busy.)
nonisolated struct AppSyncInkMerger: SyncInkMerger {
    func merge(_ request: SyncInkMergeRequest) async throws -> Data? {
        switch request.kind {
        case .page:
            return try Self.mergePage(request)
        case .note(let decision):
            return try await MainActor.run {
                try Self.mergeNote(request, decision: decision, layout: { NotePageLayoutEngine.shared.bandLayout(for: $0) })
            }
        }
    }

    // MARK: Page ink

    static func mergePage(_ request: SyncInkMergeRequest) throws -> Data? {
        let local = try drawing(request.local, side: .local)
        let remote = try drawing(request.remote, side: .remote)
        let base: PKDrawing?
        switch request.base {
        case .unavailable: base = nil
        case .none: base = PKDrawing()
        case .ink(let data): base = try? drawing(data, side: .local)
        }
        let merged = PageInkMerge.merge(local: local, remote: remote, base: base)
        return merged.strokes.isEmpty ? nil : merged.dataRepresentation()
    }

    private static func drawing(_ data: Data?, side: SyncInkUnreadable.Side) throws -> PKDrawing {
        guard let data else { return PKDrawing() }
        guard InkContentSupport.isSupported(pageInk: data), let drawing = try? PKDrawing(data: data) else {
            throw SyncInkUnreadable(side: side)
        }
        return drawing
    }

    // MARK: Note ink

    @MainActor
    static func mergeNote(_ request: SyncInkMergeRequest, decision: NoteSyncDecision,
                          layout: (String) -> NoteBandLayout) throws -> Data? {
        guard let notes = request.notes else { throw SyncInkUnreadable(side: .remote) }
        let mergedLayout = layout(notes.merged.text)
        func prepare(_ data: Data?, note: Note?, map: [Int?]?, side: SyncInkUnreadable.Side) throws -> NoteInk? {
            guard let data else { return nil }
            guard InkContentSupport.isSupported(noteInk: data) else { throw SyncInkUnreadable(side: side) }
            let own = note.map { layout($0.text) }
            let decoded: NoteInk
            do {
                decoded = try NoteInkArchive.decode(data, fallbackLayout: note?.bandLayout ?? own ?? mergedLayout)
            } catch {
                throw SyncInkUnreadable(side: side)
            }
            let relaid = own.map { decoded.relaid(to: $0) } ?? decoded
            let paragraphs = own?.paragraphs.count ?? relaid.layout.paragraphs.count
            let mapping = (map ?? Array(0..<paragraphs).map { Optional($0) }).map { $0 ?? -1 }
            return NoteInkMerging.mapped(relaid, onto: mergedLayout, paragraphMap: mapping)
        }
        let empty = NoteInk(layout: mergedLayout)
        let local = try prepare(request.local, note: notes.local, map: decision.local?.paragraphMap, side: .local) ?? empty
        let remote = try prepare(request.remote, note: notes.remote, map: decision.remote?.paragraphMap, side: .remote) ?? empty
        let base: NoteInk?
        switch request.base {
        case .unavailable:
            base = nil
        case .none:
            base = empty
        case .ink(let data):
            // A base this system cannot read merges as the union (an erased stroke may return).
            base = (try? prepare(data, note: notes.base, map: decision.base?.paragraphMap, side: .local)) ?? nil
        }
        var merged = NoteInk.merge(local: local, remote: remote, base: base)
        for (index, data) in request.absorbed.enumerated() {
            let note = notes.absorbed.indices.contains(index) ? notes.absorbed[index] : nil
            let map = decision.absorbed.indices.contains(index) ? decision.absorbed[index].paragraphMap : nil
            if let ink = try prepare(data, note: note, map: map, side: .absorbed) {
                merged = NoteInk.merge(local: merged, remote: ink, base: nil)
            }
        }
        return merged.isEmpty ? nil : try NoteInkArchive.encode(merged)
    }
}
