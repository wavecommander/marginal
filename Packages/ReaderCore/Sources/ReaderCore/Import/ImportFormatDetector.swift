import Foundation

/// A format the app recognises but cannot import, named so the app can say why.
public enum UnsupportedImportFormat: String, Codable, Sendable, CaseIterable, Hashable {
    /// MOBI, AZW, AZW3, KFX (and PalmDOC).
    case kindle
    case djvu
    /// A RAR archive (CBR comics).
    case comicRar
    /// Excel (.xlsx/.xls), Numbers, OpenDocument spreadsheets and CSV/TSV.
    case spreadsheet
    case fixedLayoutEPUB
    case protectedEPUB
}

/// What a file is, as far as importing goes.
public enum ImportDetection: Sendable, Hashable {
    case supported(ImportFormat)
    case unsupported(UnsupportedImportFormat)
    case unknown

    /// The importable format, or `nil`.
    public var supportedFormat: ImportFormat? {
        if case let .supported(format) = self { format } else { nil }
    }
}

/// Classifies a file for import: magic bytes first, the file name extension second. Reads only
/// the first few KB, plus — for ZIP archives — the central directory and a few small entries.
public enum ImportFormatDetector {
    /// How much of the file's start is read.
    static let headerLength = 8192

    /// What the file (or package directory) at `url` is. Throws only when it cannot be read;
    /// a malformed file is `.unknown` (or classified by its extension when that is decisive).
    public static func detect(fileAt url: URL, limits: ZIPArchive.Limits = .default) throws -> ImportDetection {
        let ext = url.pathExtension.lowercased()
        if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            return detectPackage(extension: ext)
        }
        let handle = try FileHandle(forReadingFrom: url)
        let header: [UInt8]
        do {
            defer { try? handle.close() }
            header = [UInt8](try handle.read(upToCount: headerLength) ?? Data())
        }
        guard !header.isEmpty else { return .unknown }

        switch magic(header, extension: ext) {
        case .pdf: return .supported(.pdf)
        case .rtf: return .supported(.rtf)
        case .image: return .supported(.image)
        case .webArchive: return .supported(.webArchive)
        case .rar: return .unsupported(.comicRar)
        case .djvu: return .unsupported(.djvu)
        case .mobi: return .unsupported(.kindle)
        case .ole:
            switch ext {
            case "doc", "dot": return .supported(.word)
            case "ppt", "pps", "pot": return .supported(.powerPoint)
            case "xls", "xlt": return .unsupported(.spreadsheet)
            default: return .unknown
            }
        case .zip:
            if let result = detectZIP(at: url, extension: ext, limits: limits) { return result }
            return byExtension(ext, header: header, allowText: false)
        case .none:
            return byExtension(ext, header: header, allowText: true)
        }
    }

    // MARK: Magic

    enum Magic: Equatable {
        case pdf, zip, ole, rtf, rar, djvu, mobi, webArchive, image, none
    }

    static func magic(_ bytes: [UInt8], extension ext: String) -> Magic {
        func starts(with prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<(offset + prefix.count)]) == prefix
        }
        func ascii(_ string: String) -> [UInt8] { Array(string.utf8) }

        if starts(with: ascii("%PDF-")) { return .pdf }
        if starts(with: [0x50, 0x4B, 0x03, 0x04]) || starts(with: [0x50, 0x4B, 0x05, 0x06])
            || starts(with: [0x50, 0x4B, 0x07, 0x08]) { return .zip }
        if starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return .ole }
        if starts(with: ascii("{\\rtf")) { return .rtf }
        if starts(with: ascii("Rar!") + [0x1A, 0x07]) { return .rar }
        if starts(with: ascii("AT&TFORM")) { return .djvu }
        if starts(with: ascii("BOOKMOBI"), at: 60) || starts(with: ascii("TEXtREAd"), at: 60) { return .mobi }
        if starts(with: ascii("bplist00")) {
            let mentionsMainResource = Data(bytes).range(of: Data("WebMainResource".utf8)) != nil
            if ext == "webarchive" || mentionsMainResource { return .webArchive }
        }
        if isImage(bytes, extension: ext) { return .image }
        // Like the app's PDF check: `%PDF-` anywhere in the first 1 KiB (leading junk is allowed).
        if Data(bytes.prefix(1024)).range(of: Data("%PDF-".utf8)) != nil { return .pdf }
        return .none
    }

    private static let heifBrands: Set<String> = [
        "heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1", "avif", "avis",
    ]

    private static func isImage(_ b: [UInt8], extension ext: String) -> Bool {
        func at(_ offset: Int, _ prefix: [UInt8]) -> Bool {
            b.count >= offset + prefix.count && Array(b[offset..<(offset + prefix.count)]) == prefix
        }
        if at(0, [0xFF, 0xD8, 0xFF]) { return true }                                          // JPEG
        if at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }            // PNG
        if at(0, Array("GIF87a".utf8)) || at(0, Array("GIF89a".utf8)) { return true }          // GIF
        if at(0, [0x49, 0x49, 0x2A, 0x00]) || at(0, [0x4D, 0x4D, 0x00, 0x2A]) { return true } // TIFF
        if at(0, Array("RIFF".utf8)) && at(8, Array("WEBP".utf8)) { return true }               // WebP
        if at(4, Array("ftyp".utf8)), b.count >= 12,                                            // HEIF / AVIF
           let brand = String(bytes: b[8..<12], encoding: .ascii), heifBrands.contains(brand) { return true }
        if at(0, Array("BM".utf8)), ext == "bmp" || ext == "dib" { return true }               // BMP
        return false
    }

    // MARK: Extension

    private static func byExtension(_ ext: String, header: [UInt8], allowText: Bool) -> ImportDetection {
        switch ext {
        case "mobi", "azw", "azw3", "azw4", "kfx", "prc": return .unsupported(.kindle)
        case "djvu", "djv": return .unsupported(.djvu)
        case "cbr", "rar": return .unsupported(.comicRar)
        case "xlsx", "xlsm", "xls", "numbers", "csv", "tsv", "ods": return .unsupported(.spreadsheet)
        default: break
        }
        guard allowText, looksLikeText(header) else { return .unknown }
        switch ext {
        case "txt", "text": return .supported(.plainText)
        case "md", "markdown", "mdown", "mkd": return .supported(.markdown)
        case "html", "htm", "xhtml": return .supported(.html)
        case "": return sniffsAsHTML(header) ? .supported(.html) : .unknown
        default: return .unknown
        }
    }

    private static func detectPackage(extension ext: String) -> ImportDetection {
        switch ext {
        case "pages": .supported(.pages)
        case "key": .supported(.keynote)
        case "numbers": .unsupported(.spreadsheet)
        default: .unknown
        }
    }

    // MARK: Text

    /// UTF-16 with a byte-order mark, UTF-16 by its pattern of zero bytes, or anything else
    /// without NUL bytes.
    static func looksLikeText(_ bytes: [UInt8]) -> Bool {
        if bytes.starts(with: [0xFE, 0xFF]) || bytes.starts(with: [0xFF, 0xFE]) { return true }
        guard bytes.contains(0) else { return true }
        // UTF-16 without a BOM: mostly-ASCII text has a zero in every other byte, never two together.
        let sample = Array(bytes.prefix(1024))
        guard sample.count >= 4 else { return false }
        let pairs = sample.count / 2
        var evenZeros = 0, oddZeros = 0
        for index in 0..<pairs {
            let (even, odd) = (sample[2 * index], sample[2 * index + 1])
            if even == 0, odd == 0 { return false }
            if even == 0 { evenZeros += 1 }
            if odd == 0 { oddZeros += 1 }
        }
        return max(evenZeros, oddZeros) * 10 >= pairs * 9 && min(evenZeros, oddZeros) == 0
    }

    private static func sniffsAsHTML(_ bytes: [UInt8]) -> Bool {
        guard let text = String(bytes: bytes.prefix(512), encoding: .utf8)?.lowercased() else { return false }
        let start = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        return start.hasPrefix("<!doctype html") || start.hasPrefix("<html")
    }

    // MARK: ZIP

    private static let comicImageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "webp", "tif", "tiff", "heic", "heif", "bmp", "avif",
    ]
    private static let comicMetadataExtensions: Set<String> = ["xml", "txt", "nfo", "sfv"]
    private static let comicMetadataNames: Set<String> = ["thumbs.db", "desktop.ini"]

    /// The verdict for a ZIP-based file, or `nil` when the archive's contents are not decisive.
    private static func detectZIP(at url: URL, extension ext: String, limits: ZIPArchive.Limits) -> ImportDetection? {
        guard let archive = try? ZIPArchive(url: url, limits: limits) else { return nil }

        // EPUB: a `mimetype` entry naming it (or an .epub with a container).
        let mimetype = archive.entry(at: "mimetype")
            .flatMap { try? archive.data(for: $0, maxSize: 256) }
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mimetype == "application/epub+zip" || (ext == "epub" && archive.contains(EPUBParser.containerPath)) {
            return epubVerdict(archive)
        }
        if mimetype?.hasPrefix("application/vnd.oasis.opendocument.spreadsheet") == true {
            return .unsupported(.spreadsheet)
        }

        // Office Open XML: [Content_Types].xml plus the part folder.
        if archive.contains("[Content_Types].xml") {
            if archive.entries.contains(where: { $0.path.hasPrefix("word/") }) { return .supported(.word) }
            if archive.entries.contains(where: { $0.path.hasPrefix("ppt/") }) { return .supported(.powerPoint) }
            if archive.entries.contains(where: { $0.path.hasPrefix("xl/") }) { return .unsupported(.spreadsheet) }
        }

        // iWork single-file documents are ZIPs; their extension is decisive.
        switch ext {
        case "pages": return .supported(.pages)
        case "key": return .supported(.keynote)
        case "numbers": return .unsupported(.spreadsheet)
        default: break
        }

        // Comics: every content entry is an image (metadata and Finder litter ignored).
        let content = archive.entries.filter { !$0.isDirectory && !isIgnoredComicEntry($0.path) }
        if !content.isEmpty, content.allSatisfy({ comicImageExtensions.contains(fileExtension($0.path)) }) {
            return .supported(.comicArchive)
        }
        return nil
    }

    private static func epubVerdict(_ archive: ZIPArchive) -> ImportDetection {
        do {
            let package = try EPUBParser.parse(archive: archive)
            if package.protection.isProtected { return .unsupported(.protectedEPUB) }
            if package.isFixedLayout { return .unsupported(.fixedLayoutEPUB) }
        } catch {
            // Unparseable: still report protection when META-INF shows it; otherwise leave
            // the error to the converter.
            if (try? EPUBParser.protection(in: archive))?.isProtected == true { return .unsupported(.protectedEPUB) }
        }
        return .supported(.epub)
    }

    static func isIgnoredComicEntry(_ path: String) -> Bool {
        if path.hasPrefix("__MACOSX/") { return true }
        let components = path.split(separator: "/")
        if components.contains(where: { $0.hasPrefix(".") }) { return true }
        guard let name = components.last?.lowercased() else { return true }
        return comicMetadataNames.contains(name) || comicMetadataExtensions.contains(fileExtension(name))
    }

    private static func fileExtension(_ path: String) -> String {
        guard let name = path.split(separator: "/").last, let dot = name.lastIndex(of: "."),
              dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}
