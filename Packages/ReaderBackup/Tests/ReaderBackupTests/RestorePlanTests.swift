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

    @Test func newBooksAreTickedAndExistingOnesAreNot() {
        let result = plan([Self.entry(1, fingerprint: "f1", sha: Self.hash("a")),
                           Self.entry(2, fingerprint: "f2", sha: Self.hash("b"))],
                          [Self.local(2, fingerprint: "f2", sha: nil, hasPDF: false)])
        #expect(result.items.map(\.id) == [Self.id(1), Self.id(2)])
        #expect(result.items[0].status == .new)
        #expect(result.items[0].isSelectedByDefault)
        #expect(result.items[0].replacedBookIDs.isEmpty)
        #expect(result.items[1].status == .inLibrary)
        #expect(!result.items[1].isSelectedByDefault)
        #expect(result.items[1].replacedBookIDs == [Self.id(2)])
        #expect(result.items[1].localMatches.map(\.counts) == [.init(notes: 1)])
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
