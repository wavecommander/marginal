import Foundation
import Testing
@testable import ReaderCore

@Suite("EPUB package parser")
struct EPUBParserTests {
    static let epub3OPF = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="en">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="isbn">urn:isbn:9780000000000</dc:identifier>
        <dc:identifier id="uid">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier>
        <dc:title>  The   Book
          of Tests </dc:title>
        <dc:creator>Ada Lovelace</dc:creator>
        <dc:creator>Charles Babbage</dc:creator>
        <dc:language>en-GB</dc:language>
        <meta property="dcterms:modified">2024-01-01T00:00:00Z</meta>
      </metadata>
      <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="cover" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
        <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml" properties="svg scripted"/>
        <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
        <item id="remote" href="https://example.com/font.woff" media-type="font/woff"/>
      </manifest>
      <spine page-progression-direction="rtl">
        <itemref idref="c1"/>
        <itemref idref="c2" properties="page-spread-left"/>
        <itemref idref="notes" linear="no"/>
        <itemref idref="ghost"/>
      </spine>
    </package>
    """

    static let epub3Nav = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
    <head><title>Contents</title></head>
    <body>
      <nav epub:type="landmarks"><ol><li><a href="text/ch1.xhtml">Begin</a></li></ol></nav>
      <nav epub:type="toc" id="toc">
        <h1>Contents</h1>
        <ol>
          <li><a href="text/ch1.xhtml">Chapter&nbsp;One</a>
            <ol>
              <li><a href="text/ch1.xhtml#sec-1">Section
                    1.1</a></li>
              <li><a href="text/ch1.xhtml#sec%202"><span>Section</span> <em>1.2</em></a></li>
            </ol>
          </li>
          <li><span>Part Two</span>
            <ol><li><a href="text/ch2.xhtml">Chapter Two</a></li></ol>
          </li>
          <li><a href="#local">Here</a></li>
          <li><a href="http://example.com/">Website</a></li>
        </ol>
      </nav>
    </body>
    </html>
    """

    static func epub3(extra: [(String, String)] = []) -> Data {
        epubData([
            ("META-INF/container.xml", container("OEBPS/content.opf")),
            ("OEBPS/content.opf", epub3OPF),
            ("OEBPS/nav.xhtml", epub3Nav),
            ("OEBPS/text/ch1.xhtml", "<html/>"),
            ("OEBPS/text/ch2.xhtml", "<html/>"),
        ] + extra)
    }

    static let ncx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <head><meta name="dtb:uid" content="x"/></head>
      <docTitle><text>Old Book</text></docTitle>
      <navMap>
        <navPoint id="p1" playOrder="1">
          <navLabel><text>Chapter 1</text></navLabel>
          <content src="Text/Chapter%201.xhtml"/>
          <navPoint id="p1a" playOrder="2">
            <navLabel><text>  First
               part </text></navLabel>
            <content src="Text/Chapter%201.xhtml#part1"/>
          </navPoint>
        </navPoint>
        <navPoint id="p2" playOrder="3">
          <navLabel><text>Chapter 2</text></navLabel>
          <content src="../Shared/ch2.html"/>
        </navPoint>
      </navMap>
    </ncx>
    """

    static func epub2OPF(coverMeta: String = #"<meta name="cover" content="cover-img"/>"#, guide: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <opf:package xmlns:opf="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="BookId">
          <opf:metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:title>Old Book</dc:title>
            <dc:creator opf:role="aut">Anon</dc:creator>
            <dc:identifier id="BookId">urn:uuid:aaaa</dc:identifier>
            \(coverMeta)
          </opf:metadata>
          <opf:manifest>
            <opf:item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <opf:item id="cover-img" href="../Images/cover%20art.png" media-type="image/png"/>
            <opf:item id="cover-page" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
            <opf:item id="ch1" href="Text/Chapter%201.xhtml" media-type="application/xhtml+xml"/>
            <opf:item id="ch2" href="./../Shared/ch2.html" media-type="application/xhtml+xml"/>
            <opf:item id="escape" href="../../../outside.xhtml" media-type="application/xhtml+xml"/>
          </opf:manifest>
          <opf:spine toc="ncx">
            <opf:itemref idref="cover-page" linear="no"/>
            <opf:itemref idref="ch1"/>
            <opf:itemref idref="ch2"/>
          </opf:spine>
          \(guide)
        </opf:package>
        """
    }

    static func epub2(opf: String = epub2OPF(), extra: [(String, String)] = []) -> Data {
        epubData([
            ("META-INF/container.xml", container("OPS/content/package.opf")),
            ("OPS/content/package.opf", opf),
            ("OPS/content/toc.ncx", ncx),
        ] + extra)
    }

    func parse(_ data: Data) throws -> EPUBPackage {
        try EPUBParser.parse(archive: try ZIPArchive(data: data))
    }

    @Test func epub3MetadataManifestSpineAndCover() throws {
        let package = try parse(Self.epub3())
        #expect(package.packagePath == "OEBPS/content.opf")
        #expect(package.version == "3.0")
        #expect(package.metadata == EPUBPackage.Metadata(
            title: "The Book of Tests", creators: ["Ada Lovelace", "Charles Babbage"], language: "en-GB",
            identifier: "urn:uuid:12345678-1234-1234-1234-123456789abc"))
        #expect(package.manifest.map(\.id) == ["nav", "cover", "c1", "c2", "notes"])  // remote item left out
        #expect(package.manifestItem(id: "c1")?.path == "OEBPS/text/ch1.xhtml")
        #expect(package.manifestItem(id: "c2")?.properties == ["svg", "scripted"])
        #expect(package.spine.map(\.idref) == ["c1", "c2", "notes", "ghost"])
        #expect(package.spine.map(\.isLinear) == [true, true, false, true])
        #expect(package.spine[1].properties == ["page-spread-left"])
        #expect(package.readingOrder.map(\.id) == ["c1", "c2", "notes"])
        #expect(package.pageProgressionDirection == .rightToLeft)
        #expect(package.coverImagePath == "OEBPS/images/cover.jpg")
        #expect(!package.isFixedLayout)
        #expect(!package.protection.isProtected)
    }

    @Test func epub3NavigationNestedWithFragments() throws {
        let package = try parse(Self.epub3())
        #expect(package.navigationSource == .navDocument)
        let expected = [
            // `&nbsp;` is accepted, and collapses like any other whitespace.
            EPUBNavigationPoint(title: "Chapter One", path: "OEBPS/text/ch1.xhtml", children: [
                EPUBNavigationPoint(title: "Section 1.1", path: "OEBPS/text/ch1.xhtml", fragment: "sec-1"),
                EPUBNavigationPoint(title: "Section 1.2", path: "OEBPS/text/ch1.xhtml", fragment: "sec 2"),
            ]),
            EPUBNavigationPoint(title: "Part Two", children: [
                EPUBNavigationPoint(title: "Chapter Two", path: "OEBPS/text/ch2.xhtml"),
            ]),
            EPUBNavigationPoint(title: "Here", path: "OEBPS/nav.xhtml", fragment: "local"),
            EPUBNavigationPoint(title: "Website"),
        ]
        #expect(package.navigation == expected)
    }

    @Test func epub2NCXInSubdirectoryWithRelativeAndPercentEncodedHrefs() throws {
        let package = try parse(Self.epub2())
        #expect(package.packagePath == "OPS/content/package.opf")
        #expect(package.version == "2.0")
        #expect(package.metadata.title == "Old Book" && package.metadata.creators == ["Anon"])
        #expect(package.metadata.identifier == "urn:uuid:aaaa")
        #expect(package.manifestItem(id: "cover-img")?.path == "OPS/Images/cover art.png")
        #expect(package.manifestItem(id: "ch1")?.path == "OPS/content/Text/Chapter 1.xhtml")
        #expect(package.manifestItem(id: "ch2")?.path == "OPS/Shared/ch2.html")
        #expect(package.manifestItem(id: "escape") == nil)
        #expect(package.pageProgressionDirection == nil)
        #expect(package.coverImagePath == "OPS/Images/cover art.png")  // <meta name="cover">
        #expect(package.navigationSource == .ncx)
        #expect(package.navigation == [
            EPUBNavigationPoint(title: "Chapter 1", path: "OPS/content/Text/Chapter 1.xhtml", children: [
                EPUBNavigationPoint(title: "First part", path: "OPS/content/Text/Chapter 1.xhtml", fragment: "part1"),
            ]),
            EPUBNavigationPoint(title: "Chapter 2", path: "OPS/Shared/ch2.html"),
        ])
    }

    @Test func navIsPreferredAndNCXIsTheFallback() throws {
        // EPUB 3 with both: nav wins.
        var opf = Self.epub3OPF.replacingOccurrences(
            of: "<item id=\"c1\"", with: "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n<item id=\"c1\"")
        let both = epubData([
            ("META-INF/container.xml", container("OEBPS/content.opf")),
            ("OEBPS/content.opf", opf),
            ("OEBPS/nav.xhtml", Self.epub3Nav),
            ("OEBPS/toc.ncx", Self.ncx),
        ])
        #expect(try parse(both).navigationSource == .navDocument)
        // The nav document is missing from the archive: fall back to the NCX.
        let noNav = epubData([
            ("META-INF/container.xml", container("OEBPS/content.opf")),
            ("OEBPS/content.opf", opf),
            ("OEBPS/toc.ncx", Self.ncx),
        ])
        let fallback = try parse(noNav)
        #expect(fallback.navigationSource == .ncx)
        #expect(fallback.navigation.first?.path == "OEBPS/Text/Chapter 1.xhtml")
        // Neither: no navigation, not an error.
        opf = Self.epub3OPF
        let neither = epubData([("META-INF/container.xml", container("OEBPS/content.opf")), ("OEBPS/content.opf", opf)])
        let bare = try parse(neither)
        #expect(bare.navigationSource == .none && bare.navigation.isEmpty)
    }

    @Test func coverFallsBackToGuideOnlyWhenItIsAnImage() throws {
        let imageGuide = #"<guide><reference type="cover" href="../Images/cover%20art.png" title="Cover"/></guide>"#
        let viaGuide = try parse(Self.epub2(opf: Self.epub2OPF(coverMeta: "", guide: imageGuide)))
        #expect(viaGuide.coverImagePath == "OPS/Images/cover art.png")
        let pageGuide = #"<guide><reference type="cover" href="Text/cover.xhtml"/></guide>"#
        #expect(try parse(Self.epub2(opf: Self.epub2OPF(coverMeta: "", guide: pageGuide))).coverImagePath == nil)
        // <meta name="cover"> naming a non-image item is ignored.
        let wrongMeta = #"<meta name="cover" content="cover-page"/>"#
        #expect(try parse(Self.epub2(opf: Self.epub2OPF(coverMeta: wrongMeta))).coverImagePath == nil)
    }

    @Test func fixedLayoutByRenditionOrAppleOptions() throws {
        let fxlOPF = Self.epub3OPF.replacingOccurrences(
            of: "<dc:language>", with: "<meta property=\"rendition:layout\">pre-paginated</meta>\n<dc:language>")
        let fxl = epubData([("META-INF/container.xml", container("OEBPS/content.opf")), ("OEBPS/content.opf", fxlOPF)])
        #expect(try parse(fxl).isFixedLayout)

        let reflowOPF = Self.epub3OPF.replacingOccurrences(
            of: "<dc:language>", with: "<meta property=\"rendition:layout\">reflowable</meta>\n<dc:language>")
        let reflow = epubData([("META-INF/container.xml", container("OEBPS/content.opf")), ("OEBPS/content.opf", reflowOPF)])
        #expect(try !parse(reflow).isFixedLayout)

        let apple = """
        <?xml version="1.0" encoding="UTF-8"?>
        <display_options><platform name="*"><option name="fixed-layout">true</option></platform></display_options>
        """
        #expect(try parse(Self.epub2(extra: [("META-INF/com.apple.ibooks.display-options.xml", apple)])).isFixedLayout)
        let appleOff = apple.replacingOccurrences(of: ">true<", with: ">false<")
        #expect(try !parse(Self.epub2(extra: [("META-INF/com.apple.ibooks.display-options.xml", appleOff)])).isFixedLayout)
    }

    static func encryption(_ items: [(algorithm: String, uri: String)]) -> String {
        let data = items.map { item in
            """
            <enc:EncryptedData xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptionMethod Algorithm="\(item.algorithm)"/>
              <enc:CipherData><enc:CipherReference URI="\(item.uri)"/></enc:CipherData>
            </enc:EncryptedData>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\(data)</encryption>
        """
    }

    @Test func fontObfuscationAloneIsNotProtection() throws {
        let xml = Self.encryption([
            ("http://www.idpf.org/2008/embedding", "OEBPS/fonts/Serif.otf"),
            ("http://ns.adobe.com/pdf/enc#RC", "OEBPS/fonts/Sans%20Bold.ttf"),
        ])
        let protection = try parse(Self.epub3(extra: [("META-INF/encryption.xml", xml)])).protection
        #expect(!protection.isProtected)
        #expect(protection.obfuscatedResources == [
            EPUBObfuscatedResource(path: "OEBPS/fonts/Serif.otf", algorithm: .idpf),
            EPUBObfuscatedResource(path: "OEBPS/fonts/Sans Bold.ttf", algorithm: .adobe),
        ])
    }

    @Test func realEncryptionRightsAndFairPlayAreProtection() throws {
        let aes = "http://www.w3.org/2001/04/xmlenc#aes128-cbc"
        let mixed = Self.encryption([("http://www.idpf.org/2008/embedding", "OEBPS/fonts/a.otf"), (aes, "OEBPS/text/ch1.xhtml")])
        let encrypted = try parse(Self.epub3(extra: [("META-INF/encryption.xml", mixed)])).protection
        #expect(encrypted.isProtected && encrypted.mechanisms == [.encryption])
        #expect(encrypted.encryptionAlgorithms == [aes])
        #expect(encrypted.obfuscatedResources.count == 1)

        let rights = try parse(Self.epub3(extra: [("META-INF/rights.xml", "<rights/>")])).protection
        #expect(rights.mechanisms == [.rightsFile])
        let fairPlay = try parse(Self.epub3(extra: [("META-INF/sinf.xml", "<fairplay/>")])).protection
        #expect(fairPlay.mechanisms == [.appleFairPlay])
        let lcp = try parse(Self.epub3(extra: [("META-INF/license.lcpl", "{}")])).protection
        #expect(lcp.mechanisms == [.readiumLCP])
        let unreadable = try parse(Self.epub3(extra: [("META-INF/encryption.xml", "<encryption><oops>")])).protection
        #expect(unreadable.mechanisms == [.encryption])
        // Protection is readable without a package document.
        let bare = try ZIPArchive(data: epubData([("META-INF/rights.xml", "<rights/>")]))
        #expect(try EPUBParser.protection(in: bare).isProtected)
    }

    @Test func malformedInputThrowsTypedErrors() throws {
        func error(_ files: [(String, String)]) -> EPUBError? {
            thrownError { _ = try parse(epubData(files)) } as? EPUBError
        }
        #expect(error([("OEBPS/content.opf", Self.epub3OPF)]) == .missingContainer)
        #expect(error([("META-INF/container.xml", container("OEBPS/missing.opf"))]) == .missingPackageDocument(path: "OEBPS/missing.opf"))
        #expect(error([("META-INF/container.xml", "<container><rootfiles/></container>")]) == .noPackageDocument)
        #expect(error([("META-INF/container.xml", "<container><rootfiles>")]) == .malformedXML(path: "META-INF/container.xml"))
        #expect(error([("META-INF/container.xml", container("a.opf")), ("a.opf", "<package><manifest>")])
            == .malformedXML(path: "a.opf"))
        #expect(error([("META-INF/container.xml", container("a.opf")), ("a.opf", "<package><manifest/></package>")])
            == .invalidPackageDocument(path: "a.opf"))
        #expect(error([("META-INF/container.xml", container("a.opf")), ("a.opf", "<html><body/></html>")])
            == .invalidPackageDocument(path: "a.opf"))
        // Not a ZIP at all, through the file entry point.
        let temp = TempDirectory()
        let url = temp.file("book.epub", Data("not a zip".utf8))
        #expect(thrownError { _ = try EPUBParser.parse(fileAt: url) } as? EPUBError == .archive(.notAZIPArchive))
    }

    @Test func externalEntitiesAreNotResolved() throws {
        let secret = TempDirectory()
        let secretFile = secret.file("secret.txt", Data("TOP-SECRET-CONTENT".utf8))
        let opf = """
        <?xml version="1.0"?>
        <!DOCTYPE package [ <!ENTITY xxe SYSTEM "\(secretFile.absoluteString)"> ]>
        <package version="3.0"><metadata><title>Book &xxe;</title></metadata>
        <manifest/><spine/></package>
        """
        let data = epubData([("META-INF/container.xml", container("a.opf")), ("a.opf", opf)])
        do {
            let package = try parse(data)
            #expect(package.metadata.title?.contains("TOP-SECRET") != true)
        } catch {
            #expect(error as? EPUBError == .malformedXML(path: "a.opf"))
        }
    }

    @Test func deeplyNestedXMLIsRejectedNotCrashing() throws {
        let deep = String(repeating: "<a>", count: 5000) + String(repeating: "</a>", count: 5000)
        #expect(XMLTree.parse(Data(deep.utf8)) == nil)
        #expect(XMLTree.parse(Data("<a><b/></a>".utf8))?.child("b") != nil)
    }

    @Test func hrefResolution() {
        #expect(EPUBPath.resolve("ch1.xhtml", relativeTo: "OEBPS/content.opf")! == ("OEBPS/ch1.xhtml", nil))
        #expect(EPUBPath.resolve("../a%20b.xhtml#f%201", relativeTo: "OEBPS/x/nav.xhtml")! == ("OEBPS/a b.xhtml", "f 1"))
        #expect(EPUBPath.resolve("/root.xhtml", relativeTo: "OEBPS/content.opf")! == ("root.xhtml", nil))
        #expect(EPUBPath.resolve("a.xhtml?x=1#y", relativeTo: "c.opf")! == ("a.xhtml", "y"))
        #expect(EPUBPath.resolve("#top", relativeTo: "OEBPS/nav.xhtml")! == ("OEBPS/nav.xhtml", "top"))
        #expect(EPUBPath.resolve("../../x", relativeTo: "OEBPS/c.opf") == nil)
        #expect(EPUBPath.resolve("mailto:a@b.c", relativeTo: "c.opf") == nil)
        #expect(EPUBPath.resolve("https://x.y/z", relativeTo: "c.opf") == nil)
        #expect(EPUBPath.resolve("", relativeTo: "") == nil)
    }
}
