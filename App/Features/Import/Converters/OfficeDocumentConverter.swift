import Foundation
import ReaderCore
import UIKit

// Word (.docx, .doc), RTF and Pages → PDF. The document keeps its own page size: there is no
// text-size setting. See docs/FORMAT_IMPORT_PLAN.md, "Word, RTF, Pages" and F0 finding 6.
//
// How each kind is laid out (found on the iOS 27 simulator):
// - Word: the file is served through the content scheme as its own MIME type, and WebKit's
//   QuickLook converter turns it into a web page (a page-sized box per section, the margins as
//   its padding, 1 px = 1 pt). The box's padding and minimum height are taken away and the page
//   is printed at the document's paper size with its margins, so lines break where the box broke
//   them. Pictures come from QuickLook's in-memory scheme (`x-apple-ql-id:`), which the network
//   blocker lets through.
// - RTF: read with the system RTF reader (see `RTFDocument`) and printed as HTML on the paper
//   and margins the file names.
// - Pages: WebKit converts it to a PDF and shows it in its PDF viewer; each page is printed at
//   its own size (see `WebPluginPageProbe`). A Pages package folder is zipped first, which is
//   what the single-file format is.
//
// Decisions the plan left open:
// - Page size: a `.docx` file's first section (`w:pgSz`, `w:pgMar`); otherwise the size of
//   QuickLook's page box, snapped to US Letter or A4 within 8 pt; otherwise US Letter in the
//   regions that use it and A4 elsewhere (`OfficePageGeometry.regionalDefault`). A document
//   with sections of different sizes is printed at the first section's.
// - Long documents are printed in segments like EPUB chapters, so a segment's last page can end
//   a little early (the Library would otherwise freeze while WebKit lays out the whole file).
// - Outline: a `.docx` file's paragraphs with heading styles or outline levels, found in the
//   printed pages by their text in reading order; `h1`–`h6` for other files when WebKit's page
//   has them (it did not for `.doc` or RTF made by TextEdit); none for Pages.
// - Title: `.docx` core properties, RTF info title, else the page's `<title>`, else none.

/// Turns Word documents, RTF and Pages documents into a PDF at their own page size.
nonisolated struct OfficeDocumentConverter: DocumentConverter {
    var version: Int { 1 }
    var formats: Set<ImportFormat> { [.word, .rtf, .pages] }
    /// Seconds the document may take to load (WebKit's own conversion included).
    var loadTimeout: TimeInterval = 90
    var diagnostics: WebConversionDiagnostics?
    var trace: (@Sendable (String) -> Void)?

    func convert(_ input: ConversionInput, progress: @escaping @Sendable (Double) -> Void) async throws -> ConvertedDocument {
        try await WebConversion.run(input, noun: "document") { workspace in
            let source = try await Self.prepare(input, workspace: workspace)
            progress(0.05)
            let rendered = try await OfficeDocumentPrinter.print(
                source, workspace: workspace, timeout: loadTimeout, diagnostics: diagnostics, trace: trace,
                progress: { progress(0.05 + 0.8 * $0) })
            try Task.checkCancellation()
            let pageCount = try await WebConversion.assemble(rendered.parts, outline: rendered.outline, title: rendered.title,
                                                             output: input.outputURL, diagnostics: diagnostics,
                                                             progress: { progress(0.85 + 0.15 * $0) })
            progress(1)
            return ConvertedDocument(pdf: input.outputURL, pageCount: pageCount, title: rendered.title, coverImage: nil)
        }
    }

    /// What the printer loads, and what was read from the file beforehand.
    struct Source: Sendable {
        enum Kind: Sendable { case word, rtf, pages }
        var kind: Kind
        var resources: WebFileResources
        var mainPath: String
        var page: OfficePageGeometry?
        var title: String?
        var headings: [WebOrderedHeading]
    }

    @concurrent
    static func prepare(_ input: ConversionInput, workspace: URL) async throws -> Source {
        let file = try await OfficeSourceFile.prepare(input, workspace: workspace)
        try Task.checkCancellation()
        let ext = file.pathExtension.lowercased()
        switch input.format {
        case .rtf:
            let converted = try RTFDocument.convert(file)
            let resources = WebFileResources(["document.html": .init(source: .data(converted.html), mimeType: "text/html", textEncodingName: "utf-8")])
            return Source(kind: .rtf, resources: resources, mainPath: "document.html", page: converted.page, title: converted.title, headings: [])
        case .word:
            let mime = QuickLookWorkarounds.mimeType(forFileExtension: ext, format: .word)
            let path = "document.\(ext.isEmpty ? "docx" : ext)"
            let resources = WebFileResources([path: .init(source: .file(file), mimeType: mime, textEncodingName: nil)])
            // A .doc is not a ZIP: nothing to read cheaply.
            let info = OfficeOpenXMLInfo.read(file, word: true)
            return Source(kind: .word, resources: resources, mainPath: path, page: info.page?.sanitized(), title: info.title,
                          headings: info.headings)
        case .pages:
            let path = "document.pages"
            let resources = WebFileResources([path: .init(source: .file(file), mimeType: QuickLookWorkarounds.mimeType(forFileExtension: "pages", format: .pages), textEncodingName: nil)])
            return Source(kind: .pages, resources: resources, mainPath: path, page: nil, title: nil, headings: [])
        default:
            throw ConversionError.unsupported(reason: "This converter does not handle \(input.format.rawValue) files.")
        }
    }
}

/// The CSS added to a document that keeps its own layout: no text size, white paper, pictures
/// kept on the page, and QuickLook's page box (`data-tactile-page`) flattened so the print path
/// paginates the text itself.
nonisolated enum OfficeDocumentStyle {
    static let css = """
        :root { color-scheme: only light; }
        html, body { margin: 0 !important; padding: 0 !important; background: #ffffff !important; -webkit-text-size-adjust: none; }
        img, svg { max-width: 100%; break-inside: avoid; page-break-inside: avoid; }
        [data-tactile-page] { width: auto !important; min-height: 0 !important; padding: 0 !important; margin: 0 !important; \
        overflow: visible !important; border: 0 !important; box-shadow: none !important; }
        """

    /// Finds QuickLook's page boxes (top-level `div`s with a minimum height and padding), reads
    /// the first one's size and padding, then marks them all so `css` flattens them.
    static let pageBoxScript = """
        const body = document.body;
        if (!body) { return 'null'; }
        const boxes = Array.from(body.children).filter(el => {
          if (el.nodeName !== 'DIV') { return false; }
          const s = getComputedStyle(el);
          return parseFloat(s.minHeight) > 200 && parseFloat(s.paddingLeft) > 0;
        });
        if (!boxes.length) { return 'null'; }
        // The edge-break pass zeroed the bottom padding of the box that holds the last text;
        // measure the box as the document set it.
        const first = boxes[0];
        const saved = [first.style.getPropertyValue('padding-bottom'), first.style.getPropertyPriority('padding-bottom')];
        first.style.removeProperty('padding-bottom');
        const s = getComputedStyle(first);
        const r = first.getBoundingClientRect();
        const box = {count: boxes.length, width: r.width, minHeight: parseFloat(s.minHeight),
          top: parseFloat(s.paddingTop), right: parseFloat(s.paddingRight), bottom: parseFloat(s.paddingBottom),
          left: parseFloat(s.paddingLeft)};
        if (saved[0]) { first.style.setProperty('padding-bottom', saved[0], saved[1]); }
        boxes.forEach(el => el.setAttribute('data-tactile-page', ''));
        void document.documentElement.offsetHeight;
        return JSON.stringify(box);
        """

    struct PageBox: Decodable {
        var count: Int
        var width: Double
        var minHeight: Double
        var top: Double
        var right: Double
        var bottom: Double
        var left: Double

        /// The page the box stands for, snapped to Letter or A4 within 8 pt. The minimum height
        /// is the page height (QuickLook sets it so, padding not counted).
        var geometry: OfficePageGeometry {
            let width = CGFloat(width.rounded())
            var height = CGFloat(minHeight.rounded())
            if height < width * 0.5 || height > width * 2.5 { height = (width * 11 / 8.5).rounded() }
            var size = CGSize(width: width, height: height)
            for paper in [OfficePageGeometry.letter, OfficePageGeometry.a4]
            where abs(size.width - paper.width) <= 8 && abs(size.height - paper.height) <= 8 {
                size = paper
            }
            return OfficePageGeometry(size: size, margins: UIEdgeInsets(top: top, left: left, bottom: bottom, right: right))
        }
    }
}

@MainActor
enum OfficeDocumentPrinter {
    struct Rendered {
        var parts: [WebPrintedPart]
        var outline: WebOutlineSource
        var title: String?
    }

    static func print(_ source: OfficeDocumentConverter.Source, workspace: URL, timeout: TimeInterval,
                      diagnostics: WebConversionDiagnostics?, trace: (@Sendable (String) -> Void)?,
                      progress: @escaping (Double) -> Void) async throws -> Rendered {
        // Loaded at the given (or a default) paper; the paper is fixed once the page is known.
        let initial = (source.page ?? OfficePageGeometry.regionalDefault()).sanitized()
        var configuration = WebPDFRenderer.Configuration(pageSize: initial.size, margins: initial.margins)
        configuration.styleSheet = OfficeDocumentStyle.css
        configuration.loadTimeout = timeout
        configuration.trace = trace
        let renderer = WebPDFRenderer(provider: source.resources, configuration: configuration)
        defer { renderer.tearDown() }
        let kind = source.kind == .pages ? "a Pages document" : source.kind == .rtf ? "an RTF document" : "a Word document"
        let started = CACurrentMediaTime()
        do {
            try await renderer.start()
            try await renderer.load(path: source.mainPath)
        } catch let error as WebRenderError {
            if let reason = OfficeSourceFile.loadFailureReason(error, kind: kind) { throw ConversionError.failed(reason: reason) }
            throw error
        }
        diagnostics?.record(loadSeconds: CACurrentMediaTime() - started)
        progress(0.3)
        let content = try await WebPageContent.check(renderer)
        if content.isEmpty {
            throw ConversionError.failed(reason: "The file shows no text or pictures, so there is nothing to convert: it may be damaged or empty.")
        }
        let title = source.title ?? (content.title.isEmpty ? nil : content.title)

        if content.pdfPlugin {
            // Pages (and anything else WebKit shows as a PDF): print each page at its own size.
            let measured = try await WebPluginPageProbe.measure(renderer, workspace: workspace)
            let size = measured ?? OfficePageGeometry.regionalDefault().size
            if measured == nil { diagnostics?.note("PDF viewer page size not found: \(size)") }
            renderer.setPage(size: size, margins: .zero)
            diagnostics?.record(pageSize: size, margins: .zero)
            let url = workspace.appendingPathComponent("part-000.pdf")
            let report = try await renderer.printPDF(to: url)
            let layout = WebDocumentLayout(height: 1, anchors: [], links: [])
            let parts = [WebPrintedPart(path: source.mainPath, pdf: url, pageCount: report.pageCount, layout: layout, report: report)]
            diagnostics?.record(parts: parts)
            diagnostics?.record(requests: renderer.schemeHandler.records)
            progress(1)
            return Rendered(parts: parts, outline: .none, title: title)
        }

        var geometry = initial
        if let box = try await pageBox(renderer) {
            if source.page == nil { geometry = box.geometry.sanitized() }
            diagnostics?.note("QuickLook page boxes: \(box.count), first \(Int(box.width))×\(Int(box.minHeight)) "
                              + "padding \(Int(box.top)) \(Int(box.right)) \(Int(box.bottom)) \(Int(box.left))")
        } else if source.kind == .word, source.page == nil {
            diagnostics?.note("no QuickLook page box; regional paper")
        }
        renderer.setPage(size: geometry.size, margins: geometry.margins)
        diagnostics?.record(pageSize: geometry.size, margins: geometry.margins)
        // Edge breaks again, now that the page boxes are flattened.
        _ = try await renderer.evaluate(WebPDFRenderer.suppressEdgeBreaksJS + "\nsuppressEdgeBreaks(); return '';")
        let parts = try await renderer.printSegments(path: source.mainPath, into: workspace, prefix: "part", headings: true,
                                                     progress: { progress(0.3 + 0.7 * $0) })
        diagnostics?.record(parts: parts)
        diagnostics?.record(requests: renderer.schemeHandler.records)
        let outline: WebOutlineSource = source.headings.isEmpty ? .headings : .orderedHeadings(source.headings)
        return Rendered(parts: parts, outline: outline, title: title)
    }

    private static func pageBox(_ renderer: WebPDFRenderer) async throws -> OfficeDocumentStyle.PageBox? {
        let json = try await renderer.evaluate(OfficeDocumentStyle.pageBoxScript)
        return try? JSONDecoder().decode(OfficeDocumentStyle.PageBox.self, from: Data(json.utf8))
    }
}
