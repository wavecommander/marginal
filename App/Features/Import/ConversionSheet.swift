import ReaderCore
import SwiftUI

/// The Convert to PDF sheet (docs/FORMAT_IMPORT_PLAN.md, "What the sheet says"): shown in the
/// window that asked, every time an import includes a file that needs converting, before anything
/// is converted. It says what converting costs (the common block, then one block per kind of file
/// in the batch), offers the Text size for EPUB and text formats, lists the batch's files that
/// can't be imported, and ends with Cancel or Convert. There is no "don't show again".
///
/// The Library presents it for `ImportService.conversionRequest(for:)` and passes the answer
/// back (`ImportService.convert` / `.discard`); dismissing it any other way counts as Cancel.
struct ConversionSheet: View {
    let request: ConversionRequest
    let onConvert: (ConversionOptions) -> Void
    let onCancel: () -> Void

    @State private var textSize = ConversionOptions().textSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    commonBlock
                }
                ForEach(request.groups, id: \.self) { group in
                    Section {
                        groupBlock(group)
                    } header: {
                        Text(group.sheetTitle)
                    }
                }
                if request.offersTextSizeChoice {
                    Section {
                        textSizePicker
                    } header: {
                        Text("Text Size", comment: "Convert to PDF sheet: header of the text size setting.")
                    } footer: {
                        Text("Choose now. It can't be changed after converting.",
                             comment: "Convert to PDF sheet: line under the Text size setting.")
                    }
                }
                if !request.rejected.isEmpty {
                    Section {
                        rejectedBlock
                    } header: {
                        Text("Can't Be Imported", comment: "Convert to PDF sheet: header of the list of files that can't be imported.")
                    }
                }
            }
            .navigationTitle(Text("Convert to PDF?", comment: "Convert to PDF sheet: title."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onCancel()
                    } label: {
                        Text("Cancel", comment: "Convert to PDF sheet: button that discards the import.")
                    }
                    .accessibilityIdentifier(AccessibilityID.Conversion.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        var options = ConversionOptions()
                        options.textSize = textSize
                        onConvert(options)
                    } label: {
                        Text("Convert", comment: "Convert to PDF sheet: button that starts converting the files.")
                    }
                    .accessibilityIdentifier(AccessibilityID.Conversion.convert)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Conversion.sheet)
    }

    // MARK: Blocks

    private var commonBlock: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Tactile Texts reads PDFs. These files will be converted to PDF copies so you can write on them, highlight them and attach notes to their pages.",
                 comment: "Convert to PDF sheet: first paragraph, the same for every format.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ConversionLimitation.common, id: \.self) { LimitationRow(limitation: $0) }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Conversion.commonBlock)
    }

    private func groupBlock(_ group: LimitationGroup) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(request.items(in: group)) { item in
                    IconRow(systemImage: group.systemImage) {
                        Text(verbatim: item.fileName)
                            .font(.body.weight(.semibold))
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                }
            }
            ForEach(ConversionLimitation.specific(to: group), id: \.self) { LimitationRow(limitation: $0) }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Conversion.block(group))
    }

    @ViewBuilder
    private var textSizePicker: some View {
        let picker = Picker(selection: $textSize) {
            ForEach(ConversionTextSize.allCases, id: \.self) { size in
                Text(size.label).tag(size)
            }
        } label: {
            Text("Text Size", comment: "Convert to PDF sheet: accessibility label of the text size setting.")
        }
        .accessibilityIdentifier(AccessibilityID.Conversion.textSize)
        // Three segments truncate at accessibility text sizes; a list of choices does not.
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.inline).labelsHidden()
        } else {
            picker.pickerStyle(.segmented).labelsHidden()
        }
    }

    private var rejectedBlock: some View {
        ForEach(request.rejected) { file in
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(verbatim: file.fileName)
                    .font(.body.weight(.semibold))
                    .lineLimit(3)
                    .truncationMode(.middle)
                Text(file.error.shortReason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Conversion.rejected(file.fileName))
        }
    }
}

/// One limitation: a symbol and a sentence.
private struct LimitationRow: View {
    let limitation: ConversionLimitation

    var body: some View {
        IconRow(systemImage: limitation.systemImage) {
            Text(limitation.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier(AccessibilityID.Conversion.limitation(limitation))
    }
}

/// A symbol in a column of its own (scaled with the text) and the content beside it. The symbol
/// is decoration: VoiceOver reads the content only, as one element.
private struct IconRow<Content: View>: View {
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
    /// The sentence the Convert to PDF sheet shows (and Settings ▸ Supported formats will).
    /// Exhaustive: a new limitation does not compile until it has words.
    var text: String {
        switch self {
        case .fixedPages:
            String(localized: "The pages are fixed once converted. You can zoom, but you can't change the text size or layout afterwards.",
                   comment: "Convert to PDF sheet: limitation shared by every converted format.")
        case .reconvertingMakesNewBook:
            String(localized: "Converting again makes a new book. Notes, ink and highlights don't move across.",
                   comment: "Convert to PDF sheet: limitation shared by every converted format.")
        case .originalKeptUsesStorage:
            String(localized: "Your original file is not changed. A copy is kept with the book, so the book uses more storage.",
                   comment: "Convert to PDF sheet: limitation shared by every converted format.")
        case .pageNumbersDiffer:
            String(localized: "Page numbers won't match the print edition or other reading apps.",
                   comment: "Convert to PDF sheet: limitation of converting an EPUB book.")
        case .contentsFromBook:
            String(localized: "Contents come from the book's own table of contents.",
                   comment: "Convert to PDF sheet: limitation of converting an EPUB book.")
        case .someLinksMayNotWork:
            String(localized: "Some links inside the book may not work.",
                   comment: "Convert to PDF sheet: limitation of converting an EPUB book.")
        case .mediaLeftOut:
            String(localized: "Audio, video and interactive parts are left out.",
                   comment: "Convert to PDF sheet: limitation of converting an EPUB book.")
        case .pagesArePictures:
            String(localized: "Pages are pictures: there is no text to select, search or highlight. Ink, notes and bookmarks work as usual.",
                   comment: "Convert to PDF sheet: limitation of converting a comic or images.")
        case .layoutMayDiffer:
            String(localized: "The layout may differ from the original app: fonts, page breaks and spacing can change.",
                   comment: "Convert to PDF sheet: limitation of converting a Word, RTF or Pages document.")
        case .commentsNotShown:
            String(localized: "Comments and tracked changes are not shown.",
                   comment: "Convert to PDF sheet: limitation of converting a Word, RTF or Pages document.")
        case .appChoosesTypography:
            String(localized: "The app chooses the typeface and page size.",
                   comment: "Convert to PDF sheet: limitation of converting plain text, Markdown or HTML.")
        case .remoteImagesNotLoaded:
            String(localized: "Images that are not inside the file are not downloaded.",
                   comment: "Convert to PDF sheet: limitation of converting plain text, Markdown or HTML.")
        case .oneSlidePerPage:
            String(localized: "Each slide becomes one page.",
                   comment: "Convert to PDF sheet: limitation of converting a presentation.")
        case .animationsAndMediaLeftOut:
            String(localized: "Animations, transitions, audio and video are left out.",
                   comment: "Convert to PDF sheet: limitation of converting a presentation.")
        case .speakerNotesNotIncluded:
            String(localized: "Speaker notes are not included.",
                   comment: "Convert to PDF sheet: limitation of converting a presentation.")
        case .fontsMayDiffer:
            String(localized: "Fonts and spacing can differ from the original app.",
                   comment: "Convert to PDF sheet: limitation of converting a presentation.")
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
    /// The header of the group's block in the Convert to PDF sheet.
    var sheetTitle: String {
        switch self {
        case .epub:
            String(localized: "EPUB Books", comment: "Convert to PDF sheet: header of the block about EPUB files.")
        case .comicsAndImages:
            String(localized: "Comics and Images", comment: "Convert to PDF sheet: header of the block about comic archives and image files.")
        case .wordProcessing:
            String(localized: "Word, RTF and Pages Documents", comment: "Convert to PDF sheet: header of the block about word-processing files.")
        case .textAndWeb:
            String(localized: "Text, Markdown and HTML", comment: "Convert to PDF sheet: header of the block about plain text, Markdown, HTML and web archive files.")
        case .presentations:
            String(localized: "Presentations", comment: "Convert to PDF sheet: header of the block about PowerPoint and Keynote files.")
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

extension ConversionTextSize {
    var label: String {
        switch self {
        case .small: String(localized: "Small", comment: "Convert to PDF sheet: text size choice.")
        case .medium: String(localized: "Medium", comment: "Convert to PDF sheet: text size choice.")
        case .large: String(localized: "Large", comment: "Convert to PDF sheet: text size choice.")
        }
    }
}

extension AccessibilityID {
    /// The Convert to PDF sheet.
    nonisolated enum Conversion {
        static let sheet = "conversion.sheet"
        static let convert = "conversion.convert"
        static let cancel = "conversion.cancel"
        /// The first block, the same for every format.
        static let commonBlock = "conversion.block.common"
        /// One block per limitation group: `conversion.block.<LimitationGroup rawValue>`.
        static func block(_ group: LimitationGroup) -> String { "conversion.block.\(group.rawValue)" }
        /// One row per limitation: `conversion.limitation.<ConversionLimitation rawValue>`.
        static func limitation(_ limitation: ConversionLimitation) -> String { "conversion.limitation.\(limitation.rawValue)" }
        static let textSize = "conversion.textSize"
        /// One row per file that can't be imported: `conversion.rejected.<file name>`.
        static func rejected(_ fileName: String) -> String { "conversion.rejected.\(fileName)" }
    }
}
