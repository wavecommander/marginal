import Foundation
import ReaderCore

// Values the merge engine reports, for the restore preview (`BackupService.mergePreview(for:)`)
// and the restore summary (`RestoreSummary.merged`).

/// How a merge treats a book's ink, counted per page and per note.
///
/// The preview and the merge count the same way, by comparing file contents (the preview uses the
/// backup manifest's SHA-256 against the local files, the merge compares bytes):
/// - **added**: the backup has ink there and this iPad has none (a page, or a merged note whose
///   local side has no ink file), so the backup's ink is added;
/// - **combined**: both have ink there and the files differ, so the two drawings are combined
///   (the union of their strokes). After an earlier merge of the same backup a page can differ
///   in bytes while already holding every stroke of the backup's; it is still counted here, and
///   `RestoreSummary.MergedBook.combinedInkAlreadyPresent` says how many of these gained nothing.
nonisolated struct MergeInkCounts: Hashable, Sendable {
    var pagesAdded = 0
    var pagesCombined = 0
    var notesAdded = 0
    var notesCombined = 0

    init(pagesAdded: Int = 0, pagesCombined: Int = 0, notesAdded: Int = 0, notesCombined: Int = 0) {
        self.pagesAdded = pagesAdded
        self.pagesCombined = pagesCombined
        self.notesAdded = notesAdded
        self.notesCombined = notesCombined
    }

    /// `true` when the merge adds and combines no ink.
    var isEmpty: Bool { pagesAdded == 0 && pagesCombined == 0 && notesAdded == 0 && notesCombined == 0 }
}

/// Ink a merge could not read, and therefore kept exactly as it was: the local file when there is
/// one, otherwise the backup's. The other side's ink for that page or note was not combined in.
nonisolated struct UnreadableInk: Hashable, Sendable {
    enum Location: Hashable, Sendable {
        /// Page ink of this page index.
        case page(Int)
        /// The ink of this note (its ID in the merged book).
        case note(UUID)
    }

    enum Side: Hashable, Sendable {
        /// The drawing on this iPad.
        case local
        /// The backup's drawing.
        case backup
    }

    var location: Location
    /// Whose drawing could not be read.
    var side: Side
}

/// What merging one backed-up book into the book already in the Library would do
/// (`BackupService.mergePreview(for:)`). Nothing is changed to compute it.
nonisolated struct BookMergePreview: Hashable, Sendable, Identifiable {
    /// The backed-up book's ID (`RestorePlan.Item.id`).
    var id: UUID
    /// The local book the backup's copy would be merged into (it keeps this ID).
    var localBookID: UUID
    /// Notes, highlights, bookmarks and headings added or combined (`BookMerge`).
    var report: BookMergeReport
    /// Pages and notes whose ink would be added or combined.
    var ink: MergeInkCounts

    /// `true` when the merge would add or combine nothing.
    var addsNothing: Bool { report.addsNothing && ink.isEmpty }
}
