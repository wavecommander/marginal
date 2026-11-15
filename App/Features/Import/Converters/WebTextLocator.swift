import Foundation
import PDFKit

// Finds things in a freshly printed PDF by their text. The print path writes no link
// annotations and keeps no element positions (F0 finding 2), so a table-of-contents target or a
// link is located by searching the page text near the page its position in the web view
// suggests. Ambiguous text is reported as not found rather than guessed.

/// One printed document (a chapter), opened privately on the calling thread, with its page
/// strings cached. Not thread-safe: use from one task.
nonisolated final class WebPrintedText {
    let document: PDFDocument
    private var strings: [Int: NSString] = [:]

    init?(url: URL) {
        guard let document = PDFDocument(url: url) else { return nil }
        self.document = document
    }

    var pageCount: Int { document.pageCount }

    func string(ofPage index: Int) -> NSString {
        if let cached = strings[index] { return cached }
        let value = (document.page(at: index)?.string ?? "") as NSString
        strings[index] = value
        return value
    }

    /// The page a position (fraction of the document height) suggests.
    func estimatedPage(forFraction fraction: Double) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(pageCount - 1, max(0, Int((fraction * Double(pageCount)).rounded(.down))))
    }

    /// Every match of `expression` on the pages in `range`, in page order.
    func matches(of expression: NSRegularExpression, pages range: ClosedRange<Int>) -> [(page: Int, match: NSTextCheckingResult)] {
        guard pageCount > 0 else { return [] }
        let clamped = max(0, range.lowerBound)...min(pageCount - 1, max(0, range.upperBound))
        var found: [(Int, NSTextCheckingResult)] = []
        for page in clamped {
            let text = string(ofPage: page)
            for match in expression.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                found.append((page, match))
            }
        }
        return found
    }

    // MARK: Targets

    /// The page that holds a target whose own text is `text` (a heading, say): the match nearest
    /// `estimate` anywhere in the document, or within `window` pages of it when given. Tries the
    /// first eight words, then the first three. `nil` when the text is not found.
    func page(forText text: String, near estimate: Int, window: Int? = nil) -> Int? {
        let range = window.map { (estimate - $0)...(estimate + $0) } ?? 0...max(0, pageCount - 1)
        for words in [8, 3] {
            guard let expression = WebTextPattern.expression(for: text, maxWords: words) else { return nil }
            let pages = matches(of: expression, pages: range).map(\.page)
            if let best = pages.min(by: { abs($0 - estimate) < abs($1 - estimate) }) { return best }
        }
        return nil
    }

    // MARK: Links

    /// Where a link's text sits: the page and one rect per line, in page space. The link text is
    /// looked for within one page of `estimate`, preceded by `before` (the text just before the
    /// link) when that is known. `nil` when it is not found or not unique.
    func linkRects(text: String, before: String, near estimate: Int) -> (page: Int, rects: [CGRect])? {
        let range = (estimate - 1)...(estimate + 1)
        guard let link = WebTextPattern.pattern(for: text, maxWords: 40) else { return nil }
        if let context = WebTextPattern.contextPattern(before),
           let expression = try? NSRegularExpression(pattern: "\(context)\\s*(\(link))", options: [.caseInsensitive]) {
            let found = matches(of: expression, pages: range)
            if found.count == 1 { return rects(page: found[0].page, range: found[0].match.range(at: 1)) }
            if found.count > 1 { return nil }
        }
        // Without context, only text long enough to be distinctive, and only when unique.
        guard text.count >= 4,
              let expression = try? NSRegularExpression(pattern: link, options: [.caseInsensitive]) else { return nil }
        let found = matches(of: expression, pages: range)
        guard found.count == 1 else { return nil }
        return rects(page: found[0].page, range: found[0].match.range)
    }

    private func rects(page index: Int, range: NSRange) -> (page: Int, rects: [CGRect])? {
        guard range.location != NSNotFound, range.length > 0, let page = document.page(at: index),
              let selection = page.selection(for: range) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let lines = selection.selectionsByLine().map { $0.bounds(for: page) }
            .filter { !$0.isEmpty && $0.width > 0.5 && $0.height > 0.5 && bounds.intersects($0) }
        return lines.isEmpty ? nil : (index, lines)
    }
}

/// Regular expressions that match collapsed web text in PDF page text, where line breaks and
/// spacing differ.
nonisolated enum WebTextPattern {
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// The first `maxWords` words, with optional whitespace between every character: PDF text
    /// extraction splits letter-spaced words ("I N TRODUCTION") and may drop the space between
    /// words at a line end.
    static func pattern(for text: String, maxWords: Int) -> String? {
        let words = tokens(text).prefix(maxWords)
        guard !words.isEmpty else { return nil }
        return words.map(spaced).joined(separator: "\\s*")
    }

    static func spaced(_ word: String) -> String {
        word.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*")
    }

    static func expression(for text: String, maxWords: Int) -> NSRegularExpression? {
        pattern(for: text, maxWords: maxWords).flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    /// The last (up to) four whole words of `before`. The first word is dropped when `before`
    /// was cut to length, since it may be a fragment.
    static func contextPattern(_ before: String) -> String? {
        var words = tokens(before)
        if before.count >= 40, words.count > 1 { words.removeFirst() }
        let tail = words.suffix(4)
        guard !tail.isEmpty else { return nil }
        return tail.map(spaced).joined(separator: "\\s*")
    }
}
