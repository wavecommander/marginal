import Foundation
import QuartzCore
import UIKit
import WebKit

// The off-screen renderer the web-family converters share (EPUB now; text, Markdown, HTML,
// Office documents and slides later). It lays a document out in a `WKWebView` that is never
// on screen and paginates it through the system print path, which gives PDF pages with real,
// selectable text. See docs/FORMAT_IMPORT_PLAN.md, "Web converter" and "F0 findings".
//
// Isolation: the document's own JavaScript is off, every load other than the content scheme is
// blocked by a content rule list (scripts off is not enough: finding 5), navigation away from the
// content scheme is cancelled, and the data store is non-persistent. The app's own queries run in
// a separate content world.
//
// Main thread: printing runs on the main thread. WebKit renders the whole document for printing
// in one synchronous step on the first page drawn (about 2 ms a page for text, 5 for pages with
// pictures), and drawing each page into the PDF costs about 2 ms more. The drawing is done in
// batches sized to `sliceBudget` with a yield between them; the first step cannot be split, so
// long documents are printed in segments (`planSegments`/`showSegment`).
//
// Typical use (on the main actor):
//
//     let renderer = WebPDFRenderer(provider: resources, configuration: .init(pageSize: size, margins: m, styleSheet: css))
//     try await renderer.start()
//     _ = try await renderer.load(path: "OEBPS/ch1.xhtml")
//     let segments = try await renderer.planSegments(pagesPerSegment: 16, splitAbove: 24)
//     for segment in 0..<segments {
//         if segments > 1 { try await renderer.showSegment(segment) }
//         let layout = try await renderer.collectLayout()
//         let report = try await renderer.printPDF(to: partURL(segment))
//     }
//     renderer.tearDown()

/// Why the renderer could not produce a PDF.
nonisolated enum WebRenderError: Error, Sendable, Equatable {
    /// The page did not load (missing main resource, network-style failure).
    case loadFailed(String)
    /// Loading (or waiting for fonts and images) took longer than the configured timeout, in seconds.
    case timedOut(Int)
    /// The web content process crashed or was killed (memory pressure, for instance).
    case contentProcessTerminated
    /// One of the app's own scripts failed.
    case scriptFailed(String)
    /// The print path could not write the PDF.
    case printFailed(String)
    /// The content rule list that blocks the network could not be compiled.
    case blockerUnavailable(String)
    /// `start()` was not called, or `tearDown()` already was.
    case notStarted

    var reason: String {
        switch self {
        case let .loadFailed(detail): "it could not be loaded (\(detail))"
        case let .timedOut(seconds): "it did not finish loading within \(seconds) seconds"
        case .contentProcessTerminated: "the web content process stopped while laying it out"
        case let .scriptFailed(detail): "laying it out failed (\(detail))"
        case let .printFailed(detail): "it could not be paginated (\(detail))"
        case let .blockerUnavailable(detail): "network blocking could not be set up (\(detail))"
        case .notStarted: "the renderer was not running"
        }
    }
}

/// What `load` found once the document was ready.
nonisolated struct WebLoadReport: Sendable, Equatable {
    /// The XML parser reported an error (an XHTML file that is not well-formed): WebKit then
    /// shows only part of it. Serving it again as `text/html` is the usual repair.
    var hasParserError: Bool
    /// The laid-out document height in CSS pixels at the printable width.
    var contentHeight: Double
}

/// What one print run did, including how long it held the main thread.
nonisolated struct WebPrintReport: Sendable, Equatable {
    var pageCount: Int
    /// The longest single stretch the main thread was busy printing (pagination or one batch).
    var longestMainThreadSlice: TimeInterval
    /// All main-thread time spent printing, summed over batches.
    var mainThreadTime: TimeInterval
    /// Wall-clock time, including the yields between batches.
    var elapsed: TimeInterval
    var batches: Int
}

/// Positions of the document's targets and links, measured in the web view before printing.
/// Fractions are of the document's height (0 = top, 1 = bottom).
nonisolated struct WebDocumentLayout: Sendable, Equatable, Codable {
    struct Anchor: Sendable, Equatable, Codable {
        var id: String
        var top: Double
        /// The element's own text (collapsed, at most 80 characters), or empty.
        var text: String
        /// When `text` is empty: the text that follows the element, for empty anchors.
        var following: String
    }

    struct Link: Sendable, Equatable, Codable {
        /// Absolute, resolved against the document (the content scheme for internal links).
        var href: String
        /// The link's text, collapsed (at most 200 characters); empty for an image link.
        var text: String
        /// Up to 48 characters of text just before the link, collapsed.
        var before: String
        var top: Double
    }

    var height: Double
    var anchors: [Anchor]
    var links: [Link]
}

@MainActor
final class WebPDFRenderer: NSObject, WKNavigationDelegate {
    struct Configuration: Sendable {
        /// The paper size in points.
        var pageSize: CGSize
        /// Space between the paper edge and the text, in points.
        var margins: UIEdgeInsets
        /// CSS added after the document's own style sheets (so it wins ties).
        var styleSheet: String = ""
        /// Seconds to wait for a document (and its fonts and images) before giving up.
        var loadTimeout: TimeInterval = 60
        /// Target main-thread time per print batch. Pages are drawn in batches sized to this
        /// budget, with a yield to the main run loop between batches.
        var sliceBudget: TimeInterval = 0.040
        /// `false` only in the test that proves the network check can see a leak.
        var blocksNetwork = true
        /// Receives a line per step (load, ready, print) with timings, for diagnostics.
        var trace: (@Sendable (String) -> Void)?

        var printableRect: CGRect {
            CGRect(origin: .zero, size: pageSize).inset(by: margins)
        }
    }

    /// The URL scheme the content is served under. Lower case (WebKit requires it).
    nonisolated static let scheme = "tactile-content"
    nonisolated static let host = "document"
    nonisolated static let ruleListIdentifier = "software.tactile.marginal.block-network.v1"
    /// Everything is blocked, then the content scheme is let through. Alternation is not allowed
    /// in rule-list regexes, and `^(https?|…):` was rejected (F0 findings).
    nonisolated static let ruleListJSON = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},\
        {"trigger":{"url-filter":"^\(scheme):"},"action":{"type":"ignore-previous-rules"}}]
        """

    let configuration: Configuration
    let schemeHandler: WebResourceSchemeHandler
    private(set) var webView: WKWebView?
    private var navigation: WKNavigation?
    private var navigationWait: WebOneShot<Void>?
    private var pendingScripts: [WebOneShot<String>] = []
    private(set) var contentProcessTerminated = false
    /// Whether the current navigation has committed (the content process answered).
    private var committed = false

    init(provider: any WebResourceProvider, configuration: Configuration) {
        self.configuration = configuration
        schemeHandler = WebResourceSchemeHandler(scheme: Self.scheme, host: Self.host, provider: provider)
        super.init()
    }

    /// The URL that serves `path` from the provider.
    nonisolated static func url(for path: String, fragment: String? = nil) -> URL {
        WebResourcePath.url(scheme: scheme, host: host, path: path, fragment: fragment)
    }

    /// The provider path a content URL names, or `nil` for any other URL.
    nonisolated static func path(of url: URL) -> String? {
        WebResourcePath.path(of: url, scheme: scheme, host: host)
    }

    // MARK: Lifecycle

    /// Builds the web view. Compiles the network blocker on first use.
    func start() async throws {
        guard webView == nil else { return }
        let begun = CACurrentMediaTime()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: Self.scheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = Self.dataStore
        config.dataDetectorTypes = []
        config.allowsInlineMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.suppressesIncrementalRendering = true
        if configuration.blocksNetwork {
            config.userContentController.add(try await Self.networkBlocker())
            configuration.trace?(String(format: "network blocker ready after %.0f ms", (CACurrentMediaTime() - begun) * 1000))
        }
        let created = CACurrentMediaTime()
        defer { configuration.trace?(String(format: "WKWebView init took %.0f ms", (CACurrentMediaTime() - created) * 1000)) }
        let view = WKWebView(frame: CGRect(origin: .zero, size: configuration.printableRect.size), configuration: config)
        // Book CSS with `prefers-color-scheme: dark` rules must not print dark pages.
        view.overrideUserInterfaceStyle = .light
        view.navigationDelegate = self
        webView = view
        configuration.trace?(String(format: "started the web view in %.0f ms", (CACurrentMediaTime() - begun) * 1000))
    }

    /// Stops loading and releases the web view (and with it the content process). Pending waits
    /// fail. Safe to call more than once.
    func tearDown() {
        navigationWait?.resume(.failure(CancellationError()))
        for script in pendingScripts { script.resume(.failure(CancellationError())) }
        pendingScripts.removeAll()
        guard let view = webView else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeAllContentRuleLists()
        webView = nil
        navigation = nil
    }

    /// One non-persistent store for every renderer: nothing is written to disk, and the
    /// networking session behind it is set up once per launch rather than per conversion.
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    private static var compiledBlocker: WebUncheckedBox<WKContentRuleList>?

    private static func networkBlocker() async throws -> WKContentRuleList {
        if let compiledBlocker { return compiledBlocker.value }
        guard let store = WKContentRuleListStore.default() else {
            throw WebRenderError.blockerUnavailable("no rule list store")
        }
        let box: WebUncheckedBox<WKContentRuleList> = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: ruleListIdentifier, encodedContentRuleList: ruleListJSON) { list, error in
                if let list {
                    continuation.resume(returning: WebUncheckedBox(list))
                } else {
                    continuation.resume(throwing: WebRenderError.blockerUnavailable(error?.localizedDescription ?? "unknown error"))
                }
            }
        }
        compiledBlocker = box
        return box.value
    }

    // MARK: Loading

    /// Loads the document at `path` and waits until it is ready to print: the load event, the
    /// app's style sheet applied, web fonts loaded and every image settled (loaded or failed).
    /// Throws `WebRenderError.timedOut` after `configuration.loadTimeout`.
    @discardableResult
    func load(path: String) async throws -> WebLoadReport {
        try await load(url: Self.url(for: path))
    }

    @discardableResult
    func load(url: URL) async throws -> WebLoadReport {
        guard webView != nil, !contentProcessTerminated else {
            throw contentProcessTerminated ? WebRenderError.contentProcessTerminated : WebRenderError.notStarted
        }
        try Task.checkCancellation()
        let begun = CACurrentMediaTime()
        configuration.trace?("load \(url.path)")
        var deadline = CACurrentMediaTime() + configuration.loadTimeout
        let timeout = Int(configuration.loadTimeout.rounded())
        do {
            try await navigate(to: url, timeout: timeout)
        } catch WebRenderError.timedOut where !committed {
            // Nothing came back at all: the content process never started or is stuck (seen when
            // the system is busy launching processes). Start a fresh one, once.
            configuration.trace?("no response for \(url.path); restarting the web view")
            tearDown()
            try await start()
            deadline = CACurrentMediaTime() + configuration.loadTimeout
            try await navigate(to: url, timeout: timeout)
        }
        configuration.trace?(String(format: "loaded %@ in %.0f ms", url.path, (CACurrentMediaTime() - begun) * 1000))
        let remaining = max(1, deadline - CACurrentMediaTime())
        let json = try await evaluate(Self.readyScript, arguments: ["css": configuration.styleSheet],
                                      timeout: remaining, timeoutError: .timedOut(timeout))
        configuration.trace?(String(format: "ready %@ in %.0f ms", url.path, (CACurrentMediaTime() - begun) * 1000))
        struct Ready: Decodable { var parserError: Bool; var height: Double }
        guard let ready = try? JSONDecoder().decode(Ready.self, from: Data(json.utf8)) else {
            throw WebRenderError.scriptFailed("unexpected result from the readiness check")
        }
        return WebLoadReport(hasParserError: ready.parserError, contentHeight: ready.height)
    }

    private func navigate(to url: URL, timeout: Int) async throws {
        guard let webView else { throw WebRenderError.notStarted }
        committed = false
        defer { navigationWait = nil }
        try await wait(seconds: configuration.loadTimeout, timeoutError: .timedOut(timeout)) { (wait: WebOneShot<Void>) in
            self.navigationWait = wait
            self.navigation = webView.load(URLRequest(url: url))
        }
    }

    /// Defines `suppressLeadingBreak()`: a forced break before the first visible content (a
    /// chapter heading with `break-before: page`, say) would print an empty first page, so it is
    /// switched off on that content and its ancestors.
    nonisolated static let suppressLeadingBreakJS = """
        const suppressLeadingBreak = () => {
          if (!document.body) { return; }
          const media = ['IMG', 'SVG', 'svg', 'VIDEO', 'OBJECT', 'EMBED', 'CANVAS', 'image'];
          const visible = el => el && el.getClientRects().length > 0;
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
            acceptNode: node => node.nodeType === Node.TEXT_NODE
              ? (node.nodeValue.trim() && visible(node.parentElement) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP)
              : (media.includes(node.nodeName) && visible(node) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP)
          });
          const first = walker.nextNode();
          for (let el = first && (first.nodeType === Node.TEXT_NODE ? first.parentElement : first);
               el && el !== document.documentElement; el = el.parentElement) {
            if (el.style) {
              el.style.setProperty('break-before', 'auto', 'important');
              el.style.setProperty('page-break-before', 'auto', 'important');
            }
          }
        };
        """

    /// Applies the style sheet, then waits for fonts and images. Runs in the app's own content
    /// world, so it works with the page's JavaScript off.
    nonisolated static let readyScript = """
        const root = document.documentElement;
        if (!root) { return JSON.stringify({parserError: false, height: 0}); }
        const xhtml = 'http://www.w3.org/1999/xhtml';
        if (css && root.namespaceURI === xhtml) {
          const style = document.createElementNS(xhtml, 'style');
          style.setAttribute('data-tactile', '');
          style.textContent = css;
          (document.head || root).appendChild(style);
        }
        \(suppressLeadingBreakJS)
        suppressLeadingBreak();
        void root.offsetHeight;
        if (document.fonts && document.fonts.ready) { await document.fonts.ready; }
        const pending = Array.from(document.images || []).filter(image => !image.complete);
        await Promise.all(pending.map(image => new Promise(done => {
          image.addEventListener('load', done, {once: true});
          image.addEventListener('error', done, {once: true});
        })));
        void root.offsetHeight;
        if (document.fonts && document.fonts.ready) { await document.fonts.ready; }
        return JSON.stringify({
          parserError: !!document.getElementsByTagName('parsererror').length,
          height: Math.max(root.scrollHeight, document.body ? document.body.scrollHeight : 0)
        });
        """

    /// Runs `functionBody` (the body of an async JavaScript function; `arguments` become its
    /// parameters) in the app's content world and returns its result as a string ("" for none).
    func evaluate(_ functionBody: String, arguments: [String: Any] = [:]) async throws -> String {
        let seconds = configuration.loadTimeout
        return try await evaluate(functionBody, arguments: arguments, timeout: seconds, timeoutError: .timedOut(Int(seconds)))
    }

    private func evaluate(_ functionBody: String, arguments: [String: Any], timeout: TimeInterval,
                          timeoutError: WebRenderError) async throws -> String {
        guard let webView, !contentProcessTerminated else {
            throw contentProcessTerminated ? WebRenderError.contentProcessTerminated : WebRenderError.notStarted
        }
        return try await wait(seconds: timeout, timeoutError: timeoutError) { (wait: WebOneShot<String>) in
            self.pendingScripts.append(wait)
            webView.callAsyncJavaScript(functionBody, arguments: arguments, in: nil, in: .defaultClient) { result in
                switch result {
                case let .success(value):
                    wait.resume(.success(value as? String ?? ""))
                case let .failure(error):
                    wait.resume(.failure(WebRenderError.scriptFailed(error.localizedDescription)))
                }
            }
        }
    }

    /// Runs `begin`, then waits for the one-shot it was handed to be resumed, the timeout, the
    /// content process ending, or the task being cancelled — whichever comes first.
    private func wait<T: Sendable>(seconds: TimeInterval, timeoutError: WebRenderError,
                                   _ begin: (WebOneShot<T>) -> Void) async throws -> T {
        try Task.checkCancellation()
        let shot = WebOneShot<T>()
        defer { pendingScripts.removeAll { ObjectIdentifier($0) == ObjectIdentifier(shot) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                shot.continuation = continuation
                let timer = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    if !Task.isCancelled { shot.resume(.failure(timeoutError)) }
                }
                shot.onResume = { timer.cancel() }
                begin(shot)
            }
        } onCancel: {
            Task { @MainActor in shot.resume(.failure(CancellationError())) }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme?.lowercased() == Self.scheme { return .allow }
        // Frames may be blank; nothing else leaves the content scheme.
        if url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" { return .allow }
        return .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        committed = true
        configuration.trace?("committed")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        navigationWait?.resume(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard navigation === self.navigation else { return }
        navigationWait?.resume(.failure(WebRenderError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard navigation === self.navigation else { return }
        navigationWait?.resume(.failure(WebRenderError.loadFailed(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        configuration.trace?("content process terminated")
        contentProcessTerminated = true
        navigationWait?.resume(.failure(WebRenderError.contentProcessTerminated))
        for script in pendingScripts { script.resume(.failure(WebRenderError.contentProcessTerminated)) }
        pendingScripts.removeAll()
    }

    // MARK: Layout

    /// Where the document's visible anchors (elements with an `id`, or `a` with a `name`) and
    /// links sit, with the text a later search of the PDF can find them by. At most 20,000 of
    /// each. Elements hidden (`display: none`, another segment) are left out.
    func collectLayout() async throws -> WebDocumentLayout {
        let json = try await evaluate(Self.layoutScript)
        do {
            return try JSONDecoder().decode(WebDocumentLayout.self, from: Data(json.utf8))
        } catch {
            throw WebRenderError.scriptFailed("unexpected layout data")
        }
    }

    nonisolated static let layoutScript = """
        const root = document.documentElement;
        if (!root) { return JSON.stringify({height: 0, anchors: [], links: []}); }
        const body = document.body || root;
        const height = Math.max(root.scrollHeight, body.scrollHeight || 0, 1);
        const scrollY = window.scrollY || 0;
        const limit = 20000;
        const clean = s => (s || '').replace(/[\\u00AD\\u200B-\\u200D\\u2060\\uFEFF]/g, '').replace(/\\s+/g, ' ').trim();
        const top = el => Math.min(1, Math.max(0, (el.getBoundingClientRect().top + scrollY) / height));
        const following = (el, max) => {
          const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
          walker.currentNode = el;
          let out = '';
          for (let node = walker.nextNode(); node && out.length < max; node = walker.nextNode()) {
            out = clean(out + ' ' + node.nodeValue);
          }
          return out.slice(0, max);
        };
        const preceding = (el, max) => {
          const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
          walker.currentNode = el;
          let out = '';
          for (let node = walker.previousNode(); node && out.length < max; node = walker.previousNode()) {
            out = node.nodeValue + ' ' + out;
            if (clean(out).length >= max) { break; }
          }
          return clean(out).slice(-max);
        };
        const anchors = [];
        for (const el of document.querySelectorAll('[id], a[name]')) {
          if (anchors.length >= limit) { break; }
          const id = el.getAttribute('id') || el.getAttribute('name');
          if (!id || el.getClientRects().length === 0) { continue; }
          const text = clean(el.textContent).slice(0, 80);
          anchors.push({id: id, top: top(el), text: text, following: text ? '' : following(el, 80)});
        }
        const links = [];
        const xlink = 'http://www.w3.org/1999/xlink';
        for (const a of document.querySelectorAll('a')) {
          if (links.length >= limit) { break; }
          const raw = a.getAttribute('href') || a.getAttributeNS(xlink, 'href');
          if (!raw || a.getClientRects().length === 0) { continue; }
          let href;
          try { href = new URL(raw, document.baseURI).href; } catch (e) { continue; }
          links.push({href: href, text: clean(a.textContent).slice(0, 200), before: preceding(a, 48), top: top(a)});
        }
        return JSON.stringify({height: height, anchors: anchors, links: links});
        """

    // MARK: Segments

    /// Splits a long document into segments of about `pagesPerSegment` pages, so each print holds
    /// the main thread for a bounded time: WebKit renders the whole document for printing in one
    /// synchronous step on the first page drawn (about 2–5 ms a page), which batching cannot
    /// split. Cuts fall between top-level blocks, preferring a heading. Returns the number of
    /// segments; 1 (nothing marked) when the document is shorter than `splitAbove` pages or has
    /// no safe place to cut. Each segment's last page ends early, like a section break.
    func planSegments(pagesPerSegment: Int, splitAbove: Int) async throws -> Int {
        let page = Double(configuration.printableRect.height)
        let json = try await evaluate(Self.planSegmentsScript, arguments: [
            "maxHeight": page * Double(pagesPerSegment), "threshold": page * Double(splitAbove),
        ])
        return max(1, Int(json) ?? 1)
    }

    /// Shows only segment `index` (from `planSegments`) and waits for the layout.
    func showSegment(_ index: Int) async throws {
        _ = try await evaluate(Self.showSegmentScript, arguments: ["index": index])
    }

    nonisolated static let planSegmentsScript = """
        const body = document.body;
        const root = document.documentElement;
        if (!body || !root) { return '1'; }
        if (Math.max(root.scrollHeight, body.scrollHeight) <= threshold) { return '1'; }
        const hasText = el => Array.from(el.childNodes).some(n => n.nodeType === Node.TEXT_NODE && n.nodeValue.trim());
        if (hasText(body)) { return '1'; }
        // Ordered lists, tables, figures and the like are never cut (hidden items would renumber).
        const whole = ['TABLE', 'OL', 'PRE', 'FIGURE', 'svg', 'SVG', 'math', 'MATH'];
        const leaves = [];
        const flatten = el => {
          for (const child of el.children) {
            const height = child.getBoundingClientRect().height;
            if (height > maxHeight && child.children.length > 1 && !hasText(child) && !whole.includes(child.nodeName)) {
              flatten(child);
            } else {
              leaves.push(child);
            }
          }
        };
        flatten(body);
        if (leaves.length < 2) { return '1'; }
        const scrollY = window.scrollY || 0;
        const tops = leaves.map(leaf => leaf.getBoundingClientRect().top + scrollY);
        const heading = el => /^H[1-6]$/i.test(el.nodeName)
          || (el.firstElementChild && /^H[1-6]$/i.test(el.firstElementChild.nodeName));
        const segment = new Array(leaves.length).fill(0);
        let current = 0, start = tops[0], lastCut = 0;
        for (let i = 1; i < leaves.length; i++) {
          if (tops[i] - start <= maxHeight) { segment[i] = current; continue; }
          let cut = i;
          for (let j = i; j > lastCut && tops[j] - start >= 0.6 * maxHeight; j--) {
            if (heading(leaves[j])) { cut = j; break; }
          }
          current += 1;
          for (let j = cut; j <= i; j++) { segment[j] = current; }
          start = tops[cut];
          lastCut = cut;
        }
        if (current === 0) { return '1'; }
        leaves.forEach((leaf, i) => leaf.setAttribute('data-tactile-segment', String(segment[i])));
        return String(current + 1);
        """

    nonisolated static let showSegmentScript = """
        \(suppressLeadingBreakJS)
        const xhtml = 'http://www.w3.org/1999/xhtml';
        let style = document.getElementById('tactile-segment-style');
        if (!style) {
          style = document.createElementNS(xhtml, 'style');
          style.id = 'tactile-segment-style';
          (document.head || document.documentElement).appendChild(style);
        }
        style.textContent = '[data-tactile-segment]:not([data-tactile-segment="' + index + '"]) { display: none !important; }';
        void document.documentElement.offsetHeight;
        suppressLeadingBreak();
        void document.documentElement.offsetHeight;
        if (document.fonts && document.fonts.ready) { await document.fonts.ready; }
        return String(document.documentElement.scrollHeight);
        """

    // MARK: Printing

    /// Paginates the loaded document into a PDF at `url` (pages of `configuration.pageSize`).
    /// Pages are drawn in batches sized to `configuration.sliceBudget`, with a yield between
    /// batches so the main thread stays responsive. Cancelling stops between batches and
    /// removes the partial file.
    func printPDF(to url: URL) async throws -> WebPrintReport {
        guard let webView, !contentProcessTerminated else {
            throw contentProcessTerminated ? WebRenderError.contentProcessTerminated : WebRenderError.notStarted
        }
        try Task.checkCancellation()
        let started = CACurrentMediaTime()
        let paper = CGRect(origin: .zero, size: configuration.pageSize)
        var mediaBox = paper
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw WebRenderError.printFailed("could not create \(url.lastPathComponent)")
        }
        var closed = false
        func abandon() {
            if !closed { context.closePDF(); closed = true }
            try? FileManager.default.removeItem(at: url)
        }

        let renderer = WebPaperRenderer(paper: paper, printable: configuration.printableRect)
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        var sliceStart = CACurrentMediaTime()
        let pageCount = renderer.numberOfPages
        var longest = CACurrentMediaTime() - sliceStart
        configuration.trace?(String(format: "paginated %d pages in %.0f ms", pageCount, longest * 1000))
        var busy = longest
        var batches = 0
        var batchSize = 4
        var index = 0
        do {
            while index < pageCount {
                if contentProcessTerminated { throw WebRenderError.contentProcessTerminated }
                try Task.checkCancellation()
                sliceStart = CACurrentMediaTime()
                let count = min(batchSize, pageCount - index)
                renderer.prepare(forDrawingPages: NSRange(location: index, length: count))
                for page in index..<(index + count) {
                    autoreleasepool {
                        context.beginPDFPage(nil)
                        context.saveGState()
                        // UIKit drawing expects a top-left origin.
                        context.translateBy(x: 0, y: paper.height)
                        context.scaleBy(x: 1, y: -1)
                        UIGraphicsPushContext(context)
                        renderer.drawPage(at: page, in: paper)
                        UIGraphicsPopContext()
                        context.restoreGState()
                        context.endPDFPage()
                    }
                }
                let slice = CACurrentMediaTime() - sliceStart
                configuration.trace?(String(format: "batch at page %d: %d pages in %.0f ms", index, count, slice * 1000))
                longest = max(longest, slice)
                busy += slice
                batches += 1
                index += count
                // Size the next batch to the budget from what this one cost per page.
                let perPage = slice / Double(count)
                batchSize = max(1, min(64, Int(configuration.sliceBudget / max(perPage, 0.0005))))
                if index < pageCount {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        } catch {
            abandon()
            throw error
        }
        context.closePDF()
        closed = true
        configuration.trace?(String(format: "printed %d pages in %.0f ms (main %.0f ms, longest %.0f ms, %d batches)", pageCount,
                                    (CACurrentMediaTime() - started) * 1000, busy * 1000, longest * 1000, batches))
        return WebPrintReport(pageCount: pageCount, longestMainThreadSlice: longest, mainThreadTime: busy,
                              elapsed: CACurrentMediaTime() - started, batches: batches)
    }
}

/// A print page renderer with a fixed paper and printable rect.
nonisolated final class WebPaperRenderer: UIPrintPageRenderer {
    private let paper: CGRect
    private let printable: CGRect

    init(paper: CGRect, printable: CGRect) {
        self.paper = paper
        self.printable = printable
        super.init()
    }

    override var paperRect: CGRect { paper }
    override var printableRect: CGRect { printable }
}

/// A continuation that can be resumed from several places (completion, timeout, cancellation,
/// process termination); only the first resume counts.
final class WebOneShot<Value: Sendable> {
    var continuation: CheckedContinuation<Value, any Error>?
    var onResume: (() -> Void)?

    func resume(_ result: Result<Value, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        onResume?()
        onResume = nil
        continuation.resume(with: result)
    }
}
