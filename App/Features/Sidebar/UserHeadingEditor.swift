import Foundation
import ReaderCore

/// Where a heading goes: at the top level or inside one of the headings that contain its page.
nonisolated enum HeadingParentChoice: Hashable, Sendable, Identifiable {
    case topLevel
    case heading(anchor: HeadingAnchor, title: String, level: Int)

    var id: String {
        switch self {
        case .topLevel: "top"
        case .heading(let anchor, _, _): anchor.rawValue
        }
    }

    var anchor: HeadingAnchor? {
        if case .heading(let anchor, _, _) = self { return anchor }
        return nil
    }

    /// The heading's level under this parent.
    var childLevel: Int {
        switch self {
        case .topLevel: 1
        case .heading(_, _, let level): level + 1
        }
    }

    var title: String {
        switch self {
        case .topLevel: "Top level"
        case .heading(_, let title, _): title
        }
    }

    /// `true` for a heading the reader added (marked as theirs in the picker).
    var isUserHeading: Bool { anchor?.isUserHeading ?? false }
}

/// The placement the reader chose last in a window (see `UserHeadingEditor.rememberedParent`).
struct HeadingPlacementMemory: Equatable {
    /// The parent heading, `nil` for top level.
    var parent: HeadingAnchor?
    /// The level the heading got.
    var childLevel: Int
}

/// What deleting a user heading will do, for the confirmation.
struct UserHeadingDeletionSummary: Equatable {
    var title: String
    /// User headings nested directly under it (they move up one level, to its parent).
    var childCount: Int
    /// The heading has its own (section) note.
    var hasNote: Bool

    /// The confirmation's message. Truthful to the core's behaviour: deleting a user heading
    /// deletes only the heading record. Its note stays stored; the Notebook lists a heading note
    /// whose heading no longer resolves under "Unfiled notes" (the core's `orphanNotes`; a user
    /// heading's anchor is its ID, so the note is never re-attached to another heading by
    /// title). Page notes, highlights, ink and bookmarks are attached to pages and are not
    /// touched; they are now filed under the enclosing heading.
    var message: String {
        var parts: [String] = []
        if childCount == 1 {
            parts.append("Its sub-heading moves up one level.")
        } else if childCount > 1 {
            parts.append("Its \(childCount) sub-headings move up one level.")
        }
        if hasNote {
            parts.append("Its section note is kept and appears under “Unfiled notes” in the Notebook.")
        }
        parts.append("Page notes, highlights and ink on its pages are not affected.")
        return parts.joined(separator: " ")
    }
}

/// Adding, editing and deleting the reader's own headings, always through `session.perform`
/// (so other windows hear about it and every window's outline rebuilds through its session on
/// `userHeadingsChanged`). PDF headings are read-only: every mutation refuses them.
@MainActor
enum UserHeadingEditor {
    enum EditError: Error, Equatable {
        case emptyTitle
        case invalidPage
        case notAUserHeading
        case invalidPlacement
    }

    // MARK: Placement

    /// The headings whose ranges would contain `pageIndex` if the heading `excluded` (and
    /// everything under it) were not in the outline, shallowest first. With `excluded == nil`
    /// this is exactly `outline.headingPath(forPage:)`. Used when editing a heading, whose own
    /// range (and its children's) must not count: a heading cannot be placed inside itself, and
    /// a top-level reader heading that takes over part of a chapter's pages must still be able
    /// to move back under that chapter. Same range rules as the core (`Outline`): siblings
    /// ordered by start page, ties keep display order, the later of same-page siblings owns the
    /// page, ranges clipped to the parent's.
    static func containingHeadings(outline: Outline, pageIndex: Int, excluding excluded: HeadingAnchor?) -> [OutlineNode] {
        guard let excluded else { return outline.headingPath(forPage: pageIndex) }
        guard PageNumbering.isValid(pageIndex, pageCount: outline.pageCount) else { return [] }
        var path: [OutlineNode] = []
        var siblings = outline.roots
        var container = 0...(outline.pageCount - 1)
        struct Ranged { let node: OutlineNode; let start: Int; let order: Int }
        while true {
            var ranged: [Ranged] = []
            for (offset, node) in siblings.enumerated() where node.anchor != excluded {
                if let start = node.startPage { ranged.append(Ranged(node: node, start: start, order: offset)) }
            }
            ranged.sort { a, b in a.start != b.start ? a.start < b.start : a.order < b.order }
            var found: (node: OutlineNode, range: ClosedRange<Int>)?
            for (k, item) in ranged.enumerated() {
                let end = k + 1 < ranged.count ? ranged[k + 1].start - 1 : container.upperBound
                let lower = max(item.start, container.lowerBound)
                let upper = min(end, container.upperBound)
                guard lower <= upper, (lower...upper).contains(pageIndex) else { continue }
                found = (item.node, lower...upper)
                break
            }
            guard let found else { break }
            path.append(found.node)
            siblings = found.node.children
            container = found.range
        }
        return path
    }

    /// The placement choices for a heading at `pageIndex`: "Top level" then every heading that
    /// contains the page, shallowest first (the core's recommendation). When editing a heading,
    /// pass it as `excluding`.
    static func parentChoices(outline: Outline, pageIndex: Int, excluding: HeadingAnchor? = nil) -> [HeadingParentChoice] {
        [.topLevel] + containingHeadings(outline: outline, pageIndex: pageIndex, excluding: excluding).map {
            .heading(anchor: $0.anchor, title: $0.title, level: $0.level)
        }
    }

    /// The default placement: under the deepest heading (PDF or the reader's own) that contains
    /// the page, so a new heading subdivides the section the reader is in; top level when the
    /// page is in no section (no outline yet, or front matter).
    static func defaultParent(outline: Outline, pageIndex: Int, excluding: HeadingAnchor? = nil) -> HeadingParentChoice {
        parentChoices(outline: outline, pageIndex: pageIndex, excluding: excluding).last ?? .topLevel
    }

    /// The placement the reader used last in this window, re-applied to a new page: the same
    /// parent if it contains the page (or top level), else the choice that gives the same level,
    /// else `nil` (use the default). So adding chapters in a row stays at the top level, and
    /// adding sections in a row stays one level down, in whichever chapter the page is.
    static func rememberedParent(_ memory: HeadingPlacementMemory?, choices: [HeadingParentChoice]) -> HeadingParentChoice? {
        guard let memory else { return nil }
        if let match = choices.first(where: { $0.anchor == memory.parent }) { return match }
        return choices.first { $0.childLevel == memory.childLevel }
    }

    /// The placement one level up (its parent's parent) or one level down (the next deeper heading
    /// that contains its page), or `nil` when there is none (or for a PDF heading).
    static func neighbourPlacement(_ node: OutlineNode, up: Bool, outline: Outline) -> HeadingParentChoice? {
        guard node.isEditable, let page = node.startPage else { return nil }
        let choices = parentChoices(outline: outline, pageIndex: page, excluding: node.anchor)
        guard let index = choices.firstIndex(where: { $0.anchor == node.parentAnchor }) else { return nil }
        let target = up ? index - 1 : index + 1
        return choices.indices.contains(target) ? choices[target] : nil
    }

    // MARK: Titles

    nonisolated static let maxTitleLength = 120

    /// A heading title from selected text: hyphenation at line ends joined, whitespace (line
    /// breaks included) collapsed to single spaces, trimmed, and capped at `maxTitleLength`
    /// characters on a word boundary.
    nonisolated static func title(fromSelection text: String) -> String {
        var joined = text.replacingOccurrences(of: "(\\w)-\\s*\\n\\s*(\\w)", with: "$1$2", options: .regularExpression)
        joined = joined.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        joined = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count > maxTitleLength else { return joined }
        let prefix = String(joined.prefix(maxTitleLength))
        if let space = prefix.lastIndex(of: " "),
           prefix.distance(from: prefix.startIndex, to: space) > maxTitleLength / 2 {
            return String(prefix[..<space]).trimmingCharacters(in: .whitespaces)
        }
        return prefix
    }

    // MARK: Mutations

    /// Adds a heading at a zero-based page. Returns the new heading's anchor.
    @discardableResult
    static func add(title: String, pageIndex: Int, parent: HeadingParentChoice,
                    session: ReaderSession) throws -> HeadingAnchor {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditError.emptyTitle }
        guard PageNumbering.isValid(pageIndex, pageCount: session.pageCount) else { throw EditError.invalidPage }
        let heading = UserHeading(bookID: session.book.id, title: trimmed, pageIndex: pageIndex, parent: parent.anchor)
        try session.perform { try $0.headings.save(heading) }
        return heading.anchor
    }

    /// Renames a user heading (its anchor, and so its note, are unchanged).
    static func rename(_ anchor: HeadingAnchor, to title: String, session: ReaderSession) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditError.emptyTitle }
        guard let id = anchor.userHeadingID, var heading = try session.store.headings.userHeading(id: id) else {
            throw EditError.notAUserHeading
        }
        guard heading.title != trimmed else { return }
        heading.title = trimmed
        try session.perform { try $0.headings.save(heading) }
    }

    /// Changes a user heading's title, page and placement at once (the edit sheet; also move,
    /// promote and demote). The anchor, and so its note, are unchanged; its own sub-headings stay
    /// under it. `parent` must be one of `parentChoices(…, excluding: anchor)` for the new page
    /// (anything else, such as the heading itself or one of its descendants, is refused).
    static func update(_ anchor: HeadingAnchor, title: String, pageIndex: Int, parent: HeadingParentChoice,
                       session: ReaderSession) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditError.emptyTitle }
        guard PageNumbering.isValid(pageIndex, pageCount: session.pageCount) else { throw EditError.invalidPage }
        guard let id = anchor.userHeadingID, var heading = try session.store.headings.userHeading(id: id) else {
            throw EditError.notAUserHeading
        }
        let allowed = parentChoices(outline: session.outline, pageIndex: pageIndex, excluding: anchor)
        guard allowed.contains(where: { $0.anchor == parent.anchor }) else { throw EditError.invalidPlacement }
        guard heading.title != trimmed || heading.pageIndex != pageIndex || heading.parent != parent.anchor else { return }
        heading.title = trimmed
        heading.pageIndex = pageIndex
        heading.parent = parent.anchor
        try session.perform { try $0.headings.save(heading) }
    }

    /// Promotes (`up`) or demotes a user heading by one level (see `neighbourPlacement`).
    static func move(_ node: OutlineNode, up: Bool, session: ReaderSession) throws {
        guard let placement = neighbourPlacement(node, up: up, outline: session.outline), let page = node.startPage else {
            throw EditError.invalidPlacement
        }
        try update(node.anchor, title: node.title, pageIndex: page, parent: placement, session: session)
    }

    /// What `delete` will do.
    static func deletionSummary(_ anchor: HeadingAnchor, session: ReaderSession) throws -> UserHeadingDeletionSummary {
        guard let id = anchor.userHeadingID, let heading = try session.store.headings.userHeading(id: id) else {
            throw EditError.notAUserHeading
        }
        let children = try session.store.headings.userHeadings(bookID: session.book.id).filter { $0.parent == anchor }
        let note = try session.store.notes.note(bookID: session.book.id, target: .heading(anchor))
        return UserHeadingDeletionSummary(title: heading.title, childCount: children.count, hasNote: note != nil)
    }

    /// Deletes a user heading. Its sub-headings are first re-parented to its own parent (so they
    /// move up one level instead of jumping to the top level), as the core recommends. Its
    /// section note is left stored (an unfiled note in the Notebook).
    static func delete(_ anchor: HeadingAnchor, session: ReaderSession) throws {
        guard let id = anchor.userHeadingID, let heading = try session.store.headings.userHeading(id: id) else {
            throw EditError.notAUserHeading
        }
        let children = try session.store.headings.userHeadings(bookID: session.book.id).filter { $0.parent == anchor }
        try session.perform { store in
            for var child in children {
                child.parent = heading.parent
                try store.headings.save(child)
            }
            try store.headings.deleteUserHeading(id: id)
        }
    }
}
