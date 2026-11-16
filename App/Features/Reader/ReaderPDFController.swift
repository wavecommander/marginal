import Foundation
import PDFKit
import ReaderCore
import SwiftUI
import UIKit

/// The PDFKit bridge of one reader window (`ReaderSession.pdf`). Owns the window's `PDFView`
/// (created once per session and re-hosted if SwiftUI rebuilds the layout, so the scroll
/// position survives switching between wide and narrow layouts), tracks the current and visible
/// pages, keeps the current page on resize and rotation, and hands page overlays, the selection
/// menu, taps and visible pages to the session's features (`ReaderSession.pageInk`,
/// `highlights`, `searchModelIfCreated`; see `ReaderExtensionPoints.swift`).
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

    /// Which offset changes are reading and which are layout (design: "The reading position is
    /// stable"): the phase, the reading anchor and the rule are `ReadingPositionKeeper`'s; this
    /// class tells it what PDFKit and the reader do, and moves the view as it answers.
    private var position: ReadingPositionKeeper

    /// The view has shown its first page (or its page after the pages were laid out again).
    var hasPositionedInitially: Bool { position.isPositioned }
    /// The reader's place: the page point at the top-left of the view (`ReadingPositionKeeper.anchor`).
    var readingAnchor: ReadingAnchor? { position.anchor }

    /// The exact place and zoom to show with the keeper's pending page (first positioning only).
    private var pendingPosition: ReaderPosition?
    private let tapDelegate = SimultaneousGestureDelegate()
    private var offsetObservation: NSKeyValueObservation?

    /// Test hook (`-exposeViewportAnchor`): an accessibility element whose value is the current
    /// reading anchor. A button trait keeps XCUITest queries for it fast (they skip PDFKit's
    /// page text elements).
    private(set) lazy var anchorProbe: UIView? = {
        guard session?.configuration.exposesViewportAnchor == true else { return nil }
        let probe = UIView()
        probe.isAccessibilityElement = true
        probe.accessibilityTraits = .button
        probe.accessibilityLabel = "Viewport anchor"
        probe.accessibilityIdentifier = AccessibilityID.Reader.viewportAnchor
        return probe
    }()

    /// A document is attached and has not been positioned yet (the view has had no size).
    var isAwaitingFirstPosition: Bool { isViewLoaded && view.document != nil && !hasPositionedInitially }

    /// The PDF view's scale (1 before the view exists).
    var scale: CGFloat { isViewLoaded ? view.scaleFactor : 1 }

    /// The scroll view PDFKit scrolls the document in.
    var scrollView: UIScrollView? { isViewLoaded ? PDFKitWorkarounds.scrollView(of: view) : nil }

    /// The reading anchor of the current scroll position (page point at the top-left corner).
    func captureAnchor() -> ReadingAnchor? {
        guard let scrollView, view.document != nil else { return nil }
        let content = ViewportAnchorMath.topLeftContentPoint(contentOffset: scrollView.contentOffset,
                                                             insets: scrollView.adjustedContentInset)
        let inView = view.convert(content, from: scrollView)
        guard let page = view.page(for: inView, nearest: true), let index = pageIndex(of: page) else { return nil }
        return ReadingAnchor(pageIndex: index, point: view.convert(inView, to: page))
    }

    private func updateAnchorProbe() {
        guard let anchorProbe else { return }
        anchorProbe.accessibilityValue = captureAnchor()?.description(scale: view.scaleFactor) ?? "none"
    }

    private func observeScrollViewIfNeeded() {
        guard offsetObservation == nil, let scrollView else { return }
        offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scrollViewDidChangeOffset() }
        }
    }

    private func scrollViewDidChangeOffset() {
        switch position.offsetDidChange(scale: view.scaleFactor, isReaderGesturing: isReaderGesturing) {
        case .layout:
            return
        case .refit:
            scheduleRefitRestore()
            return
        case .positioning:
            session?.revealPagePill()
        case .reading:
            session?.revealPagePill()
            if let anchor = captureAnchor() {
                position.recordReading(anchor: anchor, scale: view.scaleFactor)
                session?.pdfReportedPlaceChange()
            }
        }
        updateAnchorProbe()
    }

    /// `clock` times the position keeper's two windows (tests inject their own).
    init(session: ReaderSession, clock: ReadingPositionClock = .system) {
        self.session = session
        self.position = ReadingPositionKeeper(clock: clock)
        super.init()
    }

    // MARK: Document

    /// Shows `document`, positioned at `initialPageIndex` as soon as the view has a size: at
    /// `startPosition`'s exact place and zoom when given (a resumed reader's, or the book's
    /// latest), else at the top of the page.
    func attach(_ document: PDFDocument, initialPageIndex: Int, position startPosition: ReaderPosition? = nil) {
        position.setPendingPage(initialPageIndex)
        pendingPosition = startPosition
        view.document = document
        view.applyPDFKitPolicies()
        observeScrollViewIfNeeded()
        applyPendingPageIfPossible()
    }

    /// Lets the document go for good (`ReaderSession.close()`): PDFKit's pages, tiles and the
    /// page overlays go with it, and the view leaves its host.
    func close() {
        guard isViewLoaded else { return }
        position.clearPendingPage()
        pendingPosition = nil
        offsetObservation = nil
        position.invalidatePosition()
        view.clearSelection()
        view.highlightedSelections = nil
        view.document = nil
        view.removeFromSuperview()
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
            position.setPendingPage(pageIndex)
            pendingPosition = nil
            applyPendingPageIfPossible()
            return
        }
        position.willNavigate(scale: view.scaleFactor)
        view.showTop(of: page)
    }

    /// **Not for features**: puts `anchor`'s page point back at the top-left corner of the view
    /// (section history's exact place) without recording section history.
    func moveWithoutRecordingHistory(to anchor: ReadingAnchor) {
        guard hasPositionedInitially, let page = page(at: anchor.pageIndex), view.bounds.width > 0 else {
            moveWithoutRecordingHistory(toPage: anchor.pageIndex)
            return
        }
        position.willNavigate(scale: view.scaleFactor)
        view.show(anchor.point, of: page)
    }

    // MARK: Zoom

    func zoomIn() {
        readerDidZoom()
        freezeScale()
        view.zoomIn(nil)
        reportNavigationState()
    }

    func zoomOut() {
        readerDidZoom()
        freezeScale()
        view.zoomOut(nil)
        reportNavigationState()
    }

    func zoomToActualSize() {
        readerDidZoom()
        view.autoScales = false
        view.scaleFactor = 1
        reportNavigationState()
    }

    func zoomToFitWidth() {
        readerDidZoom()
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

    // MARK: Scroll direction

    /// Re-lays the pages out in `direction`, fitted to the view, with `pageIndex` at the
    /// top-left (the reader stays on the page they were reading). Positioned like a newly
    /// attached document, so nothing PDFKit does while it re-lays out is taken as reading.
    func scrollDirectionDidChange(to direction: ReaderScrollDirection, keepingPage pageIndex: Int) {
        guard isViewLoaded, view.displayDirection != direction.pdfDisplayDirection else { return }
        view.clearSelection()
        position.invalidatePosition()
        view.displayDirection = direction.pdfDisplayDirection
        view.autoScales = true
        view.layoutDocumentView()
        position.setPendingPage(pageIndex)
        pendingPosition = nil
        applyPendingPageIfPossible()
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

    /// The PDF's Select All (design: "Select All selects the paragraph"): grows the selection
    /// to the whole paragraphs it touches on each of its pages, from each page's own layout
    /// (`ParagraphSelection`). Nothing happens without a selection. The scroll position is kept
    /// and nothing is recorded in section history.
    func selectParagraphs() {
        guard isViewLoaded, let selection = view.currentSelection, !selection.pages.isEmpty else { return }
        let start = CFAbsoluteTimeGetCurrent()
        guard let grown = ParagraphSelection.expanding(selection, displayBox: view.displayBox) else { return }
        let offset = scrollView?.contentOffset
        view.setCurrentSelection(grown, animate: false)
        if let offset, let scrollView, scrollView.contentOffset != offset {
            scrollView.setContentOffset(offset, animated: false)
        }
        lastSelectAllDuration = CFAbsoluteTimeGetCurrent() - start
        updateSelectionProbe()
    }

    /// How long the last Select All took (seconds), for the test hook.
    private(set) var lastSelectAllDuration: CFTimeInterval?

    /// Test hook (`-exposeSelection`): an accessibility element whose label is the current
    /// selection's text and whose value is "pages P; ms T" (the selection's page indices and the
    /// last Select All's time).
    private(set) lazy var selectionProbe: UIView? = {
        guard session?.configuration.exposesSelection == true else { return nil }
        let probe = UIView()
        probe.isAccessibilityElement = true
        probe.accessibilityTraits = .button
        probe.accessibilityIdentifier = AccessibilityID.Reader.selectionProbe
        probe.accessibilityLabel = "none"
        NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSelectionProbe() }
        }
        return probe
    }()

    /// DEBUG performance probe (`-perfProbe`, `ReaderPerfProbe`), `nil` otherwise.
    private(set) lazy var perfProbe: UIView? = {
        #if DEBUG
        return ReaderPerfProbe.isEnabled ? ReaderPerfProbe(controller: self) : nil
        #else
        return nil
        #endif
    }()

    /// Test hook (`-exposeMarkupState`): `ReaderStateProbe`'s elements, empty otherwise.
    private(set) lazy var markupStateProbes: [UIView] = {
        guard let session, session.configuration.exposesMarkupState else { return [] }
        return ReaderStateProbe.makeViews(session: session)
    }()

    private func updateSelectionProbe() {
        guard let selectionProbe else { return }
        let selection = view.currentSelection
        selectionProbe.accessibilityLabel = selection?.string ?? "none"
        let pages = selection?.pages.compactMap { pageIndex(of: $0) }.map(String.init).joined(separator: ",") ?? ""
        let ms = lastSelectAllDuration.map { String(format: "%.1f", $0 * 1000) } ?? "-"
        selectionProbe.accessibilityValue = "pages \(pages); ms \(ms)"
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
        position.willNavigate(scale: view.scaleFactor)
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

    // MARK: PDFPageOverlayViewProvider (page ink: `ReaderSession.pageInk`)

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let pageInk = session?.pageInk, let index = pageIndex(of: page) else { return nil }
        return pageInk.makeOverlayView(for: page, pageIndex: index)
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard let pageInk = session?.pageInk, let index = pageIndex(of: page) else { return }
        pageInk.overlayWillAppear(overlayView, for: page, pageIndex: index)
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let pageInk = session?.pageInk, let index = pageIndex(of: page) else { return }
        pageInk.overlayDidDisappear(overlayView, for: page, pageIndex: index)
    }

    // MARK: View-facing (ReaderPDFView)

    /// A link inside the PDF is about to be followed (`ReaderPDFView.perform(_:)`): record it as
    /// a jump to the page PDFKit is going to, whatever form the link takes. PDFKit then moves.
    /// Go-to links (a `/Dest` or a GoTo action, direct or through a named destination) arrive
    /// with their destination resolved; a named page action (`/S /Named`, e.g. NextPage) moves
    /// relative to PDFKit's current page (TSOFT-220). A destination PDFKit cannot resolve is
    /// not followed, so nothing is recorded.
    func willPerform(_ action: PDFAction) {
        position.willNavigate(scale: view.scaleFactor)
        let target: Int?
        switch action {
        case let goTo as PDFActionGoTo:
            target = goTo.destination.page.flatMap { pageIndex(of: $0) }
        case let named as PDFActionNamed:
            target = view.currentPage.flatMap { pageIndex(of: $0) }.flatMap { current in
                Self.namedActionTarget(named.name, currentPage: current, pageCount: document?.pageCount ?? 0)
            }
        default:
            target = nil
        }
        guard let target else { return }
        session?.pdfWillFollowLink(toPage: target)
    }

    /// The page a named page action goes to from `currentPage`, or `nil` when it does not
    /// change the page (already at the end, or not a page action: GoBack and GoForward are
    /// PDFKit's own visitation history, Find, Print and zooming are not navigation).
    nonisolated static func namedActionTarget(_ name: PDFActionNamedName, currentPage: Int, pageCount: Int) -> Int? {
        guard pageCount > 0, (0..<pageCount).contains(currentPage) else { return nil }
        let target: Int
        switch name {
        case .nextPage: target = currentPage + 1
        case .previousPage: target = currentPage - 1
        case .firstPage: target = 0
        case .lastPage: target = pageCount - 1
        default: return nil
        }
        return (0..<pageCount).contains(target) && target != currentPage ? target : nil
    }

    /// The actions the features add to the edit menu of a text selection, in this order: the
    /// highlight colours (WP7), then "Add as Heading" (WP5).
    func selectionMenuElements() -> [UIMenuElement] {
        guard let selection = currentSelection, let session else { return [] }
        var elements = session.highlights?.selectionMenuElements(for: selection) ?? []
        elements.append(contentsOf: SidebarHeadingActions.selectionMenuElements(for: selection, in: session))
        if session.configuration.selectionMenuProbe {
            elements.append(UIAction(title: "Probe") { _ in })
        }
        return elements
    }

    /// Called by `ReaderPDFView.layoutSubviews` *before* PDFKit lays out for a new size. The
    /// scroll offset and page frames are still the old ones, so if no anchor exists yet it is
    /// captured here from the place the reader is looking at.
    func sizeChangeWillLayout() {
        guard view.document != nil, position.isPositioned else { return }
        let placeOnScreen = position.anchor == nil ? captureAnchor() : nil
        position.beginSizeChange(scale: view.scaleFactor, placeOnScreen: placeOnScreen)
    }

    /// Called by `ReaderPDFView.layoutSubviews` *after* PDFKit has laid out for the new size,
    /// in the same layout pass (so the position holds through an animated width change instead
    /// of being fixed up afterwards). Lays out the document view now (the layout this pass
    /// would do anyway), then puts the anchor's page point back at the top-left corner.
    func sizeChangeDidLayout() {
        defer { updateAnchorProbe() }
        guard position.phase == .restoring else { return }
        placeReadingAnchor()
        position.endSizeChange(scale: view.scaleFactor, isFitWidth: view.autoScales)
    }

    // MARK: Fit-width refits (see `ReadingPositionKeeper.ScaleOwner`)

    /// The reader touched the page or chose a zoom command: the scale changes that follow are
    /// theirs, and the place they leave is reading.
    func readerDidZoom() {
        position.readerDidZoom()
    }

    /// The scroll view is being dragged or pinched, or is bouncing back from a pinch.
    private var isReaderGesturing: Bool {
        guard let scrollView else { return false }
        return scrollView.isZooming || scrollView.isZoomBouncing || scrollView.isTracking
    }

    /// Puts the reading anchor back once PDFKit has finished this refit (coalesced per turn:
    /// PDFKit sets the zoom, then the offset).
    private func scheduleRefitRestore() {
        guard let ticket = position.scheduleRefitRestore() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.position.beginRefitRestore(ticket: ticket, isReaderGesturing: self.isReaderGesturing)
            else { return }
            self.placeReadingAnchor()
            self.position.endRefitRestore(scale: self.view.scaleFactor)
            self.updateAnchorProbe()
        }
    }

    /// Scrolls so the reading anchor's page point is at the top-left corner, after laying out
    /// the document view. Call while the keeper is `restoring`.
    private func placeReadingAnchor() {
        guard let anchor = readingAnchor, let page = page(at: anchor.pageIndex), let scrollView else { return }
        scrollView.layoutIfNeeded()
        view.documentView?.layoutIfNeeded()
        let inView = view.convert(anchor.point, from: page)
        let content = scrollView.convert(inView, from: view)
        let target = ViewportAnchorMath.contentOffset(placing: content, insets: scrollView.adjustedContentInset,
                                                      contentSize: scrollView.contentSize,
                                                      boundsSize: scrollView.bounds.size)
        if abs(target.x - scrollView.contentOffset.x) > 0.01 || abs(target.y - scrollView.contentOffset.y) > 0.01 {
            scrollView.setContentOffset(target, animated: false)
        }
    }

    /// Called by `ReaderPDFView.layoutSubviews` for the first non-zero size.
    func viewDidGetFirstSize() {
        applyPendingPageIfPossible()
    }

    // MARK: Private

    private func makeView() -> ReaderPDFView {
        isViewLoaded = true
        let view = ReaderPDFView(frame: .zero)
        view.controller = self
        // Must be set before a document is assigned for PDFKit to ask for overlays (the session
        // makes its page ink before it opens the document).
        view.pageOverlayViewProvider = self
        view.displayMode = .singlePageContinuous
        view.displayDirection = (session?.scrollDirection ?? .vertical).pdfDisplayDirection
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

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = tapDelegate
        view.addGestureRecognizer(tap)

        let touchDown = TouchDownObserver { [weak self] in self?.readerDidZoom() }
        touchDown.delegate = tapDelegate
        view.addGestureRecognizer(touchDown)
        return view
    }

    private func applyPendingPageIfPossible() {
        guard isViewLoaded, view.document != nil, view.bounds.width > 0, view.bounds.height > 0,
              position.pendingPageIndex != nil else { return }
        // Let PDFKit lay out the document view first, then position.
        DispatchQueue.main.async { [weak self] in
            guard let self, let index = self.position.pendingPageIndex, let page = self.page(at: index) else { return }
            self.position.clearPendingPage()
            let start = self.pendingPosition
            self.pendingPosition = nil
            if let start, !start.isFitWidth, start.scale > 0 {
                self.view.autoScales = false
                self.view.scaleFactor = min(max(CGFloat(start.scale), self.view.minScaleFactor), self.view.maxScaleFactor)
            }
            self.position.willNavigate(scale: self.view.scaleFactor)
            if let start, let anchorPage = self.page(at: start.anchor.pageIndex) {
                self.view.show(start.anchor.point, of: anchorPage)
            } else {
                self.view.showTop(of: page)
            }
            PerfMarks.mark("positioned")
            self.observeScrollViewIfNeeded()
            self.position.didPosition(anchor: self.captureAnchor(), scale: self.view.scaleFactor)
            self.session?.pdfReportedCurrentPage(index)
            self.reportVisiblePages()
            self.reportNavigationState()
        }
    }

    @objc private func pageChanged(_ notification: Notification) {
        guard let page = view.currentPage, let index = pageIndex(of: page),
              position.takePageReport() else { return }
        session?.pdfReportedCurrentPage(index)
    }

    @objc private func visiblePagesChanged(_ notification: Notification) {
        reportVisiblePages()
    }

    @objc private func navigationChanged(_ notification: Notification) {
        reportNavigationState()
        updateAnchorProbe()
    }

    /// A single tap on a page goes to highlights first (WP7: a tap on a highlight opens its menu
    /// and is consumed), then to the search if there is one (WP10: it clears its mark).
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let session,
              session.highlights != nil || session.searchModelIfCreated != nil else { return }
        let point = recognizer.location(in: view)
        guard let page = view.page(for: point, nearest: false), let index = pageIndex(of: page) else { return }
        let tap = ReaderPageTap(pageIndex: index, page: page, pointInPage: view.convert(point, to: page),
                                pointInView: point, view: view)
        if session.highlights?.handleTap(tap) == true { return }
        session.searchModelIfCreated?.pageWasTapped()
    }

    private func reportVisiblePages() {
        guard view.document != nil else { return }
        let pages = Array(Set(view.visiblePages.compactMap { pageIndex(of: $0) })).sorted()
        session?.pdfReportedVisiblePages(pages)
        session?.highlights?.visiblePagesDidChange(pages)
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

    /// PDFKit follows a link inside the PDF by performing its action on the view (a link with a
    /// plain destination is performed as a go-to action too), so the controller sees it here,
    /// before PDFKit moves.
    override func perform(_ action: PDFAction) {
        controller?.willPerform(action)
        super.perform(action)
    }

    /// Scrolls so the top edge of `page` is at the top of the visible area.
    ///
    /// On this SDK `go(to: PDFPage)` / `go(to: PDFDestination)` leave the neighbouring page
    /// partly visible when pages are taller than the view (PDFKit then reports the neighbour as
    /// current), and a far-away page's frame is not valid before PDFKit has laid it out. So:
    /// let PDFKit bring the page near, then (next run-loop turns) set the scroll offset from the
    /// page's now-valid frame and check the result, retrying briefly.
    ///
    /// Scrolling horizontally, the page's leading edge goes to the left of the visible area too
    /// (otherwise the horizontal offset is kept).
    func showTop(of page: PDFPage) {
        alignmentGeneration += 1
        go(to: page)
        let bounds = page.bounds(for: displayBox)
        align(page, pageY: bounds.maxY, pageX: isHorizontal ? bounds.minX : nil, attemptsLeft: 4,
              generation: alignmentGeneration)
    }

    /// Pages run side by side (`ReaderScrollDirection.horizontal`).
    var isHorizontal: Bool { displayDirection == .horizontal }

    /// Scrolls so page-space `point` of `page` is at the top-left corner of the visible area, as
    /// near as the scrollable range allows (a `ReadingAnchor`: section history's exact place).
    /// Positioned as `showTop(of:)` is.
    func show(_ point: CGPoint, of page: PDFPage) {
        alignmentGeneration += 1
        go(to: page)
        align(page, pageY: point.y, pageX: point.x, attemptsLeft: 4, generation: alignmentGeneration)
    }

    /// The page at the top of the visible area (scrolling horizontally: at its left edge) and
    /// the page-space y there.
    func pageAndPointAtTop() -> (page: PDFPage, pageY: CGFloat)? {
        guard let scrollView = PDFKitWorkarounds.scrollView(of: self) else { return nil }
        let insets = scrollView.adjustedContentInset
        let probe = isHorizontal
            ? CGPoint(x: bounds.minX + insets.left + 1, y: bounds.midY)
            : CGPoint(x: bounds.midX, y: bounds.minY + insets.top + 1)
        guard let page = page(for: probe, nearest: true) else { return nil }
        let point = convert(probe, to: page)
        return (page, min(point.y, page.bounds(for: displayBox).maxY))
    }

    private var alignmentGeneration = 0

    /// Puts page-space `pageY` (and `pageX`, when given; otherwise the horizontal offset is kept)
    /// of `page` at the top-left corner of the visible area.
    private func align(_ page: PDFPage, pageY: CGFloat, pageX: CGFloat?, attemptsLeft: Int, generation: Int) {
        DispatchQueue.main.async { [weak self, weak page] in
            guard let self, let page, attemptsLeft > 0, generation == self.alignmentGeneration,
                  let scrollView = PDFKitWorkarounds.scrollView(of: self) else { return }
            self.layoutIfNeeded()
            let bounds = page.bounds(for: self.displayBox)
            let pointInView = self.convert(CGPoint(x: pageX ?? bounds.midX, y: pageY), from: page)
            let pointInContent = scrollView.convert(pointInView, from: self)
            let target = ViewportAnchorMath.contentOffset(placing: pointInContent, insets: scrollView.adjustedContentInset,
                                                          contentSize: scrollView.contentSize,
                                                          boundsSize: scrollView.bounds.size)
            let x = pageX == nil ? scrollView.contentOffset.x : target.x
            if target.y.isFinite, x.isFinite {
                scrollView.setContentOffset(CGPoint(x: x, y: target.y), animated: false)
            }
            // Verify: the page under the top (horizontally: the left edge) of the visible area
            // must be `page`.
            if self.pageAndPointAtTop()?.page !== page {
                self.align(page, pageY: pageY, pageX: pageX, attemptsLeft: attemptsLeft - 1, generation: generation)
            }
        }
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        applyPDFKitPolicies()
        if !PDFKitWorkarounds.isPDFKitView(subview, in: self) {
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    override func willRemoveSubview(_ subview: UIView) {
        super.willRemoveSubview(subview)
        if !PDFKitWorkarounds.isPDFKitView(subview, in: self) {
            DispatchQueue.main.async { UIAccessibility.post(notification: .layoutChanged, argument: nil) }
        }
    }

    /// The per-view policies PDFKit's own views need (`PDFKitWorkarounds`), re-applied whenever
    /// PDFKit may have replaced them (subview added, every layout pass, document attached):
    /// "No scroll-to-top" (design), text-input proxies hidden from accessibility, and Select All
    /// routed to `selectParagraphs()`.
    func applyPDFKitPolicies() {
        PDFKitWorkarounds.disableScrollsToTop(in: self)
        PDFKitWorkarounds.hideTextInputProxies(in: self)
        if let documentView { PDFKitWorkarounds.routeSelectAll(from: documentView) }
    }

    // MARK: Select All ("Select All selects the paragraph")

    /// Select All is offered only with a text selection (it then selects its paragraphs).
    var canSelectParagraphs: Bool {
        guard let selection = currentSelection else { return false }
        return !selection.pages.isEmpty
    }

    /// The PDF's Select All: grows the selection to its paragraphs (never the whole document).
    func selectParagraphs() {
        controller?.selectParagraphs()
    }

    override func selectAll(_ sender: Any?) {
        selectParagraphs()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(selectAll(_:)) { return canSelectParagraphs }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: Accessibility

    /// PDFKit's document view must not be read as one text element
    /// (`PDFKitWorkarounds.visiblePageViews`). So the PDF view's accessibility children are, in
    /// this order:
    ///
    /// 1. the page views on screen, in reading order (top to bottom, or left to right when
    ///    scrolling horizontally) instead of the document view: VoiceOver
    ///    reads the visible pages through PDFKit's own page accessibility;
    /// 2. every other direct subview of the PDF view that is not PDFKit's own machinery, in
    ///    subview order: the accessibility containers features add (page ink's
    ///    `PageInkAccessibilityView`, highlights, the markup probe surface…). See
    ///    "Accessibility" in `ReaderExtensionPoints.swift`.
    ///
    /// No accessibility query reaches the whole-document text range. The list is computed on
    /// every query, so subviews added or removed later are picked up (and a layout-changed
    /// notification is posted when a feature view comes or goes). Sighted text selection,
    /// highlights and the edit menu are untouched (they never go through accessibility).
    private var visiblePageViews: [UIView] {
        PDFKitWorkarounds.visiblePageViews(in: self, horizontal: isHorizontal)
    }

    /// Feature-added direct subviews (see `accessibilityElements`), never a text input.
    private var featureAccessibilityViews: [UIView] {
        subviews.filter {
            !PDFKitWorkarounds.isPDFKitView($0, in: self) && !($0 is UITextInput) && !$0.isHidden
                && !$0.accessibilityElementsHidden
        }
    }

    override var accessibilityElements: [Any]? {
        get {
            let pages = visiblePageViews
            let features = featureAccessibilityViews
            if pages.isEmpty && features.isEmpty { return super.accessibilityElements }
            return pages + features
        }
        set { super.accessibilityElements = newValue }
    }

    override func accessibilityElementCount() -> Int {
        accessibilityElements?.count ?? 0
    }

    override func accessibilityElement(at index: Int) -> Any? {
        guard let elements = accessibilityElements, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        guard let object = element as AnyObject?, let elements = accessibilityElements else { return NSNotFound }
        return elements.firstIndex { ($0 as AnyObject) === object } ?? NSNotFound
    }

    /// Every bounds-size change (panel toggles, the divider, window resize, rotation, the
    /// keyboard, animation frames of any of these) is one pass: capture-if-needed before
    /// PDFKit lays out, restore the reading anchor right after, in the same pass.
    override func layoutSubviews() {
        defer { applyPDFKitPolicies() }
        let size = bounds.size
        let old = lastLayoutSize
        guard size != old else {
            super.layoutSubviews()
            return
        }
        lastLayoutSize = size
        if old == .zero {
            super.layoutSubviews()
            controller?.viewDidGetFirstSize()
            return
        }
        controller?.sizeChangeWillLayout()
        super.layoutSubviews()
        controller?.sizeChangeDidLayout()
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context, let elements = controller?.selectionMenuElements(),
              !elements.isEmpty else { return }
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: elements), atStartOfMenu: .root)
    }
}

/// Reports every touch that begins on the PDF view (a finger or the Pencil on the page: a pinch
/// or double tap may follow) and never recognises, so it takes nothing from PDFKit's or the features' gestures.
final class TouchDownObserver: UIGestureRecognizer {
    private let onTouchDown: () -> Void

    init(onTouchDown: @escaping () -> Void) {
        self.onTouchDown = onTouchDown
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchDown()
        state = .failed
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
        ReaderPDFHostView(controller: session.pdf, responderView: session.markup.responderView,
                          probes: [session.pdf.anchorProbe, session.pdf.selectionProbe, session.pdf.perfProbe].compactMap { $0 }
                              + session.pdf.markupStateProbes)
    }

    func updateUIView(_ uiView: ReaderPDFHostView, context: Context) {}
}

final class ReaderPDFHostView: UIView {
    private let controller: ReaderPDFController
    private let responderView: UIView
    /// Test-hook elements (`-exposeViewportAnchor`, `-exposeSelection`, `-exposeMarkupState`).
    private let probes: [UIView]

    init(controller: ReaderPDFController, responderView: UIView, probes: [UIView]) {
        self.controller = controller
        self.responderView = responderView
        self.probes = probes
        super.init(frame: .zero)
        adopt()
    }

    convenience init(controller: ReaderPDFController, responderView: UIView, anchorProbe: UIView?) {
        self.init(controller: controller, responderView: responderView, probes: [anchorProbe].compactMap { $0 })
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
        for (index, probe) in probes.enumerated() where probe.superview !== self {
            // Big enough for XCUITest to tap (the undo / redo probes), clear of the page's centre.
            probe.frame = CGRect(x: CGFloat(index) * 12, y: 0, width: 10, height: 10)
            addSubview(probe)
        }
    }
}
