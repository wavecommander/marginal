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
    /// Registers the window's "Add as Heading" text-selection menu item. Idempotent; called from
    /// the sidebar and from `BookmarkActions` (which the toolbar and menu bar read), because the
    /// shell's `ReaderFeatureWiring` (not this package's file) has no sidebar line yet. The exact
    /// shell change that makes this unconditional: in `ReaderFeatureWiring.install(on:)` add
    /// `SidebarHeadingActions.install(on: session)`.
    static func install(on session: ReaderSession) {
        let provider = session.featureState { HeadingSelectionMenuProvider(session: session) }
        provider.registerIfNeeded()
    }
}

/// "Add as Heading" in the PDF text-selection edit menu: the selection's text (cleaned up by
/// `UserHeadingEditor.title(fromSelection:)`) becomes the suggested title and its first page the
/// heading's page. Coexists with other providers (highlights add their own items).
@MainActor
final class HeadingSelectionMenuProvider: ReaderSelectionMenuProviding {
    private weak var session: ReaderSession?
    private var registered = false

    init(session: ReaderSession) {
        self.session = session
    }

    func registerIfNeeded() {
        guard !registered, let session else { return }
        registered = true
        session.pdf.addSelectionMenuProvider(self)
    }

    func selectionMenuElements(for selection: ReaderTextSelection) -> [UIMenuElement] {
        let title = UserHeadingEditor.title(fromSelection: selection.string)
        guard let page = selection.parts.first?.pageIndex, !title.isEmpty else { return [] }
        let action = UIAction(title: "Add as Heading", image: UIImage(systemName: "text.badge.plus")) { [weak self] _ in
            guard let session = self?.session else { return }
            session.pdf.clearSelection()
            session.requestAddHeading(atPage: page, suggestedTitle: title)
        }
        action.accessibilityIdentifier = "sidebar.selection.addAsHeading"
        return [action]
    }
}
