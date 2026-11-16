import Foundation
import CoreGraphics

/// The text recognised on one page of a scanned book, with where each word is.
///
/// **Text and words.** `text` is the page's lines in reading order joined by `"\n"`, each line
/// its words joined by single spaces. A *word* is a maximal run of non-whitespace in `text`;
/// `words` lists every one in order, with its UTF-16 range in `text` (the offsets search
/// matches on, as with `PDFPage.string`), its line, and its box. Because the words are derived
/// from `text`, only the boxes are stored beside it.
///
/// **Boxes** are in PDFKit *page space* for `pageIndex`, as `Highlight.rects` are: points,
/// origin at the lower-left of the page's media box, y up, unrotated. They are kept to a tenth
/// of a point (rounded when the page is made), which is well inside the half-point tolerance
/// highlights are compared with.
///
/// **Stored form** (`Codable`, one file per page under `Books/<bookID>/text/`): JSON
/// `{"format": 1, "pageIndex": …, "text": …, "boxes": [x, y, width, height, …]}`: four integers
/// per word, in tenths of a point, each the difference from the same value of the previous
/// word's box (the first word's from zero). Words along a line share their y and height, so
/// most of those are `0`. A dense printed page (about 2,500 characters and 400 words) takes
/// about 8 KB, so a 1,500-page book takes about a dozen megabytes.
public struct RecognisedPage: Hashable, Sendable {
    /// One recognised word as Vision reports it: what goes into `init(pageIndex:lines:)`.
    public struct Token: Hashable, Sendable {
        /// The word's text. Whitespace inside it splits it into several words with this box.
        public var text: String
        /// The word's box in page space.
        public var bounds: CGRect

        public init(text: String, bounds: CGRect) {
            self.text = text
            self.bounds = bounds
        }
    }

    /// One word of `text`.
    public struct Word: Hashable, Sendable {
        /// UTF-16 offsets of the word in `text`.
        public let range: Range<Int>
        /// Zero-based line of `text` the word is on.
        public let line: Int
        /// The word's box in page space, to a tenth of a point.
        public let bounds: CGRect
    }

    /// Version of the stored form written by this build.
    public static let formatVersion = 1

    /// Zero-based page.
    public let pageIndex: Int
    /// The page's text: lines joined by `"\n"`, words by single spaces.
    public let text: String
    /// Every word of `text`, in order.
    public let words: [Word]

    /// A page from recognised lines in reading order, each a list of words in reading order.
    /// Empty words are dropped, and lines left with no words.
    public init(pageIndex: Int, lines: [[Token]]) {
        var lineTexts: [String] = []
        var boxes: [CGRect] = []
        for line in lines {
            var words: [String] = []
            for token in line {
                // Split exactly as `wordSpans` will read the text back, so boxes and words match.
                let utf16 = token.text.utf16
                for span in Self.wordSpans(of: token.text) {
                    let from = utf16.index(utf16.startIndex, offsetBy: span.range.lowerBound)
                    let to = utf16.index(utf16.startIndex, offsetBy: span.range.upperBound)
                    words.append(String(token.text[from..<to]))
                    boxes.append(token.bounds)
                }
            }
            if !words.isEmpty { lineTexts.append(words.joined(separator: " ")) }
        }
        // Built from the same spans `init?(pageIndex:text:wordBoxes:)` reads, so it never fails.
        self.init(pageIndex: pageIndex, text: lineTexts.joined(separator: "\n"), wordBoxes: boxes)!
    }

    /// A page from its text and one box per word of `text` (maximal runs of non-whitespace, in
    /// order), or `nil` when the counts differ.
    public init?(pageIndex: Int, text: String, wordBoxes: [CGRect]) {
        let spans = Self.wordSpans(of: text)
        guard spans.count == wordBoxes.count else { return nil }
        self.pageIndex = pageIndex
        self.text = text
        self.words = zip(spans, wordBoxes).map { span, box in
            Word(range: span.range, line: span.line, bounds: Self.rounded(box))
        }
    }

    /// The boxes of the words that the UTF-16 range `range` of `text` touches (a word touches it
    /// when they share at least one UTF-16 unit), merged per line: one rect per line, the union
    /// of that line's touched words, in line order. Empty for an empty range or one that touches
    /// no word. This is how a search hit on recognised text becomes rects to mark.
    public func rects(forUTF16Range range: Range<Int>) -> [CGRect] {
        guard !range.isEmpty else { return [] }
        // First word that ends after the range starts (words are in order and do not overlap).
        var low = 0, high = words.count
        while low < high {
            let mid = (low + high) / 2
            if words[mid].range.upperBound <= range.lowerBound { low = mid + 1 } else { high = mid }
        }
        var result: [CGRect] = []
        var currentLine: Int?
        for word in words[low...] {
            guard word.range.lowerBound < range.upperBound else { break }
            if word.line == currentLine, let last = result.popLast() {
                result.append(last.union(word.bounds))
            } else {
                result.append(word.bounds)
                currentLine = word.line
            }
        }
        return result
    }

    // MARK: Helpers

    /// A box to a tenth of a point, standardised; non-finite values become 0.
    static func rounded(_ rect: CGRect) -> CGRect {
        let r = rect.standardized
        func tenth(_ v: CGFloat) -> CGFloat { v.isFinite ? (v * 10).rounded() / 10 : 0 }
        return CGRect(x: tenth(r.minX), y: tenth(r.minY), width: tenth(r.width), height: tenth(r.height))
    }

    /// Maximal runs of non-whitespace in `text` with their UTF-16 ranges and line numbers. A
    /// line ends at `"\n"`, `"\r"` (once for `"\r\n"`), U+2028 or U+2029.
    static func wordSpans(of text: String) -> [(range: Range<Int>, line: Int)] {
        var spans: [(range: Range<Int>, line: Int)] = []
        var offset = 0, line = 0
        var start: Int?
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            let isBreak = scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}"
            if scalar.properties.isWhitespace || isBreak {
                if let s = start { spans.append((s..<offset, line)); start = nil }
                if isBreak && !(scalar == "\n" && previousWasCR) { line += 1 }
            } else if start == nil {
                start = offset
            }
            previousWasCR = scalar == "\r"
            offset += scalar.utf16.count
        }
        if let s = start { spans.append((s..<offset, line)) }
        return spans
    }
}

extension RecognisedPage: Codable {
    private enum CodingKeys: String, CodingKey {
        case format, pageIndex, text, boxes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(Int.self, forKey: .format)
        guard format == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: container,
                                                   debugDescription: "recognised page format \(format) is not \(Self.formatVersion)")
        }
        let deltas = try container.decode([Int].self, forKey: .boxes)
        guard deltas.count % 4 == 0 else {
            throw DecodingError.dataCorruptedError(forKey: .boxes, in: container, debugDescription: "box values not in fours")
        }
        var boxes: [CGRect] = []
        boxes.reserveCapacity(deltas.count / 4)
        var running = (0, 0, 0, 0)
        for i in stride(from: 0, to: deltas.count, by: 4) {
            running = (running.0 &+ deltas[i], running.1 &+ deltas[i + 1], running.2 &+ deltas[i + 2], running.3 &+ deltas[i + 3])
            let x = CGFloat(running.0) / 10, y = CGFloat(running.1) / 10
            let width = CGFloat(running.2) / 10, height = CGFloat(running.3) / 10
            boxes.append(CGRect(x: x, y: y, width: width, height: height))
        }
        guard let page = RecognisedPage(pageIndex: try container.decode(Int.self, forKey: .pageIndex),
                                        text: try container.decode(String.self, forKey: .text), wordBoxes: boxes) else {
            throw DecodingError.dataCorruptedError(forKey: .boxes, in: container, debugDescription: "one box per word expected")
        }
        self = page
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .format)
        try container.encode(pageIndex, forKey: .pageIndex)
        try container.encode(text, forKey: .text)
        var deltas: [Int] = []
        deltas.reserveCapacity(words.count * 4)
        var previous = [0, 0, 0, 0]
        for word in words {
            let b = word.bounds
            for (k, value) in [b.minX, b.minY, b.width, b.height].enumerated() {
                let tenths = Int((value * 10).rounded())
                deltas.append(tenths - previous[k])
                previous[k] = tenths
            }
        }
        try container.encode(deltas, forKey: .boxes)
    }
}
