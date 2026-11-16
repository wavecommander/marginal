import CryptoKit
import Foundation
import ReaderCore

/// Serves an EPUB's files to the web renderer straight from its ZIP archive, streaming each
/// entry in chunks and undoing font obfuscation on the way.
///
/// The archive is opened privately and used only on the scheme handler's serial queue (the
/// `WebResourceProvider` contract), which is what makes this `@unchecked Sendable`.
nonisolated final class EPUBArchiveResources: WebResourceProvider, @unchecked Sendable {
    /// Largest single resource served (a sanity cap; the ZIP reader enforces the archive limits).
    static let maxResourceSize: UInt64 = 256 << 20
    static let chunkSize = 256 << 10

    private let archive: ZIPArchive
    private let mediaTypes: [String: String]
    private let obfuscated: [String: EPUBFontObfuscation]
    private let idpfKey: [UInt8]?
    private let adobeKey: [UInt8]?
    private let lock = NSLock()
    private var htmlPaths: Set<String> = []

    init(url: URL, package: EPUBPackage) throws {
        archive = try ZIPArchive(url: url)
        mediaTypes = Dictionary(package.manifest.map { ($0.path, $0.mediaType) }, uniquingKeysWith: { first, _ in first })
        obfuscated = Dictionary(package.protection.obfuscatedResources.map { ($0.path, $0.algorithm) },
                                uniquingKeysWith: { first, _ in first })
        idpfKey = package.metadata.identifier.map(Self.idpfKey(identifier:))
        adobeKey = package.metadata.identifier.flatMap(Self.adobeKey(identifier:))
    }

    /// Serve `path` as `text/html` from now on (an XHTML file that is not well-formed XML).
    func serveAsHTML(_ path: String) {
        lock.withLock { _ = htmlPaths.insert(path) }
    }

    /// Obfuscated resources that cannot be served because the key could not be derived (an
    /// Adobe-obfuscated font in a book whose identifier is not a UUID). They are left out, so the
    /// text falls back to a system font.
    var unservableObfuscatedPaths: [String] {
        obfuscated.filter { key(for: $0.value) == nil }.map(\.key).sorted()
    }

    func resource(at path: String) throws -> WebResource? {
        guard let entry = archive.entry(at: path), !entry.isDirectory else { return nil }
        guard entry.uncompressedSize <= Self.maxResourceSize else {
            throw ZIPError.entryTooLarge(path: path, size: entry.uncompressedSize, limit: Self.maxResourceSize)
        }
        let asHTML = lock.withLock { htmlPaths.contains(path) }
        let declared = mediaTypes[path].map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let mimeType = asHTML ? "text/html"
            : WebResourcePath.mimeType(forPath: path) ?? (declared.isEmpty ? "application/octet-stream" : declared)
        let length = Int(entry.uncompressedSize)
        let archive = archive
        var transform: ((inout Data, Int) -> Void)?
        if let algorithm = obfuscated[path] {
            guard let key = key(for: algorithm) else { return nil }
            let span = algorithm == .idpf ? 1040 : 1024
            transform = { chunk, offset in Self.xor(&chunk, offset: offset, key: key, span: span) }
        }
        return WebResource(mimeType: mimeType, textEncodingName: WebResourcePath.defaultTextEncoding(forMIMEType: mimeType),
                           expectedLength: length) { body in
            var offset = 0
            try archive.read(entry, chunkSize: Self.chunkSize) { chunk in
                var bytes = chunk
                transform?(&bytes, offset)
                offset += chunk.count
                try body(bytes)
            }
        }
    }

    private func key(for algorithm: EPUBFontObfuscation) -> [UInt8]? {
        switch algorithm {
        case .idpf: idpfKey
        case .adobe: adobeKey
        }
    }

    // MARK: Font obfuscation

    /// IDPF: the SHA-1 of the unique identifier with all XML whitespace removed.
    static func idpfKey(identifier: String) -> [UInt8] {
        let stripped = identifier.unicodeScalars.filter { !["\u{20}", "\u{09}", "\u{0D}", "\u{0A}"].contains($0) }
        return Array(Insecure.SHA1.hash(data: Data(String(String.UnicodeScalarView(stripped)).utf8)))
    }

    /// Adobe: the 16 bytes of the book's UUID (`urn:uuid:…`), or `nil` when it is not a UUID.
    static func adobeKey(identifier: String) -> [UInt8]? {
        var text = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("urn:uuid:") { text.removeFirst("urn:uuid:".count) }
        let hex = text.filter { $0 != "-" && $0 != ":" }
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// XORs the bytes of `chunk` that fall within the first `span` bytes of the file (`offset` is
    /// the chunk's position in the file) with the repeating `key`.
    static func xor(_ chunk: inout Data, offset: Int, key: [UInt8], span: Int) {
        guard offset < span, !key.isEmpty else { return }
        let count = min(chunk.count, span - offset)
        chunk.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for index in 0..<count { bytes[index] ^= key[(offset + index) % key.count] }
        }
    }
}
