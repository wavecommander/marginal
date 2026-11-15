import Foundation
import PDFKit
import Testing
import UIKit
@testable import Marginal

/// The shared web-converter pieces: the scheme's path rules, the text locator and the renderer
/// on a plain document.
@Suite(.serialized)
struct WebConverterTests {
    private let scheme = WebPDFRenderer.scheme
    private let host = WebPDFRenderer.host

    private func path(_ string: String) -> String? {
        WebResourcePath.path(of: URL(string: string)!, scheme: scheme, host: host)
    }

    @Test func pathsAreNormalisedAndCannotLeaveTheRoot() {
        #expect(path("tactile-content://document/OEBPS/text/ch1.xhtml") == "OEBPS/text/ch1.xhtml")
        #expect(path("tactile-content://document/OEBPS/text/../images/a%20b.png") == "OEBPS/images/a b.png")
        #expect(path("tactile-content://document/OEBPS/./style.css?x=1#frag") == "OEBPS/style.css")
        #expect(path("tactile-content://document/OEBPS/%C3%A9t%C3%A9.xhtml") == "OEBPS/été.xhtml")
        #expect(path("tactile-content://document/../secret") == nil)
        #expect(path("tactile-content://document/OEBPS/../../secret") == nil)
        #expect(path("tactile-content://document/OEBPS/..%2F..%2Fsecret") == nil)
        #expect(path("tactile-content://document/a%00b") == nil)
        #expect(path("tactile-content://other/OEBPS/ch1.xhtml") == nil)
        #expect(path("https://document/OEBPS/ch1.xhtml") == nil)
        #expect(path("tactile-content://document/") == nil)
        let url = WebPDFRenderer.url(for: "OEBPS/a b/ch#1.xhtml", fragment: "sec 2")
        #expect(WebPDFRenderer.path(of: url) == "OEBPS/a b/ch#1.xhtml")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment == "sec 2")
    }

    @Test func mimeTypesAreExactForWhatWebKitChecks() {
        #expect(WebResourcePath.mimeType(forPath: "a/ch1.XHTML") == "application/xhtml+xml")
        #expect(WebResourcePath.mimeType(forPath: "style.css") == "text/css")
        #expect(WebResourcePath.mimeType(forPath: "f.woff2") == "font/woff2")
        #expect(WebResourcePath.mimeType(forPath: "pic.jpeg") == "image/jpeg")
        #expect(WebResourcePath.mimeType(forPath: "weird.bin") == nil)
        #expect(WebResourcePath.defaultTextEncoding(forMIMEType: "text/css") == "utf-8")
        #expect(WebResourcePath.defaultTextEncoding(forMIMEType: "application/xhtml+xml") == nil)
    }

    @Test func obfuscationKeysFollowTheTwoSchemes() {
        // IDPF: SHA-1 of the identifier without whitespace (20 bytes).
        #expect(EPUBArchiveResources.idpfKey(identifier: " urn:uuid:abc \n") == EPUBArchiveResources.idpfKey(identifier: "urn:uuid:abc"))
        #expect(EPUBArchiveResources.idpfKey(identifier: "x").count == 20)
        // Adobe: the UUID's 16 bytes; nothing for a non-UUID identifier.
        let key = EPUBArchiveResources.adobeKey(identifier: "urn:uuid:00112233-4455-6677-8899-AABBCCDDEEFF")
        #expect(key == [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        #expect(EPUBArchiveResources.adobeKey(identifier: "isbn:9780000000000") == nil)
        // XOR across chunk boundaries equals XOR of the whole.
        let original = Data((0..<3000).map { UInt8($0 % 251) })
        let keyBytes: [UInt8] = Array(1...20)
        var whole = original
        EPUBArchiveResources.xor(&whole, offset: 0, key: keyBytes, span: 1040)
        var pieces = Data()
        for start in stride(from: 0, to: original.count, by: 700) {
            var chunk = Data(original[start..<min(original.count, start + 700)])
            EPUBArchiveResources.xor(&chunk, offset: start, key: keyBytes, span: 1040)
            pieces.append(chunk)
        }
        #expect(pieces == whole)
        #expect(whole[1040...] == original[1040...])
        #expect(whole[0] == original[0] ^ 1)
    }

    @Test func contextPatternDropsACutFirstWord() throws {
        #expect(WebTextPattern.contextPattern("") == nil)
        let s = WebTextPattern.spaced
        #expect(s("see") == "s\\s*e\\s*e")
        #expect(WebTextPattern.contextPattern("see the") == s("see") + "\\s*" + s("the"))
        let cut = String(repeating: "x", count: 30) + "ord one two three four"
        #expect(WebTextPattern.contextPattern(cut) == ["one", "two", "three", "four"].map(s).joined(separator: "\\s*"))
        // Letter-spaced PDF text still matches.
        let expression = try #require(WebTextPattern.expression(for: "The Introduction", maxWords: 8))
        let text = "THE I N TRODUCTION\nfollows" as NSString
        #expect(expression.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) != nil)
    }

    /// The renderer on its own: a document with no JavaScript running, the app's query working,
    /// and a print in several batches.
    @MainActor
    @Test func rendererPrintsInBatchesWithPageScriptsOff() async throws {
        let paragraphs = (1...400).map { "<p>Line \($0) of the batch test, long enough to wrap onto a second line of text.</p>" }.joined()
        let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>Original</title>
            <script>document.title = 'SCRIPT RAN';</script></head><body>\(paragraphs)</body></html>
            """
        let provider = WebTestProvider(["doc.html": (Data(html.utf8), "text/html")])
        var configuration = WebPDFRenderer.Configuration(pageSize: CGSize(width: 432, height: 648), margins: UIEdgeInsets(top: 36, left: 36, bottom: 36, right: 36))
        configuration.styleSheet = "body { font-size: 12px; }"
        configuration.sliceBudget = 0.02
        let renderer = WebPDFRenderer(provider: provider, configuration: configuration)
        try await renderer.start()
        defer { renderer.tearDown() }
        try await renderer.load(path: "doc.html")
        #expect(renderer.webView?.title == "Original")
        #expect(try await renderer.evaluate("return document.querySelectorAll('p').length.toString();") == "400")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("web-batch-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try await renderer.printPDF(to: url)
        print(String(format: "Web renderer: %d pages, %d batches, longest slice %.1f ms, main %.1f ms, elapsed %.1f ms",
                     report.pageCount, report.batches, report.longestMainThreadSlice * 1000, report.mainThreadTime * 1000,
                     report.elapsed * 1000))
        #expect(report.pageCount > 10)
        #expect(report.batches > 1)
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == report.pageCount)
        #expect(document.findString("Line 399 of the batch test", withOptions: []).count == 1)
        // A missing document fails the load with a clear error rather than hanging.
        await #expect(throws: WebRenderError.self) { try await renderer.load(path: "missing.html") }
    }

    @MainActor
    @Test func aLoadThatNeverFinishesTimesOut() async throws {
        let provider = WebTestProvider([:], stallPaths: ["slow.html"])
        var configuration = WebPDFRenderer.Configuration(pageSize: CGSize(width: 432, height: 648), margins: .zero)
        configuration.loadTimeout = 2
        let renderer = WebPDFRenderer(provider: provider, configuration: configuration)
        try await renderer.start()
        defer { renderer.tearDown() }
        let started = CACurrentMediaTime()
        await #expect(throws: WebRenderError.timedOut(2)) { try await renderer.load(path: "slow.html") }
        #expect(CACurrentMediaTime() - started < 5)
        provider.releaseStalls()
    }
}

/// Serves fixed files; `stallPaths` block (on the handler's queue) until released.
nonisolated final class WebTestProvider: WebResourceProvider, @unchecked Sendable {
    private let files: [String: (Data, String)]
    private let stallPaths: Set<String>
    private let release = DispatchSemaphore(value: 0)

    init(_ files: [String: (Data, String)], stallPaths: Set<String> = []) {
        self.files = files
        self.stallPaths = stallPaths
    }

    func releaseStalls() { release.signal() }

    func resource(at path: String) throws -> WebResource? {
        if stallPaths.contains(path) {
            _ = release.wait(timeout: .now() + 10)
            return nil
        }
        guard let (data, type) = files[path] else { return nil }
        return .data(data, mimeType: type, textEncodingName: WebResourcePath.defaultTextEncoding(forMIMEType: type))
    }
}
