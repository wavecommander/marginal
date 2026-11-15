import Foundation

/// What an EPUB's container and package document say: metadata, manifest, spine, cover,
/// table of contents, layout and protection. A plain value; it holds no archive handle. Every
/// path is an archive entry path (resolved against the referring file and percent-decoded).
public struct EPUBPackage: Sendable, Hashable {
    public struct Metadata: Sendable, Hashable {
        public var title: String?
        public var creators: [String]
        public var language: String?
        /// The identifier named by the package's `unique-identifier`, else the first one.
        public var identifier: String?

        public init(title: String? = nil, creators: [String] = [], language: String? = nil, identifier: String? = nil) {
            self.title = title
            self.creators = creators
            self.language = language
            self.identifier = identifier
        }
    }

    public struct ManifestItem: Sendable, Hashable {
        public var id: String
        /// Archive path of the resource.
        public var path: String
        public var mediaType: String
        /// Space-separated `properties` (e.g. `nav`, `cover-image`, `svg`).
        public var properties: [String]

        public var isImage: Bool { mediaType.lowercased().hasPrefix("image/") }

        public init(id: String, path: String, mediaType: String, properties: [String] = []) {
            self.id = id
            self.path = path
            self.mediaType = mediaType
            self.properties = properties
        }
    }

    public struct SpineItem: Sendable, Hashable {
        public var idref: String
        /// `false` for `linear="no"` (auxiliary content such as pop-up notes).
        public var isLinear: Bool
        public var properties: [String]

        public init(idref: String, isLinear: Bool = true, properties: [String] = []) {
            self.idref = idref
            self.isLinear = isLinear
            self.properties = properties
        }
    }

    public enum PageProgressionDirection: String, Sendable, Hashable, CaseIterable {
        case leftToRight = "ltr"
        case rightToLeft = "rtl"
        case `default`
    }

    public enum NavigationSource: String, Sendable, Hashable, CaseIterable {
        /// The EPUB 3 navigation document's `toc` nav.
        case navDocument
        /// The EPUB 2 NCX.
        case ncx
        /// Neither was present and readable.
        case none
    }

    /// Archive path of the package (OPF) document.
    public var packagePath: String
    /// The package's `version` attribute (e.g. "2.0", "3.0").
    public var version: String?
    public var metadata: Metadata
    /// Items in document order. Items with remote or unresolvable hrefs are left out.
    public var manifest: [ManifestItem]
    /// The reading order, as written (idrefs may name missing items; see `readingOrder`).
    public var spine: [SpineItem]
    /// The spine's `page-progression-direction`, or `nil` when absent.
    public var pageProgressionDirection: PageProgressionDirection?
    public var coverImagePath: String?
    /// The table of contents (from the nav document, else the NCX).
    public var navigation: [EPUBNavigationPoint]
    public var navigationSource: NavigationSource
    /// Pre-paginated (fixed-layout) at package level, by `rendition:layout` or Apple's display options.
    public var isFixedLayout: Bool
    public var protection: EPUBProtection

    public init(packagePath: String, version: String? = nil, metadata: Metadata = Metadata(),
                manifest: [ManifestItem] = [], spine: [SpineItem] = [],
                pageProgressionDirection: PageProgressionDirection? = nil, coverImagePath: String? = nil,
                navigation: [EPUBNavigationPoint] = [], navigationSource: NavigationSource = .none,
                isFixedLayout: Bool = false, protection: EPUBProtection = EPUBProtection()) {
        self.packagePath = packagePath
        self.version = version
        self.metadata = metadata
        self.manifest = manifest
        self.spine = spine
        self.pageProgressionDirection = pageProgressionDirection
        self.coverImagePath = coverImagePath
        self.navigation = navigation
        self.navigationSource = navigationSource
        self.isFixedLayout = isFixedLayout
        self.protection = protection
    }

    public func manifestItem(id: String) -> ManifestItem? { manifest.first { $0.id == id } }

    public func manifestItem(path: String) -> ManifestItem? { manifest.first { $0.path == path } }

    /// The spine resolved to manifest items, in order (linear and non-linear; idrefs that name
    /// no item are skipped).
    public var readingOrder: [ManifestItem] {
        let byID = Dictionary(manifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return spine.compactMap { byID[$0.idref] }
    }
}

/// One table-of-contents entry.
public struct EPUBNavigationPoint: Sendable, Hashable {
    /// The label, whitespace collapsed.
    public var title: String
    /// Archive path of the target document; `nil` for a heading without a link or an external link.
    public var path: String?
    /// The fragment identifier (after `#`), percent-decoded.
    public var fragment: String?
    public var children: [EPUBNavigationPoint]

    public init(title: String, path: String? = nil, fragment: String? = nil, children: [EPUBNavigationPoint] = []) {
        self.title = title
        self.path = path
        self.fragment = fragment
        self.children = children
    }
}

/// DRM and font obfuscation found in `META-INF`.
public struct EPUBProtection: Sendable, Hashable {
    public enum Mechanism: String, Sendable, Hashable, CaseIterable {
        /// `META-INF/rights.xml` (Adobe ADEPT and others).
        case rightsFile
        /// `META-INF/sinf.xml` (Apple FairPlay).
        case appleFairPlay
        /// `META-INF/license.lcpl` (Readium LCP).
        case readiumLCP
        /// `META-INF/encryption.xml` encrypts a resource with something other than font
        /// obfuscation (or the file could not be read).
        case encryption
    }

    /// Empty when the book is not protected.
    public var mechanisms: [Mechanism]
    /// Algorithm URIs of non-obfuscation encryption seen in `encryption.xml`, in order, unique.
    public var encryptionAlgorithms: [String]
    /// Fonts (or other resources) that are only obfuscated; a converter must de-obfuscate them.
    public var obfuscatedResources: [EPUBObfuscatedResource]

    public var isProtected: Bool { !mechanisms.isEmpty }

    public init(mechanisms: [Mechanism] = [], encryptionAlgorithms: [String] = [],
                obfuscatedResources: [EPUBObfuscatedResource] = []) {
        self.mechanisms = mechanisms
        self.encryptionAlgorithms = encryptionAlgorithms
        self.obfuscatedResources = obfuscatedResources
    }
}

public struct EPUBObfuscatedResource: Sendable, Hashable {
    /// Archive path of the obfuscated resource.
    public var path: String
    public var algorithm: EPUBFontObfuscation

    public init(path: String, algorithm: EPUBFontObfuscation) {
        self.path = path
        self.algorithm = algorithm
    }
}

/// The two font-obfuscation schemes, which are not DRM.
public enum EPUBFontObfuscation: String, Sendable, Hashable, CaseIterable {
    /// IDPF: XOR of the first 1040 bytes with the SHA-1 of the unique identifier.
    case idpf = "http://www.idpf.org/2008/embedding"
    /// Adobe: XOR of the first 1024 bytes with the 16-byte UUID from the identifier.
    case adobe = "http://ns.adobe.com/pdf/enc#RC"
}

public enum EPUBError: Error, Sendable, Hashable {
    /// No `META-INF/container.xml`.
    case missingContainer
    /// A required XML file is not well-formed.
    case malformedXML(path: String)
    /// The container lists no package document.
    case noPackageDocument
    /// The package document the container names is not in the archive.
    case missingPackageDocument(path: String)
    /// The package document has no `package` root, manifest or spine.
    case invalidPackageDocument(path: String)
    /// Reading the archive failed.
    case archive(ZIPError)
}
