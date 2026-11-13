import Foundation
import Testing
@testable import ReaderCore

@Suite("Outline tree and ranges")
struct OutlineRangeTests {
    @Test func buildsTreeFromLevelsIncludingJumps() {
        let outline = Outline(pdfEntries: [
            e("A", 1, 0), e("A.1", 2, 1), e("A.1.1 jump", 4, 2), e("A.2", 2, 3), e("B", 1, 5), e("B.x", 0, 6),
        ], pageCount: 10)
        #expect(outline.roots.map(\.title) == ["A", "B", "B.x"])           // level 0 is treated as 1
        #expect(outline.roots[0].children.map(\.title) == ["A.1", "A.2"])
        #expect(outline.titled("A.1.1 jump").level == 3)                     // depth in the tree
        #expect(outline.titled("A.1.1 jump").parentAnchor == outline.titled("A.1").anchor)
        #expect(outline.nodes.map(\.title) == ["A", "A.1", "A.1.1 jump", "A.2", "B", "B.x"])
        #expect(outline.parent(of: outline.titled("A.2").anchor)?.title == "A")
        #expect(outline.lineage(of: outline.titled("A.1.1 jump").anchor).map(\.title) == ["A", "A.1", "A.1.1 jump"])
    }

    @Test func wellOrderedRangesFollowTheDesignRule() {
        let outline = Outline(pdfEntries: [
            e("Ch1", 1, 10), e("1.1", 2, 10), e("1.2", 2, 20), e("Ch2", 1, 40), e("2.1", 2, 45), e("Ch3", 1, 70),
        ], pageCount: 100)
        #expect(outline.titled("Ch1").pageRange == 10...39)
        #expect(outline.titled("1.1").pageRange == 10...19)
        #expect(outline.titled("1.2").pageRange == 20...39)
        #expect(outline.titled("Ch2").pageRange == 40...69)
        #expect(outline.titled("2.1").pageRange == 45...69)
        #expect(outline.titled("Ch3").pageRange == 70...99)  // last runs to the end of the book
        #expect(outline.pathTitles(10) == ["Ch1", "1.1"])
        #expect(outline.pathTitles(25) == ["Ch1", "1.2"])
        #expect(outline.pathTitles(42) == ["Ch2"])           // before 2.1 starts
        #expect(outline.pathTitles(50) == ["Ch2", "2.1"])
        #expect(outline.pathTitles(99) == ["Ch3"])
        #expect(outline.deepestHeading(forPage: 50)?.title == "2.1")
    }

    @Test func pageBeforeFirstHeadingAndOutOfBoundsHaveEmptyPath() {
        let outline = Outline(pdfEntries: [e("Ch1", 1, 10)], pageCount: 20)
        #expect(outline.headingPath(forPage: 0).isEmpty)
        #expect(outline.headingPath(forPage: 9).isEmpty)
        #expect(outline.deepestHeading(forPage: 9) == nil)
        #expect(outline.pathTitles(10) == ["Ch1"])
        #expect(outline.headingPath(forPage: -1).isEmpty)
        #expect(outline.headingPath(forPage: 20).isEmpty)
    }

    @Test func entriesWithoutDestination() {
        let outline = Outline(pdfEntries: [
            e("Part I", 1, nil), e("Ch1", 2, 10), e("Ch2", 2, 30),
            e("Part II", 1, nil), e("Ch3", 2, 50), e("Exercises", 3, nil), e("Ch4", 2, 70),
            e("Appendix label", 1, nil), e("Broken link", 1, 500),
        ], pageCount: 100)
        // A parent with no destination starts at its first descendant's page.
        #expect(outline.titled("Part I").pageIndex == nil)
        #expect(outline.titled("Part I").startPage == 10)
        #expect(outline.titled("Part I").pageRange == 10...49)
        #expect(outline.titled("Part II").pageRange == 50...99)
        #expect(outline.titled("Ch3").pageRange == 50...69)
        // A leaf with no destination is kept but contains no page.
        let exercises = outline.titled("Exercises")
        #expect(exercises.startPage == nil && exercises.pageRange == nil)
        #expect(outline.titled("Appendix label").pageRange == nil)
        // A destination outside the book counts as none.
        #expect(outline.titled("Broken link").pageIndex == nil)
        #expect(outline.titled("Broken link").pageRange == nil)
        #expect(outline.pathTitles(55) == ["Part II", "Ch3"])
        #expect(outline.pathTitles(5).isEmpty)
        #expect(outline.nodes.count == 9)
    }

    @Test func entriesOutOfPageOrder() {
        let outline = Outline(pdfEntries: [
            e("Index", 1, 190),            // listed first, points near the end
            e("Ch1", 1, 10), e("1.1", 2, 8), e("1.2", 2, 15),   // a child before its parent's page
            e("Ch2", 1, 50), e("2.9 Stray", 2, 195),            // a child beyond its parent's range
            e("Contents", 1, 5),           // front matter listed after the chapters
            e("Cover", 1, 0),
        ], pageCount: 200)
        // Display order is the PDF's order; ranges use page order.
        #expect(outline.roots.map(\.title) == ["Index", "Ch1", "Ch2", "Contents", "Cover"])
        #expect(outline.titled("Cover").pageRange == 0...4)
        #expect(outline.titled("Contents").pageRange == 5...9)
        #expect(outline.titled("Ch1").pageRange == 10...49)
        #expect(outline.titled("Ch2").pageRange == 50...189)
        #expect(outline.titled("Index").pageRange == 190...199)
        #expect(outline.titled("1.1").startPage == 8)
        #expect(outline.titled("1.1").pageRange == 10...14)   // clipped to the parent
        #expect(outline.titled("2.9 Stray").pageRange == nil) // wholly outside the parent
        #expect(outline.pathTitles(2) == ["Cover"])
        #expect(outline.pathTitles(7) == ["Contents"])
        #expect(outline.pathTitles(12) == ["Ch1", "1.1"])
        #expect(outline.pathTitles(195) == ["Index"])
    }

    @Test func severalHeadingsStartingOnOnePage() {
        let outline = Outline(pdfEntries: [
            e("Ch1", 1, 10), e("1.1", 2, 10), e("1.1.1", 3, 12), e("1.1.2", 3, 12), e("1.1.3", 3, 12),
            e("1.2", 2, 20), e("Ch2", 1, 30),
        ], pageCount: 50)
        // Parent and first child on one page: both contain it.
        #expect(outline.pathTitles(10) == ["Ch1", "1.1"])
        // Siblings on one page: the last contains it, the earlier ones contain no page.
        #expect(outline.titled("1.1.1").pageRange == nil)
        #expect(outline.titled("1.1.2").pageRange == nil)
        #expect(outline.titled("1.1.3").pageRange == 12...19)
        #expect(outline.titled("1.1.1").startPage == 12)   // still a jump target
        #expect(outline.pathTitles(12) == ["Ch1", "1.1", "1.1.3"])
        #expect(outline.pathTitles(11) == ["Ch1", "1.1"])

        let chapters = Outline(pdfEntries: [e("A", 1, 5), e("B", 1, 5)], pageCount: 10)
        #expect(chapters.titled("A").pageRange == nil)
        #expect(chapters.titled("B").pageRange == 5...9)
    }

    @Test func fourLevelOutline() {
        let outline = Outline(pdfEntries: [
            e("P", 1, 0), e("C", 2, 0), e("S", 3, 5), e("SS", 4, 6), e("SS2", 4, 8), e("S2", 3, 10), e("P2", 1, 50),
        ], pageCount: 100)
        #expect(outline.pathTitles(0) == ["P", "C"])
        #expect(outline.pathTitles(5) == ["P", "C", "S"])
        #expect(outline.pathTitles(7) == ["P", "C", "S", "SS"])
        #expect(outline.pathTitles(8) == ["P", "C", "S", "SS2"])
        #expect(outline.pathTitles(30) == ["P", "C", "S2"])
        #expect(outline.pathTitles(60) == ["P2"])
        #expect(outline.headingPath(forPage: 7).map(\.level) == [1, 2, 3, 4])
        #expect(outline.titled("SS").pageRange == 6...7)
        #expect(outline.titled("SS2").pageRange == 8...9)
    }

    @Test func emptyOutlineAndZeroPages() {
        let outline = Outline(pdfEntries: [], pageCount: 40)
        #expect(outline.isEmpty)
        #expect(outline.headingPath(forPage: 3).isEmpty)
        let zero = Outline(pdfEntries: [e("A", 1, 0)], pageCount: 0)
        #expect(zero.titled("A").pageRange == nil)
        #expect(Outline.empty.isEmpty)
    }

    @Test func titlesAreNormalised() {
        let outline = Outline(pdfEntries: [e("  5.2\tThe\nCharacteristic   Equation \u{0}", 1, 0)], pageCount: 1)
        #expect(outline.roots[0].title == "5.2 The Characteristic Equation")
    }

    /// Invariants on messy generated outlines: sibling ranges are disjoint, child ranges lie in
    /// their parent's, and `p ∈ node.pageRange ⟺ node ∈ headingPath(p)`.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func rangeInvariantsOnMessyOutlines(seed: Int) {
        var rng = SeededGenerator(state: UInt64(seed))
        let pageCount = 120
        var entries: [RawOutlineEntry] = []
        var level = 1
        for i in 0..<60 {
            level = max(1, min(4, level + Int.random(in: -2...1, using: &rng)))
            let page: Int? = Int.random(in: 0..<10, using: &rng) == 0 ? nil : Int.random(in: -5..<130, using: &rng)
            entries.append(e("H\(i)", level, page))
        }
        let users = (0..<6).map { i in
            UserHeading(id: uuid(i), bookID: bookA, title: "U\(i)", pageIndex: Int.random(in: 0..<pageCount, using: &rng),
                        parent: i % 2 == 0 ? nil : HeadingAnchor(userHeadingID: uuid(i - 1)), createdAt: fixedDate)
        }
        let outline = Outline(pdfEntries: entries, userHeadings: users, pageCount: pageCount)
        #expect(outline.nodes.count == 66)

        func check(_ siblings: [OutlineNode], within container: ClosedRange<Int>?) {
            let ranges = siblings.compactMap(\.pageRange).sorted { $0.lowerBound < $1.lowerBound }
            for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(a.upperBound < b.lowerBound) }
            for node in siblings {
                if let range = node.pageRange {
                    if let container { #expect(container.contains(range.lowerBound) && container.contains(range.upperBound)) }
                }
                check(node.children, within: node.pageRange)
                if node.pageRange == nil { #expect(node.children.allSatisfy { $0.pageRange == nil }) }
            }
        }
        check(outline.roots, within: 0...(pageCount - 1))

        for page in 0..<pageCount {
            let path = Set(outline.headingPath(forPage: page).map(\.anchor))
            for node in outline.nodes {
                #expect(path.contains(node.anchor) == (node.pageRange?.contains(page) ?? false))
            }
        }
    }
}
