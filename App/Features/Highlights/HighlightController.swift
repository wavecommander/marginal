import OSLog
import PDFKit
import ReaderCore
import UIKit

let highlightLog = Logger(subsystem: "software.tactile.marginal", category: "highlights")

/// Text highlights for one reader window. Created once per window
/// (`ReaderSession.highlights`); holds the session weakly. The PDF bridge calls
/// `selectionMenuElements(for:)`, `handleTap(_:)` and `visiblePagesDidChange(_:)` directly.
///
/// ## Making a highlight
/// The selection edit menu gets the four colours (`selectionMenuElements(for:)`). Choosing one
/// stores one `Highlight` per page the selection touches through `session.perform` (the overlap
/// rule is in `HighlightEditing`), then clears the selection. The menu acts only on the
/// `ReaderTextSelection` it was built for, whichever gesture or mode produced it.
///
/// ## Scanned pages (S4)
/// On a scanned page the selection is PDFKit's Live Text and reaches this controller like any
/// other. The highlight records `HighlightTextSource.liveText` when its page has no text of its
/// own **in the file** (`textSources`, read from a private document and prefetched for the pages
/// near the screen; never the on-screen document, which gains the Live Text). It is drawn from
/// its rects like every highlight. Lists show it as a crop of the page (`crops`).
///
/// ## Showing highlights
/// In-memory `HighlightAnnotation`s on the on-screen document's pages, only for the displayed
/// pages and one page either side (`visiblePagesDidChange`): a page coming near the screen
/// gets its highlights (one store query for all newly shown pages), a page leaving loses them,
/// and a page whose `PDFPage` object changed (document re-assigned or replaced) gets them again.
/// Nothing is kept for pages off screen; nothing walks the book. Every store change for a shown
/// page, from this window or another (`.highlightsChanged`), re-reads that page and updates its
/// annotations by diff, so own and other windows' changes take the same path. The PDF is never
/// written (see `HighlightAnnotation`).
///
/// ## Tapping a highlight
/// `handleTap(_:)` hit-tests the page's stored rects (`HighlightGeometry.hitTest`, 4 pt
/// tolerance). On a hit it presents a system edit menu anchored at the tapped line (recolour,
/// with the current colour checked; Copy; Delete) and consumes the tap; anywhere else, and on a
/// link, it returns `false` so links, selection and other handlers keep working.
///
/// ## Markup mode (owner decision: highlights are made with a finger outside markup mode)
/// Highlights look the same in both modes, under page ink (PDFKit draws page overlays above
/// the page content, annotations included). In markup mode they are **display-only**: PDFKit's
/// text selection is off there, so no selection menu reaches this controller, and
/// `handleTap(_:)` returns `false` without hit-testing, because a tap in markup mode belongs to
/// the ink canvas (with finger drawing allowed it leaves a dot) and must not also open a menu.
/// The selection menu actions themselves assume no mode: they act only on the
/// `ReaderTextSelection` they were built for.
@MainActor
final class HighlightController {
    private weak var session: ReaderSession?
    private var observation: StoreChangeObservation?
    private let menuPresenter = HighlightMenuPresenter()
    private let accessibilityView = HighlightAccessibilityView(frame: .zero)

    /// Pages either side of the visible ones that also get their highlights (so a page scrolled
    /// into view is already marked when PDFKit first draws it).
    static let pageMargin = 1

    /// What is applied to one page.
    private struct AppliedPage {
        weak var page: PDFPage?
        var annotations: [UUID: HighlightAnnotation]
        var highlights: [Highlight]
    }

    private var applied: [Int: AppliedPage] = [:]
    private var visiblePages: [Int] = []

    /// Whether pages have text of their own in the file, for a new highlight's source (S4).
    /// Prefetched for the pages near the screen, so making a highlight never reads a file on the
    /// main thread.
    let textSources: HighlightTextSourceProbe
    /// Crops of scanned-page highlights for this window's lists ("Highlights on this page").
    let crops: HighlightCropCache
    /// The last correction of highlights saved before their page's source was known (tests).
    private(set) var pendingSourceCorrection: Task<Void, Never>?

    init(session: ReaderSession) {
        self.session = session
        textSources = HighlightTextSourceProbe(documentURL: session.documentURL)
        crops = HighlightCropCache(documentURL: session.documentURL)
        #if DEBUG
        ScannedHighlightDebugSeed.seedIfRequested(store: session.store, book: session.book)
        #endif
        menuPresenter.controller = self
        accessibilityView.controller = self
        observation = session.observeBookChanges(includeOwn: true) { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: Selection menu

    func selectionMenuElements(for selection: ReaderTextSelection) -> [UIMenuElement] {
        guard !selection.parts.isEmpty else { return [] }
        return [HighlightMenus.selectionMenu { [weak self] color in
            self?.highlight(selection, color: color)
        }]
    }

    /// Highlights `selection` in `color` (overlap rule: `HighlightEditing`), clears the
    /// selection, and returns the highlights now covering it. The page updates through the
    /// store's change event.
    ///
    /// The source of each highlight (S4) is decided from the page **in the file**: on a page with
    /// no text of its own it is `.liveText`. The answer is normally already cached (prefetched as
    /// the page came into view); if not, the highlight is saved at once and its source corrected
    /// as soon as the file has been read, off the main thread (`pendingSourceCorrection`).
    @discardableResult
    func highlight(_ selection: ReaderTextSelection, color: HighlightColor) -> [Highlight] {
        guard let session else { return [] }
        let sources = textSources
        let editing = HighlightEditing(store: session.store, bookID: session.book.id,
                                       textLayer: { sources.cachedLayer(forPage: $0) }) { [weak session] in
            session?.pdf.page(at: $0)
        }
        var result: [Highlight] = []
        do {
            result = try session.perform { _ in try editing.apply(color, to: selection) }
        } catch {
            highlightLog.error("Saving a highlight failed: \(String(describing: error), privacy: .public)")
        }
        session.pdf.clearSelection()
        let undecided = result.filter { sources.cachedLayer(forPage: $0.pageIndex) == nil }
        if !undecided.isEmpty { correctSources(of: undecided.map(\.id)) }
        return result
    }

    /// Reads the file's pages of highlights saved before their source was known and marks the
    /// ones on pages without text of their own as Live Text.
    private func correctSources(of ids: [UUID]) {
        let previous = pendingSourceCorrection
        pendingSourceCorrection = Task { [weak self] in
            await previous?.value
            for id in ids {
                guard let self, let session = self.session,
                      let stored = try? session.store.highlights.highlight(id: id),
                      stored.textSource != .liveText,
                      await self.textSources.layer(forPage: stored.pageIndex) == .noText,
                      // Read again: it may have changed while the file was read.
                      var current = try? session.store.highlights.highlight(id: id),
                      current.textSource != .liveText else { continue }
                current.textSource = .liveText
                do {
                    try session.perform { try $0.highlights.save(current) }
                } catch {
                    highlightLog.error("Recording a highlight's source failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Recolours a stored highlight.
    func recolor(highlightID: UUID, to color: HighlightColor) {
        guard let session, var highlight = try? session.store.highlights.highlight(id: highlightID),
              highlight.color != color else { return }
        highlight.color = color
        do {
            try session.perform { try $0.highlights.save(highlight) }
        } catch {
            highlightLog.error("Recolouring a highlight failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Deletes a stored highlight.
    func delete(highlightID: UUID) {
        guard let session else { return }
        do {
            try session.perform { try $0.highlights.deleteHighlight(id: highlightID) }
        } catch {
            highlightLog.error("Deleting a highlight failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Puts a highlight's text on the general pasteboard.
    func copyText(highlightID: UUID) {
        guard let session, let highlight = try? session.store.highlights.highlight(id: highlightID) else { return }
        UIPasteboard.general.string = highlight.text
    }

    // MARK: Taps

    func handleTap(_ tap: ReaderPageTap) -> Bool {
        // Display-only in markup mode: the tap is the canvas's.
        guard session?.isMarkupMode == false, let hit = highlight(atPageIndex: tap.pageIndex, point: tap.pointInPage) else { return false }
        // A link under the tap wins (PDFKit follows it).
        if let annotation = tap.page.annotation(at: tap.pointInPage), !(annotation is HighlightAnnotation),
           annotation.action != nil || annotation.url != nil || annotation.destination != nil {
            return false
        }
        menuPresenter.present(for: hit, in: tap.view, at: tap.pointInView)
        return true
    }

    /// The stored highlight under a page-space point, or `nil`.
    func highlight(atPageIndex pageIndex: Int, point: CGPoint) -> Highlight? {
        guard let session else { return nil }
        let highlights = applied[pageIndex]?.highlights
            ?? (try? session.store.highlights.highlights(bookID: session.book.id, pageIndex: pageIndex)) ?? []
        return HighlightGeometry.hitTest(point, in: highlights)
    }

    /// Opens the highlight menu on a displayed highlight (accessibility activation). Returns
    /// `false` when its page is not displayed.
    @discardableResult
    func presentMenu(for highlight: Highlight) -> Bool {
        guard let view = pdfViewIfLoaded, let frame = viewFrame(of: highlight) else { return false }
        menuPresenter.present(for: highlight, in: view, at: CGPoint(x: frame.midX, y: frame.midY))
        return true
    }

    /// The session, for the menu presenter.
    var sessionForMenus: ReaderSession? { session }

    /// Whether highlights can be tapped and edited now (reading mode; markup mode is display-only).
    var isInteractive: Bool { session?.isMarkupMode == false }

    /// The highlight the tap menu is showing (tests).
    var menuHighlightID: UUID? { menuPresenter.highlightID }

    /// The tap menu's contents for a highlight (also used by tests to drive its actions).
    func tapMenu(for highlight: Highlight) -> UIMenu {
        HighlightMenus.tapMenu(for: highlight, controller: self)
    }

    // MARK: Visible pages

    func visiblePagesDidChange(_ pageIndices: [Int]) {
        visiblePages = pageIndices
        sync()
        // A selection can exist only on a page in view (on a scanned page, seconds after it
        // appeared): know by then whether the page has text of its own in the file.
        textSources.prefetch(targetPages)
    }

    /// Pages that should carry highlights now: the visible ones and `pageMargin` either side.
    var targetPages: Set<Int> {
        guard let session, session.document != nil else { return [] }
        let count = session.pageCount
        var pages = Set<Int>()
        for page in visiblePages {
            for index in (page - Self.pageMargin)...(page + Self.pageMargin) where index >= 0 && index < count {
                pages.insert(index)
            }
        }
        return pages
    }

    /// The highlights currently applied, by page (reading order on each page).
    var displayedHighlights: [Int: [Highlight]] {
        applied.compactMapValues { $0.page == nil || $0.highlights.isEmpty ? nil : $0.highlights }
    }

    /// The annotations this controller has on a page right now (tests and diagnostics).
    func appliedAnnotations(onPage pageIndex: Int) -> [HighlightAnnotation] {
        guard let entry = applied[pageIndex] else { return [] }
        return Array(entry.annotations.values)
    }

    /// Pages that currently hold this controller's annotations.
    var appliedPageIndices: Set<Int> { Set(applied.filter { !$0.value.annotations.isEmpty }.keys) }

    /// Brings the shown pages in line with `targetPages` and the store. `reloading` pages are
    /// re-read even if already applied.
    func sync(reloading: Set<Int> = []) {
        guard let session else { return }
        let targets = targetPages
        for pageIndex in applied.keys where !targets.contains(pageIndex) {
            removeAll(fromPage: pageIndex)
        }
        let needed = targets.filter { index in
            guard !reloading.contains(index), let entry = applied[index] else { return true }
            return entry.page == nil || entry.page !== session.pdf.page(at: index)
                || entry.annotations.values.contains { $0.page !== entry.page }
        }
        if !needed.isEmpty, let low = needed.min(), let high = needed.max() {
            let stored = (try? session.store.highlights.highlights(bookID: session.book.id, in: low...high)) ?? []
            let byPage = Dictionary(grouping: stored, by: \.pageIndex)
            for pageIndex in needed.sorted() {
                apply(byPage[pageIndex] ?? [], toPage: pageIndex)
            }
            accessibilityView.highlightsDidChange()
        }
        installAccessibilityViewIfNeeded()
    }

    private func apply(_ highlights: [Highlight], toPage pageIndex: Int) {
        guard let session, let page = session.pdf.page(at: pageIndex) else {
            removeAll(fromPage: pageIndex)
            return
        }
        var entry = applied[pageIndex] ?? AppliedPage(page: page, annotations: [:], highlights: [])
        if entry.page !== page {
            for annotation in entry.annotations.values { annotation.page?.removeAnnotation(annotation) }
            entry = AppliedPage(page: page, annotations: [:], highlights: [])
        }
        let wanted = Dictionary(highlights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, annotation) in entry.annotations {
            let highlight = wanted[id]
            let current = highlight.map { annotation.highlightColor == $0.color && annotation.lineRects == $0.rects.filter { !$0.isNull && !$0.isEmpty } } ?? false
            if !current || annotation.page !== page {
                annotation.page?.removeAnnotation(annotation)
                entry.annotations[id] = nil
            }
        }
        for highlight in highlights where entry.annotations[highlight.id] == nil {
            let annotation = HighlightAnnotation(highlight: highlight)
            session.pdf.addAnnotation(annotation, toPageAt: pageIndex)
            entry.annotations[highlight.id] = annotation
        }
        entry.highlights = highlights
        applied[pageIndex] = entry
    }

    private func removeAll(fromPage pageIndex: Int) {
        guard let entry = applied.removeValue(forKey: pageIndex) else { return }
        for annotation in entry.annotations.values {
            annotation.page?.removeAnnotation(annotation)
        }
    }

    // MARK: Changes

    private func handle(_ event: StoreChangeEvent) {
        switch event.change {
        case .highlightsChanged(_, let pageIndex):
            guard targetPages.contains(pageIndex) else { return }
            sync(reloading: [pageIndex])
        case .bookDeleted:
            for pageIndex in Array(applied.keys) { removeAll(fromPage: pageIndex) }
        default:
            break
        }
    }

    // MARK: Geometry for menus and accessibility

    /// The PDF view, once the document is open.
    var pdfViewIfLoaded: PDFView? {
        guard let session, session.document != nil else { return nil }
        return session.pdf.view
    }

    /// A highlight's frame in the PDF view's coordinates, or `nil` when its page is not shown.
    func viewFrame(of highlight: Highlight, line: Int? = nil) -> CGRect? {
        guard let view = pdfViewIfLoaded, let page = applied[highlight.pageIndex]?.page
                ?? session?.pdf.page(at: highlight.pageIndex) else { return nil }
        let rects = line.flatMap { highlight.rects.indices.contains($0) ? [highlight.rects[$0]] : nil } ?? highlight.rects
        let union = HighlightGeometry.union(rects)
        guard !union.isNull else { return nil }
        return view.convert(union, from: page)
    }

    // MARK: Accessibility

    private func installAccessibilityViewIfNeeded() {
        guard let view = pdfViewIfLoaded, let host = view.superview else { return }
        if accessibilityView.superview !== host {
            host.insertSubview(accessibilityView, aboveSubview: view)
        }
        if accessibilityView.frame != view.frame { accessibilityView.frame = view.frame }
    }
}
