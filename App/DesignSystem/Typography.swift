import SwiftUI

/// Two voices. **Serif** (New York) speaks for the book and the reader's own writing: book and
/// chapter titles, note text. **Sans** (SF) is the interface: controls, metadata, labels.
/// Everything scales with Dynamic Type except `notePage`, which is fixed so ink stays registered
/// (zoom enlarges it instead).
enum Typeface {
    // Serif: content
    static let largeTitle = Font.system(.largeTitle, design: .serif, weight: .bold)
    static let title = Font.system(.title2, design: .serif, weight: .semibold)
    static let heading = Font.system(.headline, design: .serif, weight: .semibold)
    /// Heading rows in Contents and Notebook.
    static let outline = Font.system(.subheadline, design: .serif, weight: .medium)

    // Sans: interface
    static let control = Font.system(.body, design: .default, weight: .semibold)
    static let body = Font.system(.body)
    static let caption = Font.system(.footnote)
    static let meta = Font.system(.caption, design: .default, weight: .medium)
    /// Small uppercase section labels ("CONTINUE READING").
    static let label = Font.system(.caption2, design: .default, weight: .semibold)

    // Fixed: the note page. 16 pt New York on a 320 pt page.
    static let notePageSize: CGFloat = 16
    static let notePage = Font.system(size: notePageSize, design: .serif)
    static let notePageLineHeight: CGFloat = 24

    /// Page numbers and counts align in columns.
    static let numeric = Font.system(.caption, design: .default, weight: .medium).monospacedDigit()
}

extension View {
    /// Uppercase tracked section label.
    func sectionLabelStyle() -> some View {
        font(Typeface.label)
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(Palette.inkSecondary)
    }
}
