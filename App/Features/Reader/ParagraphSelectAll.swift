import Foundation
import ObjectiveC
import PDFKit
import UIKit

/// "Select All selects the paragraph" (design): the PDF's Select All grows a selection to the
/// paragraphs it touches, page by page, and never runs PDFKit's whole-document Select All.
@MainActor
enum ParagraphSelection {
    /// One text line of a page: its character range on the page and its layout.
    struct PageLine {
        var range: NSRange
        var line: ParagraphGrouping.Line
    }

    /// The text lines of one page, in text order. Reads only this page.
    static func lines(on page: PDFPage) -> [PageLine] {
        let count = page.numberOfCharacters
        guard count > 0, let whole = page.selection(for: NSRange(location: 0, length: count)) else { return [] }
        return whole.selectionsByLine().compactMap { line in
            let ranges = (0..<line.numberOfTextRanges(on: page)).map { line.range(at: $0, on: page) }
                .filter { $0.location != NSNotFound && $0.length > 0 }
            guard let first = ranges.min(by: { $0.location < $1.location }),
                  let end = ranges.map({ NSMaxRange($0) }).max() else { return nil }
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let hyphen = text.hasSuffix("-") || text.hasSuffix("\u{00AD}") || text.hasSuffix("\u{2010}")
            return PageLine(range: NSRange(location: first.location, length: end - first.location),
                            line: ParagraphGrouping.Line(rect: line.bounds(for: page), endsWithHyphen: hyphen))
        }
    }

    /// The character range on `page` of the whole paragraphs that `selected` (character ranges
    /// on that page) touches, or `nil` when it touches no text line.
    static func paragraphRange(touching selected: [NSRange], on page: PDFPage, displayBox: PDFDisplayBox) -> NSRange? {
        let lines = lines(on: page)
        guard !lines.isEmpty else { return nil }
        let paragraphs = ParagraphGrouping.paragraphs(lines.map(\.line), visibleBox: page.bounds(for: displayBox))
        func touches(_ line: PageLine) -> Bool {
            selected.contains { range in
                range.length == 0 ? NSLocationInRange(range.location, line.range)
                                  : NSIntersectionRange(range, line.range).length > 0
            }
        }
        let touched = paragraphs.indices.filter { paragraphs[$0].contains { touches(lines[$0]) } }
        guard let low = touched.min(), let high = touched.max() else { return nil }
        let span = paragraphs[low].lowerBound..<paragraphs[high].upperBound
        let start = span.map { lines[$0].range.location }.min()!
        let end = span.map { NSMaxRange(lines[$0].range) }.max()!
        return NSRange(location: start, length: end - start)
    }

    /// `selection` grown to the whole paragraphs it touches on each of its pages (and no further:
    /// never another page), or `nil` when it has no text.
    static func expanding(_ selection: PDFSelection, displayBox: PDFDisplayBox = .cropBox) -> PDFSelection? {
        var result: PDFSelection?
        for page in selection.pages {
            let selected = (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
                .filter { $0.location != NSNotFound }
            guard !selected.isEmpty,
                  let range = paragraphRange(touching: selected, on: page, displayBox: displayBox),
                  let part = page.selection(for: range) else { continue }
            if let result { result.add(part) } else { result = part }
        }
        return result
    }
}

// MARK: - Responder plumbing

/// Routes every Select All aimed at the PDF to `ReaderPDFView.selectParagraphs()`.
///
/// On this SDK the edit menu's Select All, the Edit menu's Select All and ⌘A are `selectAll:`
/// sent to the first responder, which while the PDF has focus is PDFKit's private document view
/// (a `UITextInput`), not the `PDFView`. That class's `selectAll:` and `canPerformAction:` are
/// replaced once (for instances inside a `ReaderPDFView`; any other instance keeps PDFKit's);
/// `ReaderPDFView` overrides both itself for the case where the action reaches it.
@MainActor
enum PDFSelectAllRouting {
    private static var installedClasses: Set<ObjectIdentifier> = []

    static func install(on documentView: UIView) {
        let cls: AnyClass = type(of: documentView)
        guard !installedClasses.contains(ObjectIdentifier(cls)) else { return }
        installedClasses.insert(ObjectIdentifier(cls))
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
}
