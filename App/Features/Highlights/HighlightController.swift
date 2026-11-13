import PDFKit
import UIKit

/// PLACEHOLDER owned by WP7 (highlights). Keep the type name, `init(session:)` and the three
/// conformances (drop one only if you also stop registering for it); replace the body.
///
/// Created once per reader window by `ReaderFeatureWiring` (which retains it for the session's
/// lifetime). Hold the session **weakly**. Registers itself with the PDF bridge for the
/// selection edit menu, page taps and visible-page changes; add highlight annotations with
/// `session.pdf.addAnnotation(_:toPageAt:)`, mutate through `session.perform { … }`, and react
/// to other windows with `session.observeBookChanges { … }` (`.highlightsChanged`).
@MainActor
final class HighlightController: ReaderSelectionMenuProviding, ReaderPageTapHandling, ReaderVisiblePagesObserving {
    private weak var session: ReaderSession?

    init(session: ReaderSession) {
        self.session = session
        session.pdf.addSelectionMenuProvider(self)
        session.pdf.addTapHandler(self)
        session.pdf.addVisiblePagesObserver(self)
    }

    func selectionMenuElements(for selection: ReaderTextSelection) -> [UIMenuElement] {
        []  // WP7: the four colour actions.
    }

    func handleTap(_ tap: ReaderPageTap) -> Bool {
        false  // WP7: hit-test stored highlights at tap.pointInPage; offer recolour/delete.
    }

    func visiblePagesDidChange(_ pageIndices: [Int]) {}
}
