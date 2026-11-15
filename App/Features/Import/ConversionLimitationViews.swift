import ReaderCore
import SwiftUI

// What converting to PDF costs, in words and symbols, and the rows that show it. Shared by the
// Convert to PDF sheet (shown before an import) and Settings ▸ Supported Formats (shown at any
// time), so both say exactly the same thing (docs/FORMAT_IMPORT_PLAN.md, "What the sheet says").

/// One limitation: a symbol and a sentence.
struct LimitationRow: View {
    let limitation: ConversionLimitation
    /// The row's accessibility identifier (each screen has its own prefix).
    let identifier: String

    var body: some View {
        IconRow(systemImage: limitation.systemImage) {
            Text(limitation.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier(identifier)
    }
}

/// A symbol in a column of its own (scaled with the text) and the content beside it. The symbol
/// is decoration: VoiceOver reads the content only, as one element.
struct IconRow<Content: View>: View {
    let systemImage: String
    @ViewBuilder let content: Content
    @ScaledMetric(relativeTo: .body) private var iconWidth = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Words

extension ConversionLimitation {
    /// The sentence the Convert to PDF sheet and Settings ▸ Supported Formats show.
    /// Exhaustive: a new limitation does not compile until it has words.
    var text: String {
        switch self {
        case .fixedPages:
            String(localized: "The pages are fixed once converted. You can zoom, but you can't change the text size or layout afterwards.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation shared by every converted format.")
        case .reconvertingMakesNewBook:
            String(localized: "Converting again makes a new book. Notes, ink and highlights don't move across.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation shared by every converted format.")
        case .originalKeptUsesStorage:
            String(localized: "Your original file is not changed. A copy is kept with the book, so the book uses more storage.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation shared by every converted format.")
        case .pageNumbersDiffer:
            String(localized: "Page numbers won't match the print edition or other reading apps.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation of converting an EPUB book.")
        case .contentsFromBook:
            String(localized: "Contents come from the book's own table of contents.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation of converting an EPUB book.")
        case .someLinksMayNotWork:
            String(localized: "Some links inside the book may not work.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation of converting an EPUB book.")
        case .mediaLeftOut:
            String(localized: "Audio, video and interactive parts are left out.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation of converting an EPUB book.")
        case .pagesArePictures:
            String(localized: "Pages are pictures: there is no text to select, search or highlight. Ink, notes and bookmarks work as usual.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation of converting a comic or images.")
        case .layoutMayDiffer:
            String(localized: "The layout may differ from the original app: fonts, page breaks and spacing can change.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation of converting a Word, RTF or Pages document.")
        case .commentsNotShown:
            String(localized: "Comments and tracked changes are not shown.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation of converting a Word, RTF or Pages document.")
        case .appChoosesTypography:
            String(localized: "The app chooses the typeface and page size.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation of converting plain text, Markdown or HTML.")
        case .remoteImagesNotLoaded:
            String(localized: "Images that are not inside the file are not downloaded.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation of converting plain text, Markdown or HTML.")
        case .oneSlidePerPage:
            String(localized: "Each slide becomes one page.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation of converting a presentation.")
        case .animationsAndMediaLeftOut:
            String(localized: "Animations, transitions, audio and video are left out.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation of converting a presentation.")
        case .speakerNotesNotIncluded:
            String(localized: "Speaker notes are not included.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation of converting a presentation.")
        case .fontsMayDiffer:
            String(localized: "Fonts and spacing can differ from the original app.",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: limitation of converting a presentation.")
        }
    }

    /// The symbol beside the sentence.
    var systemImage: String {
        switch self {
        case .fixedPages: "textformat.size"
        case .reconvertingMakesNewBook: "doc.on.doc"
        case .originalKeptUsesStorage: "internaldrive"
        case .pageNumbersDiffer: "number"
        case .contentsFromBook: "list.bullet"
        case .someLinksMayNotWork: "link"
        case .mediaLeftOut: "play.slash"
        case .pagesArePictures: "photo"
        case .layoutMayDiffer: "doc.richtext"
        case .commentsNotShown: "text.bubble"
        case .appChoosesTypography: "textformat"
        case .remoteImagesNotLoaded: "icloud.slash"
        case .oneSlidePerPage: "rectangle.on.rectangle"
        case .animationsAndMediaLeftOut: "play.slash"
        case .speakerNotesNotIncluded: "note.text"
        case .fontsMayDiffer: "textformat.alt"
        }
    }
}

extension LimitationGroup {
    /// The header of the group's block in the Convert to PDF sheet and in Settings ▸ Supported
    /// Formats.
    var sheetTitle: String {
        switch self {
        case .epub:
            String(localized: "EPUB Books",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: header of the block about EPUB files.")
        case .comicsAndImages:
            String(localized: "Comics and Images",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: header of the block about comic archives and image files.")
        case .wordProcessing:
            String(localized: "Word, RTF and Pages Documents",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: header of the block about word-processing files.")
        case .textAndWeb:
            String(localized: "Text, Markdown and HTML",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: header of the block about plain text, Markdown, HTML and web archive files.")
        case .presentations:
            String(localized: "Presentations",
                   comment: "Convert to PDF sheet and Settings ▸ Supported Formats: header of the block about PowerPoint and Keynote files.")
        }
    }

    var systemImage: String {
        switch self {
        case .epub: "book"
        case .comicsAndImages: "photo.on.rectangle"
        case .wordProcessing: "doc.richtext"
        case .textAndWeb: "doc.plaintext"
        case .presentations: "rectangle.on.rectangle"
        }
    }
}
