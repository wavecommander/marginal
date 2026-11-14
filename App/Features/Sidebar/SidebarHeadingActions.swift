import ReaderCore
import UIKit

/// Entry points for "Add Heading at This Page" from outside the sidebar (the reader's More menu,
/// the menu bar command, the notes panel, the text-selection menu). Each opens the sidebar's one
/// add-heading sheet for the window's own session.
///
/// **Wiring for the shell:** the session's pending add-heading request
/// (`session.requestAddHeading(atPage:suggestedTitle:)`) was not on `build-v1` when this package
/// was built, so the More menu / menu bar / notes panel should call
/// `SidebarHeadingActions.presentAddHeading(session:page:title:)` (one line each). Once the
/// session gains a pending-request value, observe it in `ContentsSidebar` instead.
@MainActor
enum SidebarHeadingActions {
    /// Opens the add-heading sheet for a zero-based page (default: the current page) with an
    /// optional suggested title. Shows Contents first if it is hidden (the sheet is presented
    /// from the sidebar); never moves the PDF.
    static func presentAddHeading(session: ReaderSession, page: Int? = nil, title: String = "") {
        install(on: session)
        let model = ContentsSidebarModel.shared(for: session)
        model.presentAddHeading(atPage: page ?? session.currentPageIndex, title: title)
        if !session.isContentsShown { session.toggleContents() }
    }

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
            SidebarHeadingActions.presentAddHeading(session: session, page: page, title: title)
        }
        action.accessibilityIdentifier = "sidebar.selection.addAsHeading"
        return [action]
    }
}
