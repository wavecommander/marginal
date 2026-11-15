import Foundation
import Testing
import ReaderCore
@testable import ReaderBackup

struct RestorePlanTests {
    static let date = Date(timeIntervalSinceReferenceDate: 784_000_000)

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
    static func hash(_ c: Character) -> String { String(repeating: c, count: 64) }

    static func book(_ n: Int, fingerprint: String) -> Book {
        Book(id: id(n), title: "Book \(n)", fingerprint: fingerprint, fileName: "\(n).pdf", pageCount: 10, fileSize: 100, addedAt: date)
    }

    static func entry(_ n: Int, fingerprint: String, sha: String, embedded: Bool = false) -> BackupManifest.BookEntry {
        .init(book: book(n, fingerprint: fingerprint), pdf: .init(sha256: sha, size: 100, embedded: embedded),
              counts: .init(notes: n), lastModifiedAt: date, files: [])
    }

    static func local(_ n: Int, fingerprint: String, sha: String?, hasPDF: Bool = true) -> LocalBookSummary {
        LocalBookSummary(book: book(n, fingerprint: fingerprint), hasPDF: hasPDF, sha256: sha, counts: .init(notes: 1),
                         lastModifiedAt: date.addingTimeInterval(Double(n)))
    }

    func plan(_ entries: [BackupManifest.BookEntry], _ library: [LocalBookSummary], destination: Set<String> = []) -> RestorePlan {
        let manifest = BackupManifest(createdAt: Self.date, appVersion: "1", appBuild: "1", deviceName: "iPad", includesPDFs: false, books: entries)
        return RestorePlan(manifest: manifest, localLibrary: library, destinationPDFHashes: destination)
    }

    @Test func newAndExistingBooksAreTicked() {
        let result = plan([Self.entry(1, fingerprint: "f1", sha: Self.hash("a")),
                           Self.entry(2, fingerprint: "f2", sha: Self.hash("b"))],
                          [Self.local(2, fingerprint: "f2", sha: nil, hasPDF: false)])
        #expect(result.items.map(\.id) == [Self.id(1), Self.id(2)])
        #expect(result.items[0].status == .new)
        #expect(result.items[0].isSelectedByDefault)
        #expect(result.items[0].replacedBookIDs.isEmpty)
        #expect(result.items[1].status == .inLibrary)
        #expect(result.items[1].isSelectedByDefault)
        #expect(result.items[1].replacedBookIDs == [Self.id(2)])
        #expect(result.items[1].localMatches.map(\.counts) == [.init(notes: 1)])
    }

    @Test func newBooksDefaultToRestoreAndExistingOnesToMerge() {
        let result = plan([Self.entry(1, fingerprint: "f1", sha: Self.hash("a")),
                           Self.entry(2, fingerprint: "f2", sha: Self.hash("b")),
                           Self.entry(3, fingerprint: "f3", sha: Self.hash("c"))],
                          [Self.local(2, fingerprint: "f2", sha: nil),
                           Self.local(9, fingerprint: "f3", sha: nil)])
        #expect(result.items.map(\.defaultAction) == [.restore, .merge, .merge])
        // Every book is ticked: existing ones are merged unless the reader chooses otherwise.
        #expect(result.items.map(\.isSelectedByDefault) == [true, true, true])
    }

    @Test func aSeparatelyConvertedCopyIsLeftAloneAndCanOnlyBeReplaced() {
        func converted(_ entry: BackupManifest.BookEntry) -> BackupManifest.BookEntry {
            var entry = entry
            entry.book.sourceFormat = .epub
            entry.book.originalFileName = "Book.epub"
            return entry
        }
        let result = plan([converted(Self.entry(1, fingerprint: "f1", sha: Self.hash("a"))),   // same PDF here
                           converted(Self.entry(2, fingerprint: "f2", sha: Self.hash("b"))),   // another PDF here
                           converted(Self.entry(3, fingerprint: "f3", sha: Self.hash("c"))),   // this iPad's hash unknown
                           converted(Self.entry(4, fingerprint: "f4", sha: Self.hash("d"))),   // not in the Library
                           Self.entry(5, fingerprint: "f5", sha: Self.hash("e"))],             // a PDF book, other bytes
                          [Self.local(1, fingerprint: "f1", sha: Self.hash("A")),
                           Self.local(2, fingerprint: "f2", sha: Self.hash("9")),
                           Self.local(3, fingerprint: "f3", sha: nil, hasPDF: false),
                           Self.local(5, fingerprint: "f5", sha: Self.hash("9"))])
        #expect(result.items.map(\.hasDifferentConversion) == [false, true, false, false, false])
        #expect(result.items.map(\.isSelectedByDefault) == [true, false, true, true, true])
        #expect(result.items.map(\.defaultAction) == [.merge, .replace, .merge, .restore, .merge])
    }

    @Test func restoreActionCodesAsItsName() throws {
        #expect(RestoreAction.allCases == [.restore, .merge, .replace])
        let data = try JSONEncoder().encode(RestoreAction.allCases)
        #expect(String(decoding: data, as: UTF8.self) == #"["restore","merge","replace"]"#)
        #expect(try JSONDecoder().decode([RestoreAction].self, from: data) == RestoreAction.allCases)
    }

    @Test func matchesByIDOrFingerprintAndCollectsEveryMatch() {
        let result = plan([Self.entry(1, fingerprint: "f1", sha: Self.hash("a"))],
                          [Self.local(7, fingerprint: "other", sha: nil),
                           Self.local(8, fingerprint: "f1", sha: nil),     // same fingerprint, different ID
                           Self.local(1, fingerprint: "changed", sha: nil), // same ID, different fingerprint
                           Self.local(9, fingerprint: "f9", sha: nil)])
        #expect(result.items[0].status == .inLibrary)
        #expect(result.items[0].replacedBookIDs == [Self.id(8), Self.id(1)])
    }

    @Test func pdfFromTheArchiveComesFirst() {
        let sha = Self.hash("a")
        let result = plan([Self.entry(1, fingerprint: "f1", sha: sha, embedded: true)],
                          [Self.local(2, fingerprint: "f1", sha: sha)], destination: [sha])
        #expect(result.items[0].pdfSource == .embedded)
    }

    @Test func thenFromTheDestination() {
        let sha = Self.hash("a")
        let result = plan([Self.entry(1, fingerprint: "f1", sha: sha)],
                          [Self.local(2, fingerprint: "f1", sha: sha)], destination: [sha.uppercased()])
        #expect(result.items[0].pdfSource == .destination)
    }

    @Test func thenFromALocalBookWithTheSameHash() {
        let sha = Self.hash("a")
        // A local book with an unknown hash but the same fingerprint comes after a hash match.
        let result = plan([Self.entry(1, fingerprint: "f1", sha: sha)],
                          [Self.local(3, fingerprint: "f1", sha: nil),
                           Self.local(4, fingerprint: "unrelated", sha: sha.uppercased())],
                          destination: [Self.hash("b")])
        #expect(result.items[0].pdfSource == .localBook(Self.id(4)))
        #expect(result.items[0].status == .inLibrary, "the fingerprint match is replaced")
        #expect(result.items[0].replacedBookIDs == [Self.id(3)])
    }

    @Test func orALocalBookWithTheSameFingerprintWhenItsHashIsUnknown() {
        let result = plan([Self.entry(1, fingerprint: "f1", sha: Self.hash("a"))],
                          [Self.local(3, fingerprint: "f1", sha: nil)])
        #expect(result.items[0].pdfSource == .localBook(Self.id(3)))
    }

    @Test func otherwiseMissing() {
        let sha = Self.hash("a")
        let cases: [[LocalBookSummary]] = [
            [],
            [Self.local(3, fingerprint: "f1", sha: sha, hasPDF: false)],        // same hash, PDF absent
            [Self.local(3, fingerprint: "f1", sha: nil, hasPDF: false)],        // same fingerprint, PDF absent
            [Self.local(3, fingerprint: "f1", sha: Self.hash("c"))],            // same fingerprint, known different hash
            [Self.local(3, fingerprint: "other", sha: nil)],                    // unknown hash, other fingerprint
        ]
        for library in cases {
            let result = plan([Self.entry(1, fingerprint: "f1", sha: sha)], library, destination: [Self.hash("b")])
            #expect(result.items[0].pdfSource == .missing, "\(library.map(\.book.fingerprint))")
        }
    }
}
