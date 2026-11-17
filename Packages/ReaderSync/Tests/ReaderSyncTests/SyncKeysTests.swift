import CryptoKit
import Foundation
import ReaderBackup
import Testing
@testable import ReaderSync

struct SyncKeysTests {
    static func hkdf(_ info: String) -> Data {
        // HKDF-SHA256(IKM = the key, salt = empty, info, L = 32), from the extract and expand steps.
        let prk = HMAC<SHA256>.authenticationCode(for: (0..<32).map { UInt8($0) },
                                                  using: SymmetricKey(data: [UInt8](repeating: 0, count: 32)))
        var block = Data(info.utf8)
        block.append(1)
        return Data(HMAC<SHA256>.authenticationCode(for: block, using: SymmetricKey(data: Data(prk))))
    }

    static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    @Test func subKeysAreHKDFWithVersionedSyncInfoStrings() {
        let keys = SyncKeys(key: sequentialKey)
        #expect(Self.bytes(keys.contentKey) == Self.hkdf("tactile-texts.sync.v1.content"))
        #expect(keys.content.withUnsafeBytes { Data($0) } == Self.hkdf("tactile-texts.sync.v1.content"))
        #expect(Self.bytes(keys.blobName) == Self.hkdf("tactile-texts.sync.v1.blob-name"))
        #expect(Self.bytes(keys.bookKey) == Self.hkdf("tactile-texts.sync.v1.book-key"))
        #expect(Self.bytes(keys.deviceLabel) == Self.hkdf("tactile-texts.sync.v1.device-label"))
        let all = [Self.bytes(keys.contentKey), Self.bytes(keys.blobName), Self.bytes(keys.bookKey), Self.bytes(keys.deviceLabel),
                   Self.hkdf("tactile-texts.backup.v1.content"), Self.hkdf("tactile-texts.backup.v1.pdf-name")]
        #expect(Set(all).count == all.count)
    }

    @Test func namesAreKeyedHashesOfTheLowerCaseHex() throws {
        let keys = SyncKeys(key: sequentialKey)
        let hash = sha256(Sample.pdf)
        let bookKey = try keys.bookKey(pdfSHA256: hash)
        #expect(bookKey == SyncLayout.hex(HMAC<SHA256>.authenticationCode(for: Data(hash.utf8),
                                                                          using: SymmetricKey(data: Self.hkdf("tactile-texts.sync.v1.book-key")))))
        #expect(try keys.bookKey(pdfSHA256: hash.uppercased()) == bookKey)
        #expect(SyncLayout.isValidName(bookKey))
        #expect(!bookKey.contains(hash.prefix(16)))
        let blobName = try keys.blobName(sha256: hash)
        #expect(blobName != bookKey, "book keys and blob names are independent")
        let other = SyncKeys(key: BackupEncryptionKey.generate())
        #expect(try other.bookKey(pdfSHA256: hash) != bookKey)
        #expect(try other.blobName(sha256: hash) != blobName)
        #expect(throws: SyncError.invalidName("abc")) { try keys.bookKey(pdfSHA256: "abc") }
        #expect(throws: SyncError.invalidName(String(repeating: "g", count: 64))) {
            try keys.blobName(sha256: String(repeating: "g", count: 64))
        }
    }

    @Test func layoutIsExactly() throws {
        let k = String(repeating: "ab", count: 32)
        #expect(try SyncLayout.headKey(bookKey: k) == "Sync/v1/books/\(k)")
        #expect(try SyncLayout.blobKey(name: k) == "Sync/v1/blobs/\(k)")
        #expect(try SyncLayout.historyKey(bookKey: k, version: 12) == "Sync/v1/history/\(k)/12")
        #expect(SyncLayout.bookKey(fromHeadKey: "Sync/v1/books/\(k)") == k)
        #expect(SyncLayout.bookKey(fromHeadKey: "Sync/v1/books/\(k)/x") == nil)
        #expect(SyncLayout.bookKey(fromHeadKey: "Sync/v1/blobs/\(k)") == nil)
        #expect(SyncLayout.version(fromHistoryKey: "Sync/v1/history/\(k)/12", bookKey: k) == 12)
        for bad in ["Sync/v1/history/\(k)/012", "Sync/v1/history/\(k)/", "Sync/v1/history/\(k)/1a", "Sync/v1/history/\(k)/-1"] {
            #expect(SyncLayout.version(fromHistoryKey: bad, bookKey: k) == nil)
        }
        #expect(throws: SyncError.self) { try SyncLayout.historyKey(bookKey: k, version: 0) }
        #expect(throws: SyncError.invalidName("../x")) { try SyncLayout.headKey(bookKey: "../x") }
        let pdfKey = try SyncLayout.pdfKey(sha256: sha256(Sample.pdf), key: sequentialKey)
        #expect(pdfKey == "PDFs/" + (try EncryptedBackupDestination.pdfObjectName(sha256: sha256(Sample.pdf), key: sequentialKey)))
    }

    @Test func deviceLabelsRoundTripHideTheLengthAndNeedTheKey() throws {
        let keys = SyncKeys(key: sequentialKey)
        let short = keys.sealDeviceLabel("Ben’s iPad")
        let long = keys.sealDeviceLabel(String(repeating: "é", count: 40))
        #expect(short.count == 123 && long.count == 123)
        #expect(keys.openDeviceLabel(short) == "Ben’s iPad")
        #expect(keys.openDeviceLabel(long) == String(repeating: "é", count: 32), "cut at a character boundary to 64 bytes")
        #expect(keys.sealDeviceLabel("Ben’s iPad") != short, "a fresh nonce each time")
        #expect(SyncKeys(key: BackupEncryptionKey.generate()).openDeviceLabel(short) == nil)
        var tampered = Array(short)
        tampered[40] = tampered[40] == "A" ? "B" : "A"
        #expect(keys.openDeviceLabel(String(tampered)) == nil)
        #expect(keys.openDeviceLabel("not a label") == nil)
    }

    @Test func nothingDescribesKeyMaterial() {
        let keys = SyncKeys(key: sequentialKey)
        let store = EncryptedSyncStore(store: InMemorySyncObjectStore(), key: sequentialKey)
        for text in [String(describing: keys), String(reflecting: keys), String(describing: store), String(reflecting: store)] {
            #expect(text.contains("redacted"))
        }
        var dumped = ""
        dump(keys, to: &dumped)
        dump(store, to: &dumped)
        #expect(!dumped.contains("SymmetricKey"))
        #expect(!dumped.contains("BackupEncryptionKey("), "not even the redacted master")
    }
}
