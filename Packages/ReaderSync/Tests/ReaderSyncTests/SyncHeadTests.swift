import CoreGraphics
import Foundation
import ReaderBackup
import ReaderCore
import Testing
@testable import ReaderSync

struct SyncHeadTests {
    @Test func aHeadRoundTripsThroughItsJSON() throws {
        var head = Sample.head(version: 7, previous: 6, deletedAt: Sample.date.addingTimeInterval(60))
        head.book.sourceFormat = "epub"
        head.book.originalFileName = "Middlemarch.epub"
        head.book.converterVersion = 3
        head.references.cover = digest("cover")
        head.references.conversion = digest("{\"converter\":3}")
        let data = try head.encoded()
        #expect(try SyncHead.decode(data, key: "k") == head)
        #expect(head.isDeleted)
        #expect(head.book.importFormat == .epub)
        // Sorted keys, no whitespace: the same head always encodes to the same bytes.
        #expect(try head.encoded() == data)
        #expect(!data.contains(UInt8(ascii: "\n")))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("{\"book\":{"))
        #expect(text.contains("\"writeID\":\"\(head.writeID)\""))
    }

    @Test func unknownKeysAreIgnoredAndAbsentOptionalsAreNil() throws {
        let head = Sample.head()
        var object = try #require(try JSONSerialization.jsonObject(with: head.encoded()) as? [String: Any])
        object["futureField"] = ["nested": [1, 2, 3]]
        var book = try #require(object["book"] as? [String: Any])
        book["seriesName"] = "From a newer app"
        book["sourceFormat"] = "holographicScroll"
        object["book"] = book
        var references = try #require(object["references"] as? [String: Any])
        references["audioNotes"] = [["sha256": "x"]]
        object["references"] = references
        let decoded = try SyncHead.decode(JSONSerialization.data(withJSONObject: object), key: "k")
        var expected = head
        expected.book.sourceFormat = "holographicScroll"
        #expect(decoded == expected)
        #expect(decoded.book.importFormat == nil, "a format this version does not know reads as no format, and is kept")

        object.removeValue(forKey: "deletedAt")
        object.removeValue(forKey: "previousVersion")
        let minimal = try SyncHead.decode(JSONSerialization.data(withJSONObject: object), key: "k")
        #expect(minimal.deletedAt == nil && minimal.previousVersion == nil)
    }

    @Test func aNewerFormatIsReportedBeforeAnythingElse() throws {
        let newer = Data("{\"formatVersion\":2,\"everythingElse\":\"different\"}".utf8)
        #expect(throws: SyncError.newerFormatVersion(2)) { try SyncHead.decode(newer, key: "k") }
        #expect(throws: SyncError.objectDamaged(key: "k")) { try SyncHead.decode(Data("{\"formatVersion\":1}".utf8), key: "k") }
        #expect(throws: SyncError.objectDamaged(key: "k")) { try SyncHead.decode(Data("not json".utf8), key: "k") }
    }

    @Test func malformedHeadsAreDamage() throws {
        var heads: [SyncHead] = []
        var head = Sample.head(version: 3, previous: 3); heads.append(head)
        head = Sample.head(version: 0); heads.append(head)
        head = Sample.head(writeID: "not-hex"); heads.append(head)
        head = Sample.head(); head.references.pageInk.append(head.references.pageInk[0]); heads.append(head)
        head = Sample.head(); head.references.noteInk.append(head.references.noteInk[0]); heads.append(head)
        head = Sample.head(); head.references.records.sha256 = "zz"; heads.append(head)
        head = Sample.head(); head.references.pageInk[0].pageIndex = -1; heads.append(head)
        for head in heads {
            #expect(!head.isWellFormed)
            #expect(throws: SyncError.objectDamaged(key: "k")) { try SyncHead.decode(try head.encoded(), key: "k") }
        }
        #expect(Sample.head(version: 4, previous: 2).isWellFormed, "a version may follow any lower one")
    }

    @Test func writeIDsAreFreshHex() {
        let ids = (0..<100).map { _ in SyncHead.makeWriteID() }
        #expect(Set(ids).count == 100)
        #expect(ids.allSatisfy(SyncHead.isValidWriteID))
    }

    @Test func theVersionRules() {
        typealias Rules = SyncVersionRules
        // Same format, same level: read and push.
        #expect(Rules.access(formatVersion: 1, writerLevel: 1, appFormatVersion: 1, appLevel: 1) == .readAndPush)
        // An older app's head: read and push over it.
        #expect(Rules.access(formatVersion: 1, writerLevel: 1, appFormatVersion: 1, appLevel: 3) == .readAndPush)
        // A newer app's head: pull, but do not push that book.
        #expect(Rules.access(formatVersion: 1, writerLevel: 4, appFormatVersion: 1, appLevel: 3) == .readOnly(requiredLevel: 4))
        #expect(Rules.mayRead(formatVersion: 1, appFormatVersion: 1))
        #expect(!Rules.mayPush(formatVersion: 1, writerLevel: 4, appFormatVersion: 1, appLevel: 3))
        #expect(Rules.mayPush(formatVersion: 1, writerLevel: 3, appFormatVersion: 1, appLevel: 3))
        // A newer format: stop sync for the account, whatever the level.
        #expect(Rules.access(formatVersion: 2, writerLevel: 1, appFormatVersion: 1, appLevel: 9) == .formatTooNew(formatVersion: 2))
        #expect(Rules.stopsSync(formatVersion: 2, appFormatVersion: 1))
        #expect(!Rules.mayRead(formatVersion: 2, appFormatVersion: 1))
        #expect(!Rules.mayPush(formatVersion: 2, writerLevel: 1, appFormatVersion: 1, appLevel: 9))
        // An older format is read.
        #expect(Rules.access(formatVersion: 1, writerLevel: 1, appFormatVersion: 2, appLevel: 2) == .readAndPush)
        // This app's own constants, and a head's own access.
        #expect(SyncFormat.formatVersion == 1 && SyncFormat.writerLevel == 1)
        var head = Sample.head()
        #expect(head.access() == .readAndPush)
        head.writerLevel = SyncFormat.writerLevel + 1
        #expect(head.access() == .readOnly(requiredLevel: SyncFormat.writerLevel + 1))
        #expect(head.access(appLevel: SyncFormat.writerLevel + 1) == .readAndPush)
    }

    @Test func theRecordsBlobIsTheBookArchiveInTheBackupCoding() throws {
        let bookID = UUID()
        let archive = BookArchive(book: Book(id: bookID, title: "T", fingerprint: "f", fileName: "T.pdf", pageCount: 3, fileSize: 9,
                                             addedAt: Sample.date),
                                  notes: [Note(bookID: bookID, target: .page(1), text: "n", createdAt: Sample.date)],
                                  highlights: [Highlight(bookID: bookID, pageIndex: 0, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)],
                                                         color: .blue, text: "h", createdAt: Sample.date)])
        let data = try SyncRecords.encode(archive)
        #expect(data == (try BackupCoding.makeEncoder().encode(archive)))
        #expect(try SyncRecords.decode(data, key: "r") == archive)
        var stray = archive
        stray.notes[0].bookID = UUID()
        #expect(throws: SyncError.objectDamaged(key: "r")) { try SyncRecords.decode(try SyncRecords.encode(stray), key: "r") }
        #expect(throws: SyncError.objectDamaged(key: "r")) { try SyncRecords.decode(Data("[]".utf8), key: "r") }
        #expect(SyncReferences(records: digest("r"), pdf: digest("p"), pageInk: [SyncPageInkReference(pageIndex: 1, content: digest("x"))],
                               noteInk: [SyncNoteInkReference(noteID: UUID(), content: digest("x"))], cover: digest("r")).blobs
                == [digest("r"), digest("x")])
    }
}
