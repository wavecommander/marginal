import Foundation
import PDFKit
import ReaderCore
import Testing
import UIKit
@testable import Marginal

/// The Word / RTF / Pages converter, called directly on the committed fixtures
/// (Tests/Fixtures/f6-sample.*, made by Tests/Fixtures/f6-make-fixtures.py).
@Suite(.serialized)
struct OfficeConverterTests {
    private func convert(_ workspace: F6Workspace, textSize: ConversionTextSize = .medium,
                         diagnostics: WebConversionDiagnostics? = nil) async throws -> ConvertedDocument {
        var converter = OfficeDocumentConverter()
        converter.diagnostics = diagnostics
        converter.trace = F6Check.trace("Office")
        return try await converter.convert(workspace.input(textSize: textSize)) { _ in }
    }

    private func checkSample(_ converted: ConvertedDocument, name: String) throws -> PDFDocument {
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.pageCount == converted.pageCount)
        #expect(EPUBTestPDF.blankPages(document) == [], "\(name)")
        for word in ["F6WORD-intro", "F6WORD-1-1.", "F6WORD-2-8.", "F6WORD-3-5.", "F6WORD-list-two", "F6WORD-high", "F6WORD-closing"]
            + (name == "docx" ? ["F6TABLE-north", "F6TABLE-south"] : []) {
            #expect(document.findString(word, withOptions: []).count == 1, "\(name): \(word)")
        }
        return document
    }

    // MARK: Word

    @Test func docxKeepsItsPageSizeHeadingsAndPicture() async throws {
        let workspace = try F6Workspace(copying: F6Fixtures.fixture("f6-sample.docx"), format: .word)
        let diagnostics = WebConversionDiagnostics()
        let fractions = Fractions()
        var converter = OfficeDocumentConverter()
        converter.diagnostics = diagnostics
        let started = CACurrentMediaTime()
        let converted = try await converter.convert(workspace.input()) { fractions.append($0) }
        print(String(format: "docx: %d pages in %.2fs (load %.2fs), page %@, notes %@", converted.pageCount, CACurrentMediaTime() - started,
                     diagnostics.loadSeconds, String(describing: diagnostics.pageSize), diagnostics.notes.description))
        let document = try checkSample(converted, name: "docx")
        // The document's own page: A4 with 1 in margins (w:pgSz, w:pgMar).
        for index in 0..<document.pageCount {
            let size = try #require(document.page(at: index)?.bounds(for: .mediaBox).size)
            #expect(abs(size.width - 595.3) < 0.5 && abs(size.height - 841.9) < 0.5, "page \(index): \(size)")
        }
        #expect(diagnostics.margins == UIEdgeInsets(top: 72, left: 72, bottom: 72, right: 72))
        #expect(converted.title == "F6 Sample Title")
        // Text sits inside the margins.
        let hit = try #require(document.findString("F6WORD-1-1.", withOptions: []).first)
        let page = try #require(hit.pages.first)
        #expect(hit.bounds(for: page).minX >= 70)
        // Headings from the Word styles, nested, each on the page that shows it.
        let entries = await F6Check.outline(converted.pdf)
        #expect(entries.map(\.title) == ["F6 Sample Document", "Section 1: Harbour Notes", "Section 2: Harbour Notes", "Section 3: Harbour Notes"])
        #expect(entries.map(\.level) == [1, 2, 2, 2])
        for entry in entries {
            let pageIndex = try #require(entry.page)
            #expect(EPUBTestPDF.page(document, pageIndex, shows: entry.title), "\(entry.title) → \(pageIndex)")
        }
        // The picture (served by WebKit's converter) is in the PDF.
        #expect(EPUBTestPDF.imageObjectCount(converted.pdf) >= 1)
        #expect(fractions.values.last == 1)
        #expect(workspace.contents == ["Document.pdf", "original.docx"])
        F6Check.savePages(document, name: "docx", pages: Array(0..<document.pageCount))
    }

    @Test func docAndRTFConvert() async throws {
        for (name, format) in [("f6-sample.doc", ImportFormat.word), ("f6-sample.rtf", .rtf)] {
            let workspace = try F6Workspace(copying: F6Fixtures.fixture(name), format: format)
            let diagnostics = WebConversionDiagnostics()
            let started = CACurrentMediaTime()
            let converted = try await convert(workspace, diagnostics: diagnostics)
            print(String(format: "%@: %d pages in %.2fs (load %.2fs), page %@ margins %@, notes %@, title %@", name, converted.pageCount,
                         CACurrentMediaTime() - started, diagnostics.loadSeconds, String(describing: diagnostics.pageSize),
                         String(describing: diagnostics.margins), diagnostics.notes.description, converted.title ?? "nil"))
            let document = try checkSample(converted, name: name)
            let size = try #require(document.page(at: 0)?.bounds(for: .mediaBox).size)
            if format == .rtf {
                // RTF without \paperw: the RTF default, US Letter, with the file's margins.
                #expect(size == OfficePageGeometry.letter)
                #expect(converted.title == "F6 Sample Title")
                // Set at the document's own sizes: 12 pt body text, not iOS-scaled 15.6.
                let hit = try #require(document.findString("F6WORD-1-1.", withOptions: []).first)
                let page = try #require(hit.pages.first)
                let height = hit.bounds(for: page).height
                #expect(height < 15, "line height \(height)")
            } else {
                // No page size in a .doc: QuickLook's page box (600 × 844 here), snapped to A4.
                #expect(size == OfficePageGeometry.a4, "\(size)")
                let margins = try #require(diagnostics.margins)
                #expect(margins.top > 0 && margins.bottom > 0 && margins.left > 0, "\(margins)")
            }
            F6Check.savePages(document, name: (name as NSString).pathExtension, pages: [0, 1])
        }
    }

    @Test func textSizeDoesNotChangeOfficeDocuments() async throws {
        var counts: [Int] = []
        for size in [ConversionTextSize.small, .large] {
            let workspace = try F6Workspace(copying: F6Fixtures.fixture("f6-sample.docx"), format: .word)
            counts.append(try await convert(workspace, textSize: size).pageCount)
        }
        #expect(counts[0] == counts[1])
    }

    // MARK: Failures

    @Test func damagedFilesFailWithAReason() async throws {
        let sample = try Data(contentsOf: F6Fixtures.fixture("f6-sample.docx"))
        var cases: [(String, Data, String, ImportFormat, String)] = [
            ("empty docx", Data(), "docx", .word, "empty"),
            ("junk docx", Data("PK\u{3}\u{4} this is not really a zip at all".utf8), "docx", .word, "could not be opened as a Word document"),
            ("truncated docx", sample.prefix(sample.count / 2), "docx", .word, "could not be opened as a Word document"),
            ("junk rtf", Data("{\\rtf1 \u{0}\u{1}\u{2}".utf8), "rtf", .rtf, "RTF"),
        ]
        // A ZIP with no Word parts in it.
        var zip = EPUBTestZIPWriter()
        zip.add("hello.txt", "not a document")
        cases.append(("zip without word", zip.build(), "docx", .word, "could not be opened as a Word document"))
        for (name, data, ext, format, phrase) in cases {
            let workspace = try F6Workspace(data: data, extension: ext, format: format)
            do {
                let converted = try await convert(workspace)
                Issue.record("\(name) converted to \(converted.pageCount) pages")
            } catch let ConversionError.failed(reason) {
                print("Office failure \(name): \(reason)")
                #expect(reason.contains(phrase), "\(name): \(reason)")
            }
            #expect(workspace.contents == ["original.\(ext)"], "\(name) left \(workspace.contents)")
        }
    }

    // MARK: Isolation

    /// A Word file whose picture is linked to a server, not embedded.
    static func docxWithRemotePicture(port: UInt16) -> Data {
        var zip = EPUBTestZIPWriter()
        zip.add("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
            """)
        zip.add("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """)
        zip.add("word/_rels/document.xml.rels", """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rIdPic" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" \
            Target="http://127.0.0.1:\(port)/remote-word.png" TargetMode="External"/>\
            <Relationship Id="rIdLink" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" \
            Target="http://127.0.0.1:\(port)/link" TargetMode="External"/></Relationships>
            """)
        zip.add("word/document.xml", """
            <?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\
            <w:p><w:r><w:t>REMOTEWORD before the linked picture.</w:t></w:r></w:p>\
            <w:p><w:r><w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/><wp:docPr id="1" name="Remote"/>\
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
            <pic:nvPicPr><pic:cNvPr id="1" name="remote.png"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip r:link="rIdPic"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm><a:prstGeom prst="rect"/></pic:spPr>\
            </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>\
            <w:p><w:hyperlink r:id="rIdLink"><w:r><w:t>a remote link</w:t></w:r></w:hyperlink></w:p>\
            <w:p><w:r><w:t>REMOTEWORD after the linked picture.</w:t></w:r></w:p>\
            <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>\
            </w:body></w:document>
            """)
        return zip.build()
    }

    @Test func docxWithALinkedPictureMakesNoNetworkRequest() async throws {
        let counter = try EPUBTestNetworkCounter()
        let port = try await counter.start()
        let workspace = try F6Workspace(data: Self.docxWithRemotePicture(port: port), extension: "docx", format: .word)
        let diagnostics = WebConversionDiagnostics()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(counter.connections == 0, "requests reached the listener: \(counter.requestLines)")
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.findString("REMOTEWORD after", withOptions: []).count == 1)
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == OfficePageGeometry.letter)
        print("docx remote: requests \(diagnostics.requests)")
    }

    /// The control: the same Word file without the block list, to show whether WebKit's
    /// converter would fetch the linked picture at all (printed, not asserted).
    @MainActor
    @Test func docxNetworkControl() async throws {
        let counter = try EPUBTestNetworkCounter()
        let port = try await counter.start()
        let data = Self.docxWithRemotePicture(port: port)
        var configuration = WebPDFRenderer.Configuration(pageSize: OfficePageGeometry.letter, margins: .zero)
        configuration.blocksNetwork = false
        configuration.loadTimeout = 30
        let renderer = WebPDFRenderer(provider: WebFileResources(["d.docx": .init(source: .data(data), mimeType: OfficeMIMEType.forFile(extension: "docx", format: .word), textEncodingName: nil)]),
                                      configuration: configuration)
        try await renderer.start()
        try await renderer.load(path: "d.docx")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        renderer.tearDown()
        print("docx network control (no block list): connections \(counter.connections) \(counter.requestLines)")
    }

    // MARK: Cancellation

    @Test func cancellingLeavesNothingBehind() async throws {
        let workspace = try F6Workspace(copying: F6Fixtures.fixture("f6-sample.docx"), format: .word)
        let input = workspace.input()
        let holder = EPUBTestTaskHolder()
        let task = Task { () throws -> ConvertedDocument in
            try await OfficeDocumentConverter().convert(input) { fraction in if fraction > 0.1 { holder.cancelOnce() } }
        }
        holder.set(task)
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(workspace.contents == ["original.docx"])
    }

    // MARK: Formats this Mac cannot make

    /// A real Pages document, if one is in Downloads (`f6-sample.pages`, file or package).
    @Test func aRealPagesDocument() async throws {
        guard let url = F6Fixtures.downloaded("f6-sample.pages") else {
            print("Pages: no /Users/benw/Downloads/f6-sample.pages; UNTESTED")
            return
        }
        let workspace = try F6Workspace(copying: url, format: .pages)
        let diagnostics = WebConversionDiagnostics()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        let document = try #require(PDFDocument(url: converted.pdf))
        print("Pages: \(converted.pageCount) pages, page \(String(describing: diagnostics.pageSize)), notes \(diagnostics.notes)")
        #expect(converted.pageCount > 0)
        #expect(EPUBTestPDF.blankPages(document) == [])
        #expect(!(document.page(at: 0)?.string ?? "").isEmpty)
        F6Check.savePages(document, name: "pages", pages: [0, 1])
    }
}
