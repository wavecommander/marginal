import Foundation
import PDFKit
import ReaderCore
import UIKit
@testable import Marginal

// Fixtures and helpers for the F6 converter tests (text, Office documents, slides). The Office
// fixtures are committed under Tests/Fixtures/f6-* and rebuilt by
// Tests/Fixtures/f6-make-fixtures.py; the text fixtures are built here.

nonisolated enum F6Fixtures {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static func fixture(_ name: String) -> URL { repo.appendingPathComponent("Tests/Fixtures/\(name)") }
    /// Rendered pages are written here for a look by eye (build/ is not committed).
    static let pagesDirectory = repo.appendingPathComponent("build/f6-pages", isDirectory: true)

    /// A real file of a format this Mac cannot make, if the owner left one in Downloads.
    static func downloaded(_ name: String) -> URL? {
        let url = URL(fileURLWithPath: "/Users/benw/Downloads").appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) ? url : nil
    }

    // MARK: Text

    static let markdown = """
        # The Harbour Handbook

        An opening paragraph with *emphasis*, **strong words**, `inline code` and a \
        [link to the forecast](https://example.com/f6-forecast). See [the tides](#tides-and-currents).

        ## Getting Started

        MDWORD-start. \(filler(3))

        - First item MDWORD-list-1
        - Second item
          - Nested item MDWORD-nested
          - Another nested item
        - Third item

        1. Ordered one
        2. Ordered two MDWORD-ordered

        > A block quote MDWORD-quote about the sea.

        ```swift
        let answer = 42 // MDWORD-code
        ```

        ### Equipment

        | Item | Count |
        | :--- | ---: |
        | Rope MDWORD-table | 4 |
        | Buoy | 12 |

        ---

        ![a picture that is not in the file](images/missing.png)

        ## Tides and Currents

        \((1...14).map { "MDWORD-tides-\($0). \(filler(2))" }.joined(separator: "\n\n"))

        ### Spring Tides

        MDWORD-spring. \(filler(4))

        # Appendix

        MDWORD-appendix closes the document.
        """

    static let markdownHeadings: [(String, Int)] = [
        ("The Harbour Handbook", 1), ("Getting Started", 2), ("Equipment", 3), ("Tides and Currents", 2),
        ("Spring Tides", 3), ("Appendix", 1),
    ]

    static func filler(_ sentences: Int) -> String {
        Array(repeating: "The tide came in over the flats while the gulls argued about the light.", count: sentences)
            .joined(separator: " ")
    }

    /// An HTML page with a title, headings, a table, a `data:` picture, an external link, an
    /// internal link, and (with `remotePort`) a picture, style sheet and frame on a server.
    static func html(remotePort: UInt16? = nil) -> String {
        let png = EPUBTestBook.png(width: 80, height: 40).base64EncodedString()
        let remote = remotePort.map { port in
            """
            <link rel="stylesheet" href="http://127.0.0.1:\(port)/remote.css">
            <script src="http://127.0.0.1:\(port)/remote.js"></script>
            """
        } ?? ""
        let remoteBody = remotePort.map { port in
            """
            <p><img src="http://127.0.0.1:\(port)/remote.png" alt="Remote chart"> after the remote picture.</p>
            <iframe src="http://127.0.0.1:\(port)/frame.html"></iframe>
            <p style="background-image: url('http://127.0.0.1:\(port)/bg.png')">Background paragraph.</p>
            """
        } ?? ""
        let sections = (1...3).map { section in
            """
            <h2 id="s\(section)">Section \(section): Lighthouse Duties</h2>
            \((1...8).map { "<p>HTMLWORD-\(section)-\($0). \(filler(3))</p>" }.joined(separator: "\n"))
            <h3>Subsection \(section).1 Logbook</h3>
            <p>HTMLWORD-\(section)-log. \(filler(2))</p>
            """
        }.joined(separator: "\n")
        return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><title>The Keeper's Manual</title>\(remote)
            <style>.note { color: #333; }</style>
            <script>document.title = 'SCRIPT RAN';</script></head>
            <body>
            <h1>Keeper's Manual</h1>
            <p class="note">HTMLWORD-intro with <a href="https://example.com/f6-html">an external link</a> and
            <a href="#s3">a jump to section three</a>. Café, naïve, 日本語.</p>
            <p><img src="data:image/png;base64,\(png)" alt="Inline picture"></p>
            <table><tr><th>Lamp</th><th>Hours</th></tr><tr><td>HTMLWORD-lamp</td><td>12</td></tr></table>
            \(remoteBody)
            \(sections)
            <p>HTMLWORD-closing.</p>
            </body></html>
            """
    }

    static let htmlHeadings: [(String, Int)] = [
        ("Keeper's Manual", 1),
        ("Section 1: Lighthouse Duties", 2), ("Subsection 1.1 Logbook", 3),
        ("Section 2: Lighthouse Duties", 2), ("Subsection 2.1 Logbook", 3),
        ("Section 3: Lighthouse Duties", 2), ("Subsection 3.1 Logbook", 3),
    ]

    /// Hard-wrapped prose at 70 columns, a verse with short lines, and `paragraphs` paragraphs.
    static func plainText(paragraphs: Int = 12) -> String {
        var out = "THE PLAIN TEXT\n\nTXTWORD-verse first line\nsecond short line\nthird short line\n\n"
        for index in 1...paragraphs {
            let words = "TXTWORD-\(index) " + filler(4)
            out += wrap(words, column: 70) + "\n\n"
        }
        return out + "TXTWORD-end.\n"
    }

    static func wrap(_ text: String, column: Int) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.count + word.count + 1 > column, !line.isEmpty { lines.append(line); line = "" }
            line += line.isEmpty ? String(word) : " " + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}

/// A staging directory like the import flow's, with the original in it.
nonisolated final class F6Workspace {
    let directory: URL
    let original: URL
    let format: ImportFormat

    init(data: Data, extension ext: String, format: ImportFormat) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("F6ConverterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        original = directory.appendingPathComponent("original.\(ext)")
        try data.write(to: original)
        self.format = format
    }

    init(copying source: URL, format: ImportFormat) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("F6ConverterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        original = directory.appendingPathComponent("original.\(source.pathExtension)")
        try FileManager.default.copyItem(at: source, to: original)
        self.format = format
    }

    convenience init(text: String, extension ext: String, format: ImportFormat) throws {
        try self.init(data: Data(text.utf8), extension: ext, format: format)
    }

    func input(textSize: ConversionTextSize = .medium, fileName: String? = nil) -> ConversionInput {
        ConversionInput(original: original, format: format, fileName: fileName ?? original.lastPathComponent, directory: directory,
                        outputFileName: "Document.pdf", options: ConversionOptions(textSize: textSize))
    }

    var contents: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

nonisolated enum F6Check {
    /// Writes PNGs of the given pages to build/f6-pages/<name>-p<N>.png.
    static func savePages(_ document: PDFDocument, name: String, pages: [Int]) {
        try? FileManager.default.createDirectory(at: F6Fixtures.pagesDirectory, withIntermediateDirectories: true)
        for index in pages where index >= 0 && index < document.pageCount {
            let url = F6Fixtures.pagesDirectory.appendingPathComponent("\(name)-p\(index + 1).png")
            try? EPUBTestPDF.png(document, page: index, width: 700)?.write(to: url)
        }
    }

    /// The outline as (title, level, page).
    static func outline(_ url: URL) async -> [(title: String, level: Int, page: Int?)] {
        await ReaderDocumentLoader.outlineEntries(at: url).map { ($0.title, $0.level, $0.pageIndex) }
    }

    static func trace(_ tag: String) -> @Sendable (String) -> Void {
        { print(String(format: "[%.3f] %@ trace: %@", CACurrentMediaTime(), tag, $0)) }
    }
}
