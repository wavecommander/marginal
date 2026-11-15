import ReaderCore
import SwiftUI

// "Converted from …": where a converted book came from (docs/FORMAT_IMPORT_PLAN.md, "After the
// import"). Shown, as information only, in the Library's book context menu and the reader's More
// menu. A book imported as a PDF shows nothing.

extension ImportFormat {
    /// The line that says a book was made from a file of this format, or `nil` for a PDF (not
    /// converted). One whole sentence per format, so each language words it its own way.
    /// Exhaustive: a new format does not compile until it has words.
    var convertedFromLabel: String? {
        switch self {
        case .pdf:
            nil
        case .epub:
            String(localized: "Converted from EPUB",
                   comment: "Library book menu and reader More menu: information line on a book made from an EPUB file.")
        case .comicArchive:
            String(localized: "Converted from a comic archive",
                   comment: "Library book menu and reader More menu: information line on a book made from a comic archive (CBZ or ZIP of pictures).")
        case .image:
            String(localized: "Converted from an image",
                   comment: "Library book menu and reader More menu: information line on a book made from an image file (JPEG, PNG, HEIC, TIFF…).")
        case .plainText:
            String(localized: "Converted from plain text",
                   comment: "Library book menu and reader More menu: information line on a book made from a plain text file.")
        case .markdown:
            String(localized: "Converted from Markdown",
                   comment: "Library book menu and reader More menu: information line on a book made from a Markdown file.")
        case .html:
            String(localized: "Converted from HTML",
                   comment: "Library book menu and reader More menu: information line on a book made from an HTML web page file.")
        case .webArchive:
            String(localized: "Converted from a web archive",
                   comment: "Library book menu and reader More menu: information line on a book made from a Safari web archive.")
        case .word:
            String(localized: "Converted from Word",
                   comment: "Library book menu and reader More menu: information line on a book made from a Microsoft Word document.")
        case .rtf:
            String(localized: "Converted from RTF",
                   comment: "Library book menu and reader More menu: information line on a book made from a Rich Text Format (RTF) document.")
        case .pages:
            String(localized: "Converted from Pages",
                   comment: "Library book menu and reader More menu: information line on a book made from an Apple Pages document.")
        case .powerPoint:
            String(localized: "Converted from PowerPoint",
                   comment: "Library book menu and reader More menu: information line on a book made from a PowerPoint presentation.")
        case .keynote:
            String(localized: "Converted from Keynote",
                   comment: "Library book menu and reader More menu: information line on a book made from an Apple Keynote presentation.")
        }
    }
}

extension Book {
    /// "Converted from EPUB" and the like; `nil` for a book imported as a PDF.
    var convertedFromLabel: String? {
        guard isConverted else { return nil }
        return sourceFormat?.convertedFromLabel
    }
}

/// The "Converted from …" item at the end of a book's menu, in a section of its own. It is
/// information only: a disabled item, so it cannot be chosen (VoiceOver reads it as dimmed).
/// Nothing for a book imported as a PDF.
///
/// SwiftUI does not hand accessibility identifiers on to menu items (on iPadOS 27 XCUITest sees an
/// enabled item's symbol name as its identifier, and none on a disabled one), so UI tests find
/// this item by its words; the identifier is set in case a later system passes it on. A second
/// line with the original file's name was tried and is not drawn in either menu.
struct ConvertedFromMenuSection: View {
    let book: Book
    /// `AccessibilityID.Provenance.libraryMenu` or `.readerMenu`.
    let identifier: String

    var body: some View {
        if let label = book.convertedFromLabel {
            Section {
                Button {} label: {
                    Label(label, systemImage: "doc.badge.arrow.up")
                }
                .disabled(true)
                .accessibilityIdentifier(identifier)
            }
        }
    }
}

extension AccessibilityID {
    /// "Converted from …" in a converted book's menus.
    nonisolated enum Provenance {
        /// In the Library's book context menu.
        static let libraryMenu = "library.bookMenu.convertedFrom"
        /// In the reader's More menu.
        static let readerMenu = "reader.more.convertedFrom"
    }
}
