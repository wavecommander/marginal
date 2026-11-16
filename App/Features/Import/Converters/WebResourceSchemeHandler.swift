import Foundation
import WebKit

// Serves a document and its resources to the off-screen web view through a custom URL scheme,
// straight from wherever the converter keeps them (an EPUB's ZIP archive, for instance). Nothing
// is written to disk and nothing outside the provider can be reached: the path is normalised
// so that it cannot climb above the root, and the provider only knows its own entries.

/// One response to a scheme request. `stream` is called once, on the handler's private queue,
/// and hands the bytes over in order; it may throw part-way (the request then fails).
nonisolated struct WebResource {
    var mimeType: String
    /// `nil` to let WebKit work the encoding out (XML declarations, `@charset`).
    var textEncodingName: String?
    /// The length in bytes, or `-1` when unknown.
    var expectedLength: Int
    var stream: (_ body: (Data) throws -> Void) throws -> Void

    init(mimeType: String, textEncodingName: String? = nil, expectedLength: Int = -1,
         stream: @escaping (_ body: (Data) throws -> Void) throws -> Void) {
        self.mimeType = mimeType
        self.textEncodingName = textEncodingName
        self.expectedLength = expectedLength
        self.stream = stream
    }

    /// A resource held in memory.
    static func data(_ data: Data, mimeType: String, textEncodingName: String? = nil) -> WebResource {
        WebResource(mimeType: mimeType, textEncodingName: textEncodingName, expectedLength: data.count) { body in
            try body(data)
        }
    }
}

/// Where the scheme handler gets its bytes. Called on the handler's serial queue only, one
/// request at a time, so an implementation may own non-thread-safe state (a `ZIPArchive`) as
/// long as nothing else touches it.
nonisolated protocol WebResourceProvider: AnyObject, Sendable {
    /// The resource at `path`, a normalised relative path ("OEBPS/text/ch1.xhtml": no leading
    /// `/`, no `.` or `..` components, percent-decoded), or `nil` when there is none.
    func resource(at path: String) throws -> WebResource?
}

/// URL ↔ path mapping for the content scheme, and MIME types by extension.
nonisolated enum WebResourcePath {
    /// The URL that serves `path` (a normalised relative path, optionally with a fragment).
    static func url(scheme: String, host: String, path: String, fragment: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + path
        components.fragment = fragment
        // Every component is plain text; URLComponents percent-encodes what it must.
        return components.url ?? URL(string: "\(scheme)://\(host)/")!
    }

    /// The normalised path a request URL names, or `nil` when the URL is not ours (another
    /// scheme or host) or tries to leave the root (`..` above it, an encoded separator, NUL).
    static func path(of url: URL, scheme: String, host: String) -> String? {
        guard url.scheme?.lowercased() == scheme.lowercased(),
              url.host?.lowercased() == host.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var stack: [String] = []
        for raw in components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true) {
            guard let component = String(raw).removingPercentEncoding else { return nil }
            // A decoded separator or NUL inside one component is never a real entry name.
            if component.contains("/") || component.contains("\\") || component.contains("\0") { return nil }
            switch component {
            case ".": continue
            case "..":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            default:
                stack.append(component)
            }
        }
        return stack.isEmpty ? nil : stack.joined(separator: "/")
    }

    /// The MIME type for a file extension the web view needs to know exactly (documents, style
    /// sheets, images, fonts), or `nil` for anything else.
    static func mimeType(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        return mimeTypes[ext]
    }

    static let mimeTypes: [String: String] = [
        "xhtml": "application/xhtml+xml", "xht": "application/xhtml+xml",
        "html": "text/html", "htm": "text/html",
        "css": "text/css", "js": "text/javascript", "xml": "application/xml",
        "ncx": "application/x-dtbncx+xml", "opf": "application/oebps-package+xml",
        "svg": "image/svg+xml", "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
        "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp", "tif": "image/tiff",
        "tiff": "image/tiff", "heic": "image/heic", "avif": "image/avif",
        "ttf": "font/ttf", "otf": "font/otf", "woff": "font/woff", "woff2": "font/woff2",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "mp4": "video/mp4", "m4v": "video/mp4",
        "txt": "text/plain", "md": "text/markdown",
    ]

    /// Whether WebKit should be told the text is UTF-8 (HTML and CSS, which otherwise default to
    /// Latin-1); XML-based types read their own declaration.
    static func defaultTextEncoding(forMIMEType mimeType: String) -> String? {
        switch mimeType {
        case "text/html", "text/css", "text/plain", "text/markdown", "text/javascript": "utf-8"
        default: nil
        }
    }
}

/// A record of one request, for diagnostics and tests.
nonisolated struct WebResourceRequestRecord: Sendable, Equatable {
    enum Outcome: String, Sendable { case served, notFound, rejected, failed, stopped }
    var path: String
    var outcome: Outcome
}

/// The `WKURLSchemeHandler`. WebKit calls it on the main thread; the bytes are read on a private
/// serial queue and handed back to the main thread in chunks, at most `maxChunksInFlight` at a
/// time, so a large image never sits in memory whole and the main thread never reads the archive.
final class WebResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    let scheme: String
    let host: String
    private let provider: any WebResourceProvider
    private let queue = DispatchQueue(label: "software.tactile.texts.web-resources", qos: .userInitiated)
    private let liveIDs = WebLockedIDs()
    private var idByTask: [ObjectIdentifier: Int] = [:]
    private var nextID = 0
    private(set) var records: [WebResourceRequestRecord] = []
    static let maxChunksInFlight = 4

    init(scheme: String, host: String, provider: any WebResourceProvider) {
        self.scheme = scheme
        self.host = host
        self.provider = provider
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let path = WebResourcePath.path(of: url, scheme: scheme, host: host) else {
            records.append(WebResourceRequestRecord(path: urlSchemeTask.request.url?.absoluteString ?? "", outcome: .rejected))
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        nextID += 1
        let id = nextID
        idByTask[ObjectIdentifier(urlSchemeTask)] = id
        liveIDs.insert(id)
        let delivery = WebSchemeDelivery(id: id, gate: DispatchSemaphore(value: Self.maxChunksInFlight),
                                         liveIDs: liveIDs, task: WebUncheckedBox(urlSchemeTask))
        let liveIDs = liveIDs
        let provider = provider

        queue.async {
            guard liveIDs.contains(id) else { return }
            let resource: WebResource?
            do {
                resource = try provider.resource(at: path)
            } catch {
                let reason = String(describing: error)
                delivery.post { task in self.finish(task, id: id, path: path, outcome: .failed, error: reason) }
                return
            }
            guard let resource else {
                delivery.post { task in self.finish(task, id: id, path: path, outcome: .notFound, error: "not found") }
                return
            }
            let mimeType = resource.mimeType
            let encoding = resource.textEncodingName
            let length = resource.expectedLength
            delivery.post { task in
                task.didReceive(URLResponse(url: url, mimeType: mimeType, expectedContentLength: length,
                                            textEncodingName: encoding))
            }
            do {
                try resource.stream { chunk in
                    guard liveIDs.contains(id) else { throw CancellationError() }
                    delivery.post { task in task.didReceive(chunk) }
                }
                delivery.post { task in self.finish(task, id: id, path: path, outcome: .served, error: nil) }
            } catch is CancellationError {
                return
            } catch {
                let reason = String(describing: error)
                delivery.post { task in self.finish(task, id: id, path: path, outcome: .failed, error: reason) }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        guard let id = idByTask.removeValue(forKey: ObjectIdentifier(urlSchemeTask)) else { return }
        liveIDs.remove(id)
        if let url = urlSchemeTask.request.url {
            records.append(WebResourceRequestRecord(path: WebResourcePath.path(of: url, scheme: scheme, host: host) ?? "",
                                                    outcome: .stopped))
        }
    }

    private func finish(_ task: any WKURLSchemeTask, id: Int, path: String,
                        outcome: WebResourceRequestRecord.Outcome, error: String?) {
        idByTask.removeValue(forKey: ObjectIdentifier(task))
        liveIDs.remove(id)
        records.append(WebResourceRequestRecord(path: path, outcome: outcome))
        if let error {
            let code: URLError.Code = outcome == .notFound ? .fileDoesNotExist : .cannotDecodeContentData
            task.didFailWithError(URLError(code, userInfo: [NSLocalizedDescriptionKey: "\(path): \(error)"]))
        } else {
            task.didFinish()
        }
    }
}

/// Hands work for one scheme task back to the main thread, in order, if the task is still live,
/// with at most `maxChunksInFlight` deliveries queued (back-pressure on the reading queue).
nonisolated struct WebSchemeDelivery: Sendable {
    let id: Int
    let gate: DispatchSemaphore
    let liveIDs: WebLockedIDs
    let task: WebUncheckedBox<any WKURLSchemeTask>

    func post(_ action: @escaping @MainActor @Sendable (any WKURLSchemeTask) -> Void) {
        gate.wait()
        DispatchQueue.main.async { [gate, liveIDs, id, task] in
            MainActor.assumeIsolated {
                defer { gate.signal() }
                guard liveIDs.contains(id) else { return }
                action(task.value)
            }
        }
    }
}

/// Request IDs that are still live, readable from the handler's queue.
nonisolated final class WebLockedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<Int> = []
    func insert(_ id: Int) { lock.withLock { _ = ids.insert(id) } }
    func remove(_ id: Int) { lock.withLock { _ = ids.remove(id) } }
    func contains(_ id: Int) -> Bool { lock.withLock { ids.contains(id) } }
}

/// Carries a value that is not `Sendable` to a place where only one side uses it at a time
/// (a scheme task touched only on the main thread).
nonisolated final class WebUncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
