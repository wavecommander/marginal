import Foundation
import PDFKit
import ReaderCore
import Testing
import UIKit
@testable import TactileTexts

/// The EPUB converter, called directly on fixture books built in code. Serialized: each test
/// drives an off-screen web view, and the stall measurement must not share the main thread.
@Suite(.serialized)
struct EPUBConverterTests {
    private func convert(_ workspace: EPUBTestWorkspace, textSize: ConversionTextSize = .medium,
                         diagnostics: EPUBConversionDiagnostics? = nil) async throws -> ConvertedDocument {
        var converter = EPUBConverter()
        converter.diagnostics = diagnostics
        converter.trace = { print(String(format: "[%.3f] EPUB trace: %@", CACurrentMediaTime(), $0)) }
        return try await converter.convert(workspace.input(textSize: textSize)) { _ in }
    }

    // MARK: Output

    @Test func outputIsSearchableSelectableAndTradeSized() async throws {
        let workspace = try EPUBTestWorkspace(EPUBTestFixtures.small())
        let fractions = Fractions()
        let converted = try await EPUBConverter().convert(workspace.input()) { fractions.append($0) }
        #expect(converted.pdf == workspace.input().outputURL)
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.pageCount == converted.pageCount)
        #expect(converted.pageCount >= 8)
        for index in 0..<document.pageCount {
            #expect(document.page(at: index)?.bounds(for: .mediaBox).size == CGSize(width: 432, height: 648))
        }
        // Searchable, with sane per-line bounds (what a highlight needs).
        let hits = document.findString("Paragraph 2.1.5", withOptions: [])
        #expect(hits.count == 1)
        let selection = try #require(hits.first)
        let page = try #require(selection.pages.first)
        let bounds = selection.bounds(for: page)
        let pageBounds = page.bounds(for: .mediaBox)
        #expect(bounds.width > 20 && bounds.height > 5 && bounds.height < 40)
        #expect(pageBounds.contains(bounds))
        let lines = selection.selectionsByLine()
        #expect(!lines.isEmpty)
        for line in lines { #expect(pageBounds.contains(line.bounds(for: page))) }
        // Text reads the right way up: the chapter heading sits in the top half of its page.
        let heading = try #require(document.findString("Chapter Three: Landfall", withOptions: []).first)
        let headingPage = try #require(heading.pages.first)
        #expect(heading.bounds(for: headingPage).minY > pageBounds.midY)
        // Progress rises to 1.
        #expect(fractions.values.last == 1)
        #expect(fractions.values == fractions.values.sorted())
        // Only the output and the cover are left in the directory.
        #expect(workspace.contents == ["Book.pdf", "epub-cover.png", "original.epub"])
    }

    @Test func titleAndCoverComeBack() async throws {
        let workspace = try EPUBTestWorkspace(EPUBTestFixtures.small())
        let converted = try await convert(workspace)
        #expect(converted.title == "The Tactile Test Book")
        let cover = try #require(converted.coverImage)
        #expect(cover.deletingLastPathComponent().standardizedFileURL == workspace.directory.standardizedFileURL)
        let image = try #require(UIImage(contentsOfFile: cover.path))
        #expect(image.size == CGSize(width: 600, height: 900))
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "The Tactile Test Book")

        // EPUB 2: the cover named by <meta name="cover">.
        let ncx = try EPUBTestWorkspace(EPUBTestFixtures.ncx())
        let converted2 = try await convert(ncx)
        #expect(converted2.title == "The NCX Test Book")
        #expect(converted2.coverImage?.lastPathComponent == "epub-cover.jpg")

        // No title, no cover.
        let bare = try EPUBTestWorkspace(EPUBTestFixtures.single(body: "<p>Untitled text</p>", title: "  "))
        let converted3 = try await convert(bare)
        #expect(converted3.title == nil)
        #expect(converted3.coverImage == nil)
    }

    @Test func largerTextMakesMorePages() async throws {
        var counts: [ConversionTextSize: Int] = [:]
        for size in ConversionTextSize.allCases {
            let workspace = try EPUBTestWorkspace(EPUBTestFixtures.small())
            counts[size] = try await convert(workspace, textSize: size).pageCount
        }
        let small = try #require(counts[.small]), medium = try #require(counts[.medium]), large = try #require(counts[.large])
        print("EPUB text size page counts: small \(small), medium \(medium), large \(large)")
        #expect(small < medium)
        #expect(medium < large)
    }

    @Test func tallImagesAreScaledToFitAPage() async throws {
        // 300 × 3000 px: unscaled it would run over five pages.
        let png = EPUBTestBook.png(width: 300, height: 3000)
        let workspace = try EPUBTestWorkspace(EPUBTestFixtures.single(
            body: "<p>Before the image.</p><p><img src=\"tall.png\" alt=\"\"/></p><p>After the image.</p>",
            files: [("OEBPS/tall.png", png)], items: ["<item id=\"tall\" href=\"tall.png\" media-type=\"image/png\"/>"]))
        let converted = try await convert(workspace)
        #expect(converted.pageCount <= 2)
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.findString("After the image.", withOptions: []).count == 1)
    }

    // MARK: Blank pages

    /// Forced breaks and margins at a chapter's edges printed empty pages (one per chapter in
    /// Project Gutenberg books). Each chapter here fits on one page, so the book is four pages,
    /// none blank, and each outline entry lands on its heading.
    @Test func chapterEdgesPrintNoBlankPages() async throws {
        let workspace = try EPUBTestWorkspace(EPUBTestFixtures.edgeBreaks())
        let converted = try await convert(workspace)
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(EPUBTestPDF.blankPages(document) == [])
        #expect(converted.pageCount == 4)
        let entries = await ReaderDocumentLoader.outlineEntries(at: converted.pdf)
        #expect(entries.map(\.title) == EPUBTestFixtures.edgeTitles)
        #expect(entries.map(\.pageIndex) == [0, 1, 2, 3])
        for (index, title) in EPUBTestFixtures.edgeTitles.enumerated() {
            #expect(EPUBTestPDF.page(document, index, shows: title), "\(title) is not on page \(index)")
        }
        // The rule that ends chapter four is still drawn.
        #expect(EPUBTestPDF.pageText(document, 3).contains("Paragraph E4.3"))
    }

    // MARK: Outline

    private func checkOutline(_ converted: ConvertedDocument) async throws {
        let entries = await ReaderDocumentLoader.outlineEntries(at: converted.pdf)
        #expect(entries.map(\.title) == EPUBTestFixtures.smallTOC.map(\.0))
        #expect(entries.map(\.level) == EPUBTestFixtures.smallTOC.map(\.1))
        let document = try #require(PDFDocument(url: converted.pdf))
        for entry in entries {
            let page = try #require(entry.pageIndex, "\(entry.title) has no page")
            #expect(EPUBTestPDF.page(document, page, shows: entry.title),
                    "\(entry.title) → page \(page) does not show it: \(EPUBTestPDF.pageText(document, page).prefix(120))")
        }
        // Pages never go backwards in reading order.
        let pages = entries.compactMap(\.pageIndex)
        #expect(pages == pages.sorted())
    }

    @Test func navOutlineMatchesTheTableOfContents() async throws {
        let workspace = try EPUBTestWorkspace(EPUBTestFixtures.small())
        let diagnostics = EPUBConversionDiagnostics()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        try await checkOutline(converted)
        print("EPUB nav outline: \(diagnostics.outline)")
        #expect(diagnostics.outline.dropped == 1)  // the entry whose target is not in the spine
        #expect(diagnostics.outline.estimated == 0)
    }

    @Test func ncxOutlineMatchesTheTableOfContents() async throws {
        let workspace = try EPUBTestWorkspace(EPUBTestFixtures.ncx())
        let diagnostics = EPUBConversionDiagnostics()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        try await checkOutline(converted)
        print("EPUB NCX outline: \(diagnostics.outline)")
    }

    // MARK: Links

    @Test func linksArePlacedOnTheirTextOrDropped() async throws {
        let workspace = try EPUBTestWorkspace(EPUBTestFixtures.small())
        let diagnostics = EPUBConversionDiagnostics()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        let document = try #require(PDFDocument(url: converted.pdf))
        let links = EPUBTestPDF.links(document)
        print("EPUB links: \(diagnostics.links); annotations \(links.map { "p\($0.page) \($0.url?.absoluteString ?? "→ p\($0.destination ?? -1)")" })")
        #expect(diagnostics.links.internalFound == 2)
        #expect(diagnostics.links.externalFound == 1)

        // Every annotation covers its link's text and goes where the link pointed.
        for link in links {
            let page = try #require(document.page(at: link.page))
            let covered = EPUBTestPDF.collapsed(page.selection(for: link.bounds.insetBy(dx: 1, dy: 1))?.string ?? "")
            if let url = link.url {
                #expect(url.absoluteString == "https://example.com/tactile-weather")
                #expect(covered.contains("coastal forecast") || covered.contains("consult the"), "covers '\(covered)'")
            } else {
                let destination = try #require(link.destination)
                let target = EPUBTestPDF.pageText(document, destination)
                if covered.contains("keeper") {
                    #expect(target.contains("Keeper's Log"))
                } else {
                    #expect(covered.contains("quiet harbour"), "covers '\(covered)'")
                    #expect(target.contains("A Quiet Harbour"))
                }
            }
        }
        #expect(diagnostics.links.externalPlaced == 1)
        #expect(diagnostics.links.internalPlaced == 2)
    }

    // MARK: Isolation

    @Test func noNetworkRequestIsMade() async throws {
        let counter = try EPUBTestNetworkCounter()
        let port = try await counter.start()
        let workspace = try EPUBTestWorkspace(EPUBTestFixtures.small(remotePort: port))
        let diagnostics = EPUBConversionDiagnostics()
        _ = try await convert(workspace, diagnostics: diagnostics)
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(counter.connections == 0, "requests reached the listener: \(counter.requestLines)")
        // The local resources were served through the scheme handler.
        let served = Set(diagnostics.requests.filter { $0.outcome == .served }.map(\.path))
        #expect(served.isSuperset(of: ["OEBPS/text/ch2.xhtml", "OEBPS/style.css", "OEBPS/images/figure.png"]))
    }

    /// The control for `noNetworkRequestIsMade`: the same chapter without the block list does
    /// reach the listener, so a zero above means something.
    @MainActor
    @Test func theNetworkCheckCanSeeALeak() async throws {
        let counter = try EPUBTestNetworkCounter()
        let port = try await counter.start()
        let workspace = try EPUBTestWorkspace(EPUBTestFixtures.small(remotePort: port))
        let package = try EPUBParser.parse(fileAt: workspace.original)
        for blocks in [false, true] {
            let before = counter.connections
            var configuration = WebPDFRenderer.Configuration(pageSize: ConversionOptions.reflowPageSize, margins: EPUBStyle.margins)
            configuration.blocksNetwork = blocks
            configuration.loadTimeout = 20
            let renderer = WebPDFRenderer(provider: try EPUBArchiveResources(url: workspace.original, package: package),
                                          configuration: configuration)
            try await renderer.start()
            try await renderer.load(path: "OEBPS/text/ch2.xhtml")
            try await Task.sleep(nanoseconds: 800_000_000)
            renderer.tearDown()
            let hits = counter.connections - before
            print("EPUB network control: blocksNetwork=\(blocks) connections=\(hits) \(counter.requestLines)")
            if blocks { #expect(hits == 0) } else { #expect(hits > 0) }
        }
    }

    // MARK: Fonts

    private func fontBook(_ font: Data, encryption: String?) -> Data {
        EPUBTestFixtures.single(
            body: "<p class=\"face\">Written in the embedded face.</p><p>And this in the default face.</p>",
            head: "<style>@font-face { font-family: 'TTTestFace'; src: url('fonts/face.ttf'); } .face { font-family: 'TTTestFace'; }</style>",
            files: [("OEBPS/fonts/face.ttf", font)],
            items: ["<item id=\"face\" href=\"fonts/face.ttf\" media-type=\"font/ttf\"/>"],
            encryption: encryption)
    }

    @Test func embeddedAndObfuscatedFontsRender() async throws {
        let font = try #require(EPUBTestFixtures.fontData(), "no system font file to embed")
        let id = EPUBTestFixtures.identifier
        let cases: [(String, Data, String?)] = [
            ("plain", font, nil),
            ("idpf", EPUBTestFixtures.idpfObfuscated(font, identifier: id),
             EPUBTestFixtures.encryptionXML("http://www.idpf.org/2008/embedding", "OEBPS/fonts/face.ttf")),
            ("adobe", EPUBTestFixtures.adobeObfuscated(font, uuid: id),
             EPUBTestFixtures.encryptionXML("http://ns.adobe.com/pdf/enc#RC", "OEBPS/fonts/face.ttf")),
            // Control: obfuscated bytes served as they are do not load, so the check can fail.
            ("undeclared", EPUBTestFixtures.idpfObfuscated(font, identifier: id), nil),
        ]
        for (name, data, encryption) in cases {
            let workspace = try EPUBTestWorkspace(fontBook(data, encryption: encryption))
            let converted = try await convert(workspace)
            let fonts = EPUBTestPDF.baseFontNames(converted.pdf)
            let embedded = fonts.contains { $0.contains("Chalkduster") }
            print("EPUB font \(name): \(fonts.sorted())")
            #expect(embedded == (name != "undeclared"), "\(name): \(fonts)")
        }
    }

    // MARK: Failures

    @Test func protectedFixedLayoutAndBrokenBooksAreRefused() async throws {
        let rights = try EPUBTestWorkspace(EPUBTestFixtures.single(body: "<p>x</p>", extraMeta: [("META-INF/rights.xml", "<rights/>")]))
        await #expect(throws: ConversionError.protected) { _ = try await convert(rights) }
        #expect(rights.contents == ["original.epub"])

        let aes = EPUBTestFixtures.encryptionXML("http://www.w3.org/2001/04/xmlenc#aes128-cbc", "OEBPS/one.xhtml")
        let encrypted = try EPUBTestWorkspace(EPUBTestFixtures.single(body: "<p>x</p>", encryption: aes))
        await #expect(throws: ConversionError.protected) { _ = try await convert(encrypted) }

        let fixed = try EPUBTestWorkspace(EPUBTestFixtures.single(
            body: "<p>x</p>", metadata: "<meta property=\"rendition:layout\">pre-paginated</meta>"))
        do {
            _ = try await convert(fixed)
            Issue.record("fixed layout converted")
        } catch let ConversionError.unsupported(reason) {
            #expect(reason.contains("Fixed-layout"))
        }
        #expect(fixed.contents == ["original.epub"])

        // The container names a package document that is not there.
        var zip = EPUBTestZIPWriter()
        zip.add("mimetype", "application/epub+zip")
        zip.add("META-INF/container.xml", """
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>\
            <rootfile full-path="OEBPS/gone.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """)
        let broken = try EPUBTestWorkspace(zip.build())
        try await expectFailure(broken, mentioning: "OEBPS/gone.opf")

        // Not a ZIP at all.
        let garbage = try EPUBTestWorkspace(Data("this is not an epub".utf8))
        try await expectFailure(garbage, mentioning: "archive")

        // A spine item missing from the archive fails the conversion naming the chapter.
        let missing = try EPUBTestWorkspace(EPUBTestFixtures.single(
            body: "<p>first</p>", items: ["<item id=\"two\" href=\"two.xhtml\" media-type=\"application/xhtml+xml\"/>"],
            spine: ["<itemref idref=\"one\"/>", "<itemref idref=\"two\"/>"]))
        try await expectFailure(missing, mentioning: "Chapter 2 (OEBPS/two.xhtml)")
        #expect(missing.contents == ["original.epub"])

        // Nothing in the spine that can be shown.
        let empty = try EPUBTestWorkspace(EPUBTestFixtures.single(body: "<p>x</p>", spine: []))
        try await expectFailure(empty, mentioning: "no chapters")
    }

    private func expectFailure(_ workspace: EPUBTestWorkspace, mentioning text: String) async throws {
        do {
            _ = try await convert(workspace)
            Issue.record("converted, expected a failure mentioning \(text)")
        } catch let ConversionError.failed(reason) {
            print("EPUB failure: \(reason)")
            #expect(reason.contains(text), "\(reason)")
        }
    }

    @Test func malformedXHTMLIsRenderedAsHTML() async throws {
        // An unclosed <br> and an HTML entity: not well-formed XML.
        let workspace = try EPUBTestWorkspace(EPUBTestFixtures.single(
            body: "<p>Line one<br>Line two &mdash; still here.</p><p>The closing paragraph of the broken chapter.</p>"))
        let diagnostics = EPUBConversionDiagnostics()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        #expect(diagnostics.chapters.first?.reloadedAsHTML == true)
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.findString("closing paragraph of the broken chapter", withOptions: []).count == 1)
    }

    // MARK: Cancellation

    @Test func cancellingBetweenChaptersLeavesNothingBehind() async throws {
        let workspace = try EPUBTestWorkspace(EPUBTestFixtures.small())
        let holder = EPUBTestTaskHolder()
        let input = workspace.input()
        let task = Task { () throws -> ConvertedDocument in
            try await EPUBConverter().convert(input) { fraction in
                if fraction > 0.2 { holder.cancelOnce() }
            }
        }
        holder.set(task)
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(workspace.contents == ["original.epub"])
    }

    @Test func cancellingWhilePrintingALongChapterLeavesNothingBehind() async throws {
        let workspace = try EPUBTestWorkspace(EPUBTestFixtures.long())
        let input = workspace.input()
        let holder = EPUBTestTaskHolder()
        let printedSegments = Fractions()
        var converter = EPUBConverter()
        // Cancel once the first segment of the long chapter has printed: the next step is the
        // second segment, so the cancellation lands mid-chapter.
        converter.trace = { line in
            guard line.hasPrefix("printed") else { return }
            printedSegments.append(1)
            holder.cancelOnce()
        }
        let task = Task { () throws -> ConvertedDocument in
            try await converter.convert(input) { _ in }
        }
        holder.set(task)
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(printedSegments.values.count == 1)
        #expect(workspace.contents == ["original.epub"])
    }

    // MARK: Main thread and memory

    @Test func longChapterKeepsTheMainThreadResponsive() async throws {
        // The host app's own launch work, measured with nothing converting.
        let idleWatchdog = EPUBTestMainThreadWatchdog()
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let idle = idleWatchdog.stop()
        print(String(format: "EPUB idle host app: longest main-thread stall %.0f ms", idle.longest * 1000))
        // A first conversion pays for starting WebKit's processes; measure it on its own.
        let warmUp = try EPUBTestWorkspace(EPUBTestFixtures.single(body: "<p>Warm-up.</p>"))
        let firstWatchdog = EPUBTestMainThreadWatchdog()
        _ = try await convert(warmUp)
        let first = firstWatchdog.stop()
        print(String(format: "EPUB first conversion in this process: longest main-thread stall %.0f ms", first.longest * 1000))

        let workspace = try EPUBTestWorkspace(EPUBTestFixtures.long())
        let diagnostics = EPUBConversionDiagnostics()
        let memory = EPUBTestMemorySampler()
        let watchdog = EPUBTestMainThreadWatchdog()
        let started = CACurrentMediaTime()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        let elapsed = CACurrentMediaTime() - started
        let stall = watchdog.stop()
        let footprint = memory.stop()
        let chapter = try #require(diagnostics.chapters.first)
        print("EPUB long chapter parts: " + diagnostics.chapters.map { String(format: "%d pages, longest %.0f ms", $0.pageCount, $0.print.longestMainThreadSlice * 1000) }.joined(separator: "; "))
        print(String(format: "EPUB long chapter: pages=%d total=%.2fs chapter=%.2fs print=%.2fs (main %.0f ms in %d batches) "
                     + "pages/s=%.0f longestPrintSlice=%.0f ms watchdogLongest=%.0f ms at [%.3f] (%d samples) "
                     + "footprint before %.1f peak %.1f after %.1f MB",
                     converted.pageCount, elapsed, chapter.seconds, chapter.print.elapsed, chapter.print.mainThreadTime * 1000,
                     chapter.print.batches, Double(converted.pageCount) / elapsed, chapter.print.longestMainThreadSlice * 1000,
                     stall.longest * 1000, stall.at, stall.samples, footprint.start, footprint.peak, footprint.end))
        #expect(converted.pageCount >= 150)
        // Printed in segments, each holding the main thread for a bounded time. Generous
        // bounds: the target is ~100 ms; a loaded simulator adds noise.
        #expect(chapter.parts > 1)
        #expect(diagnostics.longestMainThreadSlice < 0.2)
        #expect(stall.longest < 0.3)
        try await checkLongOutline(converted)
    }

    private func checkLongOutline(_ converted: ConvertedDocument) async throws {
        let entries = await ReaderDocumentLoader.outlineEntries(at: converted.pdf)
        #expect(entries.count == 19)
        let document = try #require(PDFDocument(url: converted.pdf))
        for entry in entries.dropFirst() {
            let page = try #require(entry.pageIndex)
            #expect(EPUBTestPDF.page(document, page, shows: entry.title), "\(entry.title) → \(page)")
        }
    }
}
