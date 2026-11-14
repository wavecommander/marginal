import Foundation
import ReaderCore
import ReaderStore
import Testing
@testable import Marginal

/// WP5: "Add heading at page N", rename and delete of user headings.
@MainActor
struct SidebarHeadingTests {
    typealias Support = SidebarTestSupport

    // MARK: Parent choices

    @Test func parentChoicesAreTopLevelPlusTheHeadingPath() {
        let outline = SidebarTreeTests.largeOutline()
        let choices = UserHeadingEditor.parentChoices(outline: outline, pageIndex: 420)
        #expect(choices.map(\.title) == ["Top level", "5 Chapter", "5.2 Section", "5.2.1 Sub"])
        #expect(choices.map(\.childLevel) == [1, 2, 3, 4])
        // Default: the same level as the current (deepest) section, i.e. inside its parent.
        #expect(UserHeadingEditor.defaultParent(outline: outline, pageIndex: 420).title == "5.2 Section")
        // In a chapter's own first page (path = [chapter]) the default is the top level.
        #expect(outline.headingPath(forPage: 400).map(\.title) == ["5 Chapter"])
        #expect(UserHeadingEditor.defaultParent(outline: outline, pageIndex: 400) == .topLevel)
        // A book with no outline: only "Top level".
        let empty = Outline(pdfEntries: [], pageCount: 40)
        #expect(UserHeadingEditor.parentChoices(outline: empty, pageIndex: 4) == [.topLevel])
        #expect(UserHeadingEditor.defaultParent(outline: empty, pageIndex: 4) == .topLevel)
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
        #expect(summary.message.contains("2 subheadings move up one level"))
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
