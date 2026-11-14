import Foundation

/// A place in a book for section history: a page and the section (deepest heading) containing
/// it, or a page alone when no heading contains it (front matter, or a book with no outline),
/// and, for a place the reader left, the exact position on screen.
public struct SectionPlace: Hashable, Sendable, Codable {
    /// Zero-based page index: the reader's current page when the place was recorded. It names
    /// the place's section and its menu entry. Going to a place without an `anchor` goes to the
    /// top of this page, so a place stays valid when its heading is later renamed, moved or
    /// deleted.
    public var pageIndex: Int
    /// The deepest heading containing `pageIndex` when the place was recorded, or `nil` for a
    /// page-keyed place.
    public var heading: HeadingAnchor?
    /// The heading's title when recorded (for menus); `nil` for a page-keyed place.
    public var title: String?
    /// The exact position the reader left: the page point that was at the top-left corner of
    /// the view (its page can be the one before `pageIndex` when the top of the view showed the
    /// end of the previous page). Going to the place puts that point back there. `nil` for a
    /// jump's destination the reader has not left yet, and in history saved before positions
    /// were recorded: such a place goes to the top of `pageIndex`.
    public var anchor: ReadingAnchor?

    public init(pageIndex: Int, heading: HeadingAnchor?, title: String?, anchor: ReadingAnchor? = nil) {
        self.pageIndex = pageIndex
        self.heading = heading
        self.title = heading == nil ? nil : title
        self.anchor = anchor
    }

    /// The place of `pageIndex` in `outline`: its `deepestHeading`, or page-keyed if none.
    public init(pageIndex: Int, in outline: Outline, anchor: ReadingAnchor? = nil) {
        let node = outline.deepestHeading(forPage: pageIndex)
        self.init(pageIndex: pageIndex, heading: node?.anchor, title: node?.title, anchor: anchor)
    }

    /// Same section: both have a heading and the anchors are equal, or both are page-keyed and
    /// on the same page.
    public func isSameSection(as other: SectionPlace) -> Bool {
        switch (heading, other.heading) {
        case let (a?, b?): a == b
        case (nil, nil): pageIndex == other.pageIndex
        default: false
        }
    }

    /// Menu text: `"5.2 The Characteristic Equation · p. 312"`, or `"Page 312"` for a page-keyed
    /// place.
    public var menuTitle: String {
        let number = PageNumbering.displayNumber(forPageIndex: pageIndex)
        if let title { return "\(title) · p. \(number)" }
        return "Page \(number)"
    }
}

/// One reader window's back/forward trail of the sections the reader jumped between (design:
/// "Section history"). A pure value: the session owns one, mutates it on every jump, and stores
/// it with the window's restorable state (`Codable`).
///
/// **Rules**
/// - `recordJump(from:to:)`: `from` is the place actually on screen (page, its section and the
///   exact position). The current entry becomes `from`. If `to` is in the same section as
///   `from`, the current entry becomes `to` and nothing is added. Otherwise the forward entries
///   are dropped, `to` is appended and becomes current, and the oldest entries drop off beyond
///   `capacity`.
/// - `back(from:)` / `forward(from:)` / `goToEntry(at:from:)`: first update the current entry to
///   `from` (the place on screen), then move the cursor and return the place to go to: the
///   exact place the reader left it, never the section's first page. Forward undoes Back.
/// - An empty history has no current entry; the first jump records both places.
public struct SectionHistory: Hashable, Sendable, Codable {
    /// Default maximum number of entries.
    public static let defaultCapacity = 50

    /// Entries, oldest first.
    public private(set) var entries: [SectionPlace]
    /// Index of the current entry in `entries` (`-1` when empty).
    public private(set) var cursor: Int
    /// Maximum number of entries (at least 2).
    public let capacity: Int

    public init(capacity: Int = SectionHistory.defaultCapacity) {
        self.entries = []
        self.cursor = -1
        self.capacity = max(2, capacity)
    }

    /// The current entry, `nil` when empty.
    public var current: SectionPlace? { entries.indices.contains(cursor) ? entries[cursor] : nil }
    public var canGoBack: Bool { cursor > 0 }
    public var canGoForward: Bool { cursor >= 0 && cursor < entries.count - 1 }

    /// Entries behind the current one, nearest first (the Back button's press-and-hold list),
    /// paired with their index for `goToEntry(at:from:)`.
    public var backList: [(index: Int, place: SectionPlace)] {
        guard cursor > 0 else { return [] }
        return (0..<cursor).reversed().map { ($0, entries[$0]) }
    }

    /// Entries ahead of the current one, nearest first (the Forward button's list).
    public var forwardList: [(index: Int, place: SectionPlace)] {
        guard canGoForward else { return [] }
        return ((cursor + 1)..<entries.count).map { ($0, entries[$0]) }
    }

    /// Records a jump. Returns `true` when an entry was added (a jump to another section).
    @discardableResult
    public mutating func recordJump(from: SectionPlace, to: SectionPlace) -> Bool {
        if entries.isEmpty {
            entries = [from]
            cursor = 0
        } else {
            entries[cursor] = from
        }
        if to.isSameSection(as: from) {
            entries[cursor] = to
            return false
        }
        entries.removeSubrange((cursor + 1)...)
        entries.append(to)
        cursor = entries.count - 1
        if entries.count > capacity {
            let excess = entries.count - capacity
            entries.removeFirst(excess)
            cursor -= excess
        }
        return true
    }

    /// Steps back. `from` is the place on screen (stored into the current entry first).
    public mutating func back(from: SectionPlace) -> SectionPlace? {
        guard canGoBack else { return nil }
        return goToEntry(at: cursor - 1, from: from)
    }

    /// Steps forward (undoes `back`). `from` is the place on screen.
    public mutating func forward(from: SectionPlace) -> SectionPlace? {
        guard canGoForward else { return nil }
        return goToEntry(at: cursor + 1, from: from)
    }

    /// Moves straight to the entry at `index` (from `backList` / `forwardList`). `from` is the
    /// place on screen. Returns `nil` (and changes nothing) for an invalid index.
    public mutating func goToEntry(at index: Int, from: SectionPlace) -> SectionPlace? {
        guard entries.indices.contains(index), cursor >= 0 else { return nil }
        entries[cursor] = from
        cursor = index
        return entries[index]
    }

    // MARK: Codable (validates the cursor)

    private enum CodingKeys: String, CodingKey { case entries, cursor, capacity }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let capacity = max(2, try container.decodeIfPresent(Int.self, forKey: .capacity) ?? Self.defaultCapacity)
        var entries = try container.decode([SectionPlace].self, forKey: .entries)
        var cursor = try container.decode(Int.self, forKey: .cursor)
        if entries.count > capacity {
            let excess = entries.count - capacity
            entries.removeFirst(excess)
            cursor -= excess
        }
        self.capacity = capacity
        self.entries = entries
        self.cursor = entries.isEmpty ? -1 : min(max(cursor, 0), entries.count - 1)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(cursor, forKey: .cursor)
        try container.encode(capacity, forKey: .capacity)
    }
}
