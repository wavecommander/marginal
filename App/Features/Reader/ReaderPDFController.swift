import Foundation
import PDFKit
import SwiftUI
import UIKit

/// The PDFKit bridge of one reader window (`ReaderSession.pdf`). Owns the window's `PDFView`
/// (created once per session and re-hosted if SwiftUI rebuilds the layout, so the scroll
/// position survives switching between wide and narrow layouts), tracks the current and visible
/// pages, keeps the current page on resize and rotation, and exposes the plug points in
/// `ReaderExtensionPoints.swift`.
///
/// Performance rules it keeps: the document is opened lazily by PDFKit (no page walk, no text
/// extraction here); only visible pages are rendered; overlays exist only for displayed pages.
@MainActor
final class ReaderPDFController: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    private weak var session: ReaderSession?

    /// The on-screen PDF view. Use for presenting menus or converting coordinates; navigate and
    /// zoom through the session so its state stays in step.
    private(set) lazy var view: ReaderPDFView = makeView()
    private var isViewLoaded = false

    /// The document shown, once attached.
    var document: PDFDocument? { isViewLoaded ? view.document : nil }

    /// WP6's overlay provider (weak; the session retains feature controllers). Set it in your
    /// controller's `init(session:)`, before the document is opened.
    weak var pageOverlayProvider: (any ReaderPageOverlayProviding)? {
        didSet { reinstallOverlayProviderIfNeeded() }
    }

    private var selectionMenuProviders: [WeakBox<any ReaderSelectionMenuProviding>] = []
    private var tapHandlers: [WeakBox<any ReaderPageTapHandling>] = []
    private var visiblePagesObservers: [WeakBox<any ReaderVisiblePagesObserving>] = []

    /// Page to show once the view has a size and a document.
    private var pendingPageIndex: Int?
    /// While true, PDFKit's page-changed reports are ignored (initial positioning, resizing).
    private var isTrackingSuspended = true
    private var resizeAnchor: (pageIndex: Int, destination: PDFDestination?)?
    private var resizeGeneration = 0
    private var hasPositionedInitially = false
    private let tapDelegate = SimultaneousGestureDelegate()

    init(session: ReaderSession) {
        self.session = session
        super.init()
    }

    // MARK: Plug-point registration

    func addSelectionMenuProvider(_ provider: any ReaderSelectionMenuProviding) {
        selectionMenuProviders.removeAll { $0.value == nil }
        selectionMenuProviders.append(WeakBox(provider))
    }

    func addTapHandler(_ handler: any ReaderPageTapHandling) {
        tapHandlers.removeAll { $0.value == nil }
        tapHandlers.append(WeakBox(handler))
    }

    func addVisiblePagesObserver(_ observer: any ReaderVisiblePagesObserving) {
        visiblePagesObservers.removeAll { $0.value == nil }
        visiblePagesObservers.append(WeakBox(observer))
    }

    // MARK: Document

    /// Shows `document`, positioned at `initialPageIndex` as soon as the view has a size.
    func attach(_ document: PDFDocument, initialPageIndex: Int) {
        pendingPageIndex = initialPageIndex
        isTrackingSuspended = true
        view.document = document
        applyPendingPageIfPossible()
    }

    /// The page object for a zero-based index on the on-screen document.
    func page(at pageIndex: Int) -> PDFPage? { document?.page(at: pageIndex) }

    /// The zero-based index of a page of the on-screen document, or `nil`.
    func pageIndex(of page: PDFPage) -> Int? {
        guard let document else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    // MARK: Navigation (call through ReaderSession)

    /// **Not for features**: moves the view without recording section history. Use `session.jump…`.
    func moveWithoutRecordingHistory(toPage pageIndex: Int) {
        guard hasPositionedInitially, let page = page(at: pageIndex), view.bounds.width > 0 else {
            pendingPageIndex = pageIndex
            applyPendingPageIfPossible()
            return
        }
        view.showTop(of: page)
    }

    // MARK: Zoom

    func zoomIn() {
        freezeScale()
        view.zoomIn(nil)
        reportNavigationState()
    }

    func zoomOut() {
        freezeScale()
        view.zoomOut(nil)
        reportNavigationState()
    }

    func zoomToActualSize() {
        view.autoScales = false
        view.scaleFactor = 1
        reportNavigationState()
    }

    func zoomToFitWidth() {
        view.scaleFactor = view.scaleFactorForSizeToFit
        view.autoScales = true
        reportNavigationState()
    }

    private func freezeScale() {
        guard view.autoScales else { return }
        let scale = view.scaleFactor
        view.autoScales = false
        view.scaleFactor = scale
    }

    // MARK: Selection (WP7)

    /// The current text selection split per page and line, or `nil` when nothing is selected.
    var currentSelection: ReaderTextSelection? {
        guard isViewLoaded, let selection = view.currentSelection, let document = view.document,
              let string = selection.string, !string.isEmpty else { return nil }
        var parts: [Int: ReaderTextSelection.PagePart] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let index = document.index(for: page)
                guard index != NSNotFound else { continue }
                let rect = line.bounds(for: page)
                guard !rect.isEmpty else { continue }
                var part = parts[index] ?? ReaderTextSelection.PagePart(pageIndex: index, lineRects: [], string: "")
                part.lineRects.append(rect)
                let text = line.string ?? ""
                part.string = part.string.isEmpty ? text : part.string + " " + text
                parts[index] = part
            }
        }
        return ReaderTextSelection(parts: parts.keys.sorted().compactMap { parts[$0] }, string: string,
                                   selection: selection)
    }

    func clearSelection() {
        guard isViewLoaded else { return }
        view.clearSelection()
    }

    // MARK: Annotations (WP7). The file on disk is never written; these live in memory only.

    /// Adds an annotation to a page of the on-screen document (shown immediately).
    func addAnnotation(_ annotation: PDFAnnotation, toPageAt pageIndex: Int) {
        page(at: pageIndex)?.addAnnotation(annotation)
    }

    func removeAnnotation(_ annotation: PDFAnnotation) {
        annotation.page?.removeAnnotation(annotation)
    }

    /// Annotations on a page of the on-screen document (including the PDF's own).
    func annotations(onPageAt pageIndex: Int) -> [PDFAnnotation] {
        page(at: pageIndex)?.annotations ?? []
    }

    // MARK: Search marking (WP10)

    /// **Not for features** (use `session.jump(toPage:revealing:mark:)`, which records history).
    /// Scrolls `rects` (page space) on `pageIndex` into view and, with `mark`, marks the text
    /// under them until `clearMarks()` (or the next `reveal`). Build the rects on your own
    /// background `PDFDocument`; this re-creates the selection on the on-screen one.
    func revealWithoutRecordingHistory(pageIndex: Int, rects: [CGRect], mark: Bool = true) {
        guard let page = page(at: pageIndex) else { return }
        let union = rects.reduce(CGRect.null) { $0.union($1) }
        if !union.isNull {
            view.go(to: union.insetBy(dx: -8, dy: -40), on: page)
        } else {
            view.showTop(of: page)
        }
        session?.pdfReportedCurrentPage(pageIndex)
        guard mark else { return }
        let selections = rects.compactMap { page.selection(for: $0) }
        guard let first = selections.first else { return }
        for other in selections.dropFirst() { first.add(other) }
        first.color = UIColor.systemYellow.withAlphaComponent(0.6)
        view.highlightedSelections = [first]
    }

    /// Removes search marks.
    func clearMarks() {
        guard isViewLoaded else { return }
        view.highlightedSelections = nil
    }

    // MARK: Mode

    func modeDidChange(to mode: ReaderSession.Mode) {
        guard isViewLoaded else { return }
        view.isInMarkupMode = mode == .markup
    }

    // MARK: PDFPageOverlayViewProvider (adapter to ReaderPageOverlayProviding)

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let provider = pageOverlayProvider, let index = pageIndex(of: page) else { return nil }
        return provider.makeOverlayView(for: page, pageIndex: index)
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard let provider = pageOverlayProvider, let index = pageIndex(of: page) else { return }
        provider.overlayWillAppear(overlayView, for: page, pageIndex: index)
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let provider = pageOverlayProvider, let index = pageIndex(of: page) else { return }
        provider.overlayDidDisappear(overlayView, for: page, pageIndex: index)
    }

    // MARK: View-facing (ReaderPDFView)

    func selectionMenuElements() -> [UIMenuElement] {
        guard let selection = currentSelection else { return [] }
        var elements: [UIMenuElement] = []
        for provider in selectionMenuProviders.compactMap(\.value) {
            elements.append(contentsOf: provider.selectionMenuElements(for: selection))
        }
        if session?.configuration.selectionMenuProbe == true {
            elements.append(UIAction(title: "Probe") { _ in })
        }
        return elements
    }

    func viewWillLayout(newSize: CGSize, oldSize: CGSize) {
        guard hasPositionedInitially, oldSize != .zero, newSize != oldSize, let session else { return }
        if resizeAnchor == nil {
            let destination = view.currentDestination
            let destinationPage = destination?.page.flatMap { pageIndex(of: $0) }
            resizeAnchor = (session.currentPageIndex, destinationPage == session.currentPageIndex ? destination : nil)
        }
        isTrackingSuspended = true
    }

    func viewDidLayout() {
        if !hasPositionedInitially {
            applyPendingPageIfPossible()
            return
        }
        guard let anchor = resizeAnchor else { return }
        resizeGeneration += 1
        let generation = resizeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.resizeGeneration else { return }
            self.resizeAnchor = nil
            if let destination = anchor.destination {
                self.view.go(to: destination)
            } else if let page = self.page(at: anchor.pageIndex) {
                self.view.showTop(of: page)
            }
            self.isTrackingSuspended = false
            self.session?.pdfReportedCurrentPage(anchor.pageIndex)
        }
    }

    // MARK: Private

    private func makeView() -> ReaderPDFView {
        isViewLoaded = true
        let view = ReaderPDFView(frame: .zero)
        view.controller = self
        // Must be set before a document is assigned for PDFKit to ask for overlays.
        view.pageOverlayViewProvider = self
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        view.autoScales = true
        view.maxScaleFactor = 8
        view.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.12, alpha: 1) : UIColor(red: 0.902, green: 0.902, blue: 0.918, alpha: 1)
        }
        view.pageShadowsEnabled = true
        view.accessibilityIdentifier = AccessibilityID.Reader.pdfView
        view.isInMarkupMode = session?.isMarkupMode ?? false

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        center.addObserver(self, selector: #selector(visiblePagesChanged(_:)), name: .PDFViewVisiblePagesChanged, object: view)
        center.addObserver(self, selector: #selector(navigationChanged(_:)), name: .PDFViewScaleChanged, object: view)
        center.addObserver(self, selector: #selector(annotationWillHit(_:)), name: .PDFViewAnnotationWillHit, object: view)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = tapDelegate
        view.addGestureRecognizer(tap)
        return view
    }

    private func reinstallOverlayProviderIfNeeded() {
        // PDFKit consults the provider only for pages displayed after a document is assigned.
        guard isViewLoaded, let document = view.document, let session else { return }
        let page = session.currentPageIndex
        view.document = nil
        view.document = document
        hasPositionedInitially = false
        pendingPageIndex = page
        isTrackingSuspended = true
        applyPendingPageIfPossible()
    }

    private func applyPendingPageIfPossible() {
        guard isViewLoaded, view.document != nil, view.bounds.width > 0, view.bounds.height > 0,
              pendingPageIndex != nil else { return }
        // Let PDFKit lay out the document view first, then position.
        DispatchQueue.main.async { [weak self] in
            guard let self, let index = self.pendingPageIndex, let page = self.page(at: index) else { return }
            self.pendingPageIndex = nil
            self.view.showTop(of: page)
            self.hasPositionedInitially = true
            self.isTrackingSuspended = false
            self.session?.pdfReportedCurrentPage(index)
            self.reportVisiblePages()
            self.reportNavigationState()
        }
    }

    @objc private func pageChanged(_ notification: Notification) {
        guard !isTrackingSuspended, let page = view.currentPage, let index = pageIndex(of: page) else { return }
        session?.pdfReportedCurrentPage(index)
    }

    @objc private func visiblePagesChanged(_ notification: Notification) {
        reportVisiblePages()
    }

    @objc private func navigationChanged(_ notification: Notification) {
        reportNavigationState()
    }

    /// A link inside the PDF is about to be followed: record it as a jump (PDFKit moves).
    @objc private func annotationWillHit(_ notification: Notification) {
        guard let annotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation else { return }
        let page = annotation.destination?.page ?? (annotation.action as? PDFActionGoTo)?.destination.page
        guard let page, let index = pageIndex(of: page) else { return }
        session?.pdfWillFollowLink(toPage: index)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let handlers = tapHandlers.compactMap(\.value)
        guard !handlers.isEmpty else { return }
        let point = recognizer.location(in: view)
        guard let page = view.page(for: point, nearest: false), let index = pageIndex(of: page) else { return }
        let tap = ReaderPageTap(pageIndex: index, page: page, pointInPage: view.convert(point, to: page),
                                pointInView: point, view: view)
        for handler in handlers where handler.handleTap(tap) { break }
    }

    private func reportVisiblePages() {
        guard view.document != nil else { return }
        let pages = Array(Set(view.visiblePages.compactMap { pageIndex(of: $0) })).sorted()
        session?.pdfReportedVisiblePages(pages)
        for observer in visiblePagesObservers.compactMap(\.value) {
            observer.visiblePagesDidChange(pages)
        }
    }

    private func reportNavigationState() {
        session?.pdfReportedScale(isFitWidth: view.autoScales)
    }
}

/// The reader's `PDFView`: adds the selection edit-menu hook, resize handling and a
/// simultaneous tap recogniser. Configure it only through `ReaderPDFController`.
final class ReaderPDFView: PDFView {
    weak var controller: ReaderPDFController?
    private var lastLayoutSize: CGSize = .zero

    /// Scrolls so the top edge of `page` is at the top of the view. (`go(to: PDFPage)` leaves
    /// the page break above it visible, and PDFKit then reports the previous page as current.)
    func showTop(of page: PDFPage) {
        let bounds = page.bounds(for: displayBox)
        go(to: PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY)))
    }

    override func layoutSubviews() {
        let size = bounds.size
        let old = lastLayoutSize
        if size != old { controller?.viewWillLayout(newSize: size, oldSize: old) }
        super.layoutSubviews()
        if size != old {
            lastLayoutSize = size
            controller?.viewDidLayout()
        }
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context, let elements = controller?.selectionMenuElements(),
              !elements.isEmpty else { return }
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: elements), atStartOfMenu: .root)
    }
}

/// Lets the bridge's tap recogniser run alongside PDFKit's own gestures.
final class SimultaneousGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Hosts the session's `PDFView` and the markup responder in SwiftUI. Several hosts may exist
/// briefly while SwiftUI swaps layouts; the one in a window adopts the view.
struct ReaderPDFViewRepresentable: UIViewRepresentable {
    let session: ReaderSession

    func makeUIView(context: Context) -> ReaderPDFHostView {
        ReaderPDFHostView(controller: session.pdf, responderView: session.markup.responderView)
    }

    func updateUIView(_ uiView: ReaderPDFHostView, context: Context) {}
}

final class ReaderPDFHostView: UIView {
    private let controller: ReaderPDFController
    private let responderView: UIView

    init(controller: ReaderPDFController, responderView: UIView) {
        self.controller = controller
        self.responderView = responderView
        super.init(frame: .zero)
        adopt()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { adopt() }
    }

    private func adopt() {
        let pdfView = controller.view
        if pdfView.superview !== self {
            pdfView.frame = bounds
            pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(pdfView)
        }
        if responderView.superview !== self {
            responderView.frame = .zero
            addSubview(responderView)
        }
    }
}

/// A weak reference to a class-constrained existential.
final class WeakBox<T> {
    private weak var object: AnyObject?
    init(_ value: T) { object = value as AnyObject }
    var value: T? { object as? T }
}
