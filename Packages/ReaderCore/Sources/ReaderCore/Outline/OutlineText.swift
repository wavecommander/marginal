import Foundation

/// Text normalisation shared by the outline, anchors and export.
public enum OutlineText {
    /// The canonical form of a heading title, used for display, for `HeadingAnchor` strings and
    /// for Markdown headings.
    ///
    /// **Rule:** Unicode NFC (precomposed); every run of whitespace, newlines and control
    /// characters becomes one ASCII space; leading and trailing spaces are removed. Case and
    /// punctuation are kept. Idempotent: `normalizedTitle(normalizedTitle(s)) == normalizedTitle(s)`.
    public static func normalizedTitle(_ title: String) -> String {
        let nfc = title.precomposedStringWithCanonicalMapping
        var result = ""
        result.reserveCapacity(nfc.utf8.count)
        var pendingSpace = false
        for character in nfc {
            let isSeparator = character.isWhitespace || character.isNewline
                || character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
            if isSeparator {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" ") }
                pendingSpace = false
                result.append(character)
            }
        }
        return result
    }

    /// The key two titles are compared by when re-matching anchors: `normalizedTitle` folded
    /// case-, diacritic- and width-insensitively with no locale ("Éigen  Values" ~ "eigen values").
    public static func matchKey(_ title: String) -> String {
        normalizedTitle(title).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
    }
}
