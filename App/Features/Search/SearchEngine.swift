import Foundation
import os
import PDFKit
import ReaderCore

// The search engine: in-book text search that streams results, can be cancelled, never
// touches the on-screen document and never holds more than a few dozen pages' text.
//
// ## Why not `PDFDocument.beginFindString`
// Checked against the installed SDK headers and by experiment (macOS PDFKit, same API): the
// asynchronous find runs in slices on the run loop of the thread that started it (nothing happens
// until that run loop spins; every callback arrives on that thread, i.e. the main thread in an
// app), it took about five times as long as the page loop below on `large.pdf` (15 s against
// 3 s), its documented options are only case-insensitive, literal and backwards (no diacritic
// folding), and it cannot resume from a page. So the engine scans page by page itself.
//
// ## Threading and memory
// A search runs on a GCD worker thread (not the Swift cooperative pool, which a multi-second
// synchronous loop would starve) over **private** `PDFDocument` instances opened from the file:
// the on-screen document is never touched, and no PDFKit object leaves the worker. Only
// `Sendable` values (`SearchHit`, `SearchEvent`) cross to the caller.
//
// A `PDFDocument` keeps every page it has handed out, with that page's text, until the document
// is released: scanning all 1,500 pages of `large.pdf` through one instance peaks at about
// 485 MB (measured, phys_footprint). The worker therefore releases its document and opens a
// fresh one every `pagesPerDocument` pages (peak about 24 MB, about 10% slower), and reads one
// page's text at a time (`PDFPage.string`), never the whole document's.
//
// ## Scanned pages (S2)
// One search path reads each page from whichever source has text (design, "Page text for
// search"): the file's own text when the page has text of its own (`PageTextPolicy`, asked of the
// worker's private document, which never has PDFKit's Live Text), otherwise the page's
// `RecognisedPage` when the book's recognition has saved one. Matching, snippets, the cap and
// cancellation are the same; a recognised hit's rects come from the recognised words' boxes
// (`RecognisedPage.rects(forUTF16Range:)`). Pages searched with no recognised text are noted in
// a `RecognisedPageLedger`, so `SearchModel` can search them again when they are recognised
// after the scan has passed them.

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
    /// Hits found since the previous event, ascending by page, and how many pages had been
    /// scanned from the start of the book when they were sent (the index of the next page to
    /// scan). The two travel together: a consumer that stops between this event and the
    /// `progress` that follows it would otherwise hold these hits with an older resume point,
    /// and resuming there would find them again.
    case hits([SearchHit], pagesSearched: Int)
    /// `pagesSearched` is the number of pages scanned from the start of the book, i.e. the index
    /// of the next page to scan (so a search can resume there).
    case progress(pagesSearched: Int, totalPages: Int)
    /// The last event of a run that was not cancelled.
    case finished(SearchCompletion)
}

nonisolated struct SearchCompletion: Hashable, Sendable {
    enum Reason: Hashable, Sendable {
        /// Every page was searched.
        case completed
        /// The hit cap was reached; `nextPage` is where a continuation resumes.
        case capped
        /// The document could not be opened, or the query folds to nothing.
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
/// expanded. A word hyphenated across a line break ("eigen-\nvalue") is not joined.
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
                    appendSpace(start: start, end: offset, to: &out)
                } else if value >= 0x41 && value <= 0x5A {
                    append(value + 0x20, start: start, end: offset, to: &out)
                } else {
                    append(value, start: start, end: offset, to: &out)
                }
                continue
            }
            for folded in foldedScalars(for: scalar) {
                if folded == Self.space {
                    appendSpace(start: start, end: offset, to: &out)
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

    private func appendSpace(start: Int32, end: Int32, to out: inout Folded) {
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

// MARK: - Recognised text (scanned books)

/// Where the search worker finds a scanned book's recognised pages.
nonisolated struct RecognisedTextSource: Sendable {
    /// The raw store (synchronous; read on the worker thread only).
    var store: any RecognisedTextStore
    var bookID: UUID
    /// Notes pages searched without recognised text, for searching them again later.
    var ledger: RecognisedPageLedger?

    /// The page's recognised text, or `nil` (not recognised yet, or unreadable).
    func page(_ index: Int) -> RecognisedPage? {
        (try? store.recognisedPage(bookID: bookID, pageIndex: index)) ?? nil
    }
}

/// The pages of one search (one query, across its continuations) that were searched without
/// recognised text, and the pages announced as recognised since it started.
///
/// The worker and `SearchModel` meet here under one lock, so a page recognised while the scan
/// passes it is searched exactly once with its recognised text: either the worker finds the page
/// (or, told it was announced meanwhile, reads it again), or the model sees it was missed and
/// searches it again (`SearchModel`'s catch-up).
nonisolated final class RecognisedPageLedger: Sendable {
    private struct State {
        var missed: Set<Int> = []
        var announced: Set<Int> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Worker: `page` was searched without recognised text. Returns `true` when the page has
    /// been announced as recognised meanwhile: the worker reads it again instead (and it is
    /// not noted as missed).
    func searchedWithoutRecognisedText(_ page: Int) -> Bool {
        state.withLock { state in
            if state.announced.contains(page) { return true }
            state.missed.insert(page)
            return false
        }
    }

    /// Model: `page` has been recognised. Returns `true` when it was searched without
    /// recognised text, so it must be searched again (once: it is no longer noted as missed).
    func pageRecognised(_ page: Int) -> Bool {
        state.withLock { state in
            if state.missed.remove(page) != nil { return true }
            state.announced.insert(page)
            return false
        }
    }

    /// Pages searched without recognised text and not recognised since (tests).
    var missedPages: Set<Int> { state.withLock { $0.missed } }
}

// MARK: - Cancellation and diagnostics

/// A thread-safe cancellation flag shared by a stream's consumer side and its worker.
nonisolated final class SearchCancellation: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}

/// Process-wide counters of the engine's live resources, so tests (and a debugger) can assert
/// that a completed or cancelled search leaves no worker and no `PDFDocument` behind and that
/// cancelled work stops. Cheap: one uncontended lock per page.
nonisolated enum SearchDiagnostics {
    struct Snapshot: Equatable, Sendable {
        /// Workers (search runs) whose loop has not returned yet.
        var liveWorkers = 0
        /// Private `PDFDocument`s the engine has opened and not yet released.
        var liveDocuments = 0
        /// Pages scanned since launch, across all runs (only ever grows).
        var pagesScanned = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: Snapshot())

    static var snapshot: Snapshot { state.withLock { $0 } }

    fileprivate static func update(_ body: @Sendable (inout Snapshot) -> Void) {
        state.withLock { body(&$0) }
    }
}

// MARK: - PDF search

/// Streams text hits from private `PDFDocument`s opened from the book's file.
nonisolated enum PDFTextSearch {
    /// Text hits per run. A run stops at the first page boundary at or after this many hits
    /// (so it can exceed the cap by the hits of one page) and finishes `.capped` with the page
    /// to resume from; the UI offers "Show More Results", which runs again from there.
    static let defaultHitCap = 500

    /// Pages scanned with one private `PDFDocument` before it is released and the file reopened
    /// (bounds memory; see the file comment).
    static let pagesPerDocument = 32

    /// Hits are delivered in batches: the first hit at once, then at most every this long, so the
    /// result list re-renders a few times a second rather than once per page.
    static let batchInterval: Duration = .milliseconds(250)

    /// Searches the PDF at `url` page by page from `startPage` and streams `SearchEvent`s.
    ///
    /// The search runs on a GCD worker thread. Ending the stream (cancelling the task that
    /// iterates it, breaking out of the loop, or dropping the stream) cancels the worker, which
    /// stops before its next page and releases its document; a cancelled run yields no
    /// `.finished`. A run that is not cancelled ends with exactly one `.finished`.
    ///
    /// - Parameter pageDelay: test hook (the UI tests' `-searchPageDelayMs`): the worker sleeps
    ///   this long after each page so a search is still running when a test acts on it.
    /// - Parameter recognised: a scanned book's recognised text, read for pages with no text of
    ///   their own (`nil`: the file's text only).
    /// - Parameter onlyPages: search just these pages, in order, then finish `.completed` (for
    ///   searching pages again once they are recognised); `startPage` is then ignored.
    static func stream(url: URL, query: String, startPage: Int = 0, hitCap: Int = defaultHitCap,
                       pageDelay: Duration = .zero, recognised: RecognisedTextSource? = nil,
                       onlyPages: [Int]? = nil) -> AsyncStream<SearchEvent> {
        AsyncStream(SearchEvent.self, bufferingPolicy: .unbounded) { continuation in
            let cancellation = SearchCancellation()
            continuation.onTermination = { _ in cancellation.cancel() }
            SearchDiagnostics.update { $0.liveWorkers += 1 }
            DispatchQueue.global(qos: .userInitiated).async {
                run(url: url, query: query, startPage: startPage, hitCap: hitCap, pageDelay: pageDelay,
                    recognised: recognised, onlyPages: onlyPages,
                    cancellation: cancellation, emit: { continuation.yield($0) })
                // The run has released its document; count it gone before the stream ends, so a
                // consumer that sees the end also sees `liveWorkers` drop.
                SearchDiagnostics.update { $0.liveWorkers -= 1 }
                continuation.finish()
            }
        }
    }

    /// The worker loop. Synchronous; every PDFKit object it creates stays on this thread.
    private static func run(url: URL, query: String, startPage: Int, hitCap: Int, pageDelay: Duration,
                            recognised: RecognisedTextSource?, onlyPages: [Int]?,
                            cancellation: SearchCancellation, emit: (SearchEvent) -> Void) {
        var matcher = SearchTextMatcher()
        let needle = matcher.foldQuery(query)
        var pages = PageSource(url: url)
        defer { pages.close() }
        guard !needle.isEmpty, let total = pages.pageCount else {
            emit(.finished(SearchCompletion(reason: .failed, nextPage: startPage)))
            return
        }
        var pending: [SearchHit] = []
        var totalHits = 0
        var lastEmit = ContinuousClock.now
        var sentFirst = false

        func flush(pagesSearched: Int, force: Bool) {
            let now = ContinuousClock.now
            let firstHitWaiting = !sentFirst && !pending.isEmpty
            guard force || firstHitWaiting || now - lastEmit >= batchInterval else { return }
            if !pending.isEmpty {
                emit(.hits(pending, pagesSearched: pagesSearched))
                sentFirst = true
                pending = []
            }
            emit(.progress(pagesSearched: pagesSearched, totalPages: total))
            lastEmit = now
        }

        /// Searches one page: its recognised text when it has no text of its own and has been
        /// recognised, otherwise the file's text.
        func search(_ page: Int) {
            autoreleasepool {
                guard let pdfPage = pages.page(at: page) else { return }
                let fileText = pdfPage.string
                if let recognised, !PageTextPolicy.hasOwnText(fileText) {
                    var found = recognised.page(page)
                    if found == nil, recognised.ledger?.searchedWithoutRecognisedText(page) == true {
                        found = recognised.page(page)  // recognised while this page was being read
                    }
                    if let found {
                        searchRecognised(found)
                        return
                    }
                }
                guard let text = fileText, !text.isEmpty else { return }
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
        }

        /// The same matching and snippets over recognised text; the rects come from the
        /// recognised words' boxes.
        func searchRecognised(_ recognisedPage: RecognisedPage) {
            let text = recognisedPage.text
            guard !text.isEmpty else { return }
            let ranges = SearchTextMatcher.matches(of: needle, in: matcher.fold(text))
            guard !ranges.isEmpty else { return }
            let nsText = text as NSString
            for (ordinal, range) in ranges.enumerated() {
                let rects = recognisedPage.rects(forUTF16Range: range.location..<NSMaxRange(range))
                pending.append(SearchHit(pageIndex: recognisedPage.pageIndex, rects: rects,
                                         snippet: SearchTextMatcher.snippet(in: nsText, around: range),
                                         ordinal: ordinal))
                totalHits += 1
            }
        }

        if let onlyPages {
            for page in onlyPages where page >= 0 && page < total {
                if cancellation.isCancelled { return }
                search(page)
                SearchDiagnostics.update { $0.pagesScanned += 1 }
            }
            if cancellation.isCancelled { return }
            flush(pagesSearched: total, force: true)
            emit(.finished(SearchCompletion(reason: .completed, nextPage: total)))
            return
        }

        var page = max(0, startPage)
        while page < total {
            if cancellation.isCancelled { return }
            search(page)
            page += 1
            SearchDiagnostics.update { $0.pagesScanned += 1 }
            if pageDelay > .zero {
                Thread.sleep(forTimeInterval: Double(pageDelay.components.seconds)
                             + Double(pageDelay.components.attoseconds) / 1e18)
            }
            if cancellation.isCancelled { return }
            if totalHits >= hitCap, page < total {
                flush(pagesSearched: page, force: true)
                emit(.finished(SearchCompletion(reason: .capped, nextPage: page)))
                return
            }
            flush(pagesSearched: page, force: false)
        }
        flush(pagesSearched: total, force: true)
        emit(.finished(SearchCompletion(reason: .completed, nextPage: total)))
    }
}

/// The worker's pages: a private `PDFDocument` replaced every `PDFTextSearch.pagesPerDocument`
/// pages so the text PDFKit caches per page is released as the scan moves on.
private nonisolated struct PageSource {
    let url: URL
    private var document: PDFDocument?
    private var pagesFromDocument = 0

    init(url: URL) {
        self.url = url
    }

    /// The page count, opening the first document; `nil` when the file cannot be opened.
    var pageCount: Int? {
        mutating get {
            if document == nil { reopen() }
            return document?.pageCount
        }
    }

    mutating func page(at index: Int) -> PDFPage? {
        if document == nil || pagesFromDocument >= PDFTextSearch.pagesPerDocument { reopen() }
        pagesFromDocument += 1
        return document?.page(at: index)
    }

    mutating func close() {
        guard document != nil else { return }
        document = nil
        SearchDiagnostics.update { $0.liveDocuments -= 1 }
    }

    private mutating func reopen() {
        close()
        pagesFromDocument = 0
        autoreleasepool {
            document = PDFDocument(url: url)
        }
        if document != nil { SearchDiagnostics.update { $0.liveDocuments += 1 } }
    }
}
