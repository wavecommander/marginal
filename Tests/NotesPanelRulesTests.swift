import CoreGraphics
import Foundation
import ReaderCore
import ReaderStore
import SwiftUI
import Testing
@testable import Marginal

/// The notes panel's pure rules (WP8): the Section tab's heading choice and level picker, "page
/// notes in this section" ranges, the switch decision while typing, zoom/width arithmetic, and
/// the heading-anchor repair.
@MainActor
struct NotesPanelRulesTests {
    // MARK: Fixture outline
    //
    // 20 pages (indices). Page 0 is front matter.
    //   1 Ch        p1   range 1...9
    //     1.1       p2   range 2...5
    //       1.1.1   p3   range 3...5
    //     1.2       p6   range 6...9
    //   2 Ch        p10  range 10...15
    //     2.1       p10  range 10...11   (starts on its parent's page)
    //     2.2       p12  no range        (shares p12 with the later 2.3)
    //     2.3       p12  range 12...15
    //   3 Ch        p16  range 16...19
    private func outline() -> Outline {
        Outline(pdfEntries: [
            RawOutlineEntry(title: "1 Ch", level: 1, pageIndex: 1),
            RawOutlineEntry(title: "1.1", level: 2, pageIndex: 2),
            RawOutlineEntry(title: "1.1.1", level: 3, pageIndex: 3),
            RawOutlineEntry(title: "1.2", level: 2, pageIndex: 6),
            RawOutlineEntry(title: "2 Ch", level: 1, pageIndex: 10),
            RawOutlineEntry(title: "2.1", level: 2, pageIndex: 10),
            RawOutlineEntry(title: "2.2", level: 2, pageIndex: 12),
            RawOutlineEntry(title: "2.3", level: 2, pageIndex: 12),
            RawOutlineEntry(title: "3 Ch", level: 1, pageIndex: 16),
        ], pageCount: 20)
    }

    private func node(_ title: String, _ outline: Outline) throws -> OutlineNode {
        try #require(outline.nodes.first { $0.title == title })
    }

    // MARK: Section heading and the level picker

    @Test func followsTheDeepestHeadingWithoutAChoice() {
        let outline = outline()
        let selection = NotesSectionSelection()
        #expect(selection.heading(forPage: 0, outline: outline) == nil, "front matter has no section")
        #expect(selection.heading(forPage: 2, outline: outline)?.title == "1.1")
        #expect(selection.heading(forPage: 4, outline: outline)?.title == "1.1.1")
        #expect(selection.heading(forPage: 11, outline: outline)?.title == "2.1")
        #expect(selection.heading(forPage: 12, outline: outline)?.title == "2.3", "the later same-page sibling owns the page")
        #expect(NotesSectionSelection().heading(forPage: 3, outline: .empty) == nil, "no outline")
    }

    @Test func aChosenLevelStaysWhileThePageIsInItsRangeAndIsDroppedOnLeaving() throws {
        let outline = outline()
        var selection = NotesSectionSelection()
        let chapter = try node("1 Ch", outline)
        selection.choose(chapter.anchor, atPage: 4)
        #expect(selection.heading(forPage: 4, outline: outline)?.title == "1 Ch")
        // Scrolling within the chapter, through its sections and subsections, keeps it.
        for page in [5, 3, 2, 6, 9, 1] {
            let dropped = selection.pageDidChange(to: page, outline: outline)
            #expect(!dropped)
            #expect(selection.heading(forPage: page, outline: outline)?.title == "1 Ch", "page \(page)")
        }
        // Leaving the range drops the choice; the tab follows the page again…
        let dropped = selection.pageDidChange(to: 10, outline: outline)
        #expect(dropped)
        #expect(selection.pinnedAnchor == nil)
        #expect(selection.heading(forPage: 10, outline: outline)?.title == "2.1")
        // …and coming back does not restore it.
        selection.pageDidChange(to: 4, outline: outline)
        #expect(selection.heading(forPage: 4, outline: outline)?.title == "1.1.1")
    }

    @Test func choosingTheDeepestLevelKeepsItAboveDeeperSubsections() throws {
        let outline = outline()
        var selection = NotesSectionSelection()
        selection.choose(try node("1.1", outline).anchor, atPage: 2)
        selection.pageDidChange(to: 3, outline: outline)  // into 1.1.1
        #expect(selection.heading(forPage: 3, outline: outline)?.title == "1.1")
        selection.pageDidChange(to: 6, outline: outline)  // into 1.2: left 1.1
        #expect(selection.heading(forPage: 6, outline: outline)?.title == "1.2")
    }

    @Test func aHeadingWithoutPagesHoldsOnlyOnThePageItWasOpenedOn() throws {
        let outline = outline()
        let earlier = try node("2.2", outline)
        #expect(earlier.pageRange == nil)
        var selection = NotesSectionSelection()
        selection.choose(earlier.anchor, atPage: 12)
        #expect(selection.heading(forPage: 12, outline: outline)?.title == "2.2")
        // Its level picker is its own lineage (it is never in a page's heading path).
        let levels = NotesSectionSelection.levels(showing: earlier, page: 12, outline: outline)
        #expect(levels.map(\.title) == ["2 Ch", "2.2"])
        let dropped = selection.pageDidChange(to: 13, outline: outline)
        #expect(dropped)
        #expect(selection.heading(forPage: 13, outline: outline)?.title == "2.3")

        // Requested from page 15 (search, Notebook) and then jumped to its start page: it holds there.
        var requested = NotesSectionSelection()
        requested.choose(earlier.anchor, atPage: 15)
        let droppedOnStart = requested.pageDidChange(to: 12, outline: outline)
        #expect(!droppedOnStart)
        #expect(requested.heading(forPage: 12, outline: outline)?.title == "2.2")
    }

    @Test func levelPickerListsTheWholeHeadingPath() throws {
        let outline = outline()
        let chapter = try node("1 Ch", outline)
        #expect(NotesSectionSelection.levels(showing: chapter, page: 4, outline: outline).map(\.title)
                == ["1 Ch", "1.1", "1.1.1"])
        // A heading shown while the page has moved on (deferred switch): its lineage.
        let sub = try node("1.1.1", outline)
        #expect(NotesSectionSelection.levels(showing: sub, page: 12, outline: outline).map(\.title)
                == ["1 Ch", "1.1", "1.1.1"])
    }

    @Test func aPinnedHeadingThatDisappearsIsDropped() throws {
        let book = UUID()
        let user = UserHeading(bookID: book, title: "Mine", pageIndex: 7, parent: nil)
        let with = Outline(pdfEntries: [RawOutlineEntry(title: "1 Ch", level: 1, pageIndex: 1)], userHeadings: [user],
                           pageCount: 20)
        var selection = NotesSectionSelection()
        selection.choose(user.anchor, atPage: 8)
        #expect(selection.heading(forPage: 8, outline: with)?.title == "Mine")
        let without = Outline(pdfEntries: [RawOutlineEntry(title: "1 Ch", level: 1, pageIndex: 1)], pageCount: 20)
        let dropped = selection.pageDidChange(to: 8, outline: without)
        #expect(dropped)
        #expect(selection.heading(forPage: 8, outline: without)?.title == "1 Ch")
    }

    // MARK: Page notes in this section

    @Test func pageNoteRangesCoverNestedHeadingsAndSkipSamePageSiblings() async throws {
        let outline = outline()
        #expect(NotesSectionSelection.pageNoteRange(of: try node("1 Ch", outline)) == 1...9)
        #expect(NotesSectionSelection.pageNoteRange(of: try node("1.1", outline)) == 2...5)
        #expect(NotesSectionSelection.pageNoteRange(of: try node("2.1", outline)) == 10...11)
        #expect(NotesSectionSelection.pageNoteRange(of: try node("2.2", outline)) == nil)
        #expect(NotesSectionSelection.pageNoteRange(of: try node("2.3", outline)) == 12...15)

        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let book = Book(title: "B", fingerprint: UUID().uuidString, fileName: "b.pdf", pageCount: 20, fileSize: 1)
        try store.books.save(book)
        for page in [0, 2, 3, 7, 10, 12, 16] {
            try store.notes.save(Note(bookID: book.id, target: .page(page), text: "note \(page)"))
        }
        func pages(_ title: String) throws -> [Int] {
            guard let range = NotesSectionSelection.pageNoteRange(of: try node(title, outline)) else { return [] }
            return try store.notes.pageNotes(bookID: book.id, in: range).compactMap(\.target.pageIndex)
        }
        #expect(try pages("1 Ch") == [2, 3, 7], "the chapter lists its subsections' page notes")
        #expect(try pages("1.1") == [2, 3])
        #expect(try pages("1.1.1") == [3])
        #expect(try pages("2 Ch") == [10, 12])
        #expect(try pages("2.2") == [])
        #expect(try pages("2.3") == [12])
    }

    // MARK: Switching while typing

    @Test func followingThePageWaitsForTypingToEndButExplicitChangesDoNot() {
        let a = NoteTarget.page(3), b = NoteTarget.page(4)
        #expect(NotesTargetSwitch.decide(displayed: a, desired: a, isEditingText: true, explicit: false) == .keep)
        #expect(NotesTargetSwitch.decide(displayed: a, desired: b, isEditingText: false, explicit: false) == .switchNow)
        #expect(NotesTargetSwitch.decide(displayed: a, desired: b, isEditingText: true, explicit: false) == .deferUntilEditingEnds)
        #expect(NotesTargetSwitch.decide(displayed: a, desired: b, isEditingText: true, explicit: true) == .switchNow)
        #expect(NotesTargetSwitch.decide(displayed: nil, desired: b, isEditingText: false, explicit: false) == .switchNow)
        #expect(NotesTargetSwitch.decide(displayed: a, desired: nil, isEditingText: true, explicit: false) == .deferUntilEditingEnds)
    }

    // MARK: Zoom and width

    @Test func paneZoomFollowsWidthAndNeverReflows() {
        func pane(_ width: CGFloat) -> NotesPanelMetrics {
            NotesPanelMetrics(presentation: .pane, size: CGSize(width: width, height: 700))
        }
        #expect(pane(330).zoom(base: 1) == 1)
        #expect(abs(pane(495).zoom(base: 1) - 1.5) < 0.0001)
        #expect(pane(660).zoom(base: 1) == 2)
        #expect(pane(900).zoom(base: 1) == 2, "clamped at 200%")
        #expect(abs(pane(462).zoom(base: 1) - 1.4) < 0.0001)
        #expect(pane(330).zoom(base: 1.25) == 1.25)
        #expect(!pane(660).usesColumns)
        #expect(pane(660).noteColumnWidth == 660)
        // The zoom control sets a base so the chosen zoom shows at this width.
        let wide = pane(495)
        #expect(abs(wide.base(forZoom: 1.5) - 1) < 0.0001)
        #expect(abs(wide.zoom(base: wide.base(forZoom: 1.75)) - 1.75) < 0.0001)
        // Back to the default width: the base is what was chosen there.
        #expect(abs(pane(330).zoom(base: wide.base(forZoom: 1.8)) - 1.2) < 0.0001)
        // A pane at its widest may need a base below 100% for 100%; it is kept in range.
        #expect(pane(900).base(forZoom: 1) == NotesPanelMetrics.baseRange.lowerBound)
    }

    @Test func narrowPresentationsGiveTheNoteAComfortableColumn() {
        let sheet = NotesPanelMetrics(presentation: .narrow, size: CGSize(width: 834, height: 560))
        #expect(sheet.usesColumns)
        #expect(sheet.noteColumnWidth == 433)
        #expect(abs(sheet.zoom(base: 1) - 1.3) < 0.0001, "capped at 130% at the default base")
        #expect(abs(sheet.zoom(base: 1.5) - 1.95) < 0.0001)
        let slim = NotesPanelMetrics(presentation: .narrow, size: CGSize(width: 375, height: 500))
        #expect(!slim.usesColumns)
        #expect(abs(slim.zoom(base: 1) - 375.0 / 330.0) < 0.0001)
        let half = NotesPanelMetrics(presentation: .narrow, size: CGSize(width: 590, height: 500))
        #expect(!half.usesColumns)
        #expect(abs(half.zoom(base: 1) - 1.3) < 0.0001, "never the 179% the full width would give")
        #expect(half.isCompactHeight)
        #expect(!NotesPanelMetrics(presentation: .pane, size: CGSize(width: 330, height: 744)).isCompactHeight)
        #expect(NotesPanelMetrics.percent(1.304) == 130)
    }

    @Test func dynamicTypeSetsTheDefaultBase() {
        #expect(NotePageStyle.defaultZoom(for: DynamicTypeSize.large) == 1)
        #expect(NotePageStyle.defaultZoom(for: DynamicTypeSize.xxxLarge) > 1)
        #expect(NotePageStyle.defaultZoom(for: DynamicTypeSize.accessibility5) == 2)
    }

    // MARK: Heading anchors

    @Test func anchorRepairMovesStaleNotesOnceAndIsIdempotent() throws {
        let outline = outline()
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let book = Book(title: "B", fingerprint: UUID().uuidString, fileName: "b.pdf", pageCount: 20, fileSize: 1)
        try store.books.save(book)
        let section = try node("1.2", outline)
        // Stored before an entry was inserted ahead of it: same title and page, another path.
        let stale = HeadingAnchor(pdfPath: [0, 5], pageIndex: 6, title: "1.2")
        let staleNote = Note(bookID: book.id, target: .heading(stale), text: "stale")
        let chapter = try node("2 Ch", outline)
        let exactNote = Note(bookID: book.id, target: .heading(chapter.anchor), text: "exact")
        let lost = Note(bookID: book.id, target: .heading(HeadingAnchor(pdfPath: [7], pageIndex: 18, title: "Gone")), text: "orphan")
        for note in [staleNote, exactNote, lost] { try store.notes.save(note) }

        let plan = NotesHeadingAnchorRepair.plan(headingNotes: [staleNote, exactNote, lost], outline: outline)
        #expect(plan == [.init(noteID: staleNote.id, from: stale, to: section.anchor)])

        let origin = ChangeOrigin(label: "panel")
        var events: [StoreChangeEvent] = []
        let token = store.hub.observe { events.append($0) }
        #expect(NotesHeadingAnchorRepair.apply(store: store, bookID: book.id, outline: outline, origin: origin) == 1)
        #expect(try store.notes.note(id: staleNote.id)?.target == .heading(section.anchor))
        #expect(try store.notes.note(id: exactNote.id)?.target == .heading(chapter.anchor))
        #expect(try store.notes.note(id: lost.id)?.target == lost.target, "orphans are kept, not moved")
        #expect(!events.isEmpty && events.allSatisfy { $0.isFrom(origin) }, "attributed to the window")

        // Another window (or the Notebook) running it again finds nothing to do.
        events.removeAll()
        #expect(NotesHeadingAnchorRepair.apply(store: store, bookID: book.id, outline: outline, origin: ChangeOrigin()) == 0)
        #expect(events.isEmpty)
        _ = token
    }

    @Test func anchorRepairNeverOverwritesAnOccupiedTarget() throws {
        let outline = outline()
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let book = Book(title: "B", fingerprint: UUID().uuidString, fileName: "b.pdf", pageCount: 20, fileSize: 1)
        try store.books.save(book)
        let section = try node("1.2", outline)
        let stale = Note(bookID: book.id, target: .heading(HeadingAnchor(pdfPath: [0, 5], pageIndex: 6, title: "1.2")), text: "a")
        try store.notes.save(stale)
        // Planned from an old snapshot, but meanwhile someone wrote a note at the current anchor.
        try store.notes.save(Note(bookID: book.id, target: .heading(section.anchor), text: "b"))
        #expect(NotesHeadingAnchorRepair.apply(store: store, bookID: book.id, outline: outline, origin: nil) == 0)
        #expect(try store.notes.note(id: stale.id)?.target == stale.target)
    }
}
