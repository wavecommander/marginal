import Foundation

/// The app-wide page convention.
///
/// **Rule:** every page reference in code and in storage is a *page index*: zero-based, `0` is
/// the first page of the PDF, `pageCount - 1` the last. This matches `PDFDocument.page(at:)` and
/// `PDFDocument.index(for:)`. The 1-based *display number* exists only in user-visible text
/// (toolbar, page pill, Notebook, Markdown export) and is produced by these helpers. PDF page
/// labels (roman numerals and the like) are not used in version 1.
public enum PageNumbering {
    /// The 1-based number shown to the reader for a zero-based page index (`311` → `312`).
    public static func displayNumber(forPageIndex pageIndex: Int) -> Int {
        pageIndex + 1
    }

    /// The zero-based page index for a 1-based number the reader typed (`312` → `311`).
    /// Does not clamp; callers validate against the book's page count with `isValid`.
    public static func pageIndex(forDisplayNumber displayNumber: Int) -> Int {
        displayNumber - 1
    }

    /// `true` when `pageIndex` names a page of a book with `pageCount` pages
    /// (`0 <= pageIndex < pageCount`).
    public static func isValid(_ pageIndex: Int, pageCount: Int) -> Bool {
        pageIndex >= 0 && pageIndex < pageCount
    }

    /// Display label for one page: `"p. 312"` for page index `311`.
    public static func label(forPageIndex pageIndex: Int) -> String {
        "p. \(displayNumber(forPageIndex: pageIndex))"
    }

    /// Display label for a page range using an en dash: `"pp. 301–340"`, or the single-page label
    /// when the range holds one page.
    public static func label(forPageRange range: ClosedRange<Int>) -> String {
        if range.lowerBound == range.upperBound {
            return label(forPageIndex: range.lowerBound)
        }
        let first = displayNumber(forPageIndex: range.lowerBound)
        let last = displayNumber(forPageIndex: range.upperBound)
        return "pp. \(first)\u{2013}\(last)"
    }
}
