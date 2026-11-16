import Foundation
import ReaderCore
import ReaderStore
import Testing
@testable import TactileTexts

/// Contents sidebar: "Add heading at page N", rename and delete of user headings.
@MainActor
struct SidebarHeadingTests {
    typealias Support = SidebarTestSupport

    // MARK: Parent choices

    @Test func parentChoicesAreTopLevelPlusTheHeadingPath() {
        let outline = Support.largeOutline()
        let choices = UserHeadingEditor.parentChoices(outline: outline, pageIndex: 420)
        #expect(choices.map(\.title) == ["Top level", "5 Chapter", "5.2 Section", "5.2.1 Sub"])
        #expect(choices.map(\.childLevel) == [1, 2, 3, 4])
        // Default: under the deepest heading that contains the page.
        #expect(UserHeadingEditor.defaultParent(outline: outline, pageIndex: 420).title == "5.2.1 Sub")
        #expect(outline.headingPath(forPage: 400).map(\.title) == ["5 Chapter"])
        #expect(UserHeadingEditor.defaultParent(outline: outline, pageIndex: 400).title == "5 Chapter")
        // Front matter / no outline: top level.
        #expect(UserHeadingEditor.defaultParent(outline: Outline(pdfEntries: [], pageCount: 9), pageIndex: 3) == .topLevel)
        // A book with no outline: only "Top level".
        let empty = Outline(pdfEntries: [], pageCount: 40)
        #expect(UserHeadingEditor.parentChoices(outline: empty, pageIndex: 4) == [.topLevel])
        #expect(UserHeadingEditor.defaultParent(outline: empty, pageIndex: 4) == .topLevel)
    }

    @Test func containingHeadingsMatchesTheCoreAndIgnoresTheEditedHeading() {
        let bookID = UUID()
        let outline = Support.largeOutline()
        // Without an exclusion (or with an anchor not in the outline) it is the heading path.
        let stranger = HeadingAnchor(userHeadingID: UUID())
        for page in stride(from: 0, to: 1500, by: 7) {
            #expect(UserHeadingEditor.containingHeadings(outline: outline, pageIndex: page, excluding: stranger).map(\.anchor)
                    == outline.headingPath(forPage: page).map(\.anchor))
        }
        // A top-level reader heading at page 311 takes pages 311… from chapter 4 (siblings
        // split ranges by start page)…
        let mine = UserHeading(bookID: bookID, title: "Mine", pageIndex: 311, parent: nil)
        let child = UserHeading(bookID: bookID, title: "Mine child", pageIndex: 312, parent: mine.anchor)
        let withMine = Support.largeOutline(userHeadings: [mine, child])
        #expect(withMine.headingPath(forPage: 312).map(\.title) == ["Mine", "Mine child"])
        // …but when editing it, chapter 4's own path is offered, never itself or its child.
        let choices = UserHeadingEditor.parentChoices(outline: withMine, pageIndex: 312, excluding: mine.anchor)
        #expect(choices.map(\.title) == ["Top level", "4 Chapter", "4.1 Section", "4.1.3 Sub"])
    }

    @Test func rememberedPlacementFollowsTheReader() {
        let outline = Support.largeOutline()
        let choices420 = UserHeadingEditor.parentChoices(outline: outline, pageIndex: 420)  // 5 › 5.2 › 5.2.1
        let choices640 = UserHeadingEditor.parentChoices(outline: outline, pageIndex: 640)  // 7 › 7.3 › 7.3.2
        #expect(UserHeadingEditor.rememberedParent(nil, choices: choices420) == nil)
        // Top level stays top level.
        let top = HeadingPlacementMemory(parent: nil, childLevel: 1)
        #expect(UserHeadingEditor.rememberedParent(top, choices: choices640) == .topLevel)
        // The same parent when it contains the page…
        let in52 = HeadingPlacementMemory(parent: choices420[2].anchor, childLevel: 3)
        #expect(UserHeadingEditor.rememberedParent(in52, choices: choices420)?.title == "5.2 Section")
        // …else the same level in the new page's path.
        #expect(UserHeadingEditor.rememberedParent(in52, choices: choices640)?.title == "7.3 Section")
        // A level the new page cannot give: no memory (the default applies).
        let deep = HeadingPlacementMemory(parent: HeadingAnchor(userHeadingID: UUID()), childLevel: 9)
        #expect(UserHeadingEditor.rememberedParent(deep, choices: choices640) == nil)
    }

    @Test func titleFromSelection() {
        #expect(UserHeadingEditor.title(fromSelection: "  The Characteristic\n  Equation \t ") == "The Characteristic Equation")
        #expect(UserHeadingEditor.title(fromSelection: "Eigen-\nvalues and eigen-\n vectors") == "Eigenvalues and eigenvectors")
        #expect(UserHeadingEditor.title(fromSelection: "Well-known  result") == "Well-known result")
        #expect(UserHeadingEditor.title(fromSelection: " \n ") == "")
        let long = Array(repeating: "word", count: 60).joined(separator: " ")  // 299 characters
        let capped = UserHeadingEditor.title(fromSelection: long)
        #expect(capped.count <= UserHeadingEditor.maxTitleLength)
        #expect(capped.hasSuffix("word"))
        #expect(!capped.hasSuffix(" "))
    }

    @Test func moveToAnotherPagePromoteAndDemote() async throws {
        let fixture = try Support.makeFixture("no-outline.pdf", pageCount: 40)
        defer { Support.cleanUp(fixture) }
        let (session, _) = await Support.openedSession(fixture)
        let part = try UserHeadingEditor.add(title: "Part", pageIndex: 2, parent: .topLevel, session: session)
        _ = await Support.waitUntil { session.outline.node(for: part) != nil }
        let partChoice = UserHeadingEditor.parentChoices(outline: session.outline, pageIndex: 9)[1]
        let chapter = try UserHeadingEditor.add(title: "Chapter", pageIndex: 9, parent: partChoice, session: session)
        _ = await Support.waitUntil { session.outline.node(for: chapter) != nil }
        let chapterChoice = UserHeadingEditor.parentChoices(outline: session.outline, pageIndex: 12)[2]
        let section = try UserHeadingEditor.add(title: "Section", pageIndex: 12, parent: chapterChoice, session: session)
        #expect(await Support.waitUntil { session.outline.node(for: section)?.level == 3 })

        // Move Section to page 20 (still inside Chapter): same parent, new page.
        try UserHeadingEditor.update(section, title: "Section", pageIndex: 19, parent: chapterChoice, session: session)
        #expect(await Support.waitUntil { session.outline.node(for: section)?.startPage == 19 })
        #expect(session.outline.parent(of: section)?.anchor == chapter)

        // Promote: under Part (level 2), then to the top level.
        var node = try #require(session.outline.node(for: section))
        #expect(UserHeadingEditor.neighbourPlacement(node, up: false, outline: session.outline) == nil)  // deepest already
        try UserHeadingEditor.move(node, up: true, session: session)
        #expect(await Support.waitUntil { session.outline.node(for: section)?.level == 2 })
        #expect(session.outline.parent(of: section)?.anchor == part)
        node = try #require(session.outline.node(for: section))
        try UserHeadingEditor.move(node, up: true, session: session)
        #expect(await Support.waitUntil { session.outline.node(for: section)?.level == 1 })
        node = try #require(session.outline.node(for: section))
        #expect(UserHeadingEditor.neighbourPlacement(node, up: true, outline: session.outline) == nil)

        // Demote: as a top-level heading at page 20 it took pages 20… from Part, yet "Part" is
        // offered as the level below (its own range is ignored while it is edited).
        let down = try #require(UserHeadingEditor.neighbourPlacement(node, up: false, outline: session.outline))
        #expect(down.anchor == part)
        try UserHeadingEditor.move(node, up: false, session: session)
        #expect(await Support.waitUntil { session.outline.parent(of: section)?.anchor == part })

        // A heading can never be placed inside itself or its own sub-heading.
        let selfChoice = HeadingParentChoice.heading(anchor: part, title: "Part", level: 1)
        #expect(throws: UserHeadingEditor.EditError.invalidPlacement) {
            try UserHeadingEditor.update(part, title: "Part", pageIndex: 2, parent: selfChoice, session: session)
        }
        let intoChild = HeadingParentChoice.heading(anchor: chapter, title: "Chapter", level: 2)
        #expect(throws: UserHeadingEditor.EditError.invalidPlacement) {
            try UserHeadingEditor.update(part, title: "Part", pageIndex: 10, parent: intoChild, session: session)
        }
    }

    @Test func entryPointOpensTheSheetAndRemembersPlacement() async throws {
        let fixture = try Support.makeFixture("no-outline.pdf", pageCount: 40)
        defer { Support.cleanUp(fixture) }
        let (session, model) = await Support.openedSession(fixture)
        session.isNarrowLayout = false
        session.isContentsVisible = false
        // The shell's request (More menu, ⌥⌘H, selection menu): taken once by the sidebar model.
        session.requestAddHeading(atPage: 6, suggestedTitle: "  From the menu ")
        #expect(session.isContentsVisible, "Contents is shown to host the sheet")
        #expect(await Support.waitUntil { model.headingSheet != nil })
        #expect(model.headingSheet?.mode == .add(pageIndex: 6, title: "From the menu"))
        #expect(session.pendingAddHeadingRequest == nil, "handled once")
        #expect(session.currentPageIndex == 0, "never moves the PDF")

        let anchor = try UserHeadingEditor.add(title: "From the menu", pageIndex: 6, parent: .topLevel, session: session)
        model.headingSaved(anchor, placement: .topLevel, isNew: true)
        #expect(model.selectedHeading == anchor)
        #expect(model.lastPlacement == HeadingPlacementMemory(parent: nil, childLevel: 1))
        #expect(await Support.waitUntil { Support.row(model, "From the menu") != nil })
        #expect(model.scrollRequest?.anchor == anchor)
        // Tapping a heading clears the selection and jumps.
        model.select(try #require(session.outline.node(for: anchor)))
        #expect(model.selectedHeading == nil)
        #expect(session.currentPageIndex == 6)
    }

    // MARK: Add, rename, delete

    @Test func addRenameDeleteOnABookWithNoOutline() async throws {
        let fixture = try Support.makeFixture("no-outline.pdf", pageCount: 40)
        defer { Support.cleanUp(fixture) }
        let (session, model) = await Support.openedSession(fixture)
        #expect(session.outline.isEmpty)

        // Add "Chapter A" at page 5 (index 4), top level.
        let a = try UserHeadingEditor.add(title: "  Chapter A ", pageIndex: 4, parent: .topLevel, session: session)
        #expect(await Support.waitUntil { session.outline.node(for: a) != nil })
        #expect(session.outline.node(for: a)?.title == "Chapter A")
        #expect(session.outline.node(for: a)?.isEditable == true)

        // "A.1" inside A at page 7: choices on page 7 are top level and Chapter A.
        let choices = UserHeadingEditor.parentChoices(outline: session.outline, pageIndex: 6)
        #expect(choices.map(\.title) == ["Top level", "Chapter A"])
        let a1 = try UserHeadingEditor.add(title: "A.1", pageIndex: 6, parent: choices[1], session: session)
        let a2 = try UserHeadingEditor.add(title: "A.2", pageIndex: 9, parent: choices[1], session: session)
        #expect(await Support.waitUntil { session.outline.nodes.count == 3 })
        #expect(session.outline.parent(of: a1)?.anchor == a)
        #expect(session.outline.node(for: a2)?.level == 2)

        // The model reveals a newly added heading.
        model.revealWhenAvailable(a2)
        #expect(Support.row(model, "A.2") != nil)
        #expect(model.scrollRequest?.anchor == a2)

        // Rename keeps the anchor (and so its note).
        _ = try session.perform {
            try $0.notes.save(Note(bookID: fixture.book.id, target: .heading(a), text: "About A"))
        }
        try UserHeadingEditor.rename(a, to: "Chapter One", session: session)
        #expect(await Support.waitUntil { session.outline.node(for: a)?.title == "Chapter One" })
        #expect(try fixture.store.notes.note(bookID: fixture.book.id, target: .heading(a))?.text == "About A")
        #expect(throws: UserHeadingEditor.EditError.emptyTitle) {
            try UserHeadingEditor.rename(a, to: "   ", session: session)
        }

        // Delete A: the summary says what happens; A.1 and A.2 move up to the top level; the
        // note stays stored and becomes an unfiled (orphan) note in the Notebook.
        let summary = try UserHeadingEditor.deletionSummary(a, session: session)
        #expect(summary.childCount == 2)
        #expect(summary.hasNote)
        #expect(summary.message.contains("2 sub-headings move up one level"))
        #expect(summary.message.contains("Unfiled notes"))
        try UserHeadingEditor.delete(a, session: session)
        #expect(await Support.waitUntil { session.outline.node(for: a) == nil && session.outline.nodes.count == 2 })
        #expect(session.outline.roots.map(\.title) == ["A.1", "A.2"])
        #expect(session.outline.node(for: a1)?.level == 1)
        #expect(try fixture.store.notes.note(bookID: fixture.book.id, target: .heading(a)) != nil)
        #expect(await Support.waitUntil { session.notebook?.orphanNotes.count == 1 })
    }

    @Test func deleteReparentsChildrenToTheDeletedHeadingsParent() async throws {
        let fixture = try Support.makeFixture()  // small.pdf, PDF outline
        defer { Support.cleanUp(fixture) }
        let (session, _) = await Support.openedSession(fixture)
        let chapter2 = try #require(session.outline.nodes.first { $0.title == "2 Vector Spaces" })
        // Mine (inside chapter 2, page 6) › Leaf (page 7).
        let mine = try UserHeadingEditor.add(title: "Mine", pageIndex: 5,
                                             parent: .heading(anchor: chapter2.anchor, title: chapter2.title, level: 1),
                                             session: session)
        _ = await Support.waitUntil { session.outline.node(for: mine) != nil }
        let leafParent = try #require(UserHeadingEditor.parentChoices(outline: session.outline, pageIndex: 6)
            .first { $0.anchor == mine })
        let leaf = try UserHeadingEditor.add(title: "Leaf", pageIndex: 6, parent: leafParent, session: session)
        #expect(await Support.waitUntil { session.outline.node(for: leaf)?.level == 3 })

        let summary = try UserHeadingEditor.deletionSummary(mine, session: session)
        #expect(summary.childCount == 1)
        #expect(!summary.hasNote)
        #expect(!summary.message.contains("Unfiled"))
        try UserHeadingEditor.delete(mine, session: session)
        #expect(await Support.waitUntil { session.outline.node(for: mine) == nil })
        // Leaf moved up one level: under chapter 2, not to the top level.
        #expect(session.outline.parent(of: leaf)?.anchor == chapter2.anchor)
        #expect(session.outline.node(for: leaf)?.level == 2)
        #expect(try fixture.store.headings.userHeading(id: leaf.userHeadingID!)?.parent == chapter2.anchor)
    }

    @Test func pdfHeadingsAreReadOnly() async throws {
        let fixture = try Support.makeFixture()
        defer { Support.cleanUp(fixture) }
        let (session, _) = await Support.openedSession(fixture)
        let pdfHeading = try #require(session.outline.nodes.first)
        #expect(!pdfHeading.isEditable)
        #expect(throws: UserHeadingEditor.EditError.notAUserHeading) {
            try UserHeadingEditor.rename(pdfHeading.anchor, to: "x", session: session)
        }
        #expect(throws: UserHeadingEditor.EditError.notAUserHeading) {
            try UserHeadingEditor.delete(pdfHeading.anchor, session: session)
        }
        #expect(throws: UserHeadingEditor.EditError.invalidPage) {
            try UserHeadingEditor.add(title: "x", pageIndex: 99, parent: .topLevel, session: session)
        }
        #expect(throws: UserHeadingEditor.EditError.emptyTitle) {
            try UserHeadingEditor.add(title: " ", pageIndex: 1, parent: .topLevel, session: session)
        }
    }
}
