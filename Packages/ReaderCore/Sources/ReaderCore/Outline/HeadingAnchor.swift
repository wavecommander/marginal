import Foundation

/// The stable identity of a heading, stored with heading notes and as a user heading's parent.
///
/// PDF outline items carry no ID, so a PDF heading's anchor is derived from three facts that are
/// identical every time the same PDF is read:
/// - **path**: the zero-based index of the item among its PDF siblings at every level, root first
///   (`[4, 1]` = second child of the fifth top-level item). User headings never count towards
///   these indices, so adding or removing user headings never changes a PDF anchor.
/// - **page**: the item's own destination page index, or none when it has no valid destination
///   (missing, or outside `0..<pageCount`).
/// - **title**: `OutlineText.normalizedTitle` of the item's title.
///
/// A user heading's anchor is its `UserHeading.id`, so renaming or moving it keeps its notes.
///
/// ## String format (`rawValue`, also the `Codable` form, a single JSON string)
/// - PDF: `pdf1/<path>/<page>/<title>` where `<path>` is the indices joined by `.`, `<page>` is
///   the decimal page index or `-`, and `<title>` is the normalised title (it may contain `/`;
///   it is everything after the third `/`). Example: `pdf1/4.1/311/5.2 The Characteristic Equation`.
/// - User: `user1/<UUID>` with the UUID in upper case. Example: `user1/9F1C…`.
///
/// Equality and hashing are by the canonical `rawValue`. `init?(rawValue:)` accepts only these
/// shapes; it re-normalises the title so a parsed anchor is always canonical.
///
/// Matching an anchor against a possibly changed outline is `Outline.resolve(_:)`; see
/// `AnchorMatchQuality` for the order of fallbacks.
public struct HeadingAnchor: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    /// What the anchor identifies.
    public enum Kind: Hashable, Sendable {
        /// A heading from the PDF's own outline.
        case pdf(path: [Int], pageIndex: Int?, title: String)
        /// A heading the reader added (`UserHeading.id`).
        case user(UUID)
    }

    /// The parsed, canonical components.
    public let kind: Kind
    /// The canonical string form. Store this; compare anchors with `==`.
    public let rawValue: String

    /// Makes the anchor of a PDF outline item. `path` must be non-empty with non-negative
    /// elements (violations are a programming error and trap); a negative `pageIndex` is stored
    /// as "no page". `title` is normalised.
    public init(pdfPath path: [Int], pageIndex: Int?, title: String) {
        precondition(!path.isEmpty && path.allSatisfy { $0 >= 0 }, "invalid outline path \(path)")
        let page = pageIndex.flatMap { $0 >= 0 ? $0 : nil }
        let normalized = OutlineText.normalizedTitle(title)
        kind = .pdf(path: path, pageIndex: page, title: normalized)
        let pathString = path.map(String.init).joined(separator: ".")
        rawValue = "pdf1/\(pathString)/\(page.map(String.init) ?? "-")/\(normalized)"
    }

    /// Makes the anchor of a user heading.
    public init(userHeadingID id: UUID) {
        kind = .user(id)
        rawValue = "user1/\(id.uuidString.uppercased())"
    }

    /// Parses a stored anchor string. Returns `nil` for anything not in the documented format.
    public init?(rawValue: String) {
        if rawValue.hasPrefix("user1/") {
            guard let id = UUID(uuidString: String(rawValue.dropFirst("user1/".count))) else { return nil }
            self.init(userHeadingID: id)
            return
        }
        guard rawValue.hasPrefix("pdf1/") else { return nil }
        let parts = rawValue.dropFirst("pdf1/".count).split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var path: [Int] = []
        for component in parts[0].split(separator: ".", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component.allSatisfy(\.isASCIIDigit), let value = Int(component) else { return nil }
            path.append(value)
        }
        guard !path.isEmpty else { return nil }
        let page: Int?
        if parts[1] == "-" {
            page = nil
        } else {
            guard !parts[1].isEmpty, parts[1].allSatisfy(\.isASCIIDigit), let value = Int(parts[1]) else { return nil }
            page = value
        }
        self.init(pdfPath: path, pageIndex: page, title: String(parts[2]))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let anchor = HeadingAnchor(rawValue: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid HeadingAnchor \"\(string)\"")
        }
        self = anchor
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func == (lhs: HeadingAnchor, rhs: HeadingAnchor) -> Bool { lhs.rawValue == rhs.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
    public var description: String { rawValue }

    /// `true` for an anchor of a user heading.
    public var isUserHeading: Bool {
        if case .user = kind { return true }
        return false
    }

    /// The user heading's ID, or `nil` for a PDF anchor.
    public var userHeadingID: UUID? {
        if case .user(let id) = kind { return id }
        return nil
    }

    /// The PDF sibling-index path, or `nil` for a user anchor.
    public var pdfPath: [Int]? {
        if case .pdf(let path, _, _) = kind { return path }
        return nil
    }

    /// The recorded destination page of a PDF anchor (`nil` for no destination or a user anchor).
    public var pageIndex: Int? {
        if case .pdf(_, let page, _) = kind { return page }
        return nil
    }

    /// The recorded normalised title of a PDF anchor, or `nil` for a user anchor. Used to label
    /// orphaned heading notes whose heading no longer exists.
    public var title: String? {
        if case .pdf(_, _, let title) = kind { return title }
        return nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
