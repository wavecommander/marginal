import Foundation

/// Serves a Safari web archive's page and the resources saved inside it.
///
/// WebKit can open a `.webarchive` itself, but only by loading the archive's own page address
/// (`file:///…` or `https://…`) as a navigation, which the renderer refuses (nothing leaves the
/// content scheme). So the archive is read here instead: every resource is served at
/// `r/<scheme>/<host>/<path>` of its original address, the page included, so the page's relative
/// references resolve to the saved copies; absolute references to saved resources are rewritten
/// to those paths. Anything not saved in the archive is not there, and the network stays blocked.
nonisolated final class WebArchiveResources: WebResourceProvider, @unchecked Sendable {
    private let resources: [String: WebFileResources.Entry]
    /// Path of the archive's page.
    let mainPath: String
    /// `r/<scheme>/<host>/` of the page, for root-relative references (`/images/a.png`).
    private let siteRoot: String

    enum ArchiveError: Error, Equatable {
        case notAnArchive
        case noMainResource
    }

    init(data: Data) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ArchiveError.notAnArchive
        }
        guard let main = plist["WebMainResource"] as? [String: Any], let mainData = main["WebResourceData"] as? Data,
              let mainURLString = main["WebResourceURL"] as? String else {
            throw ArchiveError.noMainResource
        }
        let mainURL = URL(string: mainURLString) ?? URL(fileURLWithPath: "/index.html")
        var table: [String: WebFileResources.Entry] = [:]
        var rewrites: [(String, String)] = []

        func add(_ resource: [String: Any]) {
            guard let data = resource["WebResourceData"] as? Data, let string = resource["WebResourceURL"] as? String,
                  let url = URL(string: string) else { return }
            let path = Self.localPath(for: url)
            guard table[path] == nil else { return }
            let mime = (resource["WebResourceMIMEType"] as? String) ?? WebResourcePath.mimeType(forPath: path) ?? "application/octet-stream"
            let encoding = resource["WebResourceTextEncodingName"] as? String
            table[path] = WebFileResources.Entry(source: .data(data), mimeType: mime, textEncodingName: encoding)
            rewrites.append((string, WebPDFRenderer.url(for: path).absoluteString))
        }
        func addArchive(_ archive: [String: Any], isMain: Bool) {
            if !isMain, let frame = archive["WebMainResource"] as? [String: Any] { add(frame) }
            for resource in archive["WebSubresources"] as? [[String: Any]] ?? [] { add(resource) }
            for frame in archive["WebSubframeArchives"] as? [[String: Any]] ?? [] { addArchive(frame, isMain: false) }
        }
        addArchive(plist, isMain: true)

        let mainPath = Self.localPath(for: mainURL)
        let mime = (main["WebResourceMIMEType"] as? String) ?? "text/html"
        let encodingName = main["WebResourceTextEncodingName"] as? String
        var page = mainData
        // Rewrite absolute references to saved resources (longest first, so a prefix never wins).
        if let encoding = Self.encoding(named: encodingName), let text = String(data: mainData, encoding: encoding) {
            var rewritten = text
            for (from, to) in rewrites.sorted(by: { $0.0.count > $1.0.count }) where from.contains(":") {
                rewritten = rewritten.replacingOccurrences(of: from, with: to)
                let escaped = from.replacingOccurrences(of: "&", with: "&amp;")
                if escaped != from { rewritten = rewritten.replacingOccurrences(of: escaped, with: to) }
            }
            page = Data(rewritten.utf8)
            table[mainPath] = WebFileResources.Entry(source: .data(page), mimeType: mime, textEncodingName: "utf-8")
        } else {
            table[mainPath] = WebFileResources.Entry(source: .data(page), mimeType: mime, textEncodingName: encodingName)
        }
        resources = table
        self.mainPath = mainPath
        siteRoot = Self.siteRoot(for: mainURL)
    }

    /// `r/<scheme>/<host>/<path>`, normalised the way `WebResourcePath.path(of:)` normalises a
    /// request, so a request for the served URL finds it.
    static func localPath(for url: URL) -> String {
        var components = ["r", (url.scheme ?? "file").lowercased(), (url.host?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "_"]
        var stack: [String] = []
        for component in url.path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(String(component).replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\0", with: ""))
            }
        }
        if stack.isEmpty || url.path.hasSuffix("/") { stack.append("index.html") }
        components += stack
        let joined = components.joined(separator: "/")
        return WebResourcePath.path(of: WebPDFRenderer.url(for: joined), scheme: WebPDFRenderer.scheme, host: WebPDFRenderer.host) ?? joined
    }

    static func siteRoot(for url: URL) -> String {
        "r/\((url.scheme ?? "file").lowercased())/\((url.host?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "_")/"
    }

    static func encoding(named name: String?) -> String.Encoding? {
        guard let name, !name.isEmpty else { return .utf8 }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    func resource(at path: String) throws -> WebResource? {
        // Root-relative references resolve to the top of the content scheme.
        guard let entry = resources[path] ?? (path.hasPrefix("r/") ? nil : resources[siteRoot + path]) else { return nil }
        switch entry.source {
        case let .data(data): return .data(data, mimeType: entry.mimeType, textEncodingName: entry.textEncodingName)
        case .file: return nil
        }
    }
}
