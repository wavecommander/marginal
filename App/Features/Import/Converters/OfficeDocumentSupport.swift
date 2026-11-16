import CoreGraphics
import Foundation
import ReaderCore
import UIKit

// Shared by the Office-document and slide converters: how an Office or iWork file is handed to
// WebKit (which converts it to a web page itself, through QuickLook), what can be read cheaply
// from the file (title, page size, heading styles), and how the page size of a document WebKit
// shows in its PDF viewer is found. See docs/FORMAT_IMPORT_PLAN.md, F0 finding 6.

// MARK: - The file handed to WebKit

nonisolated enum OfficeSourceFile {
    /// The file to serve: the original, or for an iWork package directory (a `.pages` or `.key`
    /// saved as a folder) a ZIP of it written into `workspace`, which is what the single-file
    /// iWork format is. Fails for an empty file.
    @concurrent
    static func prepare(_ input: ConversionInput, workspace: URL) async throws -> URL {
        let values = try? input.original.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            let zipped = workspace.appendingPathComponent("package.\(input.original.pathExtension.lowercased())")
            do {
                try WebPackageZipper.zip(directory: input.original, to: zipped)
            } catch {
                throw ConversionError.failed(reason: "The document package could not be read (\(error.localizedDescription)).")
            }
            return zipped
        }
        guard let size = values?.fileSize else {
            throw ConversionError.failed(reason: "The file could not be read.")
        }
        guard size > 0 else { throw ConversionError.failed(reason: "The file is empty.") }
        return input.original
    }

    /// The reason for a load failure inside WebKit's converter (a damaged file, a password).
    static func loadFailureReason(_ error: WebRenderError, kind: String) -> String? {
        guard case let .loadFailed(detail) = error else { return nil }
        if detail.contains("OfficeImport") || detail.contains("QuickLook") || detail.contains("interrupted") {
            return "The file could not be opened as \(kind): it may be damaged, protected with a password, or not really \(kind) (\(detail))."
        }
        return nil
    }
}

/// Writes a directory into a ZIP file with stored (uncompressed) entries.
nonisolated enum WebPackageZipper {
    enum ZipError: Error { case cannotCreate, tooLarge }

    static func zip(directory: URL, to output: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { throw ZipError.cannotCreate }
        defer { try? handle.close() }
        var central = Data()
        var offset: UInt64 = 0
        var count = 0
        let root = directory.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: keys) else { throw ZipError.cannotCreate }
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
            var name = file.standardizedFileURL.path
            guard name.hasPrefix(root + "/") else { continue }
            name.removeFirst(root.count + 1)
            let data = try Data(contentsOf: file)
            guard offset + UInt64(data.count) < UInt64(UInt32.max), count < 65_000 else { throw ZipError.tooLarge }
            let crc = CRC32.checksum(data)
            let nameBytes = Data(name.utf8)
            var header = Data()
            header.le32(0x0403_4B50); header.le16(20); header.le16(0x0800); header.le16(0); header.le16(0); header.le16(0x21)
            header.le32(crc); header.le32(UInt32(data.count)); header.le32(UInt32(data.count))
            header.le16(UInt16(nameBytes.count)); header.le16(0)
            header.append(nameBytes)
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: data)
            central.le32(0x0201_4B50); central.le16(0x031E); central.le16(20); central.le16(0x0800); central.le16(0)
            central.le16(0); central.le16(0x21); central.le32(crc); central.le32(UInt32(data.count)); central.le32(UInt32(data.count))
            central.le16(UInt16(nameBytes.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(0o100644 << 16); central.le32(UInt32(offset))
            central.append(nameBytes)
            offset += UInt64(header.count + data.count)
            count += 1
        }
        var end = Data()
        end.le32(0x0605_4B50); end.le16(0); end.le16(0); end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(central.count)); end.le32(UInt32(offset)); end.le16(0)
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end)
    }

    nonisolated enum CRC32 {
        static let table: [UInt32] = (0..<256).map { index in
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
}

nonisolated private extension Data {
    mutating func le16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}

// MARK: - What the file says about itself

/// The page size and margins in points.
nonisolated struct OfficePageGeometry: Sendable, Equatable {
    var size: CGSize
    var margins: UIEdgeInsets

    static let letter = CGSize(width: 612, height: 792)
    static let a4 = CGSize(width: 595, height: 842)

    /// The paper for a document that does not say: US Letter in the regions that use it, A4
    /// everywhere else (the rule word processors use for a new document). 1 inch margins.
    static func regionalDefault(region: String? = Locale.current.region?.identifier) -> OfficePageGeometry {
        let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "PR", "GT", "CR", "PA", "DO", "SV", "NI", "HN", "BZ"]
        let size = letterRegions.contains(region ?? "US") ? letter : a4
        return OfficePageGeometry(size: size, margins: UIEdgeInsets(top: 72, left: 72, bottom: 72, right: 72))
    }

    /// Margins clamped so at least half the page is left for text.
    func sanitized() -> OfficePageGeometry {
        let size = CGSize(width: min(max(size.width, 144), 5000), height: min(max(size.height, 144), 5000))
        func clamp(_ value: CGFloat, _ extent: CGFloat) -> CGFloat { min(max(value, 0), extent / 4) }
        return OfficePageGeometry(size: size, margins: UIEdgeInsets(
            top: clamp(margins.top, size.height), left: clamp(margins.left, size.width),
            bottom: clamp(margins.bottom, size.height), right: clamp(margins.right, size.width)))
    }
}

/// Reads an Office Open XML file's title, page size and heading paragraphs straight from its ZIP
/// parts. Everything is optional: a part that is missing or does not parse gives `nil`.
nonisolated struct OfficeOpenXMLInfo: Sendable {
    var title: String?
    /// The first section's page size and margins (Word).
    var page: OfficePageGeometry?
    /// Paragraphs with a heading style or an outline level, in order (Word).
    var headings: [WebOrderedHeading] = []

    static func read(_ url: URL, word: Bool) -> OfficeOpenXMLInfo {
        guard let archive = try? ZIPArchive(url: url) else { return OfficeOpenXMLInfo() }
        func part(_ path: String) -> Data? { try? archive.data(at: path, maxSize: 64 << 20) }
        var info = OfficeOpenXMLInfo()
        if let core = part("docProps/core.xml") {
            let title = OfficeXMLScanner.firstText(of: "title", in: core)?.trimmingCharacters(in: .whitespacesAndNewlines)
            info.title = (title?.isEmpty ?? true) ? nil : title
        }
        guard word, let document = part("word/document.xml") else { return info }
        let styles = part("word/styles.xml").map(OfficeXMLScanner.headingStyles) ?? [:]
        let scanned = OfficeXMLScanner.wordDocument(document, headingStyles: styles)
        info.page = scanned.page
        info.headings = scanned.headings
        return info
    }
}

/// Small SAX passes over WordprocessingML. Element names are matched by local name.
nonisolated final class OfficeXMLScanner: NSObject, XMLParserDelegate {
    private enum Mode { case firstText(String), styles, document }
    private let mode: Mode
    private var stack: [String] = []
    // firstText
    private var text: String?
    private var capturing = false
    // styles
    private var styleID: String?
    private var styleName: String?
    private var styleOutline: Int?
    private var styleBasedOn: String?
    private var styleLevels: [String: Int] = [:]
    private var basedOn: [String: String] = [:]
    // document
    private var headingStyles: [String: Int] = [:]
    private var paragraphStyle: String?
    private var paragraphOutline: Int?
    private var paragraphText = ""
    private var inText = false
    private var headings: [WebOrderedHeading] = []
    private var page: OfficePageGeometry?
    private var pageSize: CGSize?
    private var pageMargins: UIEdgeInsets?
    private var paragraphDepth = 0

    private init(mode: Mode) { self.mode = mode }

    static func firstText(of element: String, in data: Data) -> String? {
        let scanner = OfficeXMLScanner(mode: .firstText(element))
        scanner.parse(data)
        return scanner.text
    }

    /// Paragraph style ID → heading level (1…6), from `outlineLvl` or a "heading N" name,
    /// following `basedOn`.
    static func headingStyles(_ data: Data) -> [String: Int] {
        let scanner = OfficeXMLScanner(mode: .styles)
        scanner.parse(data)
        var resolved = scanner.styleLevels
        for id in scanner.basedOn.keys where resolved[id] == nil {
            var next = scanner.basedOn[id]
            var hops = 0
            while let parent = next, hops < 10 {
                if let level = scanner.styleLevels[parent] { resolved[id] = level; break }
                next = scanner.basedOn[parent]
                hops += 1
            }
        }
        return resolved
    }

    static func wordDocument(_ data: Data, headingStyles: [String: Int]) -> (page: OfficePageGeometry?, headings: [WebOrderedHeading]) {
        let scanner = OfficeXMLScanner(mode: .document)
        scanner.headingStyles = headingStyles
        scanner.parse(data)
        return (scanner.page, scanner.headings)
    }

    private func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
    }

    private func attribute(_ attributes: [String: String], _ name: String) -> String? {
        attributes[name] ?? attributes.first { $0.key.hasSuffix(":" + name) }?.value
    }

    private func twips(_ attributes: [String: String], _ name: String) -> CGFloat? {
        attribute(attributes, name).flatMap(Double.init).map { CGFloat($0 / 20) }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        stack.append(elementName)
        switch mode {
        case let .firstText(name):
            if text == nil, elementName == name { capturing = true; text = "" }
        case .styles:
            switch elementName {
            case "style":
                styleID = attribute(attributes, "styleId"); styleName = nil; styleOutline = nil; styleBasedOn = nil
            case "name": styleName = attribute(attributes, "val")
            case "outlineLvl": styleOutline = attribute(attributes, "val").flatMap(Int.init)
            case "basedOn": styleBasedOn = attribute(attributes, "val")
            default: break
            }
        case .document:
            switch elementName {
            case "p":
                paragraphDepth += 1
                if paragraphDepth == 1 { paragraphStyle = nil; paragraphOutline = nil; paragraphText = "" }
            case "pStyle": if stack.dropLast().last == "pPr" { paragraphStyle = attribute(attributes, "val") }
            case "outlineLvl": if stack.dropLast().last == "pPr" { paragraphOutline = attribute(attributes, "val").flatMap(Int.init) }
            case "t": inText = true
            case "tab": if paragraphDepth > 0 { paragraphText += " " }
            case "pgSz" where page == nil:
                if let width = twips(attributes, "w"), let height = twips(attributes, "h") { pageSize = CGSize(width: width, height: height) }
            case "pgMar" where page == nil:
                pageMargins = UIEdgeInsets(top: twips(attributes, "top") ?? 72, left: twips(attributes, "left") ?? 72,
                                           bottom: twips(attributes, "bottom") ?? 72, right: twips(attributes, "right") ?? 72)
            default: break
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch mode {
        case .firstText: if capturing { text? += string }
        case .styles: break
        case .document: if inText, paragraphDepth > 0 { paragraphText += string }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
        switch mode {
        case let .firstText(name):
            if elementName == name { capturing = false }
        case .styles:
            if elementName == "style", let id = styleID {
                if let outline = styleOutline, (0...5).contains(outline) {
                    styleLevels[id] = outline + 1
                } else if let name = styleName?.lowercased(), name.hasPrefix("heading "),
                          let level = Int(name.dropFirst("heading ".count)), (1...6).contains(level) {
                    styleLevels[id] = level
                } else if let parent = styleBasedOn {
                    basedOn[id] = parent
                }
            }
        case .document:
            switch elementName {
            case "t": inText = false
            case "p":
                if paragraphDepth == 1 {
                    let level = paragraphOutline.flatMap { (0...5).contains($0) ? $0 + 1 : nil }
                        ?? paragraphStyle.flatMap { headingStyles[$0] }
                    let title = paragraphText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    if let level, !title.isEmpty, headings.count < 5000 {
                        headings.append(WebOrderedHeading(level: level, title: String(title.prefix(120))))
                    }
                }
                paragraphDepth = max(0, paragraphDepth - 1)
            case "sectPr" where page == nil:
                if let size = pageSize { page = OfficePageGeometry(size: size, margins: pageMargins ?? UIEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)) }
            default: break
            }
        }
    }
}

// MARK: - RTF

/// RTF is read with the system's RTF reader rather than WebKit's: WebKit's conversion sets type
/// at iOS text scaling (12 pt text became 15.6 px, a third too large on paper), while the reader
/// can be asked for the document's own sizes. It also gives the paper size, margins and title.
nonisolated enum RTFDocument {
    struct Converted: Sendable {
        var html: Data
        var page: OfficePageGeometry
        var title: String?
    }

    static func convert(_ url: URL) throws -> Converted {
        var attributes: NSDictionary?
        let string: NSAttributedString
        do {
            string = try NSAttributedString(url: url, options: [
                .documentType: NSAttributedString.DocumentType.rtf,
                .targetTextScaling: NSTextScalingType.standard.rawValue,
            ], documentAttributes: &attributes)
        } catch {
            throw ConversionError.failed(reason: "The RTF file could not be read: it may be damaged or not really RTF (\(error.localizedDescription)).")
        }
        guard !string.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.failed(reason: "The RTF file has no text in it.")
        }
        let html: Data
        do {
            html = try string.data(from: NSRange(location: 0, length: string.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        } catch {
            throw ConversionError.failed(reason: "The RTF file could not be converted (\(error.localizedDescription)).")
        }
        let attrs = attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
        let fallback = OfficePageGeometry.regionalDefault()
        let size = (attrs[.paperSize] as? NSValue)?.cgSizeValue ?? fallback.size
        let margins = (attrs[.paperMargin] as? NSValue)?.uiEdgeInsetsValue ?? fallback.margins
        let title = (attrs[NSAttributedString.DocumentAttributeKey(rawValue: "NSTitleDocumentAttribute")] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Converted(html: html, page: OfficePageGeometry(size: size, margins: margins).sanitized(),
                         title: (title?.isEmpty ?? true) ? nil : title)
    }
}

// MARK: - Documents WebKit shows as PDF

/// iWork files (and some others) are converted by WebKit into a PDF and shown in its PDF viewer,
/// which prints each page of that PDF at its own size (1 pt = 1 pt), clipped to the paper. The
/// PDF itself cannot be reached, so its page size is found by printing the first page onto a
/// large paper and reading the clip rectangle the viewer draws the page into.
nonisolated enum WebPluginPageProbe {
    static let probePaper = CGSize(width: 3000, height: 3000)

    /// The page size the printed probe page shows, or `nil` when no page rectangle is found.
    static func pageSize(inProbe url: URL) -> CGSize? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return nil }
        let paper = page.getBoxRect(.mediaBox)
        let state = ScanState(paper: paper)
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let info else { return }
            let state = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
            var values = [CGFloat](repeating: 0, count: 4)
            for index in (0..<4).reversed() { CGPDFScannerPopNumber(scanner, &values[index]) }
            state.pending = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        let clip: CGPDFOperatorCallback = { _, info in
            guard let info else { return }
            let state = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
            if state.clip == nil, let rect = state.pending, rect.width > 20, rect.height > 20,
               abs(rect.width - state.paper.width) > 1 || abs(rect.height - state.paper.height) > 1 {
                state.clip = rect
            }
            state.pending = nil
        }
        CGPDFOperatorTableSetCallback(table, "W", clip)
        CGPDFOperatorTableSetCallback(table, "W*", clip)
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let info else { return }
            let state = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
            var values = [CGFloat](repeating: 0, count: 6)
            for index in (0..<6).reversed() { CGPDFScannerPopNumber(scanner, &values[index]) }
            // The first transform after the clip: a quarter turn means the viewer rotated the
            // page to fit the paper.
            if state.clip != nil, state.rotated == nil { state.rotated = abs(values[0]) < 0.01 && abs(abs(values[1]) - 1) < 0.01 }
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        guard let clip = state.clip else { return nil }
        let size = state.rotated == true ? CGSize(width: clip.height, height: clip.width) : clip.size
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    private final class ScanState {
        let paper: CGRect
        var pending: CGRect?
        var clip: CGRect?
        var rotated: Bool?
        init(paper: CGRect) { self.paper = paper }
    }

    /// Prints the first page of the loaded document onto the probe paper and reads its size.
    @MainActor
    static func measure(_ renderer: WebPDFRenderer, workspace: URL) async throws -> CGSize? {
        let url = workspace.appendingPathComponent("probe-\(UUID().uuidString).pdf")
        renderer.setPage(size: probePaper, margins: .zero)
        _ = try await renderer.printPDF(to: url, pageLimit: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        return pageSize(inProbe: url)
    }
}
