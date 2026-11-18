import Foundation

/// Inline formatting attributes for a run of note text.
///
/// Stored as pure Swift values in `NoteRichText` so `ReaderCore` stays platform-independent and
/// notes adapt automatically to Light/Dark appearance and `NotePageStyle` metrics.
public struct NoteTextAttributes: Codable, Hashable, Sendable {
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderline: Bool
    public var isStrikethrough: Bool

    public init(isBold: Bool = false, isItalic: Bool = false, isUnderline: Bool = false,
                isStrikethrough: Bool = false) {
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.isStrikethrough = isStrikethrough
    }

    public static let `default` = NoteTextAttributes()

    public var isDefault: Bool {
        !isBold && !isItalic && !isUnderline && !isStrikethrough
    }
}

/// A UTF-16 range of note text with non-default inline formatting.
public struct NoteTextSpan: Codable, Hashable, Sendable {
    public var location: Int
    public var length: Int
    public var attributes: NoteTextAttributes

    public init(location: Int, length: Int, attributes: NoteTextAttributes) {
        self.location = location
        self.length = length
        self.attributes = attributes
    }
}

/// Serialised inline formatting for a `Note`'s `text`.
///
/// Stored in `Note.richTextData` alongside plain `Note.text` so older app versions continue to
/// read the plain text cleanly and `NoteBandLayout` / search operate on `Note.text` unchanged.
public struct NoteRichText: Codable, Hashable, Sendable {
    public var version: Int
    public var spans: [NoteTextSpan]

    public init(version: Int = 1, spans: [NoteTextSpan] = []) {
        self.version = version
        self.spans = Self.normalized(spans)
    }

    /// Merges adjacent spans with identical attributes and drops empty or default spans.
    public static func normalized(_ raw: [NoteTextSpan]) -> [NoteTextSpan] {
        let valid = raw
            .filter { $0.location >= 0 && $0.length > 0 && !$0.attributes.isDefault }
            .sorted { ($0.location, $0.length) < ($1.location, $1.length) }
        var result: [NoteTextSpan] = []
        result.reserveCapacity(valid.count)
        for span in valid {
            if let last = result.last,
               last.location + last.length == span.location,
               last.attributes == span.attributes {
                result[result.count - 1].length += span.length
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Clamps spans to `utf16Length` in case plain text was edited by an older build.
    public func clamped(toUTF16Length utf16Length: Int) -> NoteRichText {
        guard utf16Length > 0 else { return NoteRichText(version: version, spans: []) }
        let clamped: [NoteTextSpan] = spans.compactMap { span in
            let start = max(0, span.location)
            let end = min(utf16Length, span.location + span.length)
            guard end > start else { return nil }
            return NoteTextSpan(location: start, length: end - start, attributes: span.attributes)
        }
        return NoteRichText(version: version, spans: clamped)
    }

    /// Encodes to JSON `Data`, or `nil` when there are no non-default spans.
    public func encoded() -> Data? {
        guard !spans.isEmpty else { return nil }
        return try? JSONEncoder().encode(self)
    }

    /// Decodes from `Data`, returning `nil` when `data` is `nil` or unreadable.
    public static func decoded(from data: Data?) -> NoteRichText? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(NoteRichText.self, from: data)
    }

    // MARK: Markdown rendering

    /// Renders `text` with `richTextData` inline spans as Markdown.
    /// Returns `text` unchanged when `richTextData` is `nil` or has no spans.
    public static func markdown(for text: String, richTextData: Data?) -> String {
        guard let rich = decoded(from: richTextData)?.clamped(toUTF16Length: text.utf16.count),
              !rich.spans.isEmpty else {
            return text
        }
        let nsText = text as NSString
        var output = ""
        var offset = 0
        let total = nsText.length

        while offset < total {
            let lineRange = nsText.lineRange(for: NSRange(location: offset, length: 0))
            // Separate line content from its trailing newline sequence so markers stay on one line.
            var contentEnd = lineRange.location + lineRange.length
            while contentEnd > lineRange.location {
                let ch = nsText.character(at: contentEnd - 1)
                if ch == 0x0A || ch == 0x0D || ch == 0x2029 { // \n, \r, paragraph separator
                    contentEnd -= 1
                } else {
                    break
                }
            }
            let contentRange = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
            let newlineRange = NSRange(location: contentEnd, length: lineRange.location + lineRange.length - contentEnd)
            output += markdownLine(nsText: nsText, range: contentRange, spans: rich.spans)
            if newlineRange.length > 0 {
                output += nsText.substring(with: newlineRange)
            }
            offset = lineRange.location + lineRange.length
        }
        return output
    }

    private static func markdownLine(nsText: NSString, range: NSRange, spans: [NoteTextSpan]) -> String {
        guard range.length > 0 else { return "" }
        let lineEnd = range.location + range.length
        // Collect boundary points inside this line.
        var cuts: [Int] = [range.location, lineEnd]
        for span in spans {
            let s = max(range.location, span.location)
            let e = min(lineEnd, span.location + span.length)
            if s < e {
                cuts.append(s)
                cuts.append(e)
            }
        }
        cuts = Array(Set(cuts)).sorted()

        var result = ""
        for i in 0..<(cuts.count - 1) {
            let segStart = cuts[i]
            let segEnd = cuts[i + 1]
            let segment = nsText.substring(with: NSRange(location: segStart, length: segEnd - segStart))
            let attrs = spans.first { $0.location <= segStart && $0.location + $0.length >= segEnd }?.attributes ?? .default
            result += wrapMarkdown(segment, attributes: attrs)
        }
        return result
    }

    private static func wrapMarkdown(_ segment: String, attributes: NoteTextAttributes) -> String {
        guard !attributes.isDefault, !segment.isEmpty else { return segment }
        // Keep leading/trailing whitespace outside inline markers.
        let leading = String(segment.prefix(while: { $0.isWhitespace }))
        let remainder = segment.dropFirst(leading.count)
        let trailing = String(remainder.reversed().prefix(while: { $0.isWhitespace }).reversed())
        let core = String(remainder.dropLast(trailing.count))
        guard !core.isEmpty else { return segment }

        var wrapped = core
        if attributes.isBold && attributes.isItalic {
            wrapped = "***\(wrapped)***"
        } else if attributes.isBold {
            wrapped = "**\(wrapped)**"
        } else if attributes.isItalic {
            wrapped = "*\(wrapped)*"
        }
        if attributes.isStrikethrough {
            wrapped = "~~\(wrapped)~~"
        }
        if attributes.isUnderline {
            wrapped = "<u>\(wrapped)</u>"
        }
        return leading + wrapped + trailing
    }

    // MARK: Paragraph-aware formatting merge

    /// UTF-16 `(start, length)` ranges of each paragraph in `NoteBandLayout.paragraphs(of: text)`.
    public static func paragraphUTF16Ranges(of text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var paraStart = 0
        var offset = 0
        for character in text {
            let count = character.utf16.count
            if character == "\n" || character == "\r\n" || character == "\r" || character == "\u{2029}" {
                ranges.append(NSRange(location: paraStart, length: offset - paraStart))
                paraStart = offset + count
            }
            offset += count
        }
        ranges.append(NSRange(location: paraStart, length: offset - paraStart))
        return ranges
    }

    /// Merges formatting spans for a two-way paragraph merge (`local` + `incoming` -> `mergedText`).
    public static func mergeTwoWay(local: (note: Note, paragraphMap: [Int]),
                                   incoming: (note: Note, paragraphMap: [Int]),
                                   mergedText: String) -> Data? {
        let dstRanges = paragraphUTF16Ranges(of: mergedText)
        let localRanges = paragraphUTF16Ranges(of: local.note.text)
        let incomingRanges = paragraphUTF16Ranges(of: incoming.note.text)
        let localSpans = decoded(from: local.note.richTextData)?.clamped(toUTF16Length: local.note.text.utf16.count).spans ?? []
        let incomingSpans = decoded(from: incoming.note.richTextData)?.clamped(toUTF16Length: incoming.note.text.utf16.count).spans ?? []

        // Map each destination paragraph to the source paragraph(s) that produced it.
        var localForDst: [Int: Int] = [:]
        for (srcIdx, dstIdx) in local.paragraphMap.enumerated() { localForDst[dstIdx] = srcIdx }
        var incomingForDst: [Int: Int] = [:]
        for (srcIdx, dstIdx) in incoming.paragraphMap.enumerated() { incomingForDst[dstIdx] = srcIdx }

        var mergedSpans: [NoteTextSpan] = []
        for (dstIdx, dstRange) in dstRanges.enumerated() {
            let lSrc = localForDst[dstIdx]
            let rSrc = incomingForDst[dstIdx]
            if let lSrc, lSrc < localRanges.count {
                let lParaSpans = spans(in: localSpans, within: localRanges[lSrc], shiftedTo: dstRange)
                if !lParaSpans.isEmpty {
                    mergedSpans.append(contentsOf: lParaSpans)
                    continue
                }
            }
            if let rSrc, rSrc < incomingRanges.count {
                let rParaSpans = spans(in: incomingSpans, within: incomingRanges[rSrc], shiftedTo: dstRange)
                mergedSpans.append(contentsOf: rParaSpans)
            }
        }
        return NoteRichText(spans: mergedSpans).encoded()
    }

    /// Merges formatting spans for a three-way paragraph merge (`local`, `remote`, `base` -> `mergedText`).
    public static func mergeThreeWay(local: (note: Note, paragraphMap: [Int?]),
                                     remote: (note: Note, paragraphMap: [Int?]),
                                     base: (note: Note, paragraphMap: [Int?]),
                                     mergedText: String) -> Data? {
        let dstRanges = paragraphUTF16Ranges(of: mergedText)
        let localRanges = paragraphUTF16Ranges(of: local.note.text)
        let remoteRanges = paragraphUTF16Ranges(of: remote.note.text)
        let baseRanges = paragraphUTF16Ranges(of: base.note.text)

        let localSpans = decoded(from: local.note.richTextData)?.clamped(toUTF16Length: local.note.text.utf16.count).spans ?? []
        let remoteSpans = decoded(from: remote.note.richTextData)?.clamped(toUTF16Length: remote.note.text.utf16.count).spans ?? []
        let baseSpans = decoded(from: base.note.richTextData)?.clamped(toUTF16Length: base.note.text.utf16.count).spans ?? []

        var localForDst: [Int: Int] = [:]
        for (srcIdx, dstIdx) in local.paragraphMap.enumerated() { if let dstIdx { localForDst[dstIdx] = srcIdx } }
        var remoteForDst: [Int: Int] = [:]
        for (srcIdx, dstIdx) in remote.paragraphMap.enumerated() { if let dstIdx { remoteForDst[dstIdx] = srcIdx } }
        var baseForDst: [Int: Int] = [:]
        for (srcIdx, dstIdx) in base.paragraphMap.enumerated() { if let dstIdx { baseForDst[dstIdx] = srcIdx } }

        var mergedSpans: [NoteTextSpan] = []
        for (dstIdx, dstRange) in dstRanges.enumerated() {
            let lSrc = localForDst[dstIdx]
            let rSrc = remoteForDst[dstIdx]
            let bSrc = baseForDst[dstIdx]

            let lZero = lSrc.flatMap { $0 < localRanges.count ? spans(in: localSpans, within: localRanges[$0], shiftedTo: NSRange(location: 0, length: dstRange.length)) : nil } ?? []
            let rZero = rSrc.flatMap { $0 < remoteRanges.count ? spans(in: remoteSpans, within: remoteRanges[$0], shiftedTo: NSRange(location: 0, length: dstRange.length)) : nil } ?? []
            let bZero = bSrc.flatMap { $0 < baseRanges.count ? spans(in: baseSpans, within: baseRanges[$0], shiftedTo: NSRange(location: 0, length: dstRange.length)) : nil } ?? []

            let chosenZero: [NoteTextSpan]
            if lSrc != nil && rSrc != nil {
                // If local kept base formatting and remote changed it, adopt remote's formatting.
                if lZero == bZero && rZero != bZero {
                    chosenZero = rZero
                } else {
                    chosenZero = lZero
                }
            } else if lSrc != nil {
                chosenZero = lZero
            } else if rSrc != nil {
                chosenZero = rZero
            } else {
                chosenZero = []
            }

            for span in chosenZero {
                mergedSpans.append(NoteTextSpan(location: dstRange.location + span.location,
                                                length: span.length,
                                                attributes: span.attributes))
            }
        }
        return NoteRichText(spans: mergedSpans).encoded()
    }

    private static func spans(in all: [NoteTextSpan], within srcRange: NSRange, shiftedTo dstRange: NSRange) -> [NoteTextSpan] {
        guard srcRange.length > 0, dstRange.length > 0 else { return [] }
        let srcEnd = srcRange.location + srcRange.length
        var result: [NoteTextSpan] = []
        for span in all {
            let start = max(srcRange.location, span.location)
            let end = min(srcEnd, span.location + span.length)
            guard start < end else { continue }
            let relStart = start - srcRange.location
            let relEnd = min(end - srcRange.location, dstRange.length)
            guard relStart < relEnd else { continue }
            result.append(NoteTextSpan(location: dstRange.location + relStart,
                                       length: relEnd - relStart,
                                       attributes: span.attributes))
        }
        return result
    }
}
