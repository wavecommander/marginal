import Foundation
import PDFKit
import ReaderCore
import UIKit

// PowerPoint (.pptx, .ppt) and Keynote → PDF, one slide per page at the slide's own size, with
// selectable text. See docs/FORMAT_IMPORT_PLAN.md, "PowerPoint and Keynote" and F0 finding 6.
//
// How (found on the iOS 27 simulator): the file is served through the content scheme as its own
// MIME type and WebKit's QuickLook converter lays every slide out as a fixed-size `div.slide`
// (960 × 540 CSS px for a 16:9 deck, 1 px = 1 pt), stacked with a small gap. The paper is set to
// the slide's size with no margins, the gap is removed, and every slide gets a page break after
// it and none inside it, so each slide is exactly one page; the break after the last slide is
// suppressed so no blank page follows. Long decks are printed in segments of 16 slides (a slide
// is one page, so a segment ends exactly at a slide). A Keynote file that WebKit shows in its PDF
// viewer instead is printed page by page at the PDF's own page size (`WebPluginPageProbe`).
//
// Decisions the plan left open:
// - Outline: one entry per slide, the first line of the slide's text (at most 80 characters),
//   or "Slide N" for a slide with no text.
// - A deck whose printed page count does not match its slide count (a slide WebKit laid out
//   taller than the others, say) is still converted; the outline then finds each slide's first
//   line in the pages, and the diagnostics say so.
// - Title: `.pptx` core properties, else none.

/// Turns PowerPoint and Keynote presentations into a PDF with one page per slide.
nonisolated struct SlidesConverter: DocumentConverter {
    var version: Int { 1 }
    var formats: Set<ImportFormat> { [.powerPoint, .keynote] }
    var loadTimeout: TimeInterval = 90
    /// Slides per printed segment.
    var slidesPerSegment = 16
    var diagnostics: WebConversionDiagnostics?
    var trace: (@Sendable (String) -> Void)?

    func convert(_ input: ConversionInput, progress: @escaping @Sendable (Double) -> Void) async throws -> ConvertedDocument {
        try await WebConversion.run(input, noun: "presentation") { workspace in
            let file = try await OfficeSourceFile.prepare(input, workspace: workspace)
            let ext = file.pathExtension.lowercased()
            let format: ImportFormat = input.format == .keynote ? .keynote : .powerPoint
            let path = "presentation.\(ext.isEmpty ? (format == .keynote ? "key" : "pptx") : ext)"
            let resources = WebFileResources([path: .init(source: .file(file), mimeType: OfficeMIMEType.forFile(extension: ext, format: format),
                                                          textEncodingName: nil)])
            let title = await Self.readTitle(file, format: format)
            progress(0.05)
            let rendered = try await SlidesPrinter.print(
                resources, path: path, workspace: workspace, timeout: loadTimeout, slidesPerSegment: slidesPerSegment,
                kind: format == .keynote ? "a Keynote presentation" : "a PowerPoint presentation",
                diagnostics: diagnostics, trace: trace, progress: { progress(0.05 + 0.8 * $0) })
            try Task.checkCancellation()
            let outline = await Self.outline(for: rendered, diagnostics: diagnostics)
            let pageCount = try await WebConversion.assemble(rendered.parts, outline: outline, title: title,
                                                             output: input.outputURL, diagnostics: diagnostics,
                                                             progress: { progress(0.85 + 0.15 * $0) })
            progress(1)
            return ConvertedDocument(pdf: input.outputURL, pageCount: pageCount, title: title, coverImage: nil)
        }
    }

    @concurrent
    static func readTitle(_ file: URL, format: ImportFormat) async -> String? {
        format == .powerPoint ? OfficeOpenXMLInfo.read(file, word: false).title : nil
    }

    /// One entry per slide: on its page when every slide printed as one page, else found by text.
    @concurrent
    static func outline(for rendered: SlidesPrinter.Rendered, diagnostics: WebConversionDiagnostics?) async -> WebOutlineSource {
        let pages = rendered.parts.reduce(0) { $0 + $1.pageCount }
        var titles = rendered.slideTitles
        if titles == nil {
            // Shown as a PDF: the first line of each printed page.
            var found: [String] = []
            for part in rendered.parts {
                guard let document = PDFDocument(url: part.pdf) else { continue }
                for index in 0..<document.pageCount {
                    found.append(SlidesPrinter.firstLine(document.page(at: index)?.string ?? ""))
                }
            }
            titles = found
        }
        let named = (titles ?? []).enumerated().map { index, title in title.isEmpty ? "Slide \(index + 1)" : title }
        if named.count == pages {
            return .entries(named.enumerated().map { WebPDFOutlineItem(title: $1, pageIndex: $0) })
        }
        diagnostics?.note("slides \(named.count) ≠ pages \(pages): outline placed by text")
        return .orderedHeadings(named.map { WebOrderedHeading(level: 1, title: $0) })
    }
}

/// The slide CSS: paper-sized slides with no gap, a page break after each and none inside.
nonisolated enum SlidesStyle {
    static func css(width: Int, height: Int) -> String {
        """
        :root { color-scheme: only light; }
        html, body { margin: 0 !important; padding: 0 !important; background: #ffffff !important; -webkit-text-size-adjust: none; }
        div.loading-slide { display: none !important; }
        div.slide { margin: 0 !important; border: 0 !important; box-shadow: none !important; width: \(width)px !important; \
        height: \(height)px !important; overflow: hidden !important; break-inside: avoid; page-break-inside: avoid; \
        break-after: page; page-break-after: always; }
        """
    }

    /// Counts the slides, measures the first, and reads each slide's first line of text.
    static let measureScript = """
        const slides = Array.from(document.querySelectorAll('div.slide'));
        if (!slides.length) { return JSON.stringify({count: 0, width: 0, height: 0, titles: []}); }
        const r = slides[0].getBoundingClientRect();
        const titles = slides.map(slide => {
          const lines = (slide.innerText || '').split('\\n').map(s => s.replace(/\\s+/g, ' ').trim()).filter(s => s);
          return lines.length ? lines[0].slice(0, 80) : '';
        });
        return JSON.stringify({count: slides.length, width: r.width, height: r.height, titles: titles});
        """

    struct Measure: Decodable {
        var count: Int
        var width: Double
        var height: Double
        var titles: [String]
    }

    /// Applies `css` (an argument), then suppresses the break after the last slide.
    static let applyScript = """
        \(WebPDFRenderer.suppressEdgeBreaksJS)
        let style = document.getElementById('tactile-slides-style');
        if (!style) {
          style = document.createElement('style');
          style.id = 'tactile-slides-style';
          (document.head || document.documentElement).appendChild(style);
        }
        style.textContent = css;
        void document.documentElement.offsetHeight;
        suppressEdgeBreaks();
        void document.documentElement.offsetHeight;
        return '';
        """
}

@MainActor
enum SlidesPrinter {
    struct Rendered: Sendable {
        var parts: [WebPrintedPart]
        /// Each slide's first line of text; `nil` when the deck was shown as a PDF.
        var slideTitles: [String]?
        var slideCount: Int
    }

    static func print(_ resources: WebFileResources, path: String, workspace: URL, timeout: TimeInterval, slidesPerSegment: Int,
                      kind: String, diagnostics: WebConversionDiagnostics?, trace: (@Sendable (String) -> Void)?,
                      progress: @escaping (Double) -> Void) async throws -> Rendered {
        var configuration = WebPDFRenderer.Configuration(pageSize: CGSize(width: 960, height: 540), margins: .zero)
        configuration.loadTimeout = timeout
        configuration.trace = trace
        let renderer = WebPDFRenderer(provider: resources, configuration: configuration)
        defer { renderer.tearDown() }
        let started = CACurrentMediaTime()
        do {
            try await renderer.start()
            try await renderer.load(path: path)
        } catch let error as WebRenderError {
            if let reason = OfficeSourceFile.loadFailureReason(error, kind: kind) { throw ConversionError.failed(reason: reason) }
            throw error
        }
        diagnostics?.record(loadSeconds: CACurrentMediaTime() - started)
        progress(0.3)
        let content = try await WebPageContent.check(renderer)
        if content.isEmpty {
            throw ConversionError.failed(reason: "The presentation shows no slides: it may be damaged or empty.")
        }

        if content.pdfPlugin {
            let measured = try await WebPluginPageProbe.measure(renderer, workspace: workspace)
            let size = measured ?? CGSize(width: 960, height: 540)
            if measured == nil { diagnostics?.note("PDF viewer page size not found: \(size)") }
            renderer.setPage(size: size, margins: .zero)
            diagnostics?.record(pageSize: size, margins: .zero)
            let url = workspace.appendingPathComponent("part-000.pdf")
            let report = try await renderer.printPDF(to: url)
            let parts = [WebPrintedPart(path: path, pdf: url, pageCount: report.pageCount,
                                        layout: WebDocumentLayout(height: 1, anchors: [], links: []), report: report)]
            diagnostics?.record(parts: parts)
            diagnostics?.record(requests: renderer.schemeHandler.records)
            progress(1)
            return Rendered(parts: parts, slideTitles: nil, slideCount: report.pageCount)
        }

        let json = try await renderer.evaluate(SlidesStyle.measureScript)
        guard let measure = try? JSONDecoder().decode(SlidesStyle.Measure.self, from: Data(json.utf8)), measure.count > 0,
              measure.width >= 10, measure.height >= 10 else {
            throw ConversionError.failed(reason: "No slides were found in the presentation.")
        }
        let width = Int(measure.width.rounded(.up)), height = Int(measure.height.rounded(.up))
        renderer.setPage(size: CGSize(width: width, height: height), margins: .zero)
        diagnostics?.record(pageSize: CGSize(width: width, height: height), margins: .zero)
        _ = try await renderer.evaluate(SlidesStyle.applyScript, arguments: ["css": SlidesStyle.css(width: width, height: height)])
        // A slide is one page, so a segment of N pages is N slides.
        let parts = try await renderer.printSegments(path: path, into: workspace, prefix: "slides", pagesPerSegment: slidesPerSegment,
                                                     splitAbove: slidesPerSegment + slidesPerSegment / 2,
                                                     progress: { progress(0.3 + 0.7 * $0) })
        diagnostics?.record(parts: parts)
        diagnostics?.record(requests: renderer.schemeHandler.records)
        let pages = parts.reduce(0) { $0 + $1.pageCount }
        if pages != measure.count { diagnostics?.note("printed \(pages) pages for \(measure.count) slides") }
        return Rendered(parts: parts, slideTitles: measure.titles, slideCount: measure.count)
    }

    nonisolated static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        return String(line.prefix(80))
    }
}
