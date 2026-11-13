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
        if session.configuration.markupProbeSurface {
            session.retainFeature(MarkupProbeSurface(session: session))   // UI tests only
        }
    }
}
