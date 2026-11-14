/// Creates the per-window feature controllers that plug into the PDF bridge. Each later package
/// replaces the body of its own placeholder class (same name, same `init(session:)`), so this
/// file does not change. Controllers register their plug points in their own `init`; they are
/// created inside `ReaderSession.init`, before the document opens, so the page overlay provider
/// is in place before PDFKit first asks for overlays.
@MainActor
enum ReaderFeatureWiring {
    static func install(on session: ReaderSession) {
        session.retainFeature(PageInkOverlayProvider(session: session))  // WP6
        session.retainFeature(HighlightController(session: session))     // WP7
        // WP8: with the window, not with the panel, so heading-anchor repair and section-pin
        // tracking run in a window that never shows the notes panel. Safe this early: its init
        // only reads the session's page and tab, subscribes to the store hub, makes (does not
        // load) the page note's model, and defers anything else until the outline has loaded.
        _ = NotesPanelController.forSession(session)
        // WP5: "Add as Heading" in the text-selection menu works before (or without) the sidebar
        // being shown. Safe this early: it only creates a small provider holding the session
        // weakly and appends it to the PDF bridge's selection-menu providers (as highlights do
        // above); the menu is built only when a selection exists. Idempotent with the sidebar's
        // own call.
        SidebarHeadingActions.install(on: session)
        if session.configuration.markupProbeSurface {
            session.retainFeature(MarkupProbeSurface(session: session))   // UI tests only
        }
    }
}
