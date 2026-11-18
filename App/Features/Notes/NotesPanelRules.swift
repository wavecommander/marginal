import CoreGraphics
import Foundation
import ReaderCore

// The notes panel's rules as plain values, so they are unit-tested without a view.

/// Accessibility identifiers of the notes panel (UI tests mirror these strings). The note page's
/// own identifiers (`notePage.text`, `notePage.ink`…) are the note page's `NotePageAccessibilityID`.
nonisolated enum NotesPanelAccessibilityID {
    /// The panel's root container.
    static let panel = "notesPanel"
    /// The Page note / Section note segmented control.
    static let tabs = "notesPanel.tabs"
    /// The title ("Page 312", or the heading's title).
    static let title = "notesPanel.title"
    /// The "Saved" status (the note page's identifier, kept: label "Saved", "Edited", …, or "Empty").
    static let status = "notePage.status"
    /// The shrink button (shown while the pane is wider than its default).
    static let shrink = "notesPanel.shrink"
    /// Markup and ink Undo / Redo in the header (a narrow panel on a compact screen).
    static let markup = "notesPanel.markup"
    static let undo = "notesPanel.undo"
    static let redo = "notesPanel.redo"
    /// Hides and shows the lists under or beside the note (narrow panels; value "Collapsed" or
    /// "Expanded").
    static let lowerRegionToggle = "notesPanel.lowerRegionToggle"
    /// The level picker's disclosure row (label "Heading level, <shown heading>", value
    /// "Collapsed" or "Expanded").
    static let levelToggle = "notesPanel.levelToggle"
    /// One row of the expanded level picker (label = heading title, value "Level N", selected
    /// trait).
    static let level = "notesPanel.level"
    /// The section's page range ("pp. 2–4"): a button that jumps to the heading's first page.
    static let sectionRange = "notesPanel.sectionRange"
    /// One "Highlights on this page" row.
    static let highlight = "notesPanel.highlight"
    /// The empty state of the Section note tab (no heading for this page).
    static let sectionEmpty = "notesPanel.sectionEmpty"
    /// "Add Heading at This Page…" (where the page is in no section).
    static let addHeading = "notesPanel.addHeading"
    /// Delete Note (the header button).
    static let deleteNote = "notes.deleteNote"
    /// Undo Delete pill button shown after deleting a note.
    static let undoDelete = "notes.undoDelete"
    /// "Open in Notebook".
    static let openNotebook = "notesPanel.openNotebook"
}

/// When the notes panel header carries its own Markup switch (and ink Undo/Redo while markup is on):
/// only when a narrow panel on a compact screen has been expanded to full screen, covering the
/// reader's toolbar.
nonisolated enum NotesPanelMarkupControls {
    static func isShown(presentation: NotesPanelPresentation,
                        isCompactWindow: Bool,
                        isExpandedToFullScreen: Bool) -> Bool {
        presentation == .narrow && isCompactWindow && isExpandedToFullScreen
    }
}

// MARK: - Section note: which heading

/// Which heading the Section note tab shows, and how the level picker's choice sticks.
///
/// ## The rule
/// - **Following.** With no choice made, the tab shows the deepest heading of the current page's
///   heading path (`Outline.deepestHeading(forPage:)`), so it changes as the reader scrolls.
/// - **Choosing.** Picking a level in the level picker (or any other explicit "open this
///   heading's note") *pins* that heading, remembering the page the
///   reader was on.
/// - **Staying.** The pin holds while the current page stays inside the pinned heading's page
///   range: the reader who chose the chapter note keeps it while scrolling through any of the
///   chapter's sections and subsections. A heading with no range (an earlier sibling that shares
///   its start page with a later one, so it contains no page; reachable only from Contents) or a
///   heading outside the current page's path holds only while the page is the one it was chosen
///   on (and, for a heading with no range, its own start page, so a request that also jumps there
///   keeps it).
/// - **Leaving.** The first page change that breaks that condition drops the pin for good
///   (`pageDidChange(to:outline:)` runs on *every* page change, panel shown or not), and the tab
///   follows the page again. Coming back into the heading's range later does not restore it.
/// - A pinned heading that disappears from the outline (a user heading deleted) drops the pin.
struct NotesSectionSelection: Equatable {
    /// The heading the reader chose, if any.
    private(set) var pinnedAnchor: HeadingAnchor?
    /// The page the reader was on when they chose it.
    private(set) var pinnedAtPage: Int?

    init() {}

    /// The reader chose `anchor` while on `page`.
    mutating func choose(_ anchor: HeadingAnchor, atPage page: Int) {
        pinnedAnchor = anchor
        pinnedAtPage = page
    }

    /// Back to following the page.
    mutating func clear() {
        pinnedAnchor = nil
        pinnedAtPage = nil
    }

    /// Whether the pin holds on `page` (see the type's rule).
    func pinHolds(onPage page: Int, outline: Outline) -> Bool {
        guard let pinnedAnchor, let node = outline.node(for: pinnedAnchor) else { return false }
        if let range = node.pageRange, range.contains(page) { return true }
        // A heading with no range lives on its start page (it shares it with a later sibling).
        if node.pageRange == nil, page == node.startPage { return true }
        return page == pinnedAtPage
    }

    /// Call on every page change (and after the outline is rebuilt): drops a pin that no longer
    /// holds. Returns `true` when it dropped one.
    @discardableResult
    mutating func pageDidChange(to page: Int, outline: Outline) -> Bool {
        guard pinnedAnchor != nil, !pinHolds(onPage: page, outline: outline) else { return false }
        clear()
        return true
    }

    /// The heading the tab shows on `page`: the pinned one while it holds, else the deepest
    /// heading containing the page (`nil` before the first heading or without an outline).
    func heading(forPage page: Int, outline: Outline) -> OutlineNode? {
        if pinHolds(onPage: page, outline: outline), let pinnedAnchor, let node = outline.node(for: pinnedAnchor) {
            return node
        }
        return outline.deepestHeading(forPage: page)
    }

    /// The level picker's rows for a shown heading: the current page's whole heading path when the
    /// heading is on it, else the heading's own lineage (`Outline.lineage(of:)`: a heading opened
    /// directly that contains no page, or one shown while the switch to the page's heading waits).
    static func levels(showing heading: OutlineNode, page: Int, outline: Outline) -> [OutlineNode] {
        let path = outline.headingPath(forPage: page)
        if path.contains(where: { $0.anchor == heading.anchor }) { return path }
        let lineage = outline.lineage(of: heading.anchor)
        return lineage.isEmpty ? [heading] : lineage
    }
}

// MARK: - Following without losing work

/// What the panel does when the note it should show differs from the one on screen.
nonisolated enum NotesTargetSwitch: Equatable {
    /// Already showing it.
    case keep
    /// Give the editor the new note now.
    case switchNow
    /// Wait: the reader is typing in the note on screen. Re-decided when editing ends.
    case deferUntilEditingEnds

    /// - Parameters:
    ///   - explicit: the reader asked for the change (tab, level picker, a request from another
    ///     feature):
    ///     always switch (the editor commits and flushes the old note first). Following the page
    ///     (`explicit == false`) never switches under a reader who is typing, because the keyboard
    ///     itself scrolls the PDF and would otherwise swap the note mid-sentence.
    ///   - Strokes in progress are deferred by the editor itself (`NotePageEditorView` keeps the
    ///     new model pending until the stroke ends), so they are not an input here.
    static func decide(displayed: NoteTarget?, desired: NoteTarget?, isEditingText: Bool, explicit: Bool) -> Self {
        if displayed == desired { return .keep }
        if explicit || !isEditingText || displayed == nil { return .switchNow }
        return .deferUntilEditingEnds
    }
}

// MARK: - Layout and zoom

/// How the shell presents the panel.
nonisolated enum NotesPanelPresentation: Equatable, Sendable {
    /// The right-hand pane of a wide window (330 points wide by default, widened with the divider
    /// up to half the window).
    case pane
    /// A narrow window: the system sheet with detents (iPadOS 26+) or the inline bottom panel
    /// (earlier). Full window width, half or most of its height.
    case narrow
}

/// Layout and zoom of the panel, from the panel's own size (never the screen's).
///
/// ## Zoom (design: "Writing room", "Note page")
/// The note page is 320 points wide before zoom except in a widened pane (`notePageWidth`). The
/// zoom on screen is `NotePageZoom.zoom(base:panelWidth:)` with `panelWidth = zoomReferenceWidth`:
/// - `base` is the reader's chosen zoom at the default pane width (330), remembered per window;
///   until they choose one it is `NotePageStyle.defaultZoom(for: Dynamic Type)`.
/// - **Pane:** the reference width is always the default pane width, so the pane shows the base
///   zoom at any width. Dragging the divider wider widens the note page instead, in proportion
///   (330 → 320, 660 → 640): the page grows on screen as much as it did when widening zoomed it,
///   but the text keeps its size and re-wraps to fill it (TSOFT-226). Ink moves with its
///   paragraph; ink drawn over a word may sit off it at another width (the lasso fixes that).
///   The shrink button returns the width, and the page and its line breaks with it.
/// - **Narrow (sheet / bottom panel):** the panel is as wide as the window, so following its full
///   width would pin every note at 176%–200%. Instead the note gets a column of its own when the
///   panel is at least `columnsMinimumWidth` wide (`noteColumnFraction` of the width, the lists
///   beside it, as in the "Portrait · notes sheet" mockup), and the reference width is that
///   column capped at `narrowMaximumFactor × 330`. At base 100% a portrait 11-inch sheet shows the
///   note at 130%, a slim Split View panel (375 wide) at 114%: about the mockup's 420-point-wide
///   note, comfortably readable, with room left for highlights.
/// - **Pinch** is the only way to choose a zoom (design: "Writing room"; there is no zoom button).
///   A change of Dynamic Type drops the pinched choice, so the note follows the new text size.
/// The lists under (or beside) the note: "Highlights on this page", or the level picker and
/// "Open in Notebook".
nonisolated enum NotesPanelRegions {
    /// Defaults key for "the reader hid them" (narrow panels; `-resetState` clears it).
    static let collapsedKey = "notesPanel.lowerRegionCollapsed"
}

struct NotesPanelMetrics: Equatable {
    static let defaultPaneWidth = CGFloat(ReaderSession.defaultNotesPanelWidth)
    /// Narrow panels at least this wide put the lists in a column beside the note.
    static let columnsMinimumWidth: CGFloat = 640
    /// The note column's share of a two-column panel.
    static let noteColumnFraction: CGFloat = 0.52
    /// In narrow presentations the width factor is capped here (see the type documentation).
    static let narrowMaximumFactor: CGFloat = 1.3
    /// The lists below the note take at most this share of the panel's height (stacked layout).
    static let lowerRegionMaximumFraction: CGFloat = 0.4
    /// The base zoom is kept within this range (a wide narrow-presentation panel can need a base
    /// below 1 to show 100%).
    static let baseRange: ClosedRange<CGFloat> = 0.5...2

    var presentation: NotesPanelPresentation
    var size: CGSize
    /// The reader hid the lists (narrow presentations: the header's hide button). In a
    /// two-column panel the note then has the whole width, and its page widens to fill it at
    /// the same zoom, the way a widened pane's does (the text re-wraps; nothing is zoomed).
    var listsHidden = false

    /// Lists beside the note instead of below it.
    var usesColumns: Bool { presentation == .narrow && size.width >= Self.columnsMinimumWidth }
    /// The note's column in a two-column panel, whether or not the lists are shown (the zoom
    /// follows it, so hiding the lists never changes the zoom).
    private var noteColumnShare: CGFloat { usesColumns ? floor(size.width * Self.noteColumnFraction) : size.width }
    /// The width the note editor gets.
    var noteColumnWidth: CGFloat { listsHidden ? size.width : noteColumnShare }
    /// The note page's width before zoom (see the type documentation): in proportion to a pane's
    /// width, never below `NotePageStyle.pageWidth`; that width in narrow presentations, except
    /// in a two-column panel whose lists are hidden, where it is in proportion to the panel's.
    var notePageWidth: CGFloat {
        switch presentation {
        case .pane:
            max(NotePageStyle.pageWidth, floor(NotePageStyle.pageWidth * noteColumnWidth / Self.defaultPaneWidth))
        case .narrow:
            usesColumns && listsHidden
                ? max(NotePageStyle.pageWidth, floor(NotePageStyle.pageWidth * size.width / zoomReferenceWidth))
                : NotePageStyle.pageWidth
        }
    }
    /// The width the zoom follows (see the type documentation).
    var zoomReferenceWidth: CGFloat {
        switch presentation {
        case .pane: Self.defaultPaneWidth
        case .narrow: min(noteColumnShare, Self.defaultPaneWidth * Self.narrowMaximumFactor)
        }
    }
    /// The most the stacked lists below the note may take.
    var lowerRegionMaximumHeight: CGFloat { max(96, floor(size.height * Self.lowerRegionMaximumFraction)) }

    /// The zoom on screen for a base zoom.
    func zoom(base: CGFloat) -> CGFloat {
        NotePageZoom.zoom(base: base, panelWidth: zoomReferenceWidth)
    }

    /// The base zoom that shows `zoom` here (pinch).
    func base(forZoom zoom: CGFloat) -> CGFloat {
        let base = NotePageZoom.base(forZoom: NotePageStyle.clampZoom(zoom), panelWidth: zoomReferenceWidth)
        return min(max(base, Self.baseRange.lowerBound), Self.baseRange.upperBound)
    }
}

// MARK: - Heading anchors

/// Re-attaches heading notes whose stored anchor went stale (design: "Heading identity").
///
/// Uses `Outline.resolveAll` over the book's heading notes, so the outcome is exactly
/// `Notebook.anchorRepairs` for the same outline. **Idempotent and safe to run from several
/// places** (the notes panel of every window on the book, and the Notebook screen if it does the
/// same): it runs synchronously on the main actor, so no other window's repair can interleave;
/// before each move it re-reads the note and skips it unless it is still at the stale target it
/// was planned from and the new target is still free; and after one pass every note's anchor is
/// exact, so a second pass (from any window, with the same PDF outline) finds nothing to do. Only
/// PDF anchors can be stale (user anchors are IDs and match exactly or not at all), and every
/// window reads the same PDF outline, so two windows never disagree about a repair.
@MainActor
enum NotesHeadingAnchorRepair {
    /// One planned move.
    struct Move: Equatable {
        var noteID: UUID
        var from: HeadingAnchor
        var to: HeadingAnchor
    }

    /// The moves `apply` would make (pure; for tests).
    static func plan(headingNotes: [Note], outline: Outline) -> [Move] {
        let anchors = headingNotes.compactMap(\.target.headingAnchor)
        guard !anchors.isEmpty, !outline.isEmpty else { return [] }
        let matches = outline.resolveAll(anchors)
        return headingNotes.compactMap { note -> Move? in
            guard let stored = note.target.headingAnchor, let match = matches[stored], !match.isExact else { return nil }
            return Move(noteID: note.id, from: stored, to: match.node.anchor)
        }
        .sorted { $0.noteID.uuidString < $1.noteID.uuidString }
    }

    /// Applies the repairs for `bookID` against `outline`, each attributed to `origin`. Returns
    /// the number of notes moved. Errors on one note never stop the others.
    @discardableResult
    static func apply(store: LibraryStore, bookID: UUID, outline: Outline, origin: ChangeOrigin?) -> Int {
        guard !outline.isEmpty, let notes = try? store.notes.notes(bookID: bookID) else { return 0 }
        let headingNotes = notes.filter { $0.target.headingAnchor != nil }
        var moved = 0
        for move in plan(headingNotes: headingNotes, outline: outline) {
            do {
                guard let current = try store.notes.note(id: move.noteID), current.target == .heading(move.from),
                      try store.notes.note(bookID: bookID, target: .heading(move.to)) == nil else { continue }
                try store.perform(as: origin) {
                    try store.notes.retarget(noteID: move.noteID, to: .heading(move.to))
                }
                moved += 1
            } catch {
                continue
            }
        }
        return moved
    }
}
