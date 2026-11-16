import Foundation

/// One visible row of the Contents tree: a heading plus what the row needs to draw itself.
/// The list shows `ContentsTree.visibleRows(...)`, a flat array of only the rows that are on
/// display (children of collapsed headings are not in it), so a 5,000-heading outline costs
/// one small value per *visible* row and SwiftUI creates views lazily for the rows on screen.
public struct ContentsRow: Identifiable, Equatable, Sendable {
    public let node: OutlineNode
    /// 0 for top level.
    public let depth: Int
    public let hasChildren: Bool
    public let isExpanded: Bool

    public init(node: OutlineNode, depth: Int, hasChildren: Bool, isExpanded: Bool) {
        self.node = node
        self.depth = depth
        self.hasChildren = hasChildren
        self.isExpanded = isExpanded
    }

    public var id: HeadingAnchor { node.anchor }
    public var anchor: HeadingAnchor { node.anchor }

    public static func == (a: Self, b: Self) -> Bool {
        a.node.anchor == b.node.anchor && a.node.title == b.node.title && a.node.startPage == b.node.startPage
            && a.depth == b.depth && a.hasChildren == b.hasChildren && a.isExpanded == b.isExpanded
    }
}

/// Which headings are expanded, keyed by anchor so the state survives the outline being rebuilt
/// (PDF anchors never change when user headings are added or removed; a user heading's anchor is
/// its ID, so renaming keeps it).
///
/// Two kinds of expansion are kept apart:
/// - **reader** (`byReader`): what the reader opened with a disclosure chevron, plus the default
///   expansion. Never undone by the app.
/// - **revealed** (`revealed`): ancestors opened by current-section tracking so the current
///   section's row is visible. When the current section moves to another branch, revealed
///   headings that are not ancestors of the new section close again, so reading through a book
///   does not leave every chapter open. Collapsing a revealed heading by hand removes it.
public struct ContentsExpansion: Equatable, Sendable {
    public private(set) var byReader: Set<HeadingAnchor> = []
    public private(set) var revealed: Set<HeadingAnchor> = []
    /// `true` once the default expansion was applied (it is applied once per window).
    public private(set) var hasDefaults = false

    public init() {}

    public func isExpanded(_ anchor: HeadingAnchor) -> Bool {
        byReader.contains(anchor) || revealed.contains(anchor)
    }

    /// The union of both kinds.
    public var expanded: Set<HeadingAnchor> { byReader.union(revealed) }

    /// The reader taps the chevron.
    public mutating func toggle(_ anchor: HeadingAnchor) {
        if isExpanded(anchor) {
            byReader.remove(anchor)
            revealed.remove(anchor)
        } else {
            byReader.insert(anchor)
        }
    }

    /// The reader expands (`true`) or collapses (`false`).
    public mutating func set(_ anchor: HeadingAnchor, expanded: Bool) {
        if expanded != isExpanded(anchor) { toggle(anchor) }
    }

    /// Opens every ancestor of the last node of `path` (the current section) and closes the
    /// revealed headings that are not on `path`. Returns `true` if anything changed.
    @discardableResult
    public mutating func reveal(path: [OutlineNode]) -> Bool {
        let ancestors = Set(path.dropLast().map(\.anchor))
        let newRevealed = revealed.intersection(ancestors).union(ancestors.subtracting(byReader))
        guard newRevealed != revealed else { return false }
        revealed = newRevealed
        return true
    }

    /// Opens the ancestors of a heading for good (e.g. a heading the reader just added).
    public mutating func expandLineage(_ lineage: [OutlineNode]) {
        for node in lineage.dropLast() where !isExpanded(node.anchor) { byReader.insert(node.anchor) }
    }

    /// Applies `ContentsTree.defaultExpansion(for:)` once.
    public mutating func applyDefaultsIfNeeded(for outline: Outline) {
        guard !hasDefaults, !outline.isEmpty else { return }
        hasDefaults = true
        byReader.formUnion(ContentsTree.defaultExpansion(for: outline))
    }

    /// Drops anchors that no longer exist (deleted user headings). Optional hygiene.
    public mutating func prune(keeping outline: Outline) {
        byReader = byReader.filter { outline.node(for: $0) != nil }
        revealed = revealed.filter { outline.node(for: $0) != nil }
    }
}

/// Pure rules of the Contents tree (no SwiftUI, no session), unit-tested in
/// `ContentsTreeTests`.
public enum ContentsTree {
    /// The flattened visible rows: a pre-order walk that descends only into expanded headings.
    /// O(visible rows).
    public static func visibleRows(_ outline: Outline, expanded: Set<HeadingAnchor>) -> [ContentsRow] {
        var rows: [ContentsRow] = []
        rows.reserveCapacity(min(outline.nodes.count, 512))
        var stack: [(node: OutlineNode, depth: Int)] = outline.roots.reversed().map { ($0, 0) }
        while let (node, depth) = stack.popLast() {
            let open = !node.children.isEmpty && expanded.contains(node.anchor)
            rows.append(ContentsRow(node: node, depth: depth, hasChildren: !node.children.isEmpty, isExpanded: open))
            if open {
                for child in node.children.reversed() { stack.append((child, depth + 1)) }
            }
        }
        return rows
    }

    /// Up to this many rows the default expansion opens another level.
    public static let defaultRowBudget = 40
    /// With at least this many top-level headings nothing is opened by default: the top level is
    /// already a usable table of contents (a 15-chapter, 375-entry textbook shows its chapters,
    /// with the current chapter opened by current-section tracking).
    public static let defaultTopLevelThreshold = 8

    /// The default expansion of a newly opened outline: when the top level is short (a book whose
    /// outline is one "Book" root, or a few "Part" headings), open whole levels, shallowest first,
    /// for as long as the visible rows stay within `defaultRowBudget`. Otherwise nothing.
    public static func defaultExpansion(for outline: Outline) -> Set<HeadingAnchor> {
        guard outline.roots.count < defaultTopLevelThreshold else { return [] }
        var expanded = Set<HeadingAnchor>()
        var level = outline.roots
        var visible = level.count
        while true {
            let parents = level.filter { !$0.children.isEmpty }
            guard !parents.isEmpty else { break }
            let next = parents.flatMap(\.children)
            guard visible + next.count <= defaultRowBudget else { break }
            expanded.formUnion(parents.map(\.anchor))
            visible += next.count
            level = next
        }
        return expanded
    }

    /// The row that stands for the current section: the deepest heading of `path` that has a
    /// visible row (the current section itself, or its nearest visible ancestor when a branch
    /// is collapsed). `nil` for a page before the first heading.
    public static func currentRowAnchor(path: [OutlineNode], visibleAnchors: Set<HeadingAnchor>) -> HeadingAnchor? {
        path.reversed().first { visibleAnchors.contains($0.anchor) }?.anchor
    }

    /// **The follow rule** for current-section tracking. When the current section changes, the
    /// list reveals and scrolls to the new current row only if
    /// - the change came from a *jump* (Contents, go to page, a bookmark, a thumbnail, Back /
    ///   Forward, search …: anything recorded in section history), or
    /// - the row that stood for the previous current section was on screen (the reader had not
    ///   scrolled the sidebar away from it), or there was none yet.
    ///
    /// Otherwise the reader has scrolled the sidebar to look at something else, and the list is
    /// left exactly where it is (the marking still moves). Following resumes as soon as the
    /// current row is back on screen or after the next jump. When it follows, the list scrolls
    /// only if the new current row is off screen (centring it); a row already on screen never
    /// moves.
    public static func shouldFollow(isJump: Bool, previousCurrentRow: HeadingAnchor?,
                             onScreen: Set<HeadingAnchor>) -> Bool {
        if isJump { return true }
        guard let previousCurrentRow else { return true }
        return onScreen.contains(previousCurrentRow)
    }
}
