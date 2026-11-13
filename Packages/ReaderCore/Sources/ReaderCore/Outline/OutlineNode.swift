import Foundation

/// One item of a PDF outline, as produced by flattening `PDFDocument.outlineRoot` depth-first
/// (pre-order: an item, then its children in order, then its next sibling).
///
/// The flattener (WP4) must emit every item, including ones with no destination, in that order.
public struct RawOutlineEntry: Hashable, Sendable, Codable {
    /// The item's label as the PDF gives it. Normalised by the outline builder.
    public var title: String
    /// 1-based depth: `1` for a child of the outline root (a top-level item), `2` for its
    /// children, and so on. Values below 1 are treated as 1. An entry's parent is the nearest
    /// preceding entry with a smaller level, so a jump (1 → 3) simply nests one level deeper.
    public var level: Int
    /// Zero-based index of the destination page (`PDFDocument.index(for: destination.page)`),
    /// or `nil` when the item has no destination or action resolving to a page.
    public var pageIndex: Int?

    public init(title: String, level: Int, pageIndex: Int?) {
        self.title = title
        self.level = level
        self.pageIndex = pageIndex
    }
}

/// One heading of the merged outline (PDF headings plus the reader's own headings).
///
/// Immutable value; a new `Outline` is built whenever user headings change. `id` is the anchor,
/// which is stable across rebuilds, so SwiftUI lists keep their identity.
public struct OutlineNode: Hashable, Sendable, Identifiable {
    /// Where the heading came from.
    public enum Origin: Hashable, Sendable {
        /// From the PDF's outline. Read-only in the app.
        case pdf
        /// Added by the reader (`UserHeading.id`). Renamable and deletable.
        case user(UUID)
    }

    /// Stable identity; see `HeadingAnchor`.
    public let anchor: HeadingAnchor
    /// `OutlineText.normalizedTitle` of the PDF or user title.
    public let title: String
    /// 1-based depth in the merged tree (`1` = top level). For PDF headings this equals the
    /// raw entry's (normalised) depth; for user headings it is the parent's level + 1.
    public let level: Int
    /// The heading's own destination page, validated against the page count (`nil` when the
    /// entry had none or it was outside `0..<pageCount`).
    public let pageIndex: Int?
    /// The page the heading starts on for ranges and for "jump to heading": `pageIndex` if
    /// present, else the `pageIndex` of the first descendant (pre-order) that has one, else `nil`.
    public let startPage: Int?
    /// The pages this heading contains, or `nil` if it contains none. See `Outline` for the
    /// range rules. Invariant: page `p` is in `pageRange` exactly when this node is in
    /// `Outline.headingPath(forPage: p)`.
    public let pageRange: ClosedRange<Int>?
    /// PDF or user heading.
    public let origin: Origin
    /// The parent's anchor, `nil` for a top-level heading.
    public let parentAnchor: HeadingAnchor?
    /// Children in display order: PDF children in outline order, with user headings inserted
    /// by page (see `Outline`).
    public let children: [OutlineNode]

    /// Same as `anchor`.
    public var id: HeadingAnchor { anchor }
    /// `true` for user headings (rename/delete allowed); PDF headings are read-only.
    public var isEditable: Bool { if case .user = origin { true } else { false } }
    /// `true` for headings the reader added.
    public var isUserHeading: Bool { isEditable }
    /// The user heading ID for user headings, else `nil`.
    public var userHeadingID: UUID? { if case .user(let id) = origin { id } else { nil } }
    /// `children`, or `nil` when there are none (the shape `OutlineGroup`/`List(children:)` want).
    public var childrenIfAny: [OutlineNode]? { children.isEmpty ? nil : children }

    init(anchor: HeadingAnchor, title: String, level: Int, pageIndex: Int?, startPage: Int?,
         pageRange: ClosedRange<Int>?, origin: Origin, parentAnchor: HeadingAnchor?, children: [OutlineNode]) {
        self.anchor = anchor
        self.title = title
        self.level = level
        self.pageIndex = pageIndex
        self.startPage = startPage
        self.pageRange = pageRange
        self.origin = origin
        self.parentAnchor = parentAnchor
        self.children = children
    }
}

/// How confidently a stored `HeadingAnchor` was matched to a heading of the current outline.
/// Cases are in the order `Outline.resolve(_:)` tries them; earlier is stronger (`<`).
///
/// Titles compare by `OutlineText.matchKey`; pages by equality (a missing page equals a missing
/// page only where noted).
public enum AnchorMatchQuality: Int, Comparable, Hashable, Sendable, CaseIterable {
    /// The stored anchor equals the node's anchor (identical string: same path, normalised
    /// title and page). User anchors only ever match this way, by `UserHeading.id`.
    case exact = 0
    /// Same title (by match key) and page, different anchor: typically siblings were inserted
    /// or removed earlier in the outline. A missing page matches a missing page here.
    case titleAndPage = 1
    /// Same path and title, different page: the book's pages shifted (e.g. a new front cover).
    case pathAndTitle = 2
    /// Same path and page, different title: the heading was retitled. Both pages must exist.
    case pathAndPage = 3
    /// Only the title matches and exactly one PDF heading has that title.
    case titleOnly = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A resolved anchor: the heading it now refers to and how it was matched.
public struct AnchorMatch: Hashable, Sendable {
    /// The heading in the current outline. Its `anchor` may differ from the stored one unless
    /// `quality == .exact`.
    public let node: OutlineNode
    /// How the match was made.
    public let quality: AnchorMatchQuality

    /// `true` when the stored anchor is still current and needs no repair.
    public var isExact: Bool { quality == .exact }
}
