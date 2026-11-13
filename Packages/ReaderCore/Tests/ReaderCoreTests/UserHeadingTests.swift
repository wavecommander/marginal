import Foundation
import Testing
@testable import ReaderCore

@Suite("User headings merged into the outline")
struct UserHeadingTests {
    let pdf = [e("Ch1", 1, 10), e("1.1", 2, 10), e("1.2", 2, 20), e("Ch2", 1, 40)]

    @Test func emptyPDFOutlineWithUserHeadingsOnly() {
        let part = UserHeading(id: uuid(2), bookID: bookA, title: "Part", pageIndex: 10, parent: nil, createdAt: fixedDate)
        let headings = [
            UserHeading(id: uuid(4), bookID: bookA, title: "Later", pageIndex: 30, parent: nil, createdAt: fixedDate.addingTimeInterval(-100)),
            UserHeading(id: uuid(3), bookID: bookA, title: "Detail", pageIndex: 15, parent: part.anchor, createdAt: fixedDate),
            part,
            UserHeading(id: uuid(1), bookID: bookA, title: "Intro", pageIndex: 0, parent: nil, createdAt: fixedDate),
        ]
        let outline = Outline(pdfEntries: [], userHeadings: headings, pageCount: 40)
        #expect(outline.roots.map(\.title) == ["Intro", "Part", "Later"])
        #expect(outline.titled("Part").children.map(\.title) == ["Detail"])
        #expect(outline.titled("Detail").level == 2)
        #expect(outline.titled("Intro").pageRange == 0...9)
        #expect(outline.titled("Part").pageRange == 10...29)
        #expect(outline.titled("Detail").pageRange == 15...29)
        #expect(outline.titled("Later").pageRange == 30...39)
        #expect(outline.pathTitles(20) == ["Part", "Detail"])
        #expect(outline.nodes.allSatisfy { $0.isEditable })
        #expect(outline.titled("Detail").anchor == HeadingAnchor(userHeadingID: uuid(3)))
        #expect(outline.titled("Detail").userHeadingID == uuid(3))
    }

    @Test func userHeadingInsertedBetweenPDFHeadings() {
        let plain = Outline(pdfEntries: pdf, pageCount: 60)
        let ch1 = plain.titled("Ch1").anchor
        let merged = Outline(pdfEntries: pdf, userHeadings: [
            UserHeading(id: uuid(1), bookID: bookA, title: "Interlude", pageIndex: 30, parent: nil, createdAt: fixedDate),
            UserHeading(id: uuid(2), bookID: bookA, title: "1.1b", pageIndex: 15, parent: ch1, createdAt: fixedDate),
        ], pageCount: 60)
        #expect(merged.roots.map(\.title) == ["Ch1", "Interlude", "Ch2"])
        #expect(merged.titled("Ch1").children.map(\.title) == ["1.1", "1.1b", "1.2"])
        #expect(merged.titled("Ch1").pageRange == 10...29)
        #expect(merged.titled("1.1").pageRange == 10...14)
        #expect(merged.titled("1.1b").pageRange == 15...19)
        #expect(merged.titled("1.2").pageRange == 20...29)
        #expect(merged.titled("Interlude").pageRange == 30...39)
        #expect(merged.pathTitles(16) == ["Ch1", "1.1b"])
        #expect(merged.pathTitles(35) == ["Interlude"])
        #expect(!merged.titled("Ch1").isEditable)
        #expect(merged.titled("Interlude").isEditable)
        // PDF anchors do not change when user headings are added.
        for node in plain.nodes { #expect(merged.node(for: node.anchor)?.title == node.title) }
    }

    @Test func userHeadingOnTheSamePageAsAPDFSiblingGoesAfterIt() {
        let plain = Outline(pdfEntries: pdf, pageCount: 60)
        let merged = Outline(pdfEntries: pdf, userHeadings: [
            UserHeading(id: uuid(1), bookID: bookA, title: "Mine", pageIndex: 20, parent: plain.titled("Ch1").anchor, createdAt: fixedDate),
            UserHeading(id: uuid(2), bookID: bookA, title: "Under 1.2", pageIndex: 25, parent: plain.titled("1.2").anchor, createdAt: fixedDate),
        ], pageCount: 60)
        #expect(merged.titled("Ch1").children.map(\.title) == ["1.1", "1.2", "Mine"])
        // Same-page siblings: the last one contains the page.
        #expect(merged.titled("1.2").pageRange == nil)
        #expect(merged.titled("Mine").pageRange == 20...39)
        #expect(merged.titled("Under 1.2").pageRange == nil)   // its parent contains no page
        #expect(merged.titled("Under 1.2").level == 3)
    }

    @Test func unresolvableSelfAndCyclicParentsBecomeTopLevel() {
        let a = UserHeading(id: uuid(1), bookID: bookA, title: "A", pageIndex: 5, parent: HeadingAnchor(userHeadingID: uuid(2)), createdAt: fixedDate)
        let b = UserHeading(id: uuid(2), bookID: bookA, title: "B", pageIndex: 6, parent: HeadingAnchor(userHeadingID: uuid(1)), createdAt: fixedDate)
        let me = UserHeading(id: uuid(3), bookID: bookA, title: "Self", pageIndex: 7, parent: HeadingAnchor(userHeadingID: uuid(3)), createdAt: fixedDate)
        let lost = UserHeading(id: uuid(4), bookID: bookA, title: "Lost", pageIndex: 8,
                               parent: HeadingAnchor(pdfPath: [9], pageIndex: 3, title: "Gone"), createdAt: fixedDate)
        let missing = UserHeading(id: uuid(5), bookID: bookA, title: "Missing", pageIndex: 9, parent: HeadingAnchor(userHeadingID: uuid(99)), createdAt: fixedDate)
        let outline = Outline(pdfEntries: [], userHeadings: [b, lost, a, missing, me], pageCount: 20)
        #expect(Set(outline.roots.map(\.title)) == ["A", "B", "Self", "Lost", "Missing"])
        #expect(outline.roots.map(\.title) == ["A", "B", "Self", "Lost", "Missing"])   // page order
        #expect(outline.nodes.allSatisfy { $0.level == 1 })
    }

    @Test func childOfUserHeadingIsAttachedEvenIfProcessedFirst() {
        let parent = UserHeading(id: uuid(1), bookID: bookA, title: "Parent", pageIndex: 10, parent: nil, createdAt: fixedDate)
        let child = UserHeading(id: uuid(2), bookID: bookA, title: "Child", pageIndex: 5, parent: parent.anchor, createdAt: fixedDate)
        let outline = Outline(pdfEntries: [], userHeadings: [child, parent], pageCount: 20)
        #expect(outline.roots.map(\.title) == ["Parent"])
        #expect(outline.titled("Parent").children.map(\.title) == ["Child"])
        #expect(outline.titled("Child").pageRange == 10...19)   // starts before its parent: clipped
        #expect(outline.titled("Parent").pageRange == 10...19)
    }
}
