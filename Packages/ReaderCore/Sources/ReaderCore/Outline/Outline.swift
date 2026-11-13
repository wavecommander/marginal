import Foundation

/// The merged outline of one book: the PDF's own headings plus the reader's headings, with
/// derived page ranges and a precomputed page → heading index.
///
/// Immutable and `Sendable`: build it off the main thread, then hand it to the UI. Rebuild it
/// (cheap: linear in entries + pages) whenever the user headings change.
///
/// ## Building the tree
/// 1. **PDF entries** (pre-order, see `RawOutlineEntry`) become nodes; an entry's parent is the
///    nearest preceding entry with a smaller level. Titles are normalised
///    (`OutlineText.normalizedTitle`). A page index outside `0..<pageCount` counts as no page.
/// 2. **User headings** are attached under their `parent` anchor, resolved with
///    `resolve(_:)` against the PDF headings or by ID against already attached user headings; a
///    missing, unresolvable, self-referencing or cyclic parent makes the heading top level. They
///    are processed in order of (`pageIndex`, `createdAt`, `id.uuidString`). Within its parent's
///    children a user heading is inserted before the first child whose start page is greater
///    than its page (so after every child starting on the same or an earlier page); a child
///    with no start page never stops the scan. User headings never re-parent PDF headings and
///    never change PDF anchors.
///
/// ## Page ranges (the design rule, made total for messy outlines)
/// - **Start page** (`OutlineNode.startPage`): the node's own page, else the first descendant's
///   own page in pre-order, else none. A node with no start page has no range and contains no
///   page (it stays in the tree, can hold a note, and is never in a heading path).
/// - **Siblings** (children of one parent, or the top level) that have a start page are ordered
///   by start page; ties keep display order. This puts out-of-order entries (a "Cover" item
///   listed last, an "Index" listed first) where their pages are.
/// - A node's range runs from its start page to the page before the next sibling's start page
///   in that order; the last one runs to the end of its parent's range (top level: the last
///   page of the book). In a well-ordered outline this is exactly "to the page before the next
///   heading at the same or a shallower level".
/// - The range is then clipped to the parent's range. If nothing is left (the node starts
///   after its parent ends, or it shares its start page with a later sibling, whose range then
///   starts on that page) the node has **no range**, and neither do its descendants.
///   So when several siblings start on one page, **the last of them (in display order)
///   contains that page**; the earlier ones contain no page. A child starting on its parent's
///   start page is fine (parent and child both contain it).
/// - Consequences: sibling ranges never overlap, a child's range is inside its parent's, and a
///   page belongs to at most one heading per level. Pages before the first heading belong to
///   none ("front matter").
///
/// ## Heading path
/// `headingPath(forPage:)` is the chain of nodes whose ranges contain the page, shallowest
/// first; it is read from a per-page table built once, so a call costs O(depth).
public struct Outline: Sendable {
    /// The book's page count the outline was built for.
    public let pageCount: Int
    /// Top-level headings in display order.
    public let roots: [OutlineNode]
    /// Every heading in pre-order (display order, parents before children).
    public let nodes: [OutlineNode]

    private let parentIndex: [Int]
    private let ownerByPage: [Int32]
    private let anchors: AnchorIndex

    /// An outline with no headings.
    public static let empty = Outline(pdfEntries: [], userHeadings: [], pageCount: 0)

    /// Builds the merged outline. See the type documentation for every rule applied.
    /// - Parameters:
    ///   - pdfEntries: the PDF outline flattened depth-first (may be empty).
    ///   - userHeadings: the book's user headings, in any order.
    ///   - pageCount: the book's page count (negative values are treated as 0).
    public init(pdfEntries: [RawOutlineEntry], userHeadings: [UserHeading] = [], pageCount: Int) {
        let pageCount = max(0, pageCount)
        self.pageCount = pageCount
        var builder = OutlineBuilder(pageCount: pageCount)
        builder.addPDFEntries(pdfEntries)
        builder.addUserHeadings(userHeadings)
        let built = builder.finish()
        roots = built.roots
        nodes = built.nodes
        parentIndex = built.parentIndex
        ownerByPage = built.ownerByPage
        anchors = built.anchors
    }

    /// `true` when there are no headings at all.
    public var isEmpty: Bool { nodes.isEmpty }

    /// The node whose anchor equals `anchor` exactly, or `nil`. For stored anchors that may be
    /// stale use `resolve(_:)`.
    public func node(for anchor: HeadingAnchor) -> OutlineNode? {
        anchors.byAnchor[anchor].map { nodes[$0] }
    }

    /// The parent of the node with this exact anchor (`nil` for top level or unknown anchors).
    public func parent(of anchor: HeadingAnchor) -> OutlineNode? {
        guard let index = anchors.byAnchor[anchor] else { return nil }
        let parent = parentIndex[index]
        return parent >= 0 ? nodes[parent] : nil
    }

    /// The node with this exact anchor and all its ancestors, shallowest first (empty for an
    /// unknown anchor). This is the level picker's list when a heading is opened directly.
    public func lineage(of anchor: HeadingAnchor) -> [OutlineNode] {
        guard let index = anchors.byAnchor[anchor] else { return [] }
        return chain(endingAt: index)
    }

    /// The chain of headings whose ranges contain `pageIndex`, shallowest first
    /// (`[chapter 5, section 5.2]`). Empty for a page before the first heading, a page no
    /// heading contains, or an index outside `0..<pageCount`. O(depth).
    public func headingPath(forPage pageIndex: Int) -> [OutlineNode] {
        guard let index = ownerIndex(forPage: pageIndex) else { return [] }
        return chain(endingAt: index)
    }

    /// The last element of `headingPath(forPage:)`: the deepest heading containing the page.
    /// The Section note tab opens on it, and the Notebook files the page's items under it. O(1).
    public func deepestHeading(forPage pageIndex: Int) -> OutlineNode? {
        ownerIndex(forPage: pageIndex).map { nodes[$0] }
    }

    /// Matches a stored anchor against this outline, trying in order (titles by
    /// `OutlineText.matchKey`; only PDF headings are candidates for PDF anchors):
    /// 1. `.exact`: a node's anchor equals the stored anchor (same string).
    /// 2. `.titleAndPage`: PDF nodes with the same title and the same page (both missing counts
    ///    as the same); if several, prefer the one at the anchor's path, then one whose level
    ///    equals the anchor's path length, then the first in pre-order. (This also catches a
    ///    title that differs only in case, diacritics or width at the same path.)
    /// 3. `.pathAndTitle`: the node at the anchor's path has the same title (page differs).
    /// 4. `.pathAndPage`: the node at the anchor's path has the same page, and the page exists.
    /// 5. `.titleOnly`: exactly one PDF node has the title.
    ///
    /// A user anchor matches only the user heading with that ID (`.exact`). Returns `nil` when
    /// nothing matches. Each call is independent: two different stored anchors may resolve to the
    /// same node; use `resolveAll(_:)` when that matters.
    public func resolve(_ anchor: HeadingAnchor) -> AnchorMatch? {
        anchors.resolve(anchor).map { AnchorMatch(node: nodes[$0.index], quality: $0.quality) }
    }

    /// Resolves many stored anchors at once so that **no two anchors claim the same node**.
    /// Each anchor is resolved as by `resolve(_:)`; then, in order of match quality (strongest
    /// first) and then of `rawValue`, each anchor takes its node if it is still free. Anchors
    /// that resolve to nothing, or whose node was taken by a stronger match, are absent from the
    /// result (their notes are orphans). Duplicate input anchors are treated as one.
    public func resolveAll<S: Sequence>(_ storedAnchors: S) -> [HeadingAnchor: AnchorMatch] where S.Element == HeadingAnchor {
        var candidates: [(anchor: HeadingAnchor, index: Int, quality: AnchorMatchQuality)] = []
        for anchor in Set(storedAnchors) {
            if let hit = anchors.resolve(anchor) {
                candidates.append((anchor, hit.index, hit.quality))
            }
        }
        candidates.sort { a, b in
            a.quality != b.quality ? a.quality < b.quality : a.anchor.rawValue < b.anchor.rawValue
        }
        var taken = Set<Int>()
        var result: [HeadingAnchor: AnchorMatch] = [:]
        for candidate in candidates where taken.insert(candidate.index).inserted {
            result[candidate.anchor] = AnchorMatch(node: nodes[candidate.index], quality: candidate.quality)
        }
        return result
    }

    // MARK: - Private

    private func ownerIndex(forPage pageIndex: Int) -> Int? {
        guard pageIndex >= 0, pageIndex < ownerByPage.count else { return nil }
        let owner = Int(ownerByPage[pageIndex])
        return owner >= 0 ? owner : nil
    }

    private func chain(endingAt index: Int) -> [OutlineNode] {
        var chain: [OutlineNode] = []
        var current = index
        while current >= 0 {
            chain.append(nodes[current])
            current = parentIndex[current]
        }
        chain.reverse()
        return chain
    }
}

// MARK: - Anchor resolution index

/// Lookup tables for `resolve`. Indices refer to whatever node array the index was built over.
struct AnchorIndex: Sendable {
    struct Entry: Sendable {
        var path: [Int]?      // nil for user headings
        var titleKey: String
        var pageIndex: Int?
    }

    var entries: [Entry] = []
    var byAnchor: [HeadingAnchor: Int] = [:]
    var byPath: [[Int]: Int] = [:]
    var byTitleKey: [String: [Int]] = [:]   // PDF nodes only, ascending index

    mutating func add(index: Int, anchor: HeadingAnchor, title: String, pageIndex: Int?) {
        let path = anchor.pdfPath
        let key = OutlineText.matchKey(title)
        if entries.count <= index {
            entries.append(contentsOf: Array(repeating: Entry(path: nil, titleKey: "", pageIndex: nil), count: index - entries.count + 1))
        }
        entries[index] = Entry(path: path, titleKey: key, pageIndex: pageIndex)
        byAnchor[anchor] = index
        if let path {
            byPath[path] = index
            byTitleKey[key, default: []].append(index)
        }
    }

    func resolve(_ anchor: HeadingAnchor) -> (index: Int, quality: AnchorMatchQuality)? {
        switch anchor.kind {
        case .user:
            return byAnchor[anchor].map { ($0, .exact) }
        case .pdf(let path, let page, let title):
            if let i = byAnchor[anchor] {
                return (i, .exact)
            }
            let key = OutlineText.matchKey(title)
            let atPath = byPath[path]
            let sameTitle = byTitleKey[key] ?? []
            let samePage = sameTitle.filter { entries[$0].pageIndex == page }
            if !samePage.isEmpty {
                let best = samePage.first { $0 == atPath }
                    ?? samePage.first { (entries[$0].path?.count ?? 0) == path.count }
                    ?? samePage[0]
                return (best, .titleAndPage)
            }
            if let i = atPath, entries[i].titleKey == key {
                return (i, .pathAndTitle)
            }
            if let i = atPath, let page, entries[i].pageIndex == page {
                return (i, .pathAndPage)
            }
            if sameTitle.count == 1 {
                return (sameTitle[0], .titleOnly)
            }
            return nil
        }
    }
}

// MARK: - Builder

private struct OutlineBuilder {
    struct Draft {
        var title: String
        var ownPage: Int?
        var origin: OutlineNode.Origin
        var anchor: HeadingAnchor
        var parent: Int?
        var children: [Int] = []
        var level: Int
        var startPage: Int? = nil
        var range: ClosedRange<Int>? = nil
    }

    let pageCount: Int
    var drafts: [Draft] = []
    var rootChildren: [Int] = []

    init(pageCount: Int) { self.pageCount = pageCount }

    func validPage(_ page: Int?) -> Int? {
        guard let page, PageNumbering.isValid(page, pageCount: pageCount) else { return nil }
        return page
    }

    mutating func addPDFEntries(_ entries: [RawOutlineEntry]) {
        var stack: [(index: Int, rawLevel: Int)] = []
        var paths: [[Int]] = []
        drafts.reserveCapacity(entries.count)
        for entry in entries {
            let rawLevel = max(1, entry.level)
            while let top = stack.last, top.rawLevel >= rawLevel { stack.removeLast() }
            let parent = stack.last?.index
            let siblingIndex = parent.map { drafts[$0].children.count } ?? rootChildren.count
            let path = (parent.map { paths[$0] } ?? []) + [siblingIndex]
            let page = validPage(entry.pageIndex)
            let title = OutlineText.normalizedTitle(entry.title)
            let index = drafts.count
            drafts.append(Draft(
                title: title, ownPage: page, origin: .pdf,
                anchor: HeadingAnchor(pdfPath: path, pageIndex: page, title: title),
                parent: parent, level: parent.map { drafts[$0].level + 1 } ?? 1
            ))
            paths.append(path)
            if let parent { drafts[parent].children.append(index) } else { rootChildren.append(index) }
            stack.append((index, rawLevel))
        }
    }

    /// Start page of every draft; children always have larger indices than their parents, so a
    /// reverse sweep sees children first.
    mutating func computeStartPages() {
        for index in drafts.indices.reversed() {
            var start = drafts[index].ownPage
            if start == nil {
                for child in drafts[index].children {
                    if let childStart = drafts[child].startPage { start = childStart; break }
                }
            }
            drafts[index].startPage = start
        }
    }

    mutating func addUserHeadings(_ headings: [UserHeading]) {
        guard !headings.isEmpty else { return }
        computeStartPages()  // positions for insertion among PDF siblings
        var pdfIndex = AnchorIndex()
        for (index, draft) in drafts.enumerated() {
            pdfIndex.add(index: index, anchor: draft.anchor, title: draft.title, pageIndex: draft.ownPage)
        }

        var pending = headings.sorted { a, b in
            if a.pageIndex != b.pageIndex { return a.pageIndex < b.pageIndex }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
        var waiting = Set(pending.map(\.id))
        var attached: [UUID: Int] = [:]

        while !pending.isEmpty {
            var deferred: [UserHeading] = []
            for heading in pending {
                if attached[heading.id] != nil { waiting.remove(heading.id); continue } // duplicate ID
                switch heading.parent?.kind {
                case nil:
                    attach(heading, under: nil, attached: &attached)
                case .pdf?:
                    attach(heading, under: pdfIndex.resolve(heading.parent!)?.index, attached: &attached)
                case .user(let parentID)?:
                    if let parentDraft = attached[parentID] {
                        attach(heading, under: parentDraft, attached: &attached)
                    } else if parentID != heading.id && waiting.contains(parentID) {
                        deferred.append(heading)
                        continue
                    } else {
                        attach(heading, under: nil, attached: &attached)
                    }
                }
                waiting.remove(heading.id)
            }
            if deferred.count == pending.count {
                // Only cycles remain: attach them all at top level, in sorted order.
                for heading in deferred where attached[heading.id] == nil {
                    attach(heading, under: nil, attached: &attached)
                }
                break
            }
            pending = deferred
        }
    }

    private mutating func attach(_ heading: UserHeading, under parent: Int?, attached: inout [UUID: Int]) {
        let page = validPage(heading.pageIndex)
        let index = drafts.count
        let title = OutlineText.normalizedTitle(heading.title)
        var draft = Draft(
            title: title, ownPage: page, origin: .user(heading.id), anchor: heading.anchor,
            parent: parent, level: parent.map { drafts[$0].level + 1 } ?? 1
        )
        draft.startPage = page
        drafts.append(draft)
        attached[heading.id] = index
        let siblings = parent.map { drafts[$0].children } ?? rootChildren
        var position = siblings.count
        if let page {
            position = siblings.firstIndex { sibling in
                guard let start = drafts[sibling].startPage else { return false }
                return start > page
            } ?? siblings.count
        }
        if let parent { drafts[parent].children.insert(index, at: position) } else { rootChildren.insert(index, at: position) }
    }

    mutating func computeRanges(children: [Int], container: ClosedRange<Int>?) {
        guard let container else { return }  // drafts' ranges default to nil
        let ranged = children.enumerated()
            .compactMap { offset, child in drafts[child].startPage.map { (child: child, start: $0, order: offset) } }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.order < $1.order }
        for (k, item) in ranged.enumerated() {
            let end = k + 1 < ranged.count ? ranged[k + 1].start - 1 : container.upperBound
            let lower = max(item.start, container.lowerBound)
            let upper = min(end, container.upperBound)
            let range: ClosedRange<Int>? = lower <= upper ? lower...upper : nil
            drafts[item.child].range = range
            computeRanges(children: drafts[item.child].children, container: range)
        }
    }

    struct Built {
        var roots: [OutlineNode]
        var nodes: [OutlineNode]
        var parentIndex: [Int]
        var ownerByPage: [Int32]
        var anchors: AnchorIndex
    }

    mutating func finish() -> Built {
        computeStartPages()
        computeRanges(children: rootChildren, container: pageCount > 0 ? 0...(pageCount - 1) : nil)

        // Pre-order over display order.
        var preorder: [Int] = []
        preorder.reserveCapacity(drafts.count)
        var stack = Array(rootChildren.reversed())
        while let next = stack.popLast() {
            preorder.append(next)
            stack.append(contentsOf: drafts[next].children.reversed())
        }

        // Materialise bottom-up so each node's children array is built once and shared.
        var built = [OutlineNode?](repeating: nil, count: drafts.count)
        for draftIndex in preorder.reversed() {
            let draft = drafts[draftIndex]
            built[draftIndex] = OutlineNode(
                anchor: draft.anchor, title: draft.title, level: draft.level, pageIndex: draft.ownPage,
                startPage: draft.startPage, pageRange: draft.range, origin: draft.origin,
                parentAnchor: draft.parent.map { drafts[$0].anchor },
                children: draft.children.map { built[$0]! }
            )
        }

        var preorderPosition = [Int](repeating: -1, count: drafts.count)
        for (position, draftIndex) in preorder.enumerated() { preorderPosition[draftIndex] = position }

        var nodes: [OutlineNode] = []
        nodes.reserveCapacity(preorder.count)
        var parentIndex: [Int] = []
        parentIndex.reserveCapacity(preorder.count)
        var ownerByPage = [Int32](repeating: -1, count: pageCount)
        var anchors = AnchorIndex()
        for (position, draftIndex) in preorder.enumerated() {
            let node = built[draftIndex]!
            nodes.append(node)
            parentIndex.append(drafts[draftIndex].parent.map { preorderPosition[$0] } ?? -1)
            anchors.add(index: position, anchor: node.anchor, title: node.title, pageIndex: node.pageIndex)
            // Parents come before children in pre-order, so deeper headings overwrite.
            if let range = node.pageRange {
                for page in range { ownerByPage[page] = Int32(position) }
            }
        }
        return Built(roots: rootChildren.map { built[$0]! }, nodes: nodes, parentIndex: parentIndex,
                     ownerByPage: ownerByPage, anchors: anchors)
    }
}
