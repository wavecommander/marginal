import Foundation

/// What a note is attached to: a page or a heading. A book has at most one note per target.
///
/// `Codable` as a single string, `storageKey`, which is also what WP2 should put in the unique
/// constraint together with the book ID.
public enum NoteTarget: Hashable, Sendable, Codable, CustomStringConvertible {
    /// A page note, by zero-based page index.
    case page(Int)
    /// A section note, by the heading's anchor (see `HeadingAnchor`).
    case heading(HeadingAnchor)

    /// Canonical string: `page:<pageIndex>` (decimal, zero-based) or `heading:<anchor rawValue>`.
    /// Two targets are equal exactly when their storage keys are equal.
    public var storageKey: String {
        switch self {
        case .page(let index): "page:\(index)"
        case .heading(let anchor): "heading:\(anchor.rawValue)"
        }
    }

    /// Parses a `storageKey`; `nil` if malformed.
    public init?(storageKey: String) {
        if storageKey.hasPrefix("page:") {
            let digits = storageKey.dropFirst("page:".count)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let index = Int(digits) else { return nil }
            self = .page(index)
        } else if storageKey.hasPrefix("heading:") {
            guard let anchor = HeadingAnchor(rawValue: String(storageKey.dropFirst("heading:".count))) else { return nil }
            self = .heading(anchor)
        } else {
            return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        guard let target = NoteTarget(storageKey: key) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid NoteTarget \"\(key)\"")
        }
        self = target
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageKey)
    }

    public var description: String { storageKey }

    /// The page index of a page target, else `nil`.
    public var pageIndex: Int? { if case .page(let index) = self { index } else { nil } }
    /// The anchor of a heading target, else `nil`.
    public var headingAnchor: HeadingAnchor? { if case .heading(let anchor) = self { anchor } else { nil } }
}

/// A note: typed text plus (optionally) Pencil ink over the whole note page.
///
/// The ink itself is not here: it is `InkStore` data keyed by `(bookID, id)`. `bandLayout` is the
/// paragraph-band layout the stored ink was positioned against (see `NoteBands`); it is saved
/// with the record whenever the ink is saved.
///
/// **Empty rule:** a note is empty when its text is only whitespace/newlines and it has no ink.
/// An empty note is never stored: `RecordStore.save(_:)` deletes the record instead.
public struct Note: Identifiable, Hashable, Codable, Sendable {
    /// Stable ID; also keys the note's ink (`InkStore.noteInk`).
    public var id: UUID
    /// The book the note belongs to.
    public var bookID: UUID
    /// The page or heading the note is attached to; unique per book.
    public var target: NoteTarget
    /// Plain text (no attributes); paragraphs are separated by newlines.
    public var text: String
    /// `true` when the note's ink drawing has at least one stroke. Maintained by the editor (WP13).
    public var hasInk: Bool
    /// Band layout at the time the ink was last saved; `nil` when there is no ink.
    public var bandLayout: NoteBandLayout?
    public var createdAt: Date
    /// Last edit of text or ink. Set by the caller; repositories store it verbatim.
    public var modifiedAt: Date

    public init(id: UUID = UUID(), bookID: UUID, target: NoteTarget, text: String = "", hasInk: Bool = false,
                bandLayout: NoteBandLayout? = nil, createdAt: Date = Date(), modifiedAt: Date? = nil) {
        self.id = id
        self.bookID = bookID
        self.target = target
        self.text = text
        self.hasInk = hasInk
        self.bandLayout = bandLayout
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }

    /// See the empty rule above.
    public var isEmpty: Bool {
        !hasInk && text.allSatisfy { $0.isWhitespace || $0.isNewline }
    }
}
