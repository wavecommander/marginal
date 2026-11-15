import Foundation

/// Markdown as HTML, from Foundation's Markdown parser (`AttributedString(markdown:)` with the
/// full syntax): each run's presentation intents say which blocks it sits in, and the blocks are
/// opened and closed as the identities change from run to run.
///
/// Decisions the plan left open:
/// - Headings get an `id` made from their text (lower case, letters, digits and hyphens, the
///   GitHub way), so `[see](#a-heading)` links work; the first `#` heading is the title.
/// - Pictures: only `data:` URLs are inside the file and are shown. Anything else would need a
///   file that was not imported or the network, so the picture's description (its alt text) is
///   shown in its place, in italics, or nothing when it has none.
/// - Links: web and mail links are kept; `#fragment` links go to the heading; links to other
///   files are kept as plain text.
/// - Raw HTML in the Markdown is passed through (scripts do not run and nothing is fetched).
nonisolated enum MarkdownHTML {
    struct Result: Equatable {
        var html: String
        /// The first level-1 heading's text.
        var title: String?
    }

    static func html(_ markdown: String) throws -> Result {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        let attributed = try AttributedString(markdown: markdown, options: options)
        let runs = attributed.runs

        // Pass 1: heading texts, for ids and the title.
        var headingText: [Int: String] = [:]
        var headingOrder: [Int] = []
        var headingLevel: [Int: Int] = [:]
        for run in runs {
            guard let intent = run.presentationIntent else { continue }
            for component in intent.components {
                if case let .header(level) = component.kind {
                    if headingText[component.identity] == nil { headingOrder.append(component.identity) }
                    headingText[component.identity, default: ""] += String(attributed[run.range].characters)
                    headingLevel[component.identity] = level
                }
            }
        }
        var ids: [Int: String] = [:]
        var used: Set<String> = []
        for identity in headingOrder {
            let base = slug(headingText[identity] ?? "")
            var candidate = base.isEmpty ? "section" : base
            var number = 1
            while used.contains(candidate) {
                candidate = "\(base.isEmpty ? "section" : base)-\(number)"
                number += 1
            }
            used.insert(candidate)
            ids[identity] = candidate
        }
        let title = headingOrder.first { headingLevel[$0] == 1 }
            .flatMap { headingText[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // Pass 2: the HTML.
        var out = ""
        var open: [PresentationIntent.IntentType] = []
        var tableColumns: [Int: [PresentationIntent.TableColumn]] = [:]
        var headerRows: Set<Int> = []

        func openTag(_ component: PresentationIntent.IntentType, parents: [PresentationIntent.IntentType]) -> String {
            switch component.kind {
            case .paragraph:
                return "<p>"
            case let .header(level):
                let level = min(6, max(1, level))
                return "<h\(level) id=\"\(ids[component.identity] ?? "")\">"
            case .orderedList:
                return "<ol>"
            case .unorderedList:
                return "<ul>"
            case let .listItem(ordinal):
                if let parent = parents.last, case .orderedList = parent.kind { return "<li value=\"\(ordinal)\">" }
                return "<li>"
            case let .codeBlock(hint):
                let language = hint.map { " class=\"language-\(WebTextDecoding.escapeHTML($0))\"" } ?? ""
                return "<pre><code\(language)>"
            case .blockQuote:
                return "<blockquote>"
            case .thematicBreak:
                return "<hr>"
            case let .table(columns):
                tableColumns[component.identity] = columns
                return "<table>"
            case .tableHeaderRow:
                headerRows.insert(component.identity)
                return "<tr>"
            case .tableRow:
                return "<tr>"
            case let .tableCell(column):
                let inHeader = parents.contains { headerRows.contains($0.identity) }
                let tag = inHeader ? "th" : "td"
                let table = parents.last { if case .table = $0.kind { return true } else { return false } }
                let alignment = table.flatMap { tableColumns[$0.identity] }.flatMap { column < $0.count ? $0[column].alignment : nil }
                switch alignment {
                case .center: return "<\(tag) style=\"text-align: center\">"
                case .right: return "<\(tag) style=\"text-align: right\">"
                default: return "<\(tag)>"
                }
            @unknown default:
                return "<div>"
            }
        }

        func closeTag(_ component: PresentationIntent.IntentType, parents: [PresentationIntent.IntentType]) -> String {
            switch component.kind {
            case .paragraph:
                return "</p>\n"
            case let .header(level): return "</h\(min(6, max(1, level)))>\n"
            case .orderedList: return "</ol>\n"
            case .unorderedList: return "</ul>\n"
            case .listItem: return "</li>\n"
            case .codeBlock: return "</code></pre>\n"
            case .blockQuote: return "</blockquote>\n"
            case .thematicBreak: return "\n"
            case .table: return "</table>\n"
            case .tableHeaderRow, .tableRow: return "</tr>\n"
            case .tableCell:
                let inHeader = parents.contains { headerRows.contains($0.identity) }
                return inHeader ? "</th>" : "</td>"
            @unknown default: return "</div>"
            }
        }

        for run in runs {
            let blocks = Array((run.presentationIntent?.components ?? []).reversed())  // outermost first
            var shared = 0
            while shared < min(open.count, blocks.count), open[shared].identity == blocks[shared].identity { shared += 1 }
            while open.count > shared {
                let closing = open.removeLast()
                out += closeTag(closing, parents: open)
            }
            for block in blocks[shared...] {
                out += openTag(block, parents: open)
                open.append(block)
            }
            // A thematic break's run carries a stand-in character; the `<hr>` is the break.
            if let innermost = blocks.last, case .thematicBreak = innermost.kind { continue }
            out += inline(run, in: attributed, codeBlock: blocks.contains { if case .codeBlock = $0.kind { return true } else { return false } })
        }
        while let closing = open.popLast() { out += closeTag(closing, parents: open) }
        return Result(html: out, title: title)
    }

    private static func inline(_ run: AttributedString.Runs.Run, in attributed: AttributedString, codeBlock: Bool) -> String {
        let raw = String(attributed[run.range].characters)
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.blockHTML) || intent.contains(.inlineHTML) { return raw }
        if intent.contains(.lineBreak) { return "<br>" }
        if intent.contains(.softBreak) { return codeBlock ? "\n" : " " }
        if codeBlock { return WebTextDecoding.escapeHTML(raw) }
        if let image = run.imageURL {
            if image.scheme?.lowercased() == "data" {
                return "<img src=\"\(WebTextDecoding.escapeHTML(image.absoluteString))\" alt=\"\(WebTextDecoding.escapeHTML(raw))\">"
            }
            let alt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return alt.isEmpty ? "" : "<span class=\"tt-image-alt\">\(WebTextDecoding.escapeHTML(alt))</span>"
        }
        var html = WebTextDecoding.escapeHTML(raw)
        if intent.contains(.code) { html = "<code>\(html)</code>" }
        if intent.contains(.strikethrough) { html = "<del>\(html)</del>" }
        if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
        if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
        if let link = run.link {
            let scheme = link.scheme?.lowercased()
            if ["http", "https", "mailto"].contains(scheme ?? "") {
                html = "<a href=\"\(WebTextDecoding.escapeHTML(link.absoluteString))\">\(html)</a>"
            } else if scheme == nil, link.relativeString.hasPrefix("#") {
                html = "<a href=\"\(WebTextDecoding.escapeHTML(link.relativeString))\">\(html)</a>"
            }
        }
        return html
    }

    /// GitHub-style heading anchor: lower case, punctuation removed, spaces to hyphens.
    static func slug(_ text: String) -> String {
        var out = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                out.append(character)
            } else if character == " " {
                out.append("-")
            }
        }
        return out
    }
}
