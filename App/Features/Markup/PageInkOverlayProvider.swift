import PDFKit
import UIKit

/// PLACEHOLDER owned by WP6 (page ink). Keep the type name, `init(session:)` and the
/// `ReaderPageOverlayProviding` conformance; replace the body.
///
/// Created once per reader window by `ReaderFeatureWiring` (which retains it for the session's
/// lifetime) before the document opens. Hold the session **weakly** (it owns you). See
/// `ReaderPageOverlayProviding` and `MarkupSurface` for the contracts.
@MainActor
final class PageInkOverlayProvider: ReaderPageOverlayProviding {
    private weak var session: ReaderSession?

    init(session: ReaderSession) {
        self.session = session
        session.pdf.pageOverlayProvider = self
    }

    func makeOverlayView(for page: PDFPage, pageIndex: Int) -> UIView? {
        nil  // WP6: return a view hosting this page's PKCanvasView.
    }

    func overlayWillAppear(_ overlay: UIView, for page: PDFPage, pageIndex: Int) {}

    func overlayDidDisappear(_ overlay: UIView, for page: PDFPage, pageIndex: Int) {}
}
