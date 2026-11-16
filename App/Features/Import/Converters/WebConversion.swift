import Foundation
import UIKit

// The steps every single-document web conversion shares (text, Markdown, HTML, web archives,
// Office documents, slides): a private workspace in the staging directory that is always
// removed, failures turned into `ConversionError.failed` with a reason that names the problem,
// the check that the loaded page shows something, and the join with its outline and links.

/// Where the outline of a single-document conversion comes from.
nonisolated enum WebOutlineSource: Sendable {
    case none
    /// The `h1`–`h6` collected while printing (`WebPrintedPart.headings`).
    case headings
    /// Headings read from the original file, in reading order, located by their text.
    case orderedHeadings([WebOrderedHeading])
    /// One entry per page, already placed.
    case entries([WebPDFOutlineItem])
}

nonisolated struct WebOrderedHeading: Sendable, Equatable {
    var level: Int
    var title: String
}

nonisolated enum WebConversion {
    /// Runs `body` with a fresh workspace inside `input.directory`. The workspace is removed
    /// afterwards; on any error the output is removed too and the error is mapped by
    /// `conversionError(for:noun:)`.
    static func run(_ input: ConversionInput, noun: String,
                    _ body: (URL) async throws -> ConvertedDocument) async throws -> ConvertedDocument {
        let workspace = input.directory.appendingPathComponent(".web-parts-\(UUID().uuidString)", isDirectory: true)
        do {
            try Task.checkCancellation()
            try await makeDirectory(workspace)
            let converted = try await body(workspace)
            await remove([workspace])
            return converted
        } catch {
            await remove([workspace, input.outputURL])
            throw conversionError(for: error, noun: noun)
        }
    }

    /// `noun` names the thing in the reason ("document", "presentation").
    static func conversionError(for error: any Error, noun: String) -> any Error {
        switch error {
        case is CancellationError, is ConversionError: error
        case let error as WebRenderError: ConversionError.failed(reason: "The \(noun) could not be laid out: \(error.reason).")
        default: ConversionError.failed(reason: "The \(noun) could not be converted (\(error.localizedDescription)).")
        }
    }

    @concurrent
    static func makeDirectory(_ url: URL) async throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ConversionError.failed(reason: "There is no room to convert the file (\(error.localizedDescription)).")
        }
    }

    @concurrent
    static func remove(_ urls: [URL]) async {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    @concurrent
    static func readFile(_ url: URL, maxSize: Int = 512 << 20) async throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxSize else {
            throw ConversionError.failed(reason: "The file is too large to convert (\(size / (1 << 20)) MB).")
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ConversionError.failed(reason: "The file could not be read (\(error.localizedDescription)).")
        }
    }

    /// Finds the outline and the links in the printed parts and joins them into `output`. Off the
    /// main thread. Returns the page count.
    @concurrent
    static func assemble(_ parts: [WebPrintedPart], outline source: WebOutlineSource, title: String?, output: URL,
                         diagnostics: WebConversionDiagnostics?, progress: @Sendable (Double) -> Void) async throws -> Int {
        let total = parts.reduce(0) { $0 + $1.pageCount }
        guard total > 0 else { throw ConversionError.failed(reason: "Nothing was printed: the file laid out as no pages.") }
        var locator = WebTargetLocator(printed: parts)
        let outline: [WebPDFOutlineItem]
        switch source {
        case .none: outline = []
        case .headings: outline = locator.headingOutline()
        case let .orderedHeadings(headings): outline = locator.outline(ofHeadingsInOrder: headings.map { ($0.level, $0.title) })
        case let .entries(entries): outline = entries
        }
        try Task.checkCancellation()
        let links = locator.links()
        diagnostics?.record(outline: locator.outlineStatistics, links: locator.linkStatistics)
        progress(0.2)
        try Task.checkCancellation()
        return try WebPDFJoiner.join(parts: parts.filter { $0.pageCount > 0 }.map(\.pdf), to: output, outline: outline, links: links,
                                     info: WebPDFDocumentInfo(title: title, author: nil),
                                     progress: { progress(0.2 + 0.8 * $0) })
    }
}

/// What the loaded page shows, checked before printing so a file that renders as nothing fails
/// with a reason instead of becoming a blank PDF.
nonisolated struct WebPageContent: Sendable, Equatable, Decodable {
    /// Characters of visible text.
    var text: Int
    /// Pictures that loaded, plus `svg` and `canvas` elements.
    var media: Int
    /// The page is WebKit's PDF viewer showing a document it converted (iWork files).
    var pdfPlugin: Bool
    var title: String
    var firstHeading: String

    var isEmpty: Bool { text == 0 && media == 0 && !pdfPlugin }

    /// Also replaces each picture that did not load (not in the file, or blocked) with its
    /// description, or hides it, so no broken-picture box is printed.
    static let script = """
        const body = document.body;
        const clean = s => (s || '').replace(/\\s+/g, ' ').trim();
        let media = 0;
        for (const image of Array.from(document.images || [])) {
          if (image.complete && image.naturalWidth > 0) { media += 1; continue; }
          const alt = clean(image.getAttribute('alt'));
          if (alt && image.parentNode) {
            const span = document.createElement('span');
            span.className = 'tt-image-alt';
            span.textContent = alt;
            image.parentNode.replaceChild(span, image);
          } else {
            image.style.setProperty('display', 'none', 'important');
          }
        }
        media += document.querySelectorAll('svg, canvas').length;
        const plugin = !!document.querySelector('embed[type="application/pdf"]');
        const h1 = document.querySelector('h1');
        return JSON.stringify({
          text: body ? clean(body.innerText).length : 0, media: media, pdfPlugin: plugin,
          title: clean(document.title), firstHeading: h1 ? clean(h1.textContent).slice(0, 200) : ''
        });
        """

    @MainActor
    static func check(_ renderer: WebPDFRenderer) async throws -> WebPageContent {
        let json = try await renderer.evaluate(script)
        guard let content = try? JSONDecoder().decode(WebPageContent.self, from: Data(json.utf8)) else {
            throw WebRenderError.scriptFailed("unexpected result from the content check")
        }
        return content
    }
}
