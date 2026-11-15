import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import Network
import PDFKit
import UIKit
@testable import Marginal

// Fixtures and instruments for the EPUB converter tests. Every EPUB is built here, in code.

// MARK: - ZIP

/// A minimal ZIP writer (stored entries only), enough for fixture EPUBs.
nonisolated struct EPUBTestZIPWriter {
    private(set) var entries: [(name: String, data: Data)] = []

    mutating func add(_ name: String, _ data: Data) { entries.append((name, data)) }
    mutating func add(_ name: String, _ text: String) { add(name, Data(text.utf8)) }

    func build() -> Data {
        var out = Data()
        var central = Data()
        for (name, data) in entries {
            let offset = UInt32(out.count)
            let crc = EPUBTestCRC32.checksum(data)
            let nameBytes = Array(name.utf8)
            out.le32(0x0403_4B50); out.le16(20); out.le16(0x0800); out.le16(0); out.le16(0); out.le16(0x21)
            out.le32(crc); out.le32(UInt32(data.count)); out.le32(UInt32(data.count))
            out.le16(UInt16(nameBytes.count)); out.le16(0)
            out.append(contentsOf: nameBytes)
            out.append(data)
            central.le32(0x0201_4B50); central.le16(0x031E); central.le16(20); central.le16(0x0800); central.le16(0)
            central.le16(0); central.le16(0x21); central.le32(crc); central.le32(UInt32(data.count)); central.le32(UInt32(data.count))
            central.le16(UInt16(nameBytes.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(0o100644 << 16); central.le32(offset)
            central.append(contentsOf: nameBytes)
        }
        let directoryOffset = UInt32(out.count)
        out.append(central)
        out.le32(0x0605_4B50); out.le16(0); out.le16(0)
        out.le16(UInt16(entries.count)); out.le16(UInt16(entries.count))
        out.le32(UInt32(central.count)); out.le32(directoryOffset); out.le16(0)
        return out
    }
}

nonisolated enum EPUBTestCRC32 {
    static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}

// MARK: - EPUB building

/// One EPUB under construction: files by archive path, written with `mimetype` first.
nonisolated struct EPUBTestBook {
    var files: [(String, Data)] = []
    var opfPath = "OEBPS/content.opf"

    mutating func add(_ path: String, _ text: String) { files.append((path, Data(text.utf8))) }
    mutating func add(_ path: String, _ data: Data) { files.append((path, data)) }

    func data() -> Data {
        var zip = EPUBTestZIPWriter()
        zip.add("mimetype", "application/epub+zip")
        zip.add("META-INF/container.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """)
        for (path, data) in files { zip.add(path, data) }
        return zip.build()
    }

    static func xhtml(title: String, body: String, head: String = "<link rel=\"stylesheet\" href=\"style.css\"/>") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
        <head><meta charset="utf-8"/><title>\(title)</title>\(head)</head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// Distinct, searchable paragraphs ("Paragraph 2.1.3 …").
    static func paragraphs(_ tag: String, count: Int, words: Int = 60) -> String {
        let vocabulary = ["harbour", "lantern", "evening", "orchard", "compass", "thimble", "meadow", "quarry", "sparrow",
                          "anchor", "pebble", "willow", "cobbler", "ferry", "granite", "mantle", "parcel", "ribbon"]
        return (1...count).map { index in
            let text = (0..<words).map { vocabulary[($0 * 7 + index * 3) % vocabulary.count] }.joined(separator: " ")
            return "<p>Paragraph \(tag).\(index) \(text).</p>"
        }.joined(separator: "\n")
    }

    static func png(width: Int, height: Int, color: UIColor = .systemTeal) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.setFill()
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        }.pngData()!
    }
}

/// The fixture books.
nonisolated enum EPUBTestFixtures {
    static let identifier = "urn:uuid:4f1c2b9e-7d3a-4c55-9a10-2e8f6b3d1a77"

    struct NavEntry {
        var title: String
        var href: String
        var children: [NavEntry] = []
    }

    /// The table of contents of `small` (and `ncx`), in pre-order: (title, level).
    static let smallTOC: [(String, Int)] = [
        ("Chapter One: The Beginning", 1), ("A Quiet Harbour", 2),
        ("Chapter Two: The Voyage", 1), ("Storm at Sea", 2), ("The Lighthouse", 2), ("Keeper's Log", 3),
        ("Chapter Three: Landfall", 1), ("The Village", 2),
        ("Chapter Four: Home", 1),
    ]

    static let smallNav: [NavEntry] = [
        NavEntry(title: "Chapter One: The Beginning", href: "text/ch1.xhtml", children: [
            NavEntry(title: "A Quiet Harbour", href: "text/ch1.xhtml#s1-2"),
        ]),
        NavEntry(title: "Chapter Two: The Voyage", href: "text/ch2.xhtml", children: [
            NavEntry(title: "Storm at Sea", href: "text/ch2.xhtml#s2-1"),
            NavEntry(title: "The Lighthouse", href: "text/ch2.xhtml#s2-2", children: [
                NavEntry(title: "Keeper's Log", href: "text/ch2.xhtml#s2-2-1"),
            ]),
        ]),
        NavEntry(title: "Chapter Three: Landfall", href: "text/ch3.xhtml", children: [
            NavEntry(title: "The Village", href: "text/ch3.xhtml#s3-1"),
        ]),
        NavEntry(title: "Chapter Four: Home", href: "text/ch4.xhtml"),
        // Not in the spine: dropped.
        NavEntry(title: "Missing Appendix", href: "text/missing.xhtml"),
    ]

    static let css = """
        body { font-family: Georgia, serif; }
        h1 { font-size: 1.8em; break-before: page; }
        h2 { font-size: 1.3em; }
        p { text-indent: 1.2em; margin: 0 0 0.3em 0; }
        """

    /// Chapter bodies of the small book. `remotePort` puts a remote image and style sheet in
    /// chapter 2 (they must never be fetched).
    static func smallChapters(remotePort: UInt16?) -> [(file: String, title: String, body: String)] {
        let remote = remotePort.map { port in
            """
            <link rel="stylesheet" href="http://127.0.0.1:\(port)/remote.css"/>
            <p><img src="http://127.0.0.1:\(port)/remote.png" alt="remote"/></p>
            """
        } ?? ""
        return [
            ("ch1.xhtml", "Chapter One", """
                <h1 id="c1">Chapter One: The Beginning</h1>
                <p>Before setting out, see the lighthouse keeper's notes for the tides, or visit the harbour office online.</p>
                \(EPUBTestBook.paragraphs("1.1", count: 10))
                <h2 id="s1-2">A Quiet Harbour</h2>
                \(EPUBTestBook.paragraphs("1.2", count: 12))
                <p>For the weather, <a href="https://example.com/tactile-weather">consult the coastal forecast</a> before dawn.</p>
                <p>The keeper wrote it down: <a href="ch2.xhtml#s2-2-1">read the lighthouse keeper's notes</a> in chapter two.</p>
                """),
            ("ch2.xhtml", "Chapter Two", """
                <h1>Chapter Two: The Voyage</h1>
                \(EPUBTestBook.paragraphs("2.0", count: 6))
                <figure><img src="../images/figure.png" alt="A figure"/><figcaption>Figure 1. The harbour chart.</figcaption></figure>
                \(remote)
                <h2 id="s2-1">Storm at Sea</h2>
                \(EPUBTestBook.paragraphs("2.1", count: 12))
                <h2 id="s2-2">The Lighthouse</h2>
                \(EPUBTestBook.paragraphs("2.2", count: 10))
                <h3 id="s2-2-1">Keeper's Log</h3>
                \(EPUBTestBook.paragraphs("2.3", count: 10))
                <p>Return to <a href="ch1.xhtml#s1-2">the quiet harbour section</a> when the storm has passed.</p>
                """),
            ("ch3.xhtml", "Chapter Three", """
                <h1>Chapter Three: Landfall</h1>
                \(EPUBTestBook.paragraphs("3.0", count: 8))
                <section id="s3-1"><h2>The Village</h2>
                \(EPUBTestBook.paragraphs("3.1", count: 10))
                </section>
                """),
            ("ch4.xhtml", "Chapter Four", """
                <h1>Chapter Four: Home</h1>
                \(EPUBTestBook.paragraphs("4.0", count: 8))
                <p>The end.</p>
                """),
        ]
    }

    /// (a) A small EPUB 3: four chapters, nested nav with fragments, CSS, an image, internal and
    /// external links, a cover, and remote references when `remotePort` is given.
    static func small(remotePort: UInt16? = nil, extraHead: String = "") -> Data {
        var book = EPUBTestBook()
        let chapters = smallChapters(remotePort: remotePort)
        for chapter in chapters {
            book.add("OEBPS/text/\(chapter.file)", EPUBTestBook.xhtml(
                title: chapter.title, body: chapter.body,
                head: "<link rel=\"stylesheet\" href=\"../style.css\"/>\(extraHead)"))
        }
        book.add("OEBPS/style.css", css)
        book.add("OEBPS/images/figure.png", EPUBTestBook.png(width: 900, height: 600))
        book.add("OEBPS/images/cover.png", EPUBTestBook.png(width: 600, height: 900, color: .systemOrange))
        book.add("OEBPS/nav.xhtml", navDocument(smallNav))
        let items = chapters.enumerated().map { "<item id=\"c\($0.offset + 1)\" href=\"text/\($0.element.file)\" media-type=\"application/xhtml+xml\"/>" }
        let spine = chapters.indices.map { "<itemref idref=\"c\($0 + 1)\"/>" }
        book.add("OEBPS/content.opf", opf(version: "3.0", title: "The Tactile Test Book", items: items + [
            "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
            "<item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>",
            "<item id=\"fig\" href=\"images/figure.png\" media-type=\"image/png\"/>",
            "<item id=\"cover\" href=\"images/cover.png\" media-type=\"image/png\" properties=\"cover-image\"/>",
        ], spine: spine))
        return book.data()
    }

    /// (b) An EPUB 2 whose table of contents is an NCX.
    static func ncx() -> Data {
        var book = EPUBTestBook()
        let chapters = smallChapters(remotePort: nil)
        for chapter in chapters {
            book.add("OEBPS/text/\(chapter.file)", EPUBTestBook.xhtml(title: chapter.title, body: chapter.body,
                                                                       head: "<link rel=\"stylesheet\" href=\"../style.css\"/>"))
        }
        book.add("OEBPS/style.css", css)
        book.add("OEBPS/images/figure.png", EPUBTestBook.png(width: 900, height: 600))
        book.add("OEBPS/images/cover.jpg", UIImage(data: EPUBTestBook.png(width: 300, height: 450))!.jpegData(compressionQuality: 0.8)!)
        var order = 0
        func points(_ entries: [NavEntry]) -> String {
            entries.map { entry in
                order += 1
                return """
                    <navPoint id="np\(order)" playOrder="\(order)"><navLabel><text>\(escape(entry.title))</text></navLabel>
                    <content src="\(entry.href)"/>\(points(entry.children))</navPoint>
                    """
            }.joined(separator: "\n")
        }
        book.add("OEBPS/toc.ncx", """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head><meta name="dtb:uid" content="\(identifier)"/></head>
            <docTitle><text>The NCX Test Book</text></docTitle>
            <navMap>\(points(smallNav))</navMap>
            </ncx>
            """)
        let items = chapters.enumerated().map { "<item id=\"c\($0.offset + 1)\" href=\"text/\($0.element.file)\" media-type=\"application/xhtml+xml\"/>" }
        let spine = chapters.indices.map { "<itemref idref=\"c\($0 + 1)\"/>" }
        book.add("OEBPS/content.opf", opf(version: "2.0", title: "The NCX Test Book", items: items + [
            "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>",
            "<item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>",
            "<item id=\"fig\" href=\"images/figure.png\" media-type=\"image/png\"/>",
            "<item id=\"coverimg\" href=\"images/cover.jpg\" media-type=\"image/jpeg\"/>",
        ], spine: spine, spineAttributes: " toc=\"ncx\"", extraMetadata: "<meta name=\"cover\" content=\"coverimg\"/>"))
        return book.data()
    }

    /// (c) One long chapter (about 170 pages at the medium size) with a heading every 100 paragraphs.
    static func long(paragraphs: Int = 1800) -> Data {
        var body = ""
        var nav: [NavEntry] = []
        for block in 0..<(paragraphs / 100) {
            body += "<h2 id=\"part\(block)\">Part \(block + 1) of the Long Chapter</h2>\n"
            body += EPUBTestBook.paragraphs("L\(block)", count: 100) + "\n"
            nav.append(NavEntry(title: "Part \(block + 1) of the Long Chapter", href: "long.xhtml#part\(block)"))
        }
        var book = EPUBTestBook()
        book.add("OEBPS/long.xhtml", EPUBTestBook.xhtml(title: "Long", body: body, head: ""))
        book.add("OEBPS/nav.xhtml", navDocument([NavEntry(title: "The Long Chapter", href: "long.xhtml", children: nav)]))
        book.add("OEBPS/content.opf", opf(version: "3.0", title: "A Long Book", items: [
            "<item id=\"long\" href=\"long.xhtml\" media-type=\"application/xhtml+xml\"/>",
            "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
        ], spine: ["<itemref idref=\"long\"/>"]))
        return book.data()
    }

    /// Chapters shaped like Project Gutenberg's, which printed empty pages: each opens with an
    /// empty `<div class="chapter">` with `page-break-before: always` before a heading that has
    /// one too; one ends with an empty element with `page-break-after: always`; one ends with a
    /// big bottom margin (as a figure or rule's margin does near the foot of a page); one ends
    /// with a rule followed by an empty paragraph. Each chapter's text fits on one page.
    static let edgeTitles = ["Edge One", "Edge Two", "Edge Three", "Edge Four"]

    static func edgeBreaks() -> Data {
        let css = """
            .chapter { page-break-before: always; margin-top: 4em; }
            h2 { page-break-before: always; padding-top: 1em; }
            .end { page-break-after: always; margin-top: 3em; }
            .tail { margin-bottom: 2000px; }
            hr.species { margin: 4% 47.5%; border: 1px solid; }
            """
        let bodies = [
            "<div class=\"chapter\"></div><h2>Edge One</h2>\(EPUBTestBook.paragraphs("E1", count: 3, words: 30))",
            "<div class=\"chapter\"></div><h2>Edge Two</h2>\(EPUBTestBook.paragraphs("E2", count: 3, words: 30))<div class=\"end\"></div>",
            "<h2>Edge Three</h2>\(EPUBTestBook.paragraphs("E3", count: 3, words: 30))<p class=\"tail\">Last line of edge three.</p>",
            "<h2>Edge Four</h2>\(EPUBTestBook.paragraphs("E4", count: 3, words: 30))<hr class=\"species\"/><p><span id=\"pg9\"></span></p>",
        ]
        var book = EPUBTestBook()
        for (index, body) in bodies.enumerated() {
            book.add("OEBPS/e\(index + 1).xhtml", EPUBTestBook.xhtml(title: edgeTitles[index], body: body,
                                                                    head: "<link rel=\"stylesheet\" href=\"edge.css\"/>"))
        }
        book.add("OEBPS/edge.css", css)
        book.add("OEBPS/nav.xhtml", navDocument(edgeTitles.enumerated().map { NavEntry(title: $0.element, href: "e\($0.offset + 1).xhtml") }))
        book.add("OEBPS/content.opf", opf(version: "3.0", title: "Edges", items: bodies.indices.map {
            "<item id=\"e\($0 + 1)\" href=\"e\($0 + 1).xhtml\" media-type=\"application/xhtml+xml\"/>"
        } + [
            "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
            "<item id=\"css\" href=\"edge.css\" media-type=\"text/css\"/>",
        ], spine: bodies.indices.map { "<itemref idref=\"e\($0 + 1)\"/>" }))
        return book.data()
    }

    /// A one-chapter book with `body`, plus extra files and manifest items.
    static func single(body: String, title: String = "Single", head: String = "", files: [(String, Data)] = [], items: [String] = [],
                       metadata: String = "", spine: [String]? = nil, encryption: String? = nil, extraMeta: [(String, String)] = []) -> Data {
        var book = EPUBTestBook()
        book.add("OEBPS/one.xhtml", EPUBTestBook.xhtml(title: "One", body: body, head: head))
        for (path, data) in files { book.add(path, data) }
        if let encryption { book.add("META-INF/encryption.xml", encryption) }
        for (path, text) in extraMeta { book.add(path, text) }
        book.add("OEBPS/content.opf", opf(version: "3.0", title: title, items: [
            "<item id=\"one\" href=\"one.xhtml\" media-type=\"application/xhtml+xml\"/>",
        ] + items, spine: spine ?? ["<itemref idref=\"one\"/>"], extraMetadata: metadata))
        return book.data()
    }

    static func opf(version: String, title: String, items: [String], spine: [String], spineAttributes: String = "",
                    extraMetadata: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="\(version)" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">\(identifier)</dc:identifier>
            <dc:title>\(escape(title))</dc:title>
            <dc:creator>A. Tester</dc:creator>
            <dc:language>en</dc:language>
            \(extraMetadata)
          </metadata>
          <manifest>
            \(items.joined(separator: "\n    "))
          </manifest>
          <spine\(spineAttributes)>
            \(spine.joined(separator: "\n    "))
          </spine>
        </package>
        """
    }

    static func navDocument(_ entries: [NavEntry]) -> String {
        func list(_ entries: [NavEntry]) -> String {
            "<ol>" + entries.map { entry in
                "<li><a href=\"\(entry.href)\">\(escape(entry.title))</a>\(entry.children.isEmpty ? "" : list(entry.children))</li>"
            }.joined() + "</ol>"
        }
        return EPUBTestBook.xhtml(title: "Contents", body: "<nav epub:type=\"toc\" id=\"toc\"><h1>Contents</h1>\(list(entries))</nav>", head: "")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }

    // MARK: Fonts

    /// A TrueType font file from the system (Chalkduster), to embed as a web font.
    static func fontData() -> Data? {
        let font = CTFontCreateWithName("Chalkduster" as CFString, 12, nil)
        guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL else { return nil }
        return try? Data(contentsOf: url)
    }

    /// IDPF obfuscation (written independently of the app's code): XOR the first 1040 bytes
    /// with the SHA-1 of the identifier without whitespace.
    static func idpfObfuscated(_ font: Data, identifier: String) -> Data {
        let key = Array(Insecure.SHA1.hash(data: Data(identifier.filter { !$0.isWhitespace }.utf8)))
        var bytes = [UInt8](font)
        for index in 0..<min(1040, bytes.count) { bytes[index] ^= key[index % key.count] }
        return Data(bytes)
    }

    /// Adobe obfuscation: XOR the first 1024 bytes with the 16 bytes of the UUID.
    static func adobeObfuscated(_ font: Data, uuid: String) -> Data {
        let hex = Array(uuid.replacingOccurrences(of: "urn:uuid:", with: "").replacingOccurrences(of: "-", with: ""))
        let key = stride(from: 0, to: 32, by: 2).map { UInt8(String(hex[$0..<$0 + 2]), radix: 16)! }
        var bytes = [UInt8](font)
        for index in 0..<min(1024, bytes.count) { bytes[index] ^= key[index % key.count] }
        return Data(bytes)
    }

    static func encryptionXML(_ algorithm: String, _ path: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="\(algorithm)"/>
            <enc:CipherData><enc:CipherReference URI="\(path)"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
    }
}

// MARK: - Workspace

/// A staging directory like the import flow's, with the original EPUB in it.
nonisolated final class EPUBTestWorkspace {
    let directory: URL
    let original: URL

    init(_ epub: Data, name: String = "Book.epub") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBConverterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        original = directory.appendingPathComponent("original.epub")
        try epub.write(to: original)
    }

    init(existing: URL) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBConverterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        original = existing
    }

    func input(textSize: ConversionTextSize = .medium) -> ConversionInput {
        ConversionInput(original: original, format: .epub, fileName: original.lastPathComponent, directory: directory,
                        outputFileName: "Book.pdf", options: ConversionOptions(textSize: textSize))
    }

    var contents: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

// MARK: - Instruments

/// Counts TCP connections to a loopback port: the "remote server" a book must never reach.
nonisolated final class EPUBTestNetworkCounter: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    private var paths: [String] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            lock.withLock { count += 1 }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                if let data, let line = String(data: data, encoding: .utf8)?.split(separator: "\r\n").first {
                    self.lock.withLock { self.paths.append(String(line)) }
                }
                let reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        listener.start(queue: .global())
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port != 0, listener.state == .ready { return port }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw URLError(.cannotConnectToHost)
    }

    var connections: Int { lock.withLock { count } }
    var requestLines: [String] { lock.withLock { paths } }

    deinit { listener.cancel() }
}

/// Measures how long the main thread goes without serving its queue: a background thread
/// posts a block to the main queue every few milliseconds and records how late it ran.
nonisolated final class EPUBTestMainThreadWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var longest: TimeInterval = 0
    private var longestAt: TimeInterval = 0
    private var samples = 0
    private let done = DispatchSemaphore(value: 0)

    init() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let sent = CACurrentMediaTime()
                let ran = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { ran.signal() }
                ran.wait()
                let delay = CACurrentMediaTime() - sent
                lock.withLock {
                    if delay > longest { longest = delay; longestAt = sent }
                    samples += 1
                }
                usleep(4000)
            }
            done.signal()
        }
    }

    /// Stops and returns the longest delay seen (seconds), when it began (`CACurrentMediaTime`)
    /// and the number of samples.
    func stop() -> (longest: TimeInterval, at: TimeInterval, samples: Int) {
        lock.withLock { running = false }
        done.wait()
        return lock.withLock { (longest, longestAt, samples) }
    }
}

/// Samples the process footprint every 10 ms and keeps the peak.
nonisolated final class EPUBTestMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Double = 0
    private var running = true
    private var phase = "start"
    private var phasePeaks: [String: Double] = [:]
    private var phaseOrder: [String] = ["start"]
    let start = EPUBTestMemorySampler.footprintMB()

    /// Peaks are also kept per phase (render, join…), set from a progress callback.
    func setPhase(_ name: String) {
        lock.withLock {
            guard phase != name else { return }
            phase = name
            if !phaseOrder.contains(name) { phaseOrder.append(name) }
        }
    }

    /// "render 80.1, join 95.3" in the order the phases began.
    var phaseSummary: String {
        lock.withLock { phaseOrder.compactMap { name in phasePeaks[name].map { String(format: "%@ %.1f", name, $0) } }.joined(separator: ", ") }
    }

    init() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let now = Self.footprintMB()
                lock.withLock {
                    peak = max(peak, now)
                    phasePeaks[phase] = max(phasePeaks[phase] ?? 0, now)
                }
                usleep(10_000)
            }
        }
    }

    func stop() -> (start: Double, peak: Double, end: Double) {
        let end = Self.footprintMB()
        return lock.withLock {
            running = false
            peak = max(peak, end)
            return (start, peak, end)
        }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

// MARK: - Reading the output

nonisolated enum EPUBTestPDF {
    /// Whitespace collapsed, for comparing PDF text with web text.
    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func pageText(_ document: PDFDocument, _ index: Int) -> String {
        collapsed(document.page(at: index)?.string ?? "")
    }

    /// Whether the page shows `title`, ignoring case, accents and all whitespace (PDF text
    /// extraction splits letter-spaced headings).
    static func page(_ document: PDFDocument, _ index: Int, shows title: String) -> Bool {
        let squeeze = { (text: String) in text.filter { !$0.isWhitespace } }
        return squeeze(document.page(at: index)?.string ?? "")
            .range(of: squeeze(title), options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Image XObjects in the file (CoreGraphics writes object dictionaries uncompressed).
    static func imageObjectCount(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return 0 }
        var count = 0
        for needle in ["/Subtype /Image", "/Subtype/Image"].map({ Data($0.utf8) }) {
            var range = data.startIndex..<data.endIndex
            while let found = data.range(of: needle, in: range) {
                count += 1
                range = found.upperBound..<data.endIndex
            }
        }
        return count
    }

    /// The `BaseFont` names used anywhere in the document (pages and nested form XObjects).
    static func baseFontNames(_ url: URL) -> Set<String> {
        guard let document = CGPDFDocument(url as CFURL) else { return [] }
        let names = FontNames()
        for number in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: number)?.dictionary else { continue }
            collectFonts(page, into: names, depth: 0)
        }
        return names.values
    }

    private final class FontNames { var values = Set<String>() }

    private static func collectFonts(_ dictionary: CGPDFDictionaryRef, into names: FontNames, depth: Int) {
        guard depth < 6 else { return }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return }
        var fonts: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts {
            CGPDFDictionaryApplyBlock(fonts, { _, object, _ in
                var font: CGPDFDictionaryRef?
                var name: UnsafePointer<CChar>?
                if CGPDFObjectGetValue(object, .dictionary, &font), let font,
                   CGPDFDictionaryGetName(font, "BaseFont", &name), let name {
                    names.values.insert(String(cString: name))
                }
                return true
            }, nil)
        }
        var objects: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects {
            CGPDFDictionaryApplyBlock(objects, { _, object, _ in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream), let stream, let inner = CGPDFStreamGetDictionary(stream) {
                    collectFonts(inner, into: names, depth: depth + 1)
                }
                return true
            }, nil)
        }
    }

    /// Link annotations: (page, bounds, url or destination page).
    static func links(_ document: PDFDocument) -> [(page: Int, bounds: CGRect, url: URL?, destination: Int?)] {
        var result: [(Int, CGRect, URL?, Int?)] = []
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Link" {
                let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url
                let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
                let page = destination?.page.map { document.index(for: $0) }
                result.append((index, annotation.bounds, url, page))
            }
        }
        return result
    }

    /// Pages with no extractable text whose rendered thumbnail is entirely white.
    static func blankPages(_ document: PDFDocument) -> [Int] {
        (0..<document.pageCount).filter { index in
            guard let page = document.page(at: index) else { return false }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty && isWhite(page)
        }
    }

    /// Whether the page draws nothing but white (rendered at 216 × 324 px).
    static func isWhite(_ page: PDFPage) -> Bool {
        let bounds = page.bounds(for: .mediaBox)
        let width = 216, height = Int((bounds.height / bounds.width * 216).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        page.draw(with: .mediaBox, to: context)
        guard let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else { return false }
        for index in 0..<(width * height) where pixels[index * 4] < 250 || pixels[index * 4 + 1] < 250 || pixels[index * 4 + 2] < 250 {
            return false
        }
        return true
    }

    /// Renders a page to a PNG (for looking at).
    static func png(_ document: PDFDocument, page index: Int, width: CGFloat = 600) -> Data? {
        guard let page = document.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = width / bounds.width
        let size = CGSize(width: width, height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }.pngData()
    }
}

/// Holds a task so a progress callback can cancel it.
nonisolated final class EPUBTestTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ConvertedDocument, any Error>?
    private var fired = false
    func set(_ task: Task<ConvertedDocument, any Error>) { lock.withLock { self.task = task } }
    func cancelOnce() {
        lock.withLock {
            guard !fired else { return }
            fired = true
            task?.cancel()
        }
    }
}
