import Foundation
import ReaderCore

/// Where a new heading goes: at the top level or inside one of the headings that contain its page.
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

    /// The new heading's level under this parent.
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
    /// whose heading no longer resolves under "Unfiled notes" (the core's `orphanNotes`). Page
    /// notes, highlights, ink and bookmarks are attached to pages and are not touched; they are
    /// now filed under the enclosing heading.
    var message: String {
        var parts: [String] = []
        if childCount == 1 {
            parts.append("Its subheading moves up one level.")
        } else if childCount > 1 {
            parts.append("Its \(childCount) subheadings move up one level.")
        }
        if hasNote {
            parts.append("Its section note is kept and appears under “Unfiled notes” in the Notebook.")
        }
        parts.append("Page notes, highlights and ink on its pages are not affected.")
        return parts.joined(separator: " ")
    }
}

/// Adding, renaming and deleting the reader's own headings, always through `session.perform`
/// (so other windows hear about it and this window's outline rebuilds through the session).
/// PDF headings are read-only: every method refuses them.
@MainActor
enum UserHeadingEditor {
    enum EditError: Error, Equatable {
        case emptyTitle
        case invalidPage
        case notAUserHeading
    }

    // MARK: Parent choices

    /// The parent choices for "Add heading at page N": "Top level" then the headings of
    /// `outline.headingPath(forPage:)`, shallowest first (the core's recommendation).
    static func parentChoices(outline: Outline, pageIndex: Int) -> [HeadingParentChoice] {
        [.topLevel] + outline.headingPath(forPage: pageIndex).map {
            .heading(anchor: $0.anchor, title: $0.title, level: $0.level)
        }
    }

    /// The default choice: a sibling of the page's current (deepest) section, i.e. the deepest
    /// heading's parent, so a new heading sits at the same level as the section the reader is in.
    /// Top level when the page is in no section (no outline yet, or front matter) or the
    /// deepest section is itself top level. The reader can pick any other choice.
    static func defaultParent(outline: Outline, pageIndex: Int) -> HeadingParentChoice {
        let path = outline.headingPath(forPage: pageIndex)
        guard path.count >= 2 else { return .topLevel }
        let parent = path[path.count - 2]
        return .heading(anchor: parent.anchor, title: parent.title, level: parent.level)
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

    /// What `delete` will do.
    static func deletionSummary(_ anchor: HeadingAnchor, session: ReaderSession) throws -> UserHeadingDeletionSummary {
        guard let id = anchor.userHeadingID, let heading = try session.store.headings.userHeading(id: id) else {
            throw EditError.notAUserHeading
        }
        let children = try session.store.headings.userHeadings(bookID: session.book.id).filter { $0.parent == anchor }
        let note = try session.store.notes.note(bookID: session.book.id, target: .heading(anchor))
        return UserHeadingDeletionSummary(title: heading.title, childCount: children.count, hasNote: note != nil)
    }

    /// Deletes a user heading. Its user-heading children are first re-parented to its own parent
    /// (so they move up one level instead of jumping to the top level), as the core recommends.
    /// Its section note is left stored (an "Unfiled note" in the Notebook).
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
