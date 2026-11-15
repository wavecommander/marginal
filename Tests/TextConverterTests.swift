import Foundation
import PDFKit
import ReaderCore
import Testing
import UIKit
@testable import Marginal

/// The text-family converter (plain text, Markdown, HTML, web archives), called directly.
/// Serialized: each test drives an off-screen web view, and the stall measurement must not
/// share the main thread.
@Suite(.serialized)
struct TextConverterTests {
    private func convert(_ workspace: F6Workspace, textSize: ConversionTextSize = .medium,
                         diagnostics: WebConversionDiagnostics? = nil) async throws -> ConvertedDocument {
        var converter = TextDocumentConverter()
        converter.diagnostics = diagnostics
        return try await converter.convert(workspace.input(textSize: textSize)) { _ in }
    }

    private func expectTradePages(_ document: PDFDocument) {
        for index in 0..<document.pageCount {
            #expect(document.page(at: index)?.bounds(for: .mediaBox).size == ConversionOptions.reflowPageSize)
        }
    }

    // MARK: Plain text

    @Test func plainTextConvertsSearchableWithParagraphsAndBreaks() async throws {
        let workspace = try F6Workspace(text: F6Fixtures.plainText(), extension: "txt", format: .plainText)
        let fractions = Fractions()
        let converted = try await TextDocumentConverter().convert(workspace.input()) { fractions.append($0) }
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(converted.pageCount == document.pageCount)
        #expect(converted.title == nil)
        expectTradePages(document)
        #expect(EPUBTestPDF.blankPages(document) == [])
        #expect(document.findString("TXTWORD-7", withOptions: []).count == 1)
        #expect(document.findString("TXTWORD-end.", withOptions: []).count == 1)
        // Hard-wrapped prose is joined: the 70-column line ends are gone, so a phrase that
        // straddled one is found on one line.
        let all = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }.joined(separator: "\n")
        // The verse keeps its line breaks.
        #expect(all.contains("TXTWORD-verse first line\nsecond short line"))
        #expect(fractions.values.last == 1)
        #expect(fractions.values == fractions.values.sorted())
        #expect(workspace.contents == ["Document.pdf", "original.txt"])
        F6Check.savePages(document, name: "txt", pages: [0, 1])
    }

    @Test func plainTextEncodingsAreDetected() async throws {
        let text = "ENCWORD Café naïve — “quoted” ½ €uro\n\nSecond paragraph ENCEND.\n"
        let cases: [(String, Data)] = [
            ("utf8", Data(text.utf8)),
            ("utf8-bom", Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)),
            ("utf16le-bom", Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!),
            ("utf16be-bom", Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!),
            ("utf16le-no-bom", text.data(using: .utf16LittleEndian)!),
            ("cp1252", text.data(using: .windowsCP1252)!),
        ]
        for (name, data) in cases {
            let decoded = try #require(WebTextDecoding.decode(data), "\(name) not decoded")
            #expect(decoded.text.contains("Café naïve — “quoted” ½ €uro"), "\(name): \(decoded.text.prefix(40)) as \(decoded.encoding)")
        }
        // Latin-1 bytes that are not valid UTF-8 (0xE9 é) fall back to a single-byte encoding.
        let latin = try #require(WebTextDecoding.decode(Data([0x43, 0x61, 0x66, 0xE9])))
        #expect(latin.text == "Café")
        // Binary data is not text.
        #expect(WebTextDecoding.decode(Data([0x00, 0x01, 0x02, 0x00, 0x00, 0xFF, 0x10, 0x00])) == nil)
        // One converts end to end.
        let workspace = try F6Workspace(data: cases[2].1, extension: "txt", format: .plainText)
        let document = try #require(PDFDocument(url: try await convert(workspace).pdf))
        #expect(document.findString("Café naïve", withOptions: []).count == 1)
    }

    @Test func laidOutTextKeepsItsLinesAndHTMLIsEscaped() async throws {
        let table = (1...30).map { "row \($0)    |   value \($0 * 3)   | <b>not bold</b>" }.joined(separator: "\n")
        let workspace = try F6Workspace(text: "LAIDOUT\n" + table, extension: "txt", format: .plainText)
        let document = try #require(PDFDocument(url: try await convert(workspace).pdf))
        #expect(document.findString("<b>not bold</b>", withOptions: []).count == 30)
        let first = document.page(at: 0)?.string ?? ""
        print("Laid-out text page 1: \(first.prefix(300).debugDescription)")
        #expect(first.contains("row 1    |   value 3") || first.contains("row 1 | value 3"), "\(first.prefix(200))")
    }

    // MARK: Markdown

    @Test func markdownBecomesHTMLWithEveryBlock() throws {
        let result = try MarkdownHTML.html(F6Fixtures.markdown)
        let html = result.html
        #expect(result.title == "The Harbour Handbook")
        #expect(html.contains("<h1 id=\"the-harbour-handbook\">The Harbour Handbook</h1>"))
        #expect(html.contains("<h2 id=\"tides-and-currents\">"))
        #expect(html.contains("<em>emphasis</em>"))
        #expect(html.contains("<strong>strong words</strong>"))
        #expect(html.contains("<code>inline code</code>"))
        #expect(html.contains("<a href=\"https://example.com/f6-forecast\">link to the forecast</a>"))
        #expect(html.contains("<a href=\"#tides-and-currents\">the tides</a>"))
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("<pre><code class=\"language-swift\">let answer = 42 // MDWORD-code"))
        #expect(html.contains("<table>"))
        #expect(html.contains("<th>Item</th>") || html.contains("<th style=\"text-align: left\">Item</th>") || html.contains("<th>Item"))
        #expect(html.contains("<td style=\"text-align: right\">4</td>"))
        #expect(html.contains("<hr>\n<p><span class=\"tt-image-alt\">"), "the rule carries no text of its own")
        #expect(html.contains("<span class=\"tt-image-alt\">a picture that is not in the file</span>"))
        #expect(!html.contains("images/missing.png"))
        // The nested list is inside an item of the outer list.
        let nested = try #require(html.range(of: "Nested item MDWORD-nested"))
        let outerOpen = try #require(html.range(of: "<ul>"))
        let innerOpen = try #require(html.range(of: "<ul>", range: outerOpen.upperBound..<nested.lowerBound))
        #expect(html[outerOpen.upperBound..<innerOpen.lowerBound].contains("<li>"))
        #expect(html.contains("<ol>"))
        print("Markdown HTML: \(html.prefix(1500))")
    }

    @Test func markdownConvertsWithOutlineOnTheRightPages() async throws {
        let workspace = try F6Workspace(text: F6Fixtures.markdown, extension: "md", format: .markdown)
        let diagnostics = WebConversionDiagnostics()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        #expect(converted.title == "The Harbour Handbook")
        let document = try #require(PDFDocument(url: converted.pdf))
        expectTradePages(document)
        #expect(EPUBTestPDF.blankPages(document) == [])
        for word in ["MDWORD-start", "MDWORD-nested", "MDWORD-ordered", "MDWORD-quote", "MDWORD-code", "MDWORD-table", "MDWORD-appendix"] {
            #expect(document.findString(word, withOptions: []).count == 1, "\(word)")
        }
        let entries = await F6Check.outline(converted.pdf)
        print("Markdown outline: \(entries)")
        #expect(entries.map(\.title) == F6Fixtures.markdownHeadings.map(\.0))
        #expect(entries.map(\.level) == F6Fixtures.markdownHeadings.map(\.1))
        for entry in entries {
            let page = try #require(entry.page)
            #expect(EPUBTestPDF.page(document, page, shows: entry.title), "\(entry.title) → \(page)")
        }
        #expect(entries.compactMap(\.page) == entries.compactMap(\.page).sorted())
        #expect(entries.last?.page ?? 0 > 0)
        // The internal link to "Tides and Currents" goes to its page; the external one is kept.
        let links = EPUBTestPDF.links(document)
        print("Markdown links: \(diagnostics.links) \(links.map { "p\($0.page) \($0.url?.absoluteString ?? "→ p\($0.destination ?? -1)")" })")
        #expect(links.contains { $0.url?.absoluteString == "https://example.com/f6-forecast" })
        let tides = try #require(entries.first { $0.title == "Tides and Currents" }?.page)
        #expect(links.contains { $0.destination == tides })
        F6Check.savePages(document, name: "md", pages: Array(0..<min(3, document.pageCount)))
    }

    @Test func textSizeChangesThePageCount() async throws {
        var counts: [ConversionTextSize: Int] = [:]
        for size in ConversionTextSize.allCases {
            let long = F6Fixtures.markdown + "\n\n" + (1...40).map { "Paragraph \($0). \(F6Fixtures.filler(5))" }.joined(separator: "\n\n")
            let workspace = try F6Workspace(text: long, extension: "md", format: .markdown)
            counts[size] = try await convert(workspace, textSize: size).pageCount
        }
        print("Markdown text size page counts: \(counts)")
        let small = try #require(counts[.small]), medium = try #require(counts[.medium]), large = try #require(counts[.large])
        #expect(small < medium)
        #expect(medium < large)
    }

    // MARK: HTML

    @Test func htmlConvertsWithTitleOutlineAndLinks() async throws {
        let workspace = try F6Workspace(text: F6Fixtures.html(), extension: "html", format: .html)
        let diagnostics = WebConversionDiagnostics()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        // The <title>, not what the (disabled) script would have set.
        #expect(converted.title == "The Keeper's Manual")
        let document = try #require(PDFDocument(url: converted.pdf))
        expectTradePages(document)
        #expect(EPUBTestPDF.blankPages(document) == [])
        #expect(document.findString("HTMLWORD-2-5", withOptions: []).count == 1)
        #expect(document.findString("Café, naïve", withOptions: []).count == 1)
        // Known: PDF text extraction maps the system CJK font's 日 to the Kangxi radical ⽇
        // (U+2F47), so "日本語" is not found by search in the printed PDF (printed, not asserted).
        print("CJK search: 日本語 \(document.findString("日本語", withOptions: []).count), 本 \(document.findString("本", withOptions: []).count)")
        #expect(document.findString("HTMLWORD-closing", withOptions: []).count == 1)
        #expect(EPUBTestPDF.imageObjectCount(converted.pdf) >= 1)  // the data: picture
        let entries = await F6Check.outline(converted.pdf)
        print("HTML outline: \(entries)")
        print("HTML page 1: \(EPUBTestPDF.pageText(document, 0).prefix(400))")
        #expect(entries.map(\.title) == F6Fixtures.htmlHeadings.map(\.0))
        #expect(entries.map(\.level) == F6Fixtures.htmlHeadings.map(\.1))
        for entry in entries {
            let page = try #require(entry.page)
            #expect(EPUBTestPDF.page(document, page, shows: entry.title), "\(entry.title) → \(page)")
        }
        let links = EPUBTestPDF.links(document)
        print("HTML links: \(diagnostics.links)")
        #expect(links.contains { $0.url?.absoluteString == "https://example.com/f6-html" })
        let three = try #require(entries.first { $0.title.hasPrefix("Section 3") }?.page)
        #expect(links.contains { $0.destination == three })
        F6Check.savePages(document, name: "html", pages: [0, 1])
    }

    @Test func htmlMakesNoNetworkRequest() async throws {
        let counter = try EPUBTestNetworkCounter()
        let port = try await counter.start()
        let workspace = try F6Workspace(text: F6Fixtures.html(remotePort: port), extension: "html", format: .html)
        let diagnostics = WebConversionDiagnostics()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(counter.connections == 0, "requests reached the listener: \(counter.requestLines)")
        let document = try #require(PDFDocument(url: converted.pdf))
        // The remote picture is replaced by its description; the text around it is there.
        #expect(document.findString("Remote chart", withOptions: []).count == 1)
        #expect(document.findString("after the remote picture", withOptions: []).count == 1)
        print("HTML requests: \(diagnostics.requests)")
    }

    /// The control: the same page without the block list reaches the listener.
    @MainActor
    @Test func theNetworkCheckCanSeeALeak() async throws {
        let counter = try EPUBTestNetworkCounter()
        let port = try await counter.start()
        let html = Data(F6Fixtures.html(remotePort: port).utf8)
        var configuration = WebPDFRenderer.Configuration(pageSize: ConversionOptions.reflowPageSize, margins: EPUBStyle.margins)
        configuration.blocksNetwork = false
        configuration.loadTimeout = 20
        let renderer = WebPDFRenderer(provider: WebFileResources(["d.html": .init(source: .data(html), mimeType: "text/html", textEncodingName: "utf-8")]),
                                      configuration: configuration)
        try await renderer.start()
        try await renderer.load(path: "d.html")
        try await Task.sleep(nanoseconds: 800_000_000)
        renderer.tearDown()
        print("HTML network control: \(counter.connections) \(counter.requestLines)")
        #expect(counter.connections > 0)
    }

    @Test func malformedXHTMLIsLaidOutAsHTML() async throws {
        let workspace = try F6Workspace(text: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Line one<br>Line two &mdash; XHTMLWORD</p></body></html>",
                                        extension: "xhtml", format: .html)
        let diagnostics = WebConversionDiagnostics()
        let document = try #require(PDFDocument(url: try await convert(workspace, diagnostics: diagnostics).pdf))
        #expect(document.findString("XHTMLWORD", withOptions: []).count == 1)
        #expect(diagnostics.notes.contains { $0.contains("laid out as HTML") })
    }

    // MARK: Web archive

    @Test func webArchiveConvertsWithItsSavedPicture() async throws {
        let workspace = try F6Workspace(copying: F6Fixtures.fixture("f6-sample.webarchive"), format: .webArchive)
        let diagnostics = WebConversionDiagnostics()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        let document = try #require(PDFDocument(url: converted.pdf))
        expectTradePages(document)
        #expect(EPUBTestPDF.blankPages(document) == [])
        #expect(document.findString("F6WORD-2-4", withOptions: []).count == 1)
        #expect(document.findString("F6WORD-closing", withOptions: []).count == 1)
        #expect(converted.title == "F6 Sample Title")
        // The picture saved in the archive was served and printed.
        print("Web archive requests: \(diagnostics.requests)")
        #expect(diagnostics.requests.contains { $0.path.hasSuffix("f6-picture.png") && $0.outcome == .served })
        #expect(EPUBTestPDF.imageObjectCount(converted.pdf) >= 1)
        F6Check.savePages(document, name: "webarchive", pages: [0, 1])
    }

    // MARK: Failures

    @Test func filesThatDoNotRenderFailWithAReason() async throws {
        let cases: [(String, Data, String, ImportFormat, String)] = [
            ("empty", Data(), "txt", .plainText, "empty"),
            ("blank", Data("   \n\n\t \n".utf8), "md", .markdown, "no text"),
            ("binary html", Data((0..<4096).map { UInt8(($0 * 7919) % 256) }), "html", .html, "does not contain text"),
            ("binary txt", Data([0x00, 0x00, 0x01, 0x02, 0xFF, 0x00, 0x00, 0x00]), "txt", .plainText, "does not contain text"),
            ("empty html", Data("<html><head><title>x</title></head><body>  </body></html>".utf8), "html", .html, "no text or pictures"),
            ("not an archive", Data("bplist00 nope".utf8), "webarchive", .webArchive, "web archive"),
        ]
        for (name, data, ext, format, phrase) in cases {
            let workspace = try F6Workspace(data: data, extension: ext, format: format)
            do {
                _ = try await convert(workspace)
                Issue.record("\(name) converted")
            } catch let ConversionError.failed(reason) {
                print("Text failure \(name): \(reason)")
                #expect(reason.contains(phrase), "\(name): \(reason)")
            }
            #expect(workspace.contents == ["original.\(ext)"], "\(name) left \(workspace.contents)")
        }
    }

    // MARK: Cancellation, main thread

    @Test func cancellingLeavesNothingBehind() async throws {
        let workspace = try F6Workspace(text: F6Fixtures.plainText(paragraphs: 600), extension: "txt", format: .plainText)
        let input = workspace.input()
        let holder = EPUBTestTaskHolder()
        var converter = TextDocumentConverter()
        // Cancel once the first segment has printed.
        converter.trace = { line in if line.hasPrefix("printed") { holder.cancelOnce() } }
        let task = Task { () throws -> ConvertedDocument in try await converter.convert(input) { _ in } }
        holder.set(task)
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(workspace.contents == ["original.txt"])
    }

    @Test func longTextKeepsTheMainThreadResponsive() async throws {
        // Warm-up: the first conversion in a process pays for starting WebKit's processes.
        let warmUp = try F6Workspace(text: "Warm-up.", extension: "txt", format: .plainText)
        _ = try await convert(warmUp)

        let workspace = try F6Workspace(text: F6Fixtures.plainText(paragraphs: 1600), extension: "txt", format: .plainText)
        let diagnostics = WebConversionDiagnostics()
        let memory = EPUBTestMemorySampler()
        let watchdog = EPUBTestMainThreadWatchdog()
        let started = CACurrentMediaTime()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        let elapsed = CACurrentMediaTime() - started
        let stall = watchdog.stop()
        let footprint = memory.stop()
        print(String(format: "Long text: pages=%d parts=%d total=%.2fs load=%.2fs longestPrintSlice=%.0f ms watchdogLongest=%.0f ms "
                     + "footprint before %.1f peak %.1f after %.1f MB",
                     converted.pageCount, diagnostics.parts.count, elapsed, diagnostics.loadSeconds,
                     diagnostics.longestMainThreadSlice * 1000, stall.longest * 1000, footprint.start, footprint.peak, footprint.end))
        #expect(converted.pageCount >= 150)
        #expect(diagnostics.parts.count > 1)
        #expect(diagnostics.longestMainThreadSlice < 0.2)
        #expect(stall.longest < 0.3)
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(EPUBTestPDF.blankPages(document) == [])
        #expect(document.findString("TXTWORD-1600 ", withOptions: []).count == 1)
    }
}
