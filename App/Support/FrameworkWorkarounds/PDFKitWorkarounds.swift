import Foundation
import ObjectiveC
import PDFKit
import UIKit

/// Everything the app does that depends on how PDFKit is built inside, rather than on its
/// documented API: one function per workaround, each saying what it works around. Reader code
/// calls these and holds no knowledge of PDFKit's private views itself.
///
/// What each one leans on is pinned by `FrameworkWorkaroundCanaryTests`: when an iPadOS release
/// changes PDFKit's inside, the canary for the workaround it breaks fails by name.
@MainActor
enum PDFKitWorkarounds {

    // MARK: The scroll view

    /// The scroll view PDFKit scrolls the document in.
    ///
    /// Works around: `PDFView` has no scroll-view API. Reading the scroll offset (the reading
    /// anchor), setting it (exact positioning) and observing it all need the `UIScrollView`,
    /// which on this SDK is the superview of `PDFView.documentView`.
    static func scrollView(of pdfView: PDFView) -> UIScrollView? {
        pdfView.documentView?.superview as? UIScrollView
    }

    /// Opts every scroll view PDFKit puts inside `pdfView` out of the system's
    /// tap-to-scroll-to-top.
    ///
    /// Works around: a tap on the status bar (and on iPadOS 26+ the navigation bar / title) is
    /// sent to the window's scroll-to-top scroll view, which is PDFKit's private one and would
    /// take the reader to page 1 (design: "No scroll-to-top"). PDFKit can replace its scroll view
    /// when the document, display mode or layout changes, so call this on every subview addition
    /// and layout pass. It walks only PDFKit's chrome, never into the document view's page views.
    static func disableScrollsToTop(in pdfView: PDFView) {
        let documentView = pdfView.documentView
        var queue: [(view: UIView, depth: Int)] = pdfView.subviews.map { ($0, 1) }
        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            if let scrollView = current as? UIScrollView, scrollView.scrollsToTop {
                scrollView.scrollsToTop = false
            }
            guard depth < 4, current !== documentView else { continue }
            queue.append(contentsOf: current.subviews.map { ($0, depth + 1) })
        }
    }

    /// Configures PDFKit's internal scroll view on iPadOS 26+ so the transparent navigation bar
    /// floats directly over the pages without a scroll-edge blur.
    static func configureTransparentTopBarScroll(in pdfView: PDFView) {
        guard #available(iOS 26.0, *), let scrollView = scrollView(of: pdfView) else { return }
        if !scrollView.topEdgeEffect.isHidden {
            scrollView.topEdgeEffect.isHidden = true
        }
    }

    // MARK: PDFKit's own views

    /// Whether `view`, a subview of `pdfView`, is PDFKit's own (its scroll view, the document
    /// view and anything containing it) as opposed to a view a feature added.
    ///
    /// Works around: PDFKit's views are private classes, so they are told apart by the bundle
    /// their class comes from.
    static func isPDFKitView(_ view: UIView, in pdfView: PDFView) -> Bool {
        if Bundle(for: type(of: view)) == Bundle(for: PDFView.self) { return true }
        if let documentView = pdfView.documentView, documentView === view || documentView.isDescendant(of: view) {
            return true
        }
        return false
    }

    /// The page views on screen, in reading order (top to bottom, or left to right when
    /// `horizontal`).
    ///
    /// Works around: PDFKit's document view is a `UITextInput` spanning the whole book. An
    /// accessibility client that reads it as a text element (its value, or `text(in:)` over its
    /// full range, as UIKit's text-element accessibility does) makes PDFKit build a selection
    /// over every page on the main thread: measured 9.7 s and 3.4 M characters for `large.pdf`
    /// in one call, repeated per query. So the reader exposes these views, PDFKit's per-page
    /// views (the document view's subviews that are not text inputs), instead of the document
    /// view itself.
    static func visiblePageViews(in pdfView: PDFView, horizontal: Bool) -> [UIView] {
        guard let documentView = pdfView.documentView else { return [] }
        let visible = pdfView.convert(pdfView.bounds, to: documentView)
        return documentView.subviews
            .filter { !($0 is UITextInput) && !$0.isHidden && $0.frame.intersects(visible) }
            .sorted { horizontal ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
    }

    /// Hides every other `UITextInput` view PDFKit has added to `pdfView` from accessibility,
    /// and routes its Select All (`routeSelectAll(from:)`).
    ///
    /// Works around: a text-input proxy PDFKit adds while text is selected (such as
    /// `PDFTextInputView`) answers accessibility with whole-document text in the same way as the
    /// document view; it has no visible content of its own.
    static func hideTextInputProxies(in pdfView: PDFView) {
        guard let documentView = pdfView.documentView else { return }
        var queue: [(view: UIView, depth: Int)] = pdfView.subviews.map { ($0, 1) } + documentView.subviews.map { ($0, 1) }
        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            if current is UITextInput, current !== documentView {
                if !current.accessibilityElementsHidden { current.accessibilityElementsHidden = true }
                routeSelectAll(from: current)
            }
            guard depth < 3, current !== documentView else { continue }
            queue.append(contentsOf: current.subviews.map { ($0, depth + 1) })
        }
    }

    // MARK: Select All

    private static var selectAllRoutedClasses: Set<ObjectIdentifier> = []

    /// Routes every Select All aimed at `textInputView` (PDFKit's document view, or one of its
    /// text-input proxies) to the `ReaderPDFView` that contains it.
    ///
    /// Works around: on this SDK the edit menu's Select All, the Edit menu's Select All and ⌘A
    /// are `selectAll:` sent to the first responder, which while the PDF has focus is PDFKit's
    /// private document view (a `UITextInput`), not the `PDFView`; its own `selectAll:` selects
    /// the whole book, page by page, on the main thread. That private class's `selectAll:` and
    /// `canPerformAction:withSender:` are replaced once per class (for instances inside a
    /// `ReaderPDFView`; any other instance keeps PDFKit's). `ReaderPDFView` overrides both itself
    /// for the case where the action reaches it.
    static func routeSelectAll(from textInputView: UIView) {
        let cls: AnyClass = type(of: textInputView)
        guard !selectAllRoutedClasses.contains(ObjectIdentifier(cls)) else { return }
        selectAllRoutedClasses.insert(ObjectIdentifier(cls))
        replaceSelectAll(in: cls)
        replaceCanPerformAction(in: cls)
    }

    private static func readerView(containing view: UIView) -> ReaderPDFView? {
        var current = view.superview
        while let candidate = current {
            if let reader = candidate as? ReaderPDFView { return reader }
            current = candidate.superview
        }
        return nil
    }

    private typealias SelectAllIMP = @convention(c) (AnyObject, Selector, Any?) -> Void
    private typealias CanPerformIMP = @convention(c) (AnyObject, Selector, Selector, Any?) -> Bool

    private static func replaceSelectAll(in cls: AnyClass) {
        let selector = #selector(UIResponderStandardEditActions.selectAll(_:))
        let original: SelectAllIMP? = class_getInstanceMethod(cls, selector)
            .map { unsafeBitCast(method_getImplementation($0), to: SelectAllIMP.self) }
        let block: @convention(block) (AnyObject, Any?) -> Void = { object, sender in
            MainActor.assumeIsolated {
                if let view = object as? UIView, let reader = readerView(containing: view) {
                    reader.selectParagraphs()
                } else {
                    original?(object, selector, sender)
                }
            }
        }
        class_replaceMethod(cls, selector, imp_implementationWithBlock(block), "v@:@")
    }

    private static func replaceCanPerformAction(in cls: AnyClass) {
        let selector = #selector(UIResponder.canPerformAction(_:withSender:))
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: CanPerformIMP.self)
        let selectAll = #selector(UIResponderStandardEditActions.selectAll(_:))
        let block: @convention(block) (AnyObject, Selector, Any?) -> Bool = { object, action, sender in
            MainActor.assumeIsolated {
                if action == selectAll, let view = object as? UIView, let reader = readerView(containing: view) {
                    return reader.canSelectParagraphs
                }
                return original(object, selector, action, sender)
            }
        }
        class_replaceMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    // MARK: Document-span selections (TSOFT-222)

    /// Spans of at least this many pages (first to last) are built in one batch.
    nonisolated static let batchedSelectionThreshold = 3

    /// The selection from one character of one page of `document` to one character of another
    /// (end character inclusive, as PDFKit's), built from per-page selections added in one
    /// batch, or `nil` to let PDFKit build it: spans of fewer than `batchedSelectionThreshold`
    /// pages, and anything out of range.
    ///
    /// Works around: when the text-selection edit menu is built, UIKit asks the selection for
    /// its range in the whole document (`UITextContextMenuInteraction` → `_selectedNSRange`), and
    /// PDFKit's text-input view answers it with
    /// `selection(from:atCharacterIndex:to:atCharacterIndex:)` from the start of page 1 to the
    /// selection, twice per menu. PDFKit builds that selection page by page and re-normalises it
    /// after every page, which grows with the square of the page number: measured on the iOS 27
    /// simulator with `large.pdf`, about 3 s per call at page 1,200 (6 s before the menu
    /// appears), 0.4 s at page 600, 60 ms at page 300. This builds the same selection (the same
    /// text ranges on the same pages). Reading a page's character count still lays out its text
    /// the first time (PDFKit does the same); nothing here walks the book otherwise.
    /// `ReaderPDFDocument` answers PDFKit's method with it.
    nonisolated static func batchedSelection(in document: PDFDocument, from startPage: PDFPage,
                                             atCharacterIndex startCharacter: Int, to endPage: PDFPage,
                                             atCharacterIndex endCharacter: Int) -> PDFSelection? {
        let first = document.index(for: startPage)
        let last = document.index(for: endPage)
        guard first != NSNotFound, last != NSNotFound, last - first >= batchedSelectionThreshold,
              startCharacter >= 0, endCharacter >= 0 else { return nil }
        let startCount = startPage.numberOfCharacters
        let endCount = endPage.numberOfCharacters
        guard startCharacter < startCount, endCharacter < endCount else { return nil }
        var parts: [PDFSelection] = []
        if let head = startPage.selection(for: NSRange(location: startCharacter, length: startCount - startCharacter)) {
            parts.append(head)
        }
        for pageIndex in (first + 1)..<last {
            guard let page = document.page(at: pageIndex) else { continue }
            let count = page.numberOfCharacters
            if count > 0, let whole = page.selection(for: NSRange(location: 0, length: count)) {
                parts.append(whole)
            }
        }
        if let tail = endPage.selection(for: NSRange(location: 0, length: endCharacter + 1)) {
            parts.append(tail)
        }
        guard !parts.isEmpty else { return nil }
        let result = PDFSelection(document: document)
        result.add(parts)
        return result
    }
}
