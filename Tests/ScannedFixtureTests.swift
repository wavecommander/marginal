import Foundation
import PDFKit
import Testing

/// `Fixtures/out/scanned.pdf` as iOS PDFKit sees it (S0): a typed cover with a text layer, then
/// 29 pages that are pictures of text with none. The generator checks the same on macOS; this
/// checks it on the platform the scanned-book packages run on.
@MainActor
struct ScannedFixtureTests {
    static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out/scanned.pdf")
    static let phrase = "The quiet heron measures tidewater."

    @Test func coverHasTextAndScannedPagesHaveNone() throws {
        let document = try #require(PDFDocument(url: Self.url), "run scripts/fixtures.sh")
        #expect(document.pageCount == 30)
        let cover = document.page(at: 0)?.string ?? ""
        #expect(cover.contains("The Scanned Fixture Book"))
        for index in 1..<document.pageCount {
            let page = try #require(document.page(at: index))
            #expect((page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "page \(index + 1)")
            #expect(page.numberOfCharacters == 0, "page \(index + 1)")
        }
        #expect(document.findString(Self.phrase, withOptions: [.caseInsensitive]).isEmpty)
    }
}
