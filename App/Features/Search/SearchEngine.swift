import Foundation
import PDFKit

// The search engine (WP10): in-book text search that streams results, can be cancelled and never
// touches the on-screen document.
//
// ## Why not `PDFDocument.beginFindString`
// PDFKit's asynchronous find is driven by the run loop of the thread that started it (in
// practice the main thread, in slices), its delegate callbacks arrive on that thread, it offers
// only case-insensitive/literal options (no diacritic folding), gives no per-page progress we can
// throttle, and cannot resume from a page. So the engine runs a page-by-page loop on its own
// background task over its own `PDFDocument`: `PDFPage.string` of one page at a time (never the
// whole document's text), folded and matched by `SearchTextMatcher`, with `Task.isCancelled`
// checked between pages. The `PDFDocument` is created inside the task and never leaves it; only
// `Sendable` values (`SearchHit`, `SearchEvent`) cross to the main actor.

// MARK: - Values

/// A short piece of context around a match: `before` + `match` + `after`, whitespace collapsed.
nonisolated struct SearchSnippet: Hashable, Sendable {
    var before: String
    var match: String
    var after: String

    var text: String { before + match + after }
}

/// One text match in the PDF.
nonisolated struct SearchHit: Hashable, Sendable, Identifiable {
    /// Zero-based page.
    var pageIndex: Int
    /// The match's rects, one per line, in PDFKit page space (the space of `PDFSelection.bounds`).
    var rects: [CGRect]
    var snippet: SearchSnippet
    /// Index of the match among the page's matches.
    var ordinal: Int

    var id: String { "text-\(pageIndex)-\(ordinal)" }
}

/// What the engine reports, in order. `hits` always precede the `progress` that covers them.
nonisolated enum SearchEvent: Sendable, Equatable {
    /// Hits found since the previous event, ascending by page.
    case hits([SearchHit])
    /// `pagesSearched` is the number of pages scanned from the start of the book, i.e. the index
    /// of the next page to scan (so a search can resume there).
    case progress(pagesSearched: Int, totalPages: Int)
    case finished(SearchCompletion)
}

nonisolated struct SearchCompletion: Hashable, Sendable {
    enum Reason: Hashable, Sendable {
        /// Every page was searched.
        case completed
        /// The hit cap was reached; `nextPage` is where a continuation resumes.
        case capped
        /// The document could not be opened.
        case failed
    }

    var reason: Reason
    var nextPage: Int
}

// MARK: - Matching

/// Case-, diacritic-, width- and whitespace-insensitive matching with a mapping back to the
/// original text's UTF-16 offsets (the offsets `PDFPage.selection(for: NSRange)` takes).
///
/// Folding is done scalar by scalar: ASCII by arithmetic (the common case), other scalars through
/// Foundation once and then from a cache. Runs of whitespace (including the newline at a line
/// wrap) collapse to one space, so "lighthouse\ntheorem" matches "lighthouse theorem". Combining
/// marks and soft hyphens are dropped; compatibility forms (ligatures, full-width letters) are
/// expanded.
nonisolated struct SearchTextMatcher {
    /// Text folded for matching, with each folded scalar's span in the original UTF-16.
    struct Folded {
        var scalars: [UInt32] = []
        var starts: [Int32] = []
        var ends: [Int32] = []
    }

    private var cache: [UInt32: [UInt32]] = [:]
    private static let space: UInt32 = 0x20

    init() {}

    /// The folded form of a user's query (trimmed, whitespace collapsed).
    mutating func foldQuery(_ query: String) -> [UInt32] {
        var folded = fold(query).scalars
        while folded.last == Self.space { folded.removeLast() }
        while folded.first == Self.space { folded.removeFirst() }
        return folded
    }

    mutating func fold(_ text: String) -> Folded {
        var out = Folded()
        out.scalars.reserveCapacity(text.utf8.count)
        out.starts.reserveCapacity(text.utf8.count)
        out.ends.reserveCapacity(text.utf8.count)
        var offset: Int32 = 0
        for scalar in text.unicodeScalars {
            let length: Int32 = scalar.value > 0xFFFF ? 2 : 1
            let start = offset
            offset += length
            let value = scalar.value
            if value < 0x80 {
                if value == 0x20 || (value >= 0x09 && value <= 0x0D) {
                    append(space: true, start: start, end: offset, to: &out)
                } else if value >= 0x41 && value <= 0x5A {
                    append(value + 0x20, start: start, end: offset, to: &out)
                } else {
                    append(value, start: start, end: offset, to: &out)
                }
                continue
            }
            for folded in foldedScalars(for: scalar) {
                if folded == Self.space {
                    append(space: true, start: start, end: offset, to: &out)
                } else {
                    append(folded, start: start, end: offset, to: &out)
                }
            }
        }
        return out
    }

    private func append(_ value: UInt32, start: Int32, end: Int32, to out: inout Folded) {
        out.scalars.append(value)
        out.starts.append(start)
        out.ends.append(end)
    }

    private func append(space: Bool, start: Int32, end: Int32, to out: inout Folded) {
        if out.scalars.last == Self.space {
            out.ends[out.ends.count - 1] = end  // collapse the run
        } else {
            append(Self.space, start: start, end: end, to: &out)
        }
    }

    private mutating func foldedScalars(for scalar: Unicode.Scalar) -> [UInt32] {
        if let cached = cache[scalar.value] { return cached }
        var result: [UInt32] = []
        if scalar.value == 0x00AD || scalar.value == 0x200B || scalar.value == 0xFEFF {
            result = []  // soft hyphen, zero-width space, BOM: invisible
        } else if scalar.properties.isWhitespace {
            result = [Self.space]
        } else if scalar.properties.generalCategory == .nonspacingMark {
            result = []
        } else {
            let compat = String(scalar).decomposedStringWithCompatibilityMapping
            let folded = compat.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                        locale: nil)
            for s in folded.unicodeScalars where s.properties.generalCategory != .nonspacingMark {
                result.append(s.properties.isWhitespace ? Self.space : s.value)
            }
        }
        cache[scalar.value] = result
        return result
    }

    /// Non-overlapping matches of `query` (already folded), as UTF-16 ranges of the original text.
    static func matches(of query: [UInt32], in text: Folded) -> [NSRange] {
        let m = query.count
        let n = text.scalars.count
        guard m > 0, n >= m else { return [] }
        var found: [NSRange] = []
        let first = query[0]
        var i = 0
        text.scalars.withUnsafeBufferPointer { haystack in
            query.withUnsafeBufferPointer { needle in
                while i <= n - m {
                    if haystack[i] == first {
                        var j = 1
                        while j < m, haystack[i + j] == needle[j] { j += 1 }
                        if j == m {
                            let start = Int(text.starts[i])
                            let end = Int(text.ends[i + m - 1])
                            found.append(NSRange(location: start, length: end - start))
                            i += m
                            continue
                        }
                    }
                    i += 1
                }
            }
        }
        return found
    }

    /// Context around `range` in `text` (UTF-16 range): about 40 characters before and 70 after,
    /// whitespace collapsed, cut at word boundaries and marked with "…" where truncated.
    static func snippet(in text: NSString, around range: NSRange, before: Int = 40, after: Int = 70) -> SearchSnippet {
        let length = text.length
        let loc = min(max(range.location, 0), length)
        let end = min(range.location + range.length, length)
        var beforeStart = max(0, loc - before)
        var afterEnd = min(length, end + after)
        if beforeStart > 0 { beforeStart = text.rangeOfComposedCharacterSequence(at: beforeStart).location }
        if afterEnd < length { afterEnd = NSMaxRange(text.rangeOfComposedCharacterSequence(at: afterEnd - 1)) }

        var beforeText = text.substring(with: NSRange(location: beforeStart, length: loc - beforeStart))
        var afterText = text.substring(with: NSRange(location: end, length: afterEnd - end))
        let matchText = text.substring(with: NSRange(location: loc, length: end - loc))

        beforeText = collapse(beforeText)
        afterText = collapse(afterText)
        if beforeStart > 0 {
            // Drop a cut-off first word.
            if let space = beforeText.firstIndex(of: " "), beforeText.distance(from: beforeText.startIndex, to: space) < 12 {
                beforeText = String(beforeText[beforeText.index(after: space)...])
            }
            beforeText = "…" + beforeText
        }
        if afterEnd < length {
            if let space = afterText.lastIndex(of: " "), afterText.distance(from: space, to: afterText.endIndex) < 12 {
                afterText = String(afterText[..<space])
            }
            afterText += "…"
        }
        return SearchSnippet(before: beforeText, match: collapse(matchText), after: afterText)
    }

    private static func collapse(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        var lastWasSpace = false
        for character in string {
            if character.isWhitespace || character.isNewline {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(character)
                lastWasSpace = false
            }
        }
        return out
    }
}

// MARK: - PDF search

/// Streams text hits from a private `PDFDocument`.
nonisolated enum PDFTextSearch {
    /// Maximum text hits per search run; "Show more results…" continues from where it stopped.
    static let defaultHitCap = 500

    /// Searches the PDF at `url` page by page, starting at `startPage`.
    ///
    /// The returned stream yields `SearchEvent`s (batched: the first hit is delivered at once,
    /// later ones at most every ~250 ms (each batch re-renders the result list)) and finishes after `.finished`. Cancelling the consuming
    /// task, or dropping the stream, cancels the search within one page. A run stops at the
    /// first page boundary after `hitCap` hits, so it can exceed the cap by one page's hits.
    ///
    /// - Parameter pageDelay: test hook; sleeps this long after each page (slows the search so a
    ///   UI test can cancel it midway).
    static func stream(url: URL, query: String, startPage: Int = 0, hitCap: Int = defaultHitCap,
                       pageDelay: Duration = .zero) -> AsyncStream<SearchEvent> {
        AsyncStream(SearchEvent.self, bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                run(url: url, query: query, startPage: startPage, hitCap: hitCap, pageDelay: pageDelay,
                    emit: { continuation.yield($0) })
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(url: URL, query: String, startPage: Int, hitCap: Int, pageDelay: Duration,
                            emit: (SearchEvent) -> Void) {
        var matcher = SearchTextMatcher()
        let needle = matcher.foldQuery(query)
        guard !needle.isEmpty, let document = PDFDocument(url: url) else {
            emit(.finished(SearchCompletion(reason: .failed, nextPage: startPage)))
            return
        }
        let total = document.pageCount
        var pending: [SearchHit] = []
        var totalHits = 0
        var lastEmit = ContinuousClock.now - .seconds(1)
        var sentFirst = false
        let flushInterval = Duration.milliseconds(250)
        let sleepNanos = pageDelay > .zero ? pageDelay : nil

        func flush(pagesSearched: Int, force: Bool) {
            let now = ContinuousClock.now
            guard force || now - lastEmit >= flushInterval || (!pending.isEmpty && !sentFirst) else { return }
            if !pending.isEmpty {
                emit(.hits(pending))
                sentFirst = true
                pending = []
            }
            emit(.progress(pagesSearched: pagesSearched, totalPages: total))
            lastEmit = now
        }

        var page = max(0, startPage)
        while page < total {
            if Task.isCancelled { return }
            autoreleasepool {
                guard let pdfPage = document.page(at: page), let text = pdfPage.string, !text.isEmpty else { return }
                let folded = matcher.fold(text)
                let ranges = SearchTextMatcher.matches(of: needle, in: folded)
                guard !ranges.isEmpty else { return }
                let nsText = text as NSString
                for (ordinal, range) in ranges.enumerated() {
                    let rects = pdfPage.selection(for: range)?.selectionsByLine()
                        .map { $0.bounds(for: pdfPage) }
                        .filter { !$0.isEmpty } ?? []
                    pending.append(SearchHit(pageIndex: page, rects: rects,
                                             snippet: SearchTextMatcher.snippet(in: nsText, around: range),
                                             ordinal: ordinal))
                    totalHits += 1
                }
            }
            page += 1
            if let delay = sleepNanos {
                Thread.sleep(forTimeInterval: Double(delay.components.seconds)
                             + Double(delay.components.attoseconds) / 1e18)
            }
            if totalHits >= hitCap, page < total {
                if Task.isCancelled { return }
                flush(pagesSearched: page, force: true)
                emit(.finished(SearchCompletion(reason: .capped, nextPage: page)))
                return
            }
            flush(pagesSearched: page, force: false)
        }
        if Task.isCancelled { return }
        flush(pagesSearched: total, force: true)
        emit(.finished(SearchCompletion(reason: .completed, nextPage: total)))
    }
}
