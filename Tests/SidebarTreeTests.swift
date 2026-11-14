import Foundation
import ReaderCore
import Testing
@testable import Marginal

/// WP5: the pure Contents tree rules (`ContentsTree`, `ContentsExpansion`).
@MainActor
struct SidebarTreeTests {
    // MARK: Builders

    /// A 4-level outline: 2 chapters × 2 sections × 2 subsections × 2 items, pages ascending.
    static func fourLevelOutline() -> Outline {
        var entries: [RawOutlineEntry] = []
        var page = 0
        for c in 1...2 {
            entries.append(RawOutlineEntry(title: "\(c)", level: 1, pageIndex: page)); page += 1
            for s in 1...2 {
                entries.append(RawOutlineEntry(title: "\(c).\(s)", level: 2, pageIndex: page)); page += 1
                for u in 1...2 {
                    entries.append(RawOutlineEntry(title: "\(c).\(s).\(u)", level: 3, pageIndex: page)); page += 1
                    for i in 1...2 {
                        entries.append(RawOutlineEntry(title: "\(c).\(s).\(u).\(i)", level: 4, pageIndex: page)); page += 1
                    }
                }
            }
        }
        return Outline(pdfEntries: entries, pageCount: page + 5)
    }

    /// The `large.pdf` fixture's outline shape: 15 chapters × 6 sections × 3 subsections (375).
    static func largeOutline(userHeadings: [UserHeading] = []) -> Outline {
        var entries: [RawOutlineEntry] = []
        for c in 0..<15 {
            let cStart = c * 100
            entries.append(RawOutlineEntry(title: "\(c + 1) Chapter", level: 1, pageIndex: cStart))
            for s in 0..<6 {
                let sStart = cStart + s * 16 + 1
                entries.append(RawOutlineEntry(title: "\(c + 1).\(s + 1) Section", level: 2, pageIndex: sStart))
                for u in 0..<3 {
                    entries.append(RawOutlineEntry(title: "\(c + 1).\(s + 1).\(u + 1) Sub", level: 3, pageIndex: sStart + u * 4 + 1))
                }
            }
        }
        return Outline(pdfEntries: entries, userHeadings: userHeadings, pageCount: 1500)
    }

    static func node(_ outline: Outline, _ title: String) -> OutlineNode {
        outline.nodes.first { $0.title == title }!
    }

    // MARK: Visible rows

    @Test func collapsedOutlineShowsOnlyTopLevel() {
        let outline = Self.fourLevelOutline()
        let rows = ContentsTree.visibleRows(outline, expanded: [])
        #expect(rows.map(\.node.title) == ["1", "2"])
        #expect(rows.allSatisfy { $0.depth == 0 && $0.hasChildren && !$0.isExpanded })
    }

    @Test func expandingShowsChildrenInOrderAtTheirDepth() {
        let outline = Self.fourLevelOutline()
        var expansion = ContentsExpansion()
        expansion.toggle(Self.node(outline, "1").anchor)
        expansion.toggle(Self.node(outline, "1.2").anchor)
        expansion.toggle(Self.node(outline, "1.2.1").anchor)
        let rows = ContentsTree.visibleRows(outline, expanded: expansion.expanded)
        #expect(rows.map(\.node.title) == ["1", "1.1", "1.2", "1.2.1", "1.2.1.1", "1.2.1.2", "1.2.2", "2"])
        #expect(rows.map(\.depth) == [0, 1, 1, 2, 3, 3, 2, 0])
        #expect(rows.first { $0.node.title == "1.2.1.1" }?.hasChildren == false)
        #expect(rows.first { $0.node.title == "1.2" }?.isExpanded == true)
        #expect(rows.first { $0.node.title == "1.1" }?.isExpanded == false)

        // Collapsing a middle level hides its whole subtree but remembers the deeper expansion.
        expansion.toggle(Self.node(outline, "1.2").anchor)
        #expect(ContentsTree.visibleRows(outline, expanded: expansion.expanded).map(\.node.title) == ["1", "1.1", "1.2", "2"])
        expansion.toggle(Self.node(outline, "1.2").anchor)
        #expect(ContentsTree.visibleRows(outline, expanded: expansion.expanded).count == 8)
    }

    @Test func fullyExpandedFourLevelTreeIsPreOrder() {
        let outline = Self.fourLevelOutline()
        let all = Set(outline.nodes.map(\.anchor))
        let rows = ContentsTree.visibleRows(outline, expanded: all)
        #expect(rows.map(\.anchor) == outline.nodes.map(\.anchor))
        #expect(rows.map(\.depth) == outline.nodes.map { $0.level - 1 })
    }

    @Test func largeOutlinesAreCheap() {
        // 20 × 25 × 40 = 20,000 leaves plus parents: far beyond any real book.
        var entries: [RawOutlineEntry] = []
        var page = 0
        for c in 0..<20 {
            entries.append(RawOutlineEntry(title: "C\(c)", level: 1, pageIndex: page))
            for s in 0..<25 {
                entries.append(RawOutlineEntry(title: "C\(c).S\(s)", level: 2, pageIndex: page))
                for u in 0..<40 {
                    entries.append(RawOutlineEntry(title: "C\(c).S\(s).U\(u)", level: 3, pageIndex: page))
                    page += 1
                }
            }
        }
        let outline = Outline(pdfEntries: entries, pageCount: page)
        #expect(outline.nodes.count == 20 + 500 + 20_000)

        let clock = ContinuousClock()
        var collapsed: [ContentsRow] = []
        let collapsedTime = clock.measure { collapsed = ContentsTree.visibleRows(outline, expanded: []) }
        #expect(collapsed.count == 20)
        // Only visible rows are visited, so a collapsed tree costs nothing however big it is.
        #expect(collapsedTime < .milliseconds(5))

        let all = Set(outline.nodes.map(\.anchor))
        var expanded: [ContentsRow] = []
        let expandedTime = clock.measure { expanded = ContentsTree.visibleRows(outline, expanded: all) }
        #expect(expanded.count == outline.nodes.count)
        #expect(expandedTime < .milliseconds(500))
    }

    // MARK: Stability across rebuilds

    @Test func expansionSurvivesOutlineRebuildWithUserHeadings() {
        let bookID = UUID()
        let before = Self.largeOutline()
        var expansion = ContentsExpansion()
        expansion.toggle(Self.node(before, "5 Chapter").anchor)
        expansion.toggle(Self.node(before, "5.2 Section").anchor)
        let rowsBefore = ContentsTree.visibleRows(before, expanded: expansion.expanded)

        // A user heading inside 5.2 (page 420) and one at the top level: PDF anchors are unchanged.
        let inside = UserHeading(bookID: bookID, title: "My note", pageIndex: 420,
                                 parent: Self.node(before, "5.2 Section").anchor)
        let top = UserHeading(bookID: bookID, title: "Appendix", pageIndex: 1499, parent: nil)
        let after = Self.largeOutline(userHeadings: [inside, top])
        let rowsAfter = ContentsTree.visibleRows(after, expanded: expansion.expanded)
        #expect(rowsAfter.count == rowsBefore.count + 2)
        #expect(rowsAfter.contains { $0.node.title == "My note" && $0.depth == 2 })
        #expect(rowsAfter.last?.node.title == "Appendix")
        #expect(rowsAfter.first { $0.node.title == "5 Chapter" }?.isExpanded == true)
        #expect(rowsAfter.first { $0.node.title == "5.2 Section" }?.isExpanded == true)
        // Every row that was visible is still visible, in the same order.
        let afterAnchors = rowsAfter.map(\.anchor).filter { anchor in rowsBefore.contains { $0.anchor == anchor } }
        #expect(afterAnchors == rowsBefore.map(\.anchor))
    }

    // MARK: Default expansion

    @Test func defaultExpansionForTheLargeTextbookIsTheChapterList() {
        let outline = Self.largeOutline()
        #expect(outline.nodes.count == 375)
        #expect(ContentsTree.defaultExpansion(for: outline).isEmpty)
        var expansion = ContentsExpansion()
        expansion.applyDefaultsIfNeeded(for: outline)
        #expect(ContentsTree.visibleRows(outline, expanded: expansion.expanded).count == 15)
    }

    @Test func defaultExpansionOpensShortTopLevels() {
        // One "Book" root with 6 parts of 5 chapters of 10 sections.
        var entries = [RawOutlineEntry(title: "Book", level: 1, pageIndex: 0)]
        var page = 1
        for p in 0..<6 {
            entries.append(RawOutlineEntry(title: "Part \(p)", level: 2, pageIndex: page))
            for c in 0..<5 {
                entries.append(RawOutlineEntry(title: "P\(p)C\(c)", level: 3, pageIndex: page))
                for s in 0..<10 {
                    entries.append(RawOutlineEntry(title: "P\(p)C\(c)S\(s)", level: 4, pageIndex: page))
                    page += 1
                }
            }
        }
        let outline = Outline(pdfEntries: entries, pageCount: page)
        let expanded = ContentsTree.defaultExpansion(for: outline)
        let rows = ContentsTree.visibleRows(outline, expanded: expanded)
        // Book (1) + parts (6) + chapters (30) = 37 ≤ 40; sections (300) would exceed the budget.
        #expect(rows.count == 37)
        #expect(rows.filter { $0.depth == 2 }.count == 30)
        #expect(!rows.contains { $0.depth == 3 })

        // Applied once: a later collapse by the reader sticks.
        var expansion = ContentsExpansion()
        expansion.applyDefaultsIfNeeded(for: outline)
        expansion.toggle(Self.node(outline, "Book").anchor)
        expansion.applyDefaultsIfNeeded(for: outline)
        #expect(ContentsTree.visibleRows(outline, expanded: expansion.expanded).count == 1)
    }

    // MARK: Current section

    @Test func revealOpensAncestorsAndClosesWhatItOpenedBefore() {
        let outline = Self.largeOutline()
        var expansion = ContentsExpansion()
        let readerOpened = Self.node(outline, "1 Chapter").anchor
        expansion.toggle(readerOpened)

        let path5 = outline.headingPath(forPage: 420)  // 5 Chapter › 5.2 Section › 5.2.1 Sub
        #expect(path5.map(\.title) == ["5 Chapter", "5.2 Section", "5.2.1 Sub"])
        let opened = expansion.reveal(path: path5)
        #expect(opened)
        #expect(expansion.isExpanded(path5[0].anchor) && expansion.isExpanded(path5[1].anchor))
        #expect(!expansion.isExpanded(path5[2].anchor))
        let openedAgain = expansion.reveal(path: path5)
        #expect(!openedAgain)  // nothing new

        let path7 = outline.headingPath(forPage: 610)
        let moved = expansion.reveal(path: path7)
        #expect(moved)
        // Chapter 5 was only opened by tracking: it closes. Chapter 1 was opened by the reader.
        #expect(!expansion.isExpanded(path5[0].anchor))
        #expect(!expansion.isExpanded(path5[1].anchor))
        #expect(expansion.isExpanded(path7[0].anchor))
        #expect(expansion.isExpanded(readerOpened))

        // Collapsing a revealed heading by hand removes it.
        expansion.toggle(path7[0].anchor)
        #expect(!expansion.isExpanded(path7[0].anchor))
    }

    @Test func currentRowIsTheDeepestVisibleHeadingOfThePath() {
        let outline = Self.largeOutline()
        let path = outline.headingPath(forPage: 420)
        var expansion = ContentsExpansion()
        var rows = ContentsTree.visibleRows(outline, expanded: expansion.expanded)
        #expect(ContentsTree.currentRowAnchor(path: path, visibleAnchors: Set(rows.map(\.anchor))) == path[0].anchor)
        expansion.reveal(path: path)
        rows = ContentsTree.visibleRows(outline, expanded: expansion.expanded)
        #expect(ContentsTree.currentRowAnchor(path: path, visibleAnchors: Set(rows.map(\.anchor))) == path[2].anchor)
        #expect(ContentsTree.currentRowAnchor(path: [], visibleAnchors: Set(rows.map(\.anchor))) == nil)
    }

    @Test func followRule() {
        let a = HeadingAnchor(pdfPath: [0], pageIndex: 0, title: "A")
        // A jump always follows.
        #expect(ContentsTree.shouldFollow(isJump: true, previousCurrentRow: a, onScreen: []))
        // Scrolling the book follows while the previous current row was on screen…
        #expect(ContentsTree.shouldFollow(isJump: false, previousCurrentRow: a, onScreen: [a]))
        // …but not after the reader scrolled the sidebar away from it.
        #expect(!ContentsTree.shouldFollow(isJump: false, previousCurrentRow: a, onScreen: []))
        // No previous current row (front matter, first load): follow.
        #expect(ContentsTree.shouldFollow(isJump: false, previousCurrentRow: nil, onScreen: []))
    }

    @Test func pruneDropsDeletedAnchors() {
        let bookID = UUID()
        let heading = UserHeading(bookID: bookID, title: "Mine", pageIndex: 3, parent: nil)
        let child = UserHeading(bookID: bookID, title: "Child", pageIndex: 4, parent: heading.anchor)
        let with = Outline(pdfEntries: [], userHeadings: [heading, child], pageCount: 10)
        var expansion = ContentsExpansion()
        expansion.toggle(heading.anchor)
        #expect(ContentsTree.visibleRows(with, expanded: expansion.expanded).count == 2)
        let without = Outline(pdfEntries: [], userHeadings: [], pageCount: 10)
        expansion.prune(keeping: without)
        #expect(expansion.expanded.isEmpty)
    }
}
