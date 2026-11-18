import Foundation

/// Highlight background colours available for note text.
public enum NoteTextHighlightColor: String, Codable, Hashable, Sendable, CaseIterable {
    case yellow
    case green
    case blue
    case pink
}

/// Inline formatting attributes for a run of note text.
///
/// Stored as pure Swift values in `NoteRichText` so `ReaderCore` stays platform-independent and
/// notes adapt automatically to Light/Dark appearance and `NotePageStyle` metrics.
public struct NoteTextAttributes: Codable, Hashable, Sendable {
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderline: Bool
    public var isStrikethrough: Bool
    public var isCode: Bool
    public var highlight: NoteTextHighlightColor?

    public init(isBold: Bool = false, isItalic: Bool = false, isUnderline: Bool = false,
                isStrikethrough: Bool = false, isCode: Bool = false,
                highlight: NoteTextHighlightColor? = nil) {
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.isStrikethrough = isStrikethrough
        self.isCode = isCode
        self.highlight = highlight
    }

    public static let `default` = NoteTextAttributes()

    public var isDefault: Bool {
        !isBold && !isItalic && !isUnderline && !isStrikethrough && !isCode && highlight == nil
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
}
