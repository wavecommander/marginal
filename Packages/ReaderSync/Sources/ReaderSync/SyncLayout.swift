import CryptoKit
import Foundation
import ReaderBackup

/// Where sync's objects live, relative to the account's folder (beside `Backups/` and `PDFs/`):
///
///     Sync/v1/books/<book key>              the book's head: one small encrypted object
///     Sync/v1/blobs/<blob name>             immutable encrypted content, named by its hash
///     Sync/v1/history/<book key>/<version>  earlier heads (kept 30 days by housekeeping)
///     PDFs/<keyed hash>.ttenc               the PDF, shared with snapshot backups
///
/// Book keys and blob names are 64 lower-case hex digits (`SyncKeys`); a version is a decimal
/// integer without leading zeros. PDF names are `EncryptedBackupDestination.pdfObjectName`.
public enum SyncLayout {
    /// `Sync/v1/`
    public static let root = "Sync/v1/"
    /// `Sync/v1/books/`: list this prefix for every head and its ETag in one call.
    public static let headsPrefix = root + "books/"
    /// `Sync/v1/blobs/`
    public static let blobsPrefix = root + "blobs/"
    /// `Sync/v1/history/`
    public static let historyPrefix = root + "history/"
    /// `PDFs/`
    public static let pdfsPrefix = BackupBlobFolder.pdfs.rawValue + "/"

    /// `Sync/v1/books/<book key>`
    public static func headKey(bookKey: String) throws -> String {
        headsPrefix + (try validName(bookKey))
    }

    /// `Sync/v1/blobs/<blob name>`
    public static func blobKey(name: String) throws -> String {
        blobsPrefix + (try validName(name))
    }

    /// `Sync/v1/history/<book key>/`
    public static func historyPrefix(bookKey: String) throws -> String {
        historyPrefix + (try validName(bookKey)) + "/"
    }

    /// `Sync/v1/history/<book key>/<version>`
    public static func historyKey(bookKey: String, version: Int) throws -> String {
        guard version >= 1 else { throw SyncError.invalidName(String(version)) }
        return try historyPrefix(bookKey: bookKey) + String(version)
    }

    /// The book key in a head's key (`Sync/v1/books/<book key>`), or `nil` for any other key.
    public static func bookKey(fromHeadKey key: String) -> String? {
        guard key.hasPrefix(headsPrefix) else { return nil }
        let name = String(key.dropFirst(headsPrefix.count))
        return isValidName(name) ? name : nil
    }

    /// The version in a history object's key under `bookKey`, or `nil` for any other key.
    public static func version(fromHistoryKey key: String, bookKey: String) -> Int? {
        guard let prefix = try? historyPrefix(bookKey: bookKey), key.hasPrefix(prefix) else { return nil }
        let text = key.dropFirst(prefix.count)
        guard !text.isEmpty, text.utf8.count <= 18, text.allSatisfy({ $0.isASCII && $0.isNumber }), text.first != "0",
              let version = Int(text) else { return nil }
        return version
    }

    /// `PDFs/<keyed hash>.ttenc` for the PDF with this SHA-256 under `key`.
    public static func pdfKey(sha256: String, key: BackupEncryptionKey) throws -> String {
        do {
            return pdfsPrefix + (try EncryptedBackupDestination.pdfObjectName(sha256: sha256, key: key))
        } catch {
            throw SyncError.invalidName(sha256)
        }
    }

    /// `true` for 64 lower-case hex digits.
    public static func isValidName(_ name: String) -> Bool {
        ContentHash.isValidSHA256(name)
    }

    // MARK: Internals

    static func validName(_ name: String) throws -> String {
        guard isValidName(name) else { throw SyncError.invalidName(name) }
        return name
    }

    /// The SHA-256 lower-cased, if it is 64 hex digits.
    static func validSHA256(_ sha256: String) throws -> String {
        let lower = sha256.lowercased()
        guard ContentHash.isValidSHA256(lower) else { throw SyncError.invalidName(sha256) }
        return lower
    }

    /// `hex(HMAC-SHA256(key, text))`
    static func keyedName(_ text: String, key: SymmetricKey) -> String {
        hex(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key))
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `text` cut at a character boundary to at most `limit` UTF-8 bytes.
    static func cut(_ text: String, toUTF8Bytes limit: Int) -> String {
        var result = ""
        var bytes = 0
        for character in text {
            let count = character.utf8.count
            guard bytes + count <= limit else { break }
            result.append(character)
            bytes += count
        }
        return result
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func bytes(fromBase64URL text: String) -> [UInt8]? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64).map { [UInt8]($0) }
    }
}
