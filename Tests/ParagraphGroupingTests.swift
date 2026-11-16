import Foundation
import PDFKit
import Testing
@testable import TactileTexts

/// "Select All selects the paragraph": the pure paragraph grouping on synthetic layouts, and the
/// selection growth on the fixtures.
@Suite struct ParagraphGroupingTests {
    typealias Line = ParagraphGrouping.Line

    /// Body lines of 11 pt type (13 pt boxes) at a 15 pt pitch, 468 pt wide, from page y `top` down.
    private func body(_ count: Int, top: CGFloat, x: CGFloat = 72, width: CGFloat = 468,
                      indentFirst: CGFloat = 0, lastWidth: CGFloat? = nil, pitch: CGFloat = 15) -> [Line] {
        (0..<count).map { index in
            let indent = index == 0 ? indentFirst : 0
            let w = index == count - 1 ? (lastWidth ?? width) : width
            return Line(x + indent, top - CGFloat(index) * pitch, w - indent, 13)
        }
    }

    @Test func singleParagraph() {
        #expect(ParagraphGrouping.paragraphs(body(6, top: 700, lastWidth: 200)) == [0..<6])
    }

    @Test func paragraphsSeparatedBySpacing() {
        // 4 lines, a 9 pt paragraph gap (pitch 24), 3 lines, another gap, 5 lines.
        let lines = body(4, top: 700) + body(3, top: 700 - 3 * 15 - 24) + body(5, top: 700 - 5 * 15 - 48)
        #expect(ParagraphGrouping.paragraphs(lines) == [0..<4, 4..<7, 7..<12])
    }

    @Test func indentedFirstLinesWithoutSpacing() {
        let lines = body(4, top: 700, indentFirst: 18, lastWidth: 300)
            + body(3, top: 640, indentFirst: 18, lastWidth: 120)
            + body(2, top: 595, indentFirst: 18)
        #expect(ParagraphGrouping.paragraphs(lines) == [0..<4, 4..<7, 7..<9])
    }

    @Test func hyphenatedLineEndDoesNotStartAParagraphAtAnIndentedContinuation() {
        var lines = body(2, top: 700)
        lines[1].rect.origin.x += 12  // the last line starts to the right (ragged or centred)
        lines[1].rect.size.width -= 200
        #expect(ParagraphGrouping.paragraphs(lines) == [0..<1, 1..<2])
        lines[0].endsWithHyphen = true  // ...but the word continues on it
        #expect(ParagraphGrouping.paragraphs(lines) == [0..<2])
    }

    @Test func headingAboveAParagraph() {
        // 17 pt bold heading (20 pt box), then body at the normal pitch below it.
        let heading = Line(72, 700, 220, 20)
        let lines = [heading] + body(4, top: 672)
        #expect(ParagraphGrouping.paragraphs(lines) == [0..<1, 1..<5])
    }

    @Test func sameSizeCentredHeadingAboveAParagraph() {
        let heading = Line(250, 700, 110, 13)
        let lines = [heading] + body(4, top: 685)
        #expect(ParagraphGrouping.paragraphs(lines) == [0..<1, 1..<5])
    }

    @Test func twoColumnsDoNotJoin() {
        // Left column 72...297, right column 315...540; one paragraph runs from the bottom of the
        // left column into the top of the right one, and stays split at the column edge.
        let left = body(5, top: 700, x: 72, width: 225)
        let right = body(4, top: 700, x: 315, width: 225)
        #expect(ParagraphGrouping.paragraphs(left + right) == [0..<5, 5..<9])
    }

    @Test func lastParagraphOfAPageEndsAtThePage() {
        let lines = body(3, top: 700, lastWidth: 200) + body(4, top: 700 - 2 * 15 - 24)
            + [Line(72, 54, 70, 10)]  // footer
        #expect(ParagraphGrouping.paragraphs(lines) == [0..<3, 3..<7, 7..<8])
    }

    @Test func splitPiecesOfOneVisualLineStayTogether() {
        var lines = body(3, top: 700)
        let first = lines[0].rect
        lines[0] = Line(first.minX, first.minY, 200, 13)
        lines.insert(Line(first.minX + 204, first.minY, first.width - 204, 13), at: 1)
        #expect(ParagraphGrouping.paragraphs(lines) == [0..<4])
    }

    @Test func linesOutsideTheCropBoxStandAlone() {
        let lines = body(3, top: 700) + [Line(72, -40, 300, 13)]
        let paragraphs = ParagraphGrouping.paragraphs(lines, visibleBox: CGRect(x: 0, y: 0, width: 612, height: 792))
        #expect(paragraphs == [0..<3, 3..<4])
    }

    @Test func rotatedTextGroupsTheSame() {
        // The spacing layout turned a quarter turn (text reading upwards): x <- y, y <- x.
        let upright = body(4, top: 700) + body(3, top: 700 - 3 * 15 - 24)
        let turned = upright.map { line in
            Line(rect: CGRect(x: 792 - line.rect.maxY, y: line.rect.minX, width: line.rect.height,
                              height: line.rect.width))
        }
        #expect(ParagraphGrouping.paragraphs(turned) == [0..<4, 4..<7])
    }

    @Test func emptyInput() {
        #expect(ParagraphGrouping.paragraphs([]).isEmpty)
    }

    // MARK: Fixtures

    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/out")
    }

    @MainActor @Test func smallPage3SelectsTheSpecialParagraph() throws {
        let document = try #require(PDFDocument(url: Self.fixtures.appendingPathComponent("small.pdf")))
        let page = try #require(document.page(at: 2))
        let text = try #require(page.string as NSString?)
        let word = text.range(of: "amber")
        #expect(word.location != NSNotFound)
        let selection = try #require(page.selection(for: word))
        let grown = try #require(ParagraphSelection.expanding(selection))
        let string = grown.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(string == "Remember that the quick amber fox annotates margins.")
        #expect(grown.pages.count == 1)
    }

    @MainActor @Test func aBodyWordGrowsToItsWholeParagraphOnly() throws {
        let document = try #require(PDFDocument(url: Self.fixtures.appendingPathComponent("small.pdf")))
        let page = try #require(document.page(at: 5))
        let lines = ParagraphSelection.lines(on: page)
        let paragraphs = ParagraphGrouping.paragraphs(lines.map(\.line))
        // Header, (heading lines,) four body paragraphs, footer.
        #expect(paragraphs.count >= 6)
        let longest = try #require(paragraphs.max { $0.count < $1.count })
        let middle = lines[longest[longest.lowerBound + longest.count / 2]].range
        let selection = try #require(page.selection(for: NSRange(location: middle.location + 2, length: 3)))
        let grown = try #require(ParagraphSelection.expanding(selection))
        let expected = NSRange(location: lines[longest.lowerBound].range.location,
                               length: NSMaxRange(lines[longest.upperBound - 1].range) - lines[longest.lowerBound].range.location)
        #expect(grown.range(at: 0, on: page) == expected)
        #expect(grown.pages.count == 1)
    }

    /// A one-page selection never grows onto another page, and the cost is one page's (measured
    /// on page 700 of `large.pdf`).
    @MainActor @Test func largeBookStaysOnOnePageAndIsFast() throws {
        let document = try #require(PDFDocument(url: Self.fixtures.appendingPathComponent("large.pdf")))
        // Cold: the first touch of page 700's text, as on the reader's first Select All there.
        let cold = try #require(document.page(at: 699)?.selection(for: NSRange(location: 400, length: 3)))
        let coldStart = Date()
        let coldGrown = try #require(ParagraphSelection.expanding(cold))
        let coldElapsed = Date().timeIntervalSince(coldStart)
        print("SELECT-ALL page 700 cold: \(String(format: "%.1f", coldElapsed * 1000)) ms, "
              + "\(coldGrown.string?.count ?? 0) characters")
        #expect(coldGrown.pages.count == 1 && coldElapsed < 1)
        for index in [0, 699, 1499] {
            let page = try #require(document.page(at: index))
            let lines = ParagraphSelection.lines(on: page)
            // The last body line, and the first: paragraphs at the page edges.
            for line in [lines[lines.count - 2], lines[1]] {
                let selection = try #require(page.selection(for: NSRange(location: line.range.location, length: 2)))
                let start = Date()
                let grown = try #require(ParagraphSelection.expanding(selection))
                let elapsed = Date().timeIntervalSince(start)
                if index == 699 { print("SELECT-ALL page 700 paragraph: \(String(format: "%.1f", elapsed * 1000)) ms") }
                #expect(grown.pages.count == 1 && grown.pages.first === page)
                #expect(elapsed < 1)
            }
        }
    }
}
