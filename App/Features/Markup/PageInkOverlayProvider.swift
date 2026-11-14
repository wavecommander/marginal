import PDFKit
import ReaderCore
import UIKit

/// Page ink (WP6): one `PKCanvasView` per displayed PDF page, through the PDF bridge's overlay
/// hook. Created once per reader window by `ReaderFeatureWiring`; holds the session weakly.
///
/// - PDFKit asks for an overlay when a page comes near the screen: the provider makes a
///   `PageInkOverlayView` and a `PageInkSurface` (canvas + load), registers the surface with the
///   session's markup controller when PDFKit shows the overlay, and finishes it (save now,
///   unregister, detach the canvas) when PDFKit ends the overlay. The overlay owns the surface,
///   and this provider keeps only weak references, so nothing per page outlives PDFKit's overlay.
/// - Ink space, zoom and gestures: see `PageInkGeometry` and `PageInkSurface`.
/// - Another window's write of a displayed page (`pageInkChanged` from another origin) is
///   handed to that page's surface, which reconciles (see `PageInkMerge`).
@MainActor
final class PageInkOverlayProvider: ReaderPageOverlayProviding {
    private weak var session: ReaderSession?
    private let context: PageInkContext
    private var surfaces: [Int: WeakSurface] = [:]
    private var observation: StoreChangeObservation?

    /// Delay of the debounced save after the last change on a page.
    var saveDelay: Duration = .seconds(1)

    init(session: ReaderSession) {
        self.session = session
        context = PageInkContext(store: session.store, bookID: session.book.id, origin: session.origin)
        session.pdf.pageOverlayProvider = self
        observation = session.observeBookChanges { [weak self] event in
            self?.handle(event)
        }
    }

    /// The surfaces of pages PDFKit currently displays, by page (tests and diagnostics).
    var liveSurfaces: [Int: PageInkSurface] {
        surfaces.compactMapValues(\.value).filter { !$0.value.isFinished }
    }

    // MARK: ReaderPageOverlayProviding

    func makeOverlayView(for page: PDFPage, pageIndex: Int) -> UIView? {
        guard let session else { return nil }
        if let existing = surfaces[pageIndex]?.value {
            existing.finish()
        }
        let geometry = PageInkGeometry(page: page)
        let displayBox = page.bounds(for: session.pdf.view.displayBox)
        let overlay = PageInkOverlayView(pageIndex: pageIndex, geometry: geometry, displayBox: displayBox)
        installAccessibilityView(in: session.pdf.view)
        overlay.onInkChange = { [weak accessibilityView] in accessibilityView?.inkDidChange() }
        let surface = PageInkSurface(pageIndex: pageIndex, geometry: geometry, overlay: overlay, context: context,
                                     markup: session.markup, saveDelay: saveDelay)
        surfaces[pageIndex] = WeakSurface(surface)
        surface.startLoading()
        Self.debugLog("make overlay page \(pageIndex); live canvases \(PageInkCanvasView.liveCount)")
        return overlay
    }

    func overlayWillAppear(_ overlay: UIView, for page: PDFPage, pageIndex: Int) {
        (overlay as? PageInkOverlayView)?.surface?.register()
    }

    func overlayDidDisappear(_ overlay: UIView, for page: PDFPage, pageIndex: Int) {
        guard let surface = (overlay as? PageInkOverlayView)?.surface else { return }
        surface.finish()
        if surfaces[pageIndex]?.value === surface { surfaces[pageIndex] = nil }
        surfaces = surfaces.filter { $0.value.value != nil }
    }

    // MARK: Accessibility

    /// Exposes the displayed pages' handwriting to accessibility (see `PageInkAccessibilityView`).
    private let accessibilityView = PageInkAccessibilityView(frame: .zero)

    private func installAccessibilityView(in pdfView: UIView) {
        guard accessibilityView.superview !== pdfView else { return }
        accessibilityView.surfaces = { [weak self] in self?.liveSurfaces ?? [:] }
        accessibilityView.frame = pdfView.bounds
        pdfView.addSubview(accessibilityView)
    }

    // MARK: Changes

    private func handle(_ event: StoreChangeEvent) {
        guard case .pageInkChanged(_, let pageIndex) = event.change,
              let surface = surfaces[pageIndex]?.value, !surface.isFinished else { return }
        surface.remoteDidChange()
    }

    // MARK: Debug

    nonisolated static let isDebugLogging = ProcessInfo.processInfo.environment["PAGE_INK_DEBUG"] != nil
        || ProcessInfo.processInfo.arguments.contains("-pageInkDebug")

    static func debugLog(_ message: @autoclosure () -> String) {
        guard isDebugLogging else { return }
        let text = message()
        pageInkLog.debug("\(text, privacy: .public)")
        NSLog("PageInk: %@", text)
    }

    private final class WeakSurface {
        weak var value: PageInkSurface?
        init(_ value: PageInkSurface) { self.value = value }
    }
}
