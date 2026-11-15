import CoreGraphics
import Foundation

// Resolves outline targets and links to pages of the joined document, by searching the printed
// parts for the target's text near the page its position suggests (the print path keeps no
// element positions: F0 finding 2). Shared by every web-family converter: an EPUB's table of
// contents, a document's own headings, a deck's slide titles, and links in all of them.

/// How the outline entries were placed.
nonisolated struct WebOutlineStatistics: Sendable, Equatable {
    var exact = 0
    var estimated = 0
    var missingFragment = 0
    var dropped = 0
}

/// How the links were placed.
nonisolated struct WebLinkStatistics: Sendable, Equatable {
    var internalFound = 0
    var internalPlaced = 0
    var externalFound = 0
    var externalPlaced = 0
    /// Why each dropped link was dropped.
    var dropped: [String] = []
}

nonisolated struct WebTargetLocator {
    struct Key: Hashable {
        /// Index into `printed` of the document's first part.
        var chapter: Int
        var fragment: String?
    }

    enum Resolution {
        /// Found by text (or the document start, which is exact).
        case exact(Int)
        /// From the position estimate only.
        case estimated(Int)
        /// The fragment is not in the document.
        case missing
    }

    let printed: [WebPrintedPart]
    let starts: [Int]
    let total: Int
    /// Each document's first part, by path.
    let chapterByPath: [String: Int]
    private var cache: [Key: Resolution] = [:]
    private var texts: [Int: WebPrintedText] = [:]
    var outlineStatistics = WebOutlineStatistics()
    var linkStatistics = WebLinkStatistics()

    init(printed: [WebPrintedPart]) {
        self.printed = printed
        var starts: [Int] = []
        var running = 0
        for part in printed {
            starts.append(running)
            running += part.pageCount
        }
        self.starts = starts
        total = running
        var byPath: [String: Int] = [:]
        for (index, part) in printed.enumerated() where byPath[part.path] == nil {
            byPath[part.path] = index
        }
        chapterByPath = byPath
    }

    /// A part's first page in the joined document (the next part's for an empty one).
    func startPage(_ part: Int) -> Int { min(starts[part], max(0, total - 1)) }

    mutating func text(_ part: Int) -> WebPrintedText? {
        if let cached = texts[part] { return cached }
        // Keep one part open at a time: lookups arrive grouped by part.
        texts.removeAll()
        guard let text = WebPrintedText(url: printed[part].pdf) else { return nil }
        texts[part] = text
        return text
    }

    mutating func resolve(_ key: Key) -> Resolution {
        if let cached = cache[key] { return cached }
        let result = compute(key)
        cache[key] = result
        return result
    }

    private mutating func compute(_ key: Key) -> Resolution {
        let start = startPage(key.chapter)
        guard let fragment = key.fragment, !fragment.isEmpty else { return .exact(start) }
        // The fragment may be in any segment of the document.
        let path = printed[key.chapter].path
        var part = key.chapter
        var found: WebDocumentLayout.Anchor?
        while part < printed.count, printed[part].path == path {
            if let anchor = printed[part].layout.anchors.first(where: { $0.id == fragment }) {
                found = anchor
                break
            }
            part += 1
        }
        guard let anchor = found else { return .missing }
        let partStart = startPage(part)
        guard printed[part].pageCount > 0, let printedText = text(part) else { return .exact(partStart) }
        let estimate = printedText.estimatedPage(forFraction: anchor.top)
        if !anchor.text.isEmpty, let page = printedText.page(forText: anchor.text, near: estimate) {
            return .exact(partStart + page)
        }
        if anchor.text.isEmpty, !anchor.following.isEmpty, let page = printedText.page(forText: anchor.following, near: estimate, window: 1) {
            return .exact(partStart + page)
        }
        return .estimated(partStart + estimate)
    }

    // MARK: Outline from headings

    /// An entry before nesting: its level (1 = top) and its page in the joined document.
    struct FlatEntry: Equatable {
        var level: Int
        var title: String
        var pageIndex: Int
    }

    /// The outline from the headings collected while printing (`WebPrintedPart.headings`), each
    /// placed on the page that shows its text nearest where the web view put it, nested by level.
    mutating func headingOutline() -> [WebPDFOutlineItem] {
        var flat: [FlatEntry] = []
        for (index, part) in printed.enumerated() where part.pageCount > 0 && !part.headings.isEmpty {
            guard let printedText = text(index) else { continue }
            for heading in part.headings {
                let estimate = printedText.estimatedPage(forFraction: heading.top)
                let page: Int
                if let found = printedText.page(forText: heading.text, near: estimate, window: 2) {
                    page = found
                    outlineStatistics.exact += 1
                } else {
                    page = estimate
                    outlineStatistics.estimated += 1
                }
                flat.append(FlatEntry(level: heading.level, title: heading.text, pageIndex: starts[index] + page))
            }
        }
        return Self.nest(flat)
    }

    /// Places headings known only by their text and order (read from the original file rather
    /// than the web page): each is looked for from the previous one's page onwards. A heading
    /// that is not found is dropped.
    mutating func outline(ofHeadingsInOrder headings: [(level: Int, title: String)]) -> [WebPDFOutlineItem] {
        var flat: [FlatEntry] = []
        var part = 0
        var page = 0
        for heading in headings {
            var found: (part: Int, page: Int)?
            var searchPart = part
            var from = page
            while found == nil, searchPart < printed.count {
                if printed[searchPart].pageCount > 0, let printedText = text(searchPart),
                   let expression = WebTextPattern.expression(for: heading.title, maxWords: 8) {
                    let hits = printedText.matches(of: expression, pages: from...max(from, printedText.pageCount - 1))
                    if let first = hits.first { found = (searchPart, first.page) }
                }
                searchPart += 1
                from = 0
            }
            guard let found else {
                outlineStatistics.dropped += 1
                continue
            }
            outlineStatistics.exact += 1
            part = found.part
            page = found.page
            flat.append(FlatEntry(level: heading.level, title: heading.title, pageIndex: starts[found.part] + found.page))
        }
        return Self.nest(flat)
    }

    /// Nests entries by level: each entry becomes a child of the nearest earlier entry with a
    /// smaller level. Skipped levels (an `h1` followed by an `h3`) nest one step.
    static func nest(_ flat: [FlatEntry]) -> [WebPDFOutlineItem] {
        var index = 0
        func children(above level: Int) -> [WebPDFOutlineItem] {
            var items: [WebPDFOutlineItem] = []
            while index < flat.count, flat[index].level > level {
                let entry = flat[index]
                index += 1
                var item = WebPDFOutlineItem(title: entry.title, pageIndex: entry.pageIndex)
                item.children = children(above: entry.level)
                items.append(item)
            }
            return items
        }
        var roots: [WebPDFOutlineItem] = []
        while index < flat.count {
            roots += children(above: 0)
        }
        return roots
    }

    // MARK: Links

    /// The links that could be placed: their text found exactly once near where the web view put
    /// them, and (for internal links) their target found by text. Everything else is dropped.
    mutating func links() -> [WebPDFLink] {
        struct Pending {
            var page: Int
            var rects: [CGRect]
            var target: Key?
            var url: URL?
        }
        var pending: [Pending] = []
        for (index, part) in printed.enumerated() where part.pageCount > 0 {
            for link in part.layout.links {
                guard let url = URL(string: link.href) else { continue }
                var target: Key?
                var external: URL?
                if let path = WebPDFRenderer.path(of: url) {
                    linkStatistics.internalFound += 1
                    guard let destination = chapterByPath[path] else {
                        linkStatistics.dropped.append("\(link.href): target not in the document")
                        continue
                    }
                    let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
                    target = Key(chapter: destination, fragment: fragment)
                } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    linkStatistics.externalFound += 1
                    external = url
                } else {
                    continue
                }
                guard !link.text.isEmpty, let printedText = text(index) else {
                    linkStatistics.dropped.append("\(link.href): no link text")
                    continue
                }
                let estimate = printedText.estimatedPage(forFraction: link.top)
                guard let found = printedText.linkRects(text: link.text, before: link.before, near: estimate) else {
                    linkStatistics.dropped.append("\(link.href): '\(link.text.prefix(30))' after '\(link.before.suffix(30))' "
                        + "not found once near page \(estimate + 1) of \(part.path)")
                    continue
                }
                pending.append(Pending(page: starts[index] + found.page, rects: found.rects, target: target, url: external))
            }
        }
        var links: [WebPDFLink] = []
        for item in pending.sorted(by: { ($0.target?.chapter ?? -1) < ($1.target?.chapter ?? -1) }) {
            if let url = item.url {
                links.append(WebPDFLink(pageIndex: item.page, rects: item.rects, target: .url(url)))
                linkStatistics.externalPlaced += 1
            } else if let key = item.target {
                // A link whose target could only be estimated would risk landing a page out.
                guard case let .exact(page) = resolve(key) else {
                    linkStatistics.dropped.append("target \(printed[key.chapter].path)#\(key.fragment ?? ""): not found by text")
                    continue
                }
                links.append(WebPDFLink(pageIndex: item.page, rects: item.rects, target: .page(page)))
                linkStatistics.internalPlaced += 1
            }
        }
        return links.sorted { $0.pageIndex < $1.pageIndex }
    }
}
