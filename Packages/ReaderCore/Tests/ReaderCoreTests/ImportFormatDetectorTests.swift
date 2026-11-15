import Foundation
import Testing
@testable import ReaderCore

@Suite("Import format detection")
struct ImportFormatDetectorTests {
    let temp = TempDirectory()

    func detect(_ name: String, _ data: Data) throws -> ImportDetection {
        try ImportFormatDetector.detect(fileAt: temp.file(name, data))
    }

    func detect(_ name: String, _ text: String) throws -> ImportDetection {
        try detect(name, Data(text.utf8))
    }

    static let pdf = Data("%PDF-1.7\n1 0 obj << >> endobj\n%%EOF\n".utf8)
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0, 1, 2, 3])
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8))
    static let ole = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 504))
    static let epub = EPUBParserTests.epub3()

    static func ftyp(_ brand: String) -> Data {
        Data([0, 0, 0, 0x18] + Array("ftyp".utf8) + Array(brand.utf8) + [0, 0, 0, 0] + Array("mif1heic".utf8))
    }

    static func imagesZip(_ names: [String]) -> Data {
        TestZIP(names.map { TestZIPEntry($0, jpeg) }).build()
    }

    static func ooxml(_ part: String) -> Data {
        zipData([("[Content_Types].xml", "<Types/>"), ("_rels/.rels", "<Relationships/>"), ("\(part)/document.xml", "<x/>")])
    }

    // MARK: PDF

    @Test func pdfByMagicWhateverTheName() throws {
        #expect(try detect("a.pdf", Self.pdf) == .supported(.pdf))
        #expect(try detect("misnamed.epub", Self.pdf) == .supported(.pdf))
        #expect(try detect("noext", Self.pdf) == .supported(.pdf))
        // Leading junk within the first 1 KiB, like the app's existing check.
        #expect(try detect("junk.pdf", Data(repeating: 0x20, count: 1000) + Self.pdf) == .supported(.pdf))
        #expect(try detect("late.pdf", Data(repeating: 0x20, count: 1100) + Self.pdf) == .unknown)
    }

    // MARK: ZIP-based

    @Test func epubByMimetypeWhateverTheName() throws {
        #expect(try detect("book.epub", Self.epub) == .supported(.epub))
        #expect(try detect("book.zip", Self.epub) == .supported(.epub))
        #expect(try detect("book.cbz", Self.epub) == .supported(.epub))
        // An .epub with a container but no mimetype entry.
        let noMimetype = epubData([("META-INF/container.xml", container("a.opf"))], mimetype: false)
        #expect(try detect("loose.epub", noMimetype) == .supported(.epub))
        #expect(try detect("loose.zip", noMimetype) == .unknown)
    }

    @Test func protectedAndFixedLayoutEPUBsAreNamed() throws {
        let rights = EPUBParserTests.epub3(extra: [("META-INF/rights.xml", "<rights/>")])
        #expect(try detect("drm.epub", rights) == .unsupported(.protectedEPUB))
        let aes = EPUBParserTests.encryption([("http://www.w3.org/2001/04/xmlenc#aes128-cbc", "OEBPS/text/ch1.xhtml")])
        #expect(try detect("drm2.epub", EPUBParserTests.epub3(extra: [("META-INF/encryption.xml", aes)])) == .unsupported(.protectedEPUB))
        let fonts = EPUBParserTests.encryption([("http://www.idpf.org/2008/embedding", "OEBPS/fonts/a.otf")])
        #expect(try detect("fonts.epub", EPUBParserTests.epub3(extra: [("META-INF/encryption.xml", fonts)])) == .supported(.epub))
        let fairPlay = epubData([("META-INF/sinf.xml", "<x/>")])  // no package document at all
        #expect(try detect("apple.epub", fairPlay) == .unsupported(.protectedEPUB))
        let apple = """
        <display_options><platform name="*"><option name="fixed-layout">true</option></platform></display_options>
        """
        let fxl = EPUBParserTests.epub2(extra: [("META-INF/com.apple.ibooks.display-options.xml", apple)])
        #expect(try detect("fxl.epub", fxl) == .unsupported(.fixedLayoutEPUB))
        // A broken package document is still an EPUB here; the converter reports it.
        let broken = epubData([("META-INF/container.xml", container("a.opf")), ("a.opf", "<package>")])
        #expect(try detect("broken.epub", broken) == .supported(.epub))
    }

    @Test func comicArchivesAreZipsOfImages() throws {
        let pages = ["001.jpg", "002.JPG", "sub/003.png", "004.webp", "005.heic", "006.tiff", "007.gif"]
        #expect(try detect("comic.cbz", Self.imagesZip(pages)) == .supported(.comicArchive))
        #expect(try detect("comic.zip", Self.imagesZip(pages)) == .supported(.comicArchive))
        #expect(try detect("comic.cbr", Self.imagesZip(pages)) == .supported(.comicArchive))  // magic beats extension
        var littered = TestZIP(pages.map { TestZIPEntry($0, Self.jpeg) })
        littered.entries += [
            TestZIPEntry("ComicInfo.xml", "<ComicInfo/>"), TestZIPEntry("readme.txt", "hi"),
            TestZIPEntry("__MACOSX/._001.jpg", "junk"), TestZIPEntry(".DS_Store", "junk"),
            TestZIPEntry("sub/.hidden", "junk"), TestZIPEntry("Thumbs.db", "junk"), TestZIPEntry("sub/", Data()),
        ]
        #expect(try detect("littered.cbz", littered.build()) == .supported(.comicArchive))
        // Mixed non-images, or nothing but metadata: not a comic.
        let mixed = zipData([("001.jpg", "x"), ("notes.docx", "x"), ("song.mp3", "x")])
        #expect(try detect("mixed.zip", mixed) == .unknown)
        #expect(try detect("mixed.cbz", mixed) == .unknown)
        #expect(try detect("meta.zip", zipData([("ComicInfo.xml", "<x/>")])) == .unknown)
        #expect(try detect("empty.zip", TestZIP([]).build()) == .unknown)
    }

    @Test func officeOpenXML() throws {
        #expect(try detect("report.docx", Self.ooxml("word")) == .supported(.word))
        #expect(try detect("report.zip", Self.ooxml("word")) == .supported(.word))
        #expect(try detect("deck.pptx", Self.ooxml("ppt")) == .supported(.powerPoint))
        #expect(try detect("sheet.xlsx", Self.ooxml("xl")) == .unsupported(.spreadsheet))
        #expect(try detect("drawing.vsdx", Self.ooxml("visio")) == .unknown)
        let ods = zipData([("mimetype", "application/vnd.oasis.opendocument.spreadsheet"), ("content.xml", "<x/>")])
        #expect(try detect("sheet.ods", ods) == .unsupported(.spreadsheet))
    }

    @Test func iWorkFilesAndPackages() throws {
        let iwa = zipData([("Index/Document.iwa", "x"), ("Metadata/Properties.plist", "x"), ("preview.jpg", "x")])
        #expect(try detect("essay.pages", iwa) == .supported(.pages))
        #expect(try detect("talk.key", iwa) == .supported(.keynote))
        #expect(try detect("budget.numbers", iwa) == .unsupported(.spreadsheet))
        #expect(try detect("essay.zip", iwa) == .unknown)
        // Not a ZIP: the extension alone is not enough.
        #expect(try detect("fake.pages", "plain text") == .unknown)
        // Package directories.
        let pages = temp.directory("Paper.pages")
        try Data("x".utf8).write(to: pages.appendingPathComponent("Index.zip"))
        #expect(try ImportFormatDetector.detect(fileAt: pages) == .supported(.pages))
        #expect(try ImportFormatDetector.detect(fileAt: temp.directory("Slides.key")) == .supported(.keynote))
        #expect(try ImportFormatDetector.detect(fileAt: temp.directory("Accounts.numbers")) == .unsupported(.spreadsheet))
        #expect(try ImportFormatDetector.detect(fileAt: temp.directory("Folder")) == .unknown)
    }

    // MARK: Other magic

    @Test func oleCompoundFilesByExtension() throws {
        #expect(try detect("old.doc", Self.ole) == .supported(.word))
        #expect(try detect("old.ppt", Self.ole) == .supported(.powerPoint))
        #expect(try detect("old.xls", Self.ole) == .unsupported(.spreadsheet))
        #expect(try detect("mail.msg", Self.ole) == .unknown)
    }

    @Test func rtf() throws {
        #expect(try detect("letter.rtf", #"{\rtf1\ansi Hello}"#) == .supported(.rtf))
        #expect(try detect("letter.doc", #"{\rtf1\ansi Hello}"#) == .supported(.rtf))
    }

    @Test func images() throws {
        #expect(try detect("a.jpg", Self.jpeg) == .supported(.image))
        #expect(try detect("a.png", Self.png) == .supported(.image))
        #expect(try detect("a.png", Self.jpeg) == .supported(.image))
        #expect(try detect("a.gif", "GIF89a....") == .supported(.image))
        #expect(try detect("a.tif", Data([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0])) == .supported(.image))
        #expect(try detect("a.tif", Data([0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8])) == .supported(.image))
        #expect(try detect("a.webp", Data("RIFF".utf8) + Data([0x24, 0, 0, 0]) + Data("WEBPVP8 ".utf8)) == .supported(.image))
        for brand in ["heic", "heix", "mif1", "avif"] {
            #expect(try detect("a.heic", Self.ftyp(brand)) == .supported(.image), "\(brand)")
        }
        #expect(try detect("clip.mp4", Self.ftyp("isom")) == .unknown)
        #expect(try detect("a.bmp", Data("BM".utf8) + Data(repeating: 0, count: 50)) == .supported(.image))
        #expect(try detect("a.bin", Data("BM".utf8) + Data(repeating: 0, count: 50)) == .unknown)
    }

    @Test func webArchive() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["WebMainResource": ["WebResourceData": Data("<html/>".utf8)]], format: .binary, options: 0)
        #expect(try detect("page.webarchive", plist) == .supported(.webArchive))
        #expect(try detect("page.bin", plist) == .supported(.webArchive))
        let other = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0)
        #expect(try detect("settings.plist", other) == .unknown)
    }

    // MARK: Text

    @Test func textByExtensionWithATextGuard() throws {
        #expect(try detect("notes.txt", "Hello\nworld") == .supported(.plainText))
        #expect(try detect("notes.text", "Hello") == .supported(.plainText))
        #expect(try detect("README.md", "# Title\n\nBody") == .supported(.markdown))
        #expect(try detect("README.markdown", "# Title") == .supported(.markdown))
        #expect(try detect("page.html", "<!doctype html><p>x") == .supported(.html))
        #expect(try detect("page.htm", "<p>x") == .supported(.html))
        #expect(try detect("page.xhtml", "<?xml version=\"1.0\"?><html/>") == .supported(.html))
        #expect(try detect("latin1.txt", Data([0x63, 0x61, 0x66, 0xE9])) == .supported(.plainText))
        // Binary content behind a text extension.
        #expect(try detect("binary.txt", Data([0x41, 0x00, 0x00, 0x42, 0x00, 0x00, 0x7F, 0x01])) == .unknown)
        #expect(try detect("noise.md", noise(4000, seed: 1) + Data([0])) == .unknown)
        // UTF-16, with and without a byte-order mark.
        let bom = Data([0xFF, 0xFE]) + "Hello, world".data(using: .utf16LittleEndian)!
        #expect(try detect("utf16.txt", bom) == .supported(.plainText))
        #expect(try detect("utf16be.txt", "Hello, world".data(using: .utf16BigEndian)!) == .supported(.plainText))
        // No extension: HTML is sniffed, other text is not guessed.
        #expect(try detect("index", "  <!DOCTYPE html>\n<html>") == .supported(.html))
        #expect(try detect("notes", "just words") == .unknown)
        #expect(try detect("notes.log", "just words") == .unknown)
    }

    // MARK: Unsupported and unknown

    @Test func namedUnsupportedFormats() throws {
        #expect(try detect("comic.cbr", Data("Rar!".utf8) + Data([0x1A, 0x07, 0x00, 0xCF])) == .unsupported(.comicRar))
        #expect(try detect("comic.cbz", Data("Rar!".utf8) + Data([0x1A, 0x07, 0x01, 0x00])) == .unsupported(.comicRar))
        #expect(try detect("scan.djvu", Data("AT&TFORM".utf8) + Data([0, 0, 1, 0]) + Data("DJVM".utf8)) == .unsupported(.djvu))
        var mobi = Data(repeating: 0x20, count: 60)
        mobi.append(Data("BOOKMOBI".utf8))
        mobi.append(Data(repeating: 0, count: 20))
        #expect(try detect("book.mobi", mobi) == .unsupported(.kindle))
        #expect(try detect("book.pdb", mobi) == .unsupported(.kindle))
        for ext in ["azw", "azw3", "kfx", "mobi", "prc"] {
            #expect(try detect("book.\(ext)", noise(200, seed: 9)) == .unsupported(.kindle), "\(ext)")
        }
        #expect(try detect("kfx.kfx", zipData([("book.kdf", "x")])) == .unsupported(.kindle))
        #expect(try detect("data.csv", "a,b\n1,2\n") == .unsupported(.spreadsheet))
        #expect(try detect("data.tsv", "a\tb\n") == .unsupported(.spreadsheet))
    }

    @Test func unknownAndUnreadable() throws {
        #expect(try detect("empty.txt", Data()) == .unknown)
        #expect(try detect("random.bin", noise(5000, seed: 5)) == .unknown)
        #expect(try detect("corrupt.epub", Data([0x50, 0x4B, 0x03, 0x04]) + noise(100, seed: 2)) == .unknown)
        #expect(try detect("corrupt.xlsx", Data([0x50, 0x4B, 0x03, 0x04]) + noise(100, seed: 2)) == .unsupported(.spreadsheet))
        let missing = temp.url.appendingPathComponent("missing.pdf")
        #expect(throws: (any Error).self) { _ = try ImportFormatDetector.detect(fileAt: missing) }
        #expect(ImportDetection.supported(.epub).supportedFormat == .epub)
        #expect(ImportDetection.unsupported(.djvu).supportedFormat == nil)
    }

    @Test func respectsZIPLimits() throws {
        let url = temp.file("big.cbz", Self.imagesZip((0..<20).map { "\($0).jpg" }))
        #expect(try ImportFormatDetector.detect(fileAt: url, limits: .init(maxEntryCount: 10)) == .unknown)
        #expect(try ImportFormatDetector.detect(fileAt: url) == .supported(.comicArchive))
    }
}
