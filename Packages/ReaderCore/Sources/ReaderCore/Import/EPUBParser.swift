import Foundation

/// Reads an EPUB's container, package document, navigation and `META-INF` protection files.
/// Malformed input throws `EPUBError`; a missing or unreadable table of contents is not an
/// error (`navigationSource == .none`).
public enum EPUBParser {
    static let containerPath = "META-INF/container.xml"
    static let packageMediaType = "application/oebps-package+xml"
    static let maxSmallXMLSize: UInt64 = 1 << 20
    static let maxXMLSize: UInt64 = 16 << 20

    /// Opens the archive at `url` and parses it.
    public static func parse(fileAt url: URL, limits: ZIPArchive.Limits = .default) throws -> EPUBPackage {
        let archive: ZIPArchive
        do {
            archive = try ZIPArchive(url: url, limits: limits)
        } catch let error as ZIPError {
            throw EPUBError.archive(error)
        }
        return try parse(archive: archive)
    }

    public static func parse(archive: ZIPArchive) throws -> EPUBPackage {
        let packagePath = try packageDocumentPath(in: archive)
        guard archive.contains(packagePath) else { throw EPUBError.missingPackageDocument(path: packagePath) }
        let opf = try xml(at: packagePath, in: archive, maxSize: maxXMLSize)
        guard opf.name == "package",
              let manifestNode = opf.child("manifest"),
              let spineNode = opf.child("spine") else {
            throw EPUBError.invalidPackageDocument(path: packagePath)
        }
        let metadataNode = opf.child("metadata")

        var package = EPUBPackage(packagePath: packagePath)
        package.version = opf.attribute("version")
        package.metadata = metadata(from: metadataNode, uniqueIdentifier: opf.attribute("unique-identifier"))
        package.manifest = manifestNode.children("item").compactMap { item in
            guard let id = item.attribute("id"), let href = item.attribute("href"),
                  let target = EPUBPath.resolve(href, relativeTo: packagePath) else { return nil }
            return EPUBPackage.ManifestItem(id: id, path: target.path, mediaType: item.attribute("media-type") ?? "",
                                            properties: tokens(item.attribute("properties")))
        }
        package.spine = spineNode.children("itemref").compactMap { itemref in
            guard let idref = itemref.attribute("idref") else { return nil }
            let linear = itemref.attribute("linear")?.trimmingCharacters(in: .whitespaces).lowercased()
            return EPUBPackage.SpineItem(idref: idref, isLinear: linear != "no",
                                         properties: tokens(itemref.attribute("properties")))
        }
        if let direction = spineNode.attribute("page-progression-direction") {
            package.pageProgressionDirection = EPUBPackage.PageProgressionDirection(
                rawValue: direction.trimmingCharacters(in: .whitespaces).lowercased())
        }
        package.coverImagePath = coverImagePath(package: package, metadata: metadataNode, guide: opf.child("guide"))
        (package.navigation, package.navigationSource) = navigation(package: package, spine: spineNode, in: archive)
        package.isFixedLayout = isPrePaginated(metadataNode) || appleDisplayOptionsSayFixedLayout(in: archive)
        package.protection = try protection(in: archive)
        return package
    }

    /// DRM and font obfuscation, from `META-INF` only (no package document needed).
    /// An `encryption.xml` that cannot be read counts as protection.
    public static func protection(in archive: ZIPArchive) throws -> EPUBProtection {
        var result = EPUBProtection()
        if archive.contains("META-INF/rights.xml") { result.mechanisms.append(.rightsFile) }
        if archive.contains("META-INF/sinf.xml") { result.mechanisms.append(.appleFairPlay) }
        if archive.contains("META-INF/license.lcpl") { result.mechanisms.append(.readiumLCP) }
        let encryptionPath = "META-INF/encryption.xml"
        guard let entry = archive.entry(at: encryptionPath) else { return result }
        let root: XMLNode?
        do {
            root = XMLTree.parse(try archive.data(for: entry, maxSize: maxXMLSize))
        } catch {
            root = nil
        }
        guard let root else {
            result.mechanisms.append(.encryption)
            return result
        }
        var sawEncryption = false
        for encrypted in root.descendants("EncryptedData") {
            let algorithm = encrypted.child("EncryptionMethod")?.attribute("Algorithm")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let obfuscation = EPUBFontObfuscation(rawValue: algorithm) {
                let uri = encrypted.child("CipherData")?.child("CipherReference")?.attribute("URI")
                if let uri, let target = EPUBPath.resolve(uri, relativeTo: "") {
                    result.obfuscatedResources.append(EPUBObfuscatedResource(path: target.path, algorithm: obfuscation))
                }
            } else {
                sawEncryption = true
                if !algorithm.isEmpty, !result.encryptionAlgorithms.contains(algorithm) {
                    result.encryptionAlgorithms.append(algorithm)
                }
            }
        }
        if sawEncryption { result.mechanisms.append(.encryption) }
        return result
    }

    // MARK: Container and package

    static func packageDocumentPath(in archive: ZIPArchive) throws -> String {
        guard archive.contains(containerPath) else { throw EPUBError.missingContainer }
        let container = try xml(at: containerPath, in: archive, maxSize: maxSmallXMLSize)
        let rootfiles = container.descendants("rootfile").compactMap { node -> (path: String, type: String?)? in
            guard let path = node.attribute("full-path")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else { return nil }
            return (path, node.attribute("media-type")?.trimmingCharacters(in: .whitespaces).lowercased())
        }
        guard let chosen = rootfiles.first(where: { $0.type == packageMediaType }) ?? rootfiles.first else {
            throw EPUBError.noPackageDocument
        }
        let raw = chosen.path.hasPrefix("/") ? String(chosen.path.drop(while: { $0 == "/" })) : chosen.path
        if archive.contains(raw) { return raw }
        // Some writers percent-encode the path.
        if let decoded = raw.removingPercentEncoding, archive.contains(decoded) { return decoded }
        return raw
    }

    static func xml(at path: String, in archive: ZIPArchive, maxSize: UInt64, htmlEntities: Bool = false) throws -> XMLNode {
        var data: Data
        do {
            data = try archive.data(at: path, maxSize: maxSize)
        } catch let error as ZIPError {
            throw EPUBError.archive(error)
        }
        if htmlEntities { data = XMLTree.replacingHTMLEntities(in: data) }
        guard let root = XMLTree.parse(data) else { throw EPUBError.malformedXML(path: path) }
        return root
    }

    private static func tokens(_ string: String?) -> [String] {
        (string ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func metadata(from node: XMLNode?, uniqueIdentifier: String?) -> EPUBPackage.Metadata {
        guard let node else { return EPUBPackage.Metadata() }
        func nonEmpty(_ nodes: [XMLNode]) -> [String] { nodes.map(\.collapsedText).filter { !$0.isEmpty } }
        let identifiers = node.descendants("identifier")
        let unique = uniqueIdentifier.flatMap { id in identifiers.first { $0.attribute("id") == id } }
        let identifier = (unique.map { [$0] } ?? []) + identifiers
        return EPUBPackage.Metadata(title: nonEmpty(node.descendants("title")).first,
                                    creators: nonEmpty(node.descendants("creator")),
                                    language: nonEmpty(node.descendants("language")).first,
                                    identifier: nonEmpty(identifier).first)
    }

    private static func isPrePaginated(_ metadata: XMLNode?) -> Bool {
        guard let metadata else { return false }
        return metadata.descendants("meta").contains { meta in
            meta.attribute("property")?.trimmingCharacters(in: .whitespaces) == "rendition:layout"
                && meta.collapsedText == "pre-paginated"
        }
    }

    private static func appleDisplayOptionsSayFixedLayout(in archive: ZIPArchive) -> Bool {
        let path = "META-INF/com.apple.ibooks.display-options.xml"
        guard archive.contains(path), let root = try? xml(at: path, in: archive, maxSize: maxSmallXMLSize) else {
            return false
        }
        return root.descendants("option").contains {
            $0.attribute("name") == "fixed-layout" && $0.collapsedText.lowercased() == "true"
        }
    }

    // MARK: Cover

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic", "avif"]

    private static func coverImagePath(package: EPUBPackage, metadata: XMLNode?, guide: XMLNode?) -> String? {
        // EPUB 3: properties="cover-image".
        if let item = package.manifest.first(where: { $0.properties.contains("cover-image") }) { return item.path }
        // EPUB 2: <meta name="cover" content="item-id"> (some writers put the href instead).
        if let content = metadata?.descendants("meta").first(where: { $0.attribute("name") == "cover" })?
            .attribute("content")?.trimmingCharacters(in: .whitespaces), !content.isEmpty {
            if let item = package.manifestItem(id: content), item.isImage { return item.path }
            if let target = EPUBPath.resolve(content, relativeTo: package.packagePath),
               let item = package.manifestItem(path: target.path), item.isImage {
                return item.path
            }
        }
        // Guide: <reference type="cover" href="…"> when it points straight at an image.
        if let reference = guide?.children("reference").first(where: { $0.attribute("type")?.lowercased() == "cover" }),
           let href = reference.attribute("href"),
           let target = EPUBPath.resolve(href, relativeTo: package.packagePath) {
            if let item = package.manifestItem(path: target.path) {
                if item.isImage { return item.path }
            } else if let ext = target.path.split(separator: ".").last, imageExtensions.contains(ext.lowercased()) {
                return target.path
            }
        }
        return nil
    }

    // MARK: Navigation

    private static func navigation(package: EPUBPackage, spine: XMLNode,
                                   in archive: ZIPArchive) -> ([EPUBNavigationPoint], EPUBPackage.NavigationSource) {
        if let nav = package.manifest.first(where: { $0.properties.contains("nav") }),
           let root = try? xml(at: nav.path, in: archive, maxSize: maxXMLSize, htmlEntities: true) {
            let points = navDocumentPoints(root, documentPath: nav.path)
            if !points.isEmpty { return (points, .navDocument) }
        }
        let ncxItem = spine.attribute("toc").flatMap { package.manifestItem(id: $0) }
            ?? package.manifest.first { $0.mediaType.lowercased() == "application/x-dtbncx+xml" }
        if let ncxItem, let root = try? xml(at: ncxItem.path, in: archive, maxSize: maxXMLSize, htmlEntities: true),
           let navMap = root.child("navMap") {
            let points = ncxPoints(navMap, documentPath: ncxItem.path)
            if !points.isEmpty { return (points, .ncx) }
        }
        return ([], .none)
    }

    private static func navTypes(_ node: XMLNode) -> [String] {
        tokens(node.attributes["epub:type"] ?? node.attribute("type"))
    }

    static func navDocumentPoints(_ root: XMLNode, documentPath: String) -> [EPUBNavigationPoint] {
        let navs = root.descendants("nav")
        guard let toc = navs.first(where: { navTypes($0).contains("toc") }) ?? navs.first(where: { navTypes($0).isEmpty }),
              let list = toc.firstDescendant(where: { $0.name == "ol" || $0.name == "ul" }) else { return [] }
        return navListPoints(list, documentPath: documentPath)
    }

    private static func navListPoints(_ list: XMLNode, documentPath: String) -> [EPUBNavigationPoint] {
        list.children("li").compactMap { item in
            let label = item.elements.first { $0.name == "a" || $0.name == "span" }
                ?? item.firstDescendant(where: { $0.name == "a" || $0.name == "span" }, skipping: ["ol", "ul"])
            var title = label?.collapsedText ?? ""
            if title.isEmpty { title = XMLNode.collapse(label?.attribute("title") ?? "") }
            let target = label?.name == "a" ? label?.attribute("href").flatMap { EPUBPath.resolve($0, relativeTo: documentPath) } : nil
            let sublist = item.elements.first { $0.name == "ol" || $0.name == "ul" }
            let children = sublist.map { navListPoints($0, documentPath: documentPath) } ?? []
            if title.isEmpty, target == nil, children.isEmpty { return nil }
            return EPUBNavigationPoint(title: title, path: target?.path, fragment: target?.fragment, children: children)
        }
    }

    static func ncxPoints(_ parent: XMLNode, documentPath: String) -> [EPUBNavigationPoint] {
        parent.children("navPoint").compactMap { point in
            let title = point.child("navLabel")?.child("text")?.collapsedText ?? point.child("navLabel")?.collapsedText ?? ""
            let target = point.child("content")?.attribute("src").flatMap { EPUBPath.resolve($0, relativeTo: documentPath) }
            let children = ncxPoints(point, documentPath: documentPath)
            if title.isEmpty, target == nil, children.isEmpty { return nil }
            return EPUBNavigationPoint(title: title, path: target?.path, fragment: target?.fragment, children: children)
        }
    }
}

/// Resolving EPUB hrefs (URLs relative to a document) to archive paths.
enum EPUBPath {
    /// The archive path and fragment `href` points at, relative to the document at
    /// `documentPath` (an empty path part means that document itself). `nil` for an external
    /// URL (one with a scheme) or a path that climbs above the archive root.
    static func resolve(_ href: String, relativeTo documentPath: String) -> (path: String, fragment: String?)? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasScheme(trimmed) { return nil }
        var pathPart = Substring(trimmed)
        var fragment: String?
        if let hash = pathPart.firstIndex(of: "#") {
            let raw = String(pathPart[pathPart.index(after: hash)...])
            fragment = raw.isEmpty ? nil : (raw.removingPercentEncoding ?? raw)
            pathPart = pathPart[..<hash]
        }
        if let query = pathPart.firstIndex(of: "?") { pathPart = pathPart[..<query] }
        let decoded = String(pathPart).removingPercentEncoding ?? String(pathPart)
        if decoded.isEmpty { return documentPath.isEmpty ? nil : (documentPath, fragment) }

        var stack: [Substring] = []
        if !decoded.hasPrefix("/") {
            stack = Array(documentPath.split(separator: "/", omittingEmptySubsequences: true).dropLast())
        }
        for component in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            default: stack.append(component)
            }
        }
        guard !stack.isEmpty else { return nil }
        return (stack.joined(separator: "/"), fragment)
    }

    private static func hasScheme(_ string: String) -> Bool {
        guard let colon = string.firstIndex(of: ":") else { return false }
        let scheme = string[..<colon]
        guard let first = scheme.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic else { return false }
        return scheme.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "+" || $0 == "-" || $0 == ".")
        }
    }
}
