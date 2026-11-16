import ReaderCore
import SwiftUI

/// What can be imported, worked out from the converters the app has. A group of formats is listed
/// only while at least one of its formats has a converter, and only those formats are named, so
/// registering a converter in `ConverterRegistry.standard` is all it takes for its formats to
/// appear here.
nonisolated struct SupportedFormatsCatalog: Equatable, Sendable {
    /// A limitation group with the formats in it that can be imported now.
    struct Group: Equatable, Sendable, Identifiable {
        let group: LimitationGroup
        /// In `ImportFormat.allCases` order; never empty.
        let formats: [ImportFormat]
        var id: LimitationGroup { group }
    }

    /// In `LimitationGroup.allCases` order.
    let groups: [Group]

    init(convertible: Set<ImportFormat>) {
        groups = LimitationGroup.allCases.compactMap { group in
            let formats = group.formats.filter { convertible.contains($0) }
            return formats.isEmpty ? nil : Group(group: group, formats: formats)
        }
    }

    /// What the app's own converters can import.
    static var standard: SupportedFormatsCatalog {
        SupportedFormatsCatalog(convertible: ConverterRegistry.standard.convertibleFormats)
    }

    /// The kinds of file that cannot be imported, in the order the screen lists them
    /// (docs/FORMAT_IMPORT_PLAN.md, "Not supported"). Every `UnsupportedImportFormat` is here.
    static let notSupported: [UnsupportedImportFormat] = [
        .protectedEPUB, .kindle, .djvu, .comicRar, .fixedLayoutEPUB, .spreadsheet,
    ]
}

/// Settings ▸ Supported Formats: what can be imported, and what converting to PDF costs, at any
/// time. The words and rows are the Convert to PDF sheet's (`ConversionLimitationViews.swift`):
/// the common block, then one block per kind of file the app can convert, then what it can't
/// import and why.
struct SupportedFormatsView: View {
    var catalog: SupportedFormatsCatalog = .standard

    var body: some View {
        Form {
            Section {
                FormatRow(format: .pdf, systemImage: "doc.text")
                Text("PDFs are imported as they are. Nothing is converted.",
                     comment: "Settings ▸ Supported Formats: line under the PDF row.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("PDF", comment: "Settings ▸ Supported Formats: header of the section about PDF files.")
            }

            if !catalog.groups.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: Space.m) {
                        Text("Tactile Texts reads PDFs. Other books and documents are converted to PDF copies when you import them, so you can write on them, highlight them and attach notes to their pages. You are asked before anything is converted.",
                             comment: "Settings ▸ Supported Formats: first paragraph of the section about converting to PDF.")
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(ConversionLimitation.common, id: \.self) {
                            LimitationRow(limitation: $0, identifier: AccessibilityID.SupportedFormats.limitation($0))
                        }
                    }
                    .padding(.vertical, Space.xs)
                } header: {
                    Text("Converted to PDF", comment: "Settings ▸ Supported Formats: header of the section about what converting any file to PDF means.")
                }

                ForEach(catalog.groups) { entry in
                    Section {
                        ForEach(entry.formats, id: \.self) { format in
                            FormatRow(format: format, systemImage: entry.group.systemImage)
                        }
                        VStack(alignment: .leading, spacing: Space.m) {
                            ForEach(ConversionLimitation.specific(to: entry.group), id: \.self) {
                                LimitationRow(limitation: $0, identifier: AccessibilityID.SupportedFormats.limitation($0))
                            }
                        }
                        .padding(.vertical, Space.xs)
                    } header: {
                        Text(entry.group.sheetTitle)
                            .accessibilityIdentifier(AccessibilityID.SupportedFormats.group(entry.group))
                    }
                }
            }

            Section {
                ForEach(SupportedFormatsCatalog.notSupported, id: \.self) { kind in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(kind.name)
                            .font(.body.weight(.semibold))
                        Text(kind.reason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Space.xxs)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.SupportedFormats.notSupported(kind))
                }
            } header: {
                Text("Not Supported", comment: "Settings ▸ Supported Formats: header of the list of kinds of file that can't be imported.")
            }
        }
        .settingsPageMargins()
        .navigationTitle(Text("Supported Formats", comment: "Settings ▸ Supported Formats: screen title."))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(AccessibilityID.SupportedFormats.screen)
    }
}

/// One importable format: its name, and its file name extensions under it.
private struct FormatRow: View {
    let format: ImportFormat
    let systemImage: String

    var body: some View {
        IconRow(systemImage: systemImage) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(format.displayName)
                    .font(.body.weight(.semibold))
                Text(format.fileExtensions.map { ".\($0)" }.formatted(.list(type: .and, width: .narrow)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier(AccessibilityID.SupportedFormats.format(format))
    }
}

// MARK: - Words

extension ImportFormat {
    /// The format's name in Settings ▸ Supported Formats. Exhaustive: a new format does not
    /// compile until it has a name.
    var displayName: String {
        switch self {
        case .pdf:
            String(localized: "PDF", comment: "Settings ▸ Supported Formats: name of a file format.")
        case .epub:
            String(localized: "EPUB books", comment: "Settings ▸ Supported Formats: name of a file format.")
        case .comicArchive:
            String(localized: "Comic archives", comment: "Settings ▸ Supported Formats: name of a file format (CBZ, or a ZIP of pictures).")
        case .image:
            String(localized: "Images", comment: "Settings ▸ Supported Formats: name of a file format (JPEG, PNG, HEIC, TIFF and others).")
        case .plainText:
            String(localized: "Plain text", comment: "Settings ▸ Supported Formats: name of a file format.")
        case .markdown:
            String(localized: "Markdown", comment: "Settings ▸ Supported Formats: name of a file format.")
        case .html:
            String(localized: "Web pages (HTML)", comment: "Settings ▸ Supported Formats: name of a file format.")
        case .webArchive:
            String(localized: "Safari web archives", comment: "Settings ▸ Supported Formats: name of a file format.")
        case .word:
            String(localized: "Word documents", comment: "Settings ▸ Supported Formats: name of a file format (Microsoft Word).")
        case .rtf:
            String(localized: "Rich Text (RTF)", comment: "Settings ▸ Supported Formats: name of a file format.")
        case .pages:
            String(localized: "Pages documents", comment: "Settings ▸ Supported Formats: name of a file format (Apple Pages).")
        case .powerPoint:
            String(localized: "PowerPoint presentations", comment: "Settings ▸ Supported Formats: name of a file format (Microsoft PowerPoint).")
        case .keynote:
            String(localized: "Keynote presentations", comment: "Settings ▸ Supported Formats: name of a file format (Apple Keynote).")
        }
    }
}

extension UnsupportedImportFormat {
    /// The name in Settings ▸ Supported Formats' "Not Supported" list.
    var name: String {
        switch self {
        case .protectedEPUB:
            String(localized: "Copy-protected (DRM) books",
                   comment: "Settings ▸ Supported Formats, Not Supported list: books bought with DRM (Kindle, Apple Books, Adobe DRM EPUB).")
        case .kindle:
            String(localized: "Kindle books (MOBI, AZW3)", comment: "Settings ▸ Supported Formats, Not Supported list: a kind of file.")
        case .djvu:
            String(localized: "DjVu documents", comment: "Settings ▸ Supported Formats, Not Supported list: a kind of file.")
        case .comicRar:
            String(localized: "CBR and RAR comics", comment: "Settings ▸ Supported Formats, Not Supported list: a kind of file.")
        case .fixedLayoutEPUB:
            String(localized: "Fixed-layout EPUB books", comment: "Settings ▸ Supported Formats, Not Supported list: a kind of file.")
        case .spreadsheet:
            String(localized: "Spreadsheets", comment: "Settings ▸ Supported Formats, Not Supported list: a kind of file (Excel, Numbers, CSV).")
        }
    }

    /// Why it can't be imported, in one or two short sentences.
    var reason: String {
        switch self {
        case .protectedEPUB:
            String(localized: "Books from Kindle, Apple Books and other stores that use copy protection can be opened only by the seller's app.",
                   comment: "Settings ▸ Supported Formats, Not Supported list: why DRM-protected books can't be imported.")
        case .kindle:
            String(localized: "iPadOS has no built-in way to read Kindle formats.",
                   comment: "Settings ▸ Supported Formats, Not Supported list: why Kindle files can't be imported.")
        case .djvu:
            String(localized: "No DjVu reader can be included in an App Store app.",
                   comment: "Settings ▸ Supported Formats, Not Supported list: why DjVu files can't be imported (the usual decoder's licence is not allowed on the App Store).")
        case .comicRar:
            String(localized: "RAR is a closed format. Comics saved as CBZ or ZIP can be imported.",
                   comment: "Settings ▸ Supported Formats, Not Supported list: why CBR comics can't be imported.")
        case .fixedLayoutEPUB:
            String(localized: "Books laid out page by page, such as picture books, can't be converted. EPUB books whose text reflows can.",
                   comment: "Settings ▸ Supported Formats, Not Supported list: why fixed-layout EPUB books can't be imported.")
        case .spreadsheet:
            String(localized: "Sheets don't fit on fixed pages. Export a PDF from the spreadsheet app and import that.",
                   comment: "Settings ▸ Supported Formats, Not Supported list: why spreadsheets can't be imported, and what to do instead.")
        }
    }
}

extension AccessibilityID {
    /// Settings ▸ Supported Formats.
    nonisolated enum SupportedFormats {
        /// The row in Settings that opens the screen.
        static let settingsRow = "settings.supportedFormats"
        static let screen = "supportedFormats.screen"
        /// A group's header: `supportedFormats.group.<LimitationGroup rawValue>`.
        static func group(_ group: LimitationGroup) -> String { "supportedFormats.group.\(group.rawValue)" }
        /// An importable format: `supportedFormats.format.<ImportFormat rawValue>`.
        static func format(_ format: ImportFormat) -> String { "supportedFormats.format.\(format.rawValue)" }
        /// A limitation: `supportedFormats.limitation.<ConversionLimitation rawValue>`.
        static func limitation(_ limitation: ConversionLimitation) -> String {
            "supportedFormats.limitation.\(limitation.rawValue)"
        }
        /// A kind of file that can't be imported: `supportedFormats.notSupported.<rawValue>`.
        static func notSupported(_ kind: UnsupportedImportFormat) -> String { "supportedFormats.notSupported.\(kind.rawValue)" }
    }
}
