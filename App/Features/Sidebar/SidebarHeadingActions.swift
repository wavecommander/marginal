import ReaderCore
import UIKit

/// How "Add Heading at This Page" reaches the sidebar. There is one path: every entry point
/// (the reader's More menu and the Book menu ⌥⌘H in the shell, the notes panel, and this
/// package's text-selection item) calls `session.requestAddHeading(atPage:suggestedTitle:)`,
/// which shows Contents and sets `session.pendingAddHeadingRequest`; `ContentsSidebarModel`
/// observes it, takes it once with `takeAddHeadingRequest()`, and opens the add-heading sheet
/// (switching the sidebar to the Contents tab).
@MainActor
enum SidebarHeadingActions {
    /// "Add as Heading" in the PDF text-selection edit menu (the PDF bridge adds it after the
    /// highlight colours): the selection's text (cleaned up by
    /// `UserHeadingEditor.title(fromSelection:)`) becomes the suggested title and its first page
    /// the heading's page. Nothing for a selection with no usable title.
    static func selectionMenuElements(for selection: ReaderTextSelection, in session: ReaderSession) -> [UIMenuElement] {
        let title = UserHeadingEditor.title(fromSelection: selection.string)
        guard let page = selection.parts.first?.pageIndex, !title.isEmpty else { return [] }
        let action = UIAction(title: "Add as Heading", image: UIImage(systemName: "text.badge.plus")) { [weak session] _ in
            guard let session else { return }
            session.pdf.clearSelection()
            session.requestAddHeading(atPage: page, suggestedTitle: title)
        }
        action.accessibilityIdentifier = "sidebar.selection.addAsHeading"
        return [action]
    }
}
