import Foundation

/// A file format the app can import. PDFs are imported as they are; every other format is
/// converted to a PDF at import. The raw values are stored, so never change them.
///
/// **The one list of what is importable.** A format's file name extensions and uniform type
/// identifiers are written once, here (and for the kinds the app turns down by name, on
/// `UnsupportedImportFormat`). Everything else is derived from them: detection by extension
/// (`ImportFormatDetector`), Settings ▸ Supported Formats, what the Files picker and drops accept
/// (`ImportContentTypes`), and the MIME type a file is handed to WebKit with. The app's
/// `Info.plist` cannot be derived (it is written by XcodeGen from `project.yml`), so
/// `ImportFormatCatalogTests` in the app's tests fails when its "Open in" document types or its
/// type declarations disagree with this list.
public enum ImportFormat: String, Codable, Sendable, CaseIterable, Hashable {
    case pdf, epub, comicArchive, image, plainText, markdown, html, webArchive
    case word, rtf, pages, powerPoint, keynote

    /// Which converter turns this format into a PDF.
    public var converterFamily: ConverterFamily {
        switch self {
        case .pdf: .none
        case .comicArchive, .image: .images
        case .epub, .plainText, .markdown, .html, .webArchive, .word, .rtf, .pages, .powerPoint, .keynote: .web
        }
    }

    /// The group whose limitations the import sheet shows, or `nil` for PDFs (not converted).
    public var limitationGroup: LimitationGroup? {
        switch self {
        case .pdf: nil
        case .epub: .epub
        case .comicArchive, .image: .comicsAndImages
        case .word, .rtf, .pages: .wordProcessing
        case .plainText, .markdown, .html, .webArchive: .textAndWeb
        case .powerPoint, .keynote: .presentations
        }
    }

    /// Whether the file is converted to a PDF at import.
    public var isConverted: Bool { self != .pdf }

    /// Lower-case file name extensions usually seen for this format (first is the canonical
    /// one): the ones Settings ▸ Supported Formats lists. Detection does not rely on these
    /// alone; see `ImportFormatDetector`.
    public var fileExtensions: [String] {
        switch self {
        case .pdf: ["pdf"]
        case .epub: ["epub"]
        case .comicArchive: ["cbz", "zip"]
        case .image: ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp", "avif"]
        case .plainText: ["txt", "text"]
        case .markdown: ["md", "markdown", "mdown", "mkd"]
        case .html: ["html", "htm", "xhtml"]
        case .webArchive: ["webarchive"]
        case .word: ["docx", "doc", "docm", "dotx"]
        case .rtf: ["rtf"]
        case .pages: ["pages"]
        case .powerPoint: ["pptx", "ppt", "pptm", "ppsx", "pps"]
        case .keynote: ["key"]
        }
    }

    /// Rarer spellings of the same format that the app also takes but does not list.
    public var unlistedFileExtensions: [String] {
        switch self {
        case .image: ["jpe", "dib"]
        case .word: ["dot"]
        case .powerPoint: ["pot"]
        case .pdf, .epub, .comicArchive, .plainText, .markdown, .html, .webArchive, .rtf, .pages, .keynote: []
        }
    }

    /// Every extension the app takes for this format: `fileExtensions`, then
    /// `unlistedFileExtensions`.
    public var allFileExtensions: [String] { fileExtensions + unlistedFileExtensions }

    /// Those of `allFileExtensions` that name the pre-2007 binary (OLE) Office form of the
    /// format. Empty for formats that have none.
    public var binaryOfficeFileExtensions: [String] {
        switch self {
        case .word: ["doc", "dot"]
        case .powerPoint: ["ppt", "pps", "pot"]
        default: []
        }
    }

    /// The uniform type identifiers a file of this format can carry: what the app's "Open in"
    /// document types declare and what the Files picker and drops accept. A type that covers a
    /// whole family (`public.image`) stands for every member of it.
    public var typeIdentifiers: [String] {
        switch self {
        case .pdf: ["com.adobe.pdf"]
        case .epub: ["org.idpf.epub-container"]
        case .comicArchive: ["software.tactile.texts.cbz", "public.zip-archive"]
        case .image: ["public.image"]
        case .plainText: ["public.plain-text"]
        case .markdown: ["net.daringfireball.markdown"]
        case .html: ["public.html", "public.xhtml"]
        case .webArchive: ["com.apple.webarchive"]
        case .word: [
            "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
            "org.openxmlformats.wordprocessingml.document.macroenabled",
            "org.openxmlformats.wordprocessingml.template", "com.microsoft.word.dot",
        ]
        case .rtf: ["public.rtf"]
        case .pages: ["com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages"]
        case .powerPoint: [
            "org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt",
            "org.openxmlformats.presentationml.presentation.macroenabled",
            "org.openxmlformats.presentationml.slideshow", "com.microsoft.powerpoint.pps",
            "com.microsoft.powerpoint.pot",
        ]
        case .keynote: ["com.apple.iwork.keynote.sffkey", "com.apple.iwork.keynote.key"]
        }
    }

    /// The format, among `candidates`, that takes `fileExtension` (lower case, no dot).
    public static func format(forFileExtension fileExtension: String,
                              among candidates: [ImportFormat] = ImportFormat.allCases) -> ImportFormat? {
        candidates.first { $0.allFileExtensions.contains(fileExtension) }
    }
}

/// The lists derived from every format at once.
public enum ImportFormatCatalog {
    /// The type identifiers of every importable format, in `ImportFormat.allCases` order: the
    /// app's "Open in" document types, and what the Files picker and drops accept.
    public static var importableTypeIdentifiers: [String] { ImportFormat.allCases.flatMap(\.typeIdentifiers) }

    /// The type identifiers of the kinds of file the app recognises and turns down by name: the
    /// Files picker and drops accept them too, so the app can say why.
    public static var namedUnsupportedTypeIdentifiers: [String] {
        UnsupportedImportFormat.allCases.flatMap(\.typeIdentifiers)
    }

    /// A type the app declares itself (`UTImportedTypeDeclarations` in its `Info.plist`),
    /// because the system does not, or may not, know it.
    public struct DeclaredType: Hashable, Sendable {
        public let identifier: String
        public let fileExtensions: [String]
    }

    /// The types the app's `Info.plist` must declare, with the extensions each declaration
    /// must carry: the app's own (comics, and the kinds it names when it turns them down), and
    /// the system types a device may lack (Markdown; the iWork packages on a device without
    /// Pages or Keynote).
    public static var declaredTypes: [DeclaredType] {
        [
            DeclaredType(identifier: "software.tactile.texts.cbz", fileExtensions: ["cbz"]),
            DeclaredType(identifier: "software.tactile.texts.cbr", fileExtensions: ["cbr"]),
            DeclaredType(identifier: "software.tactile.texts.kindle-book",
                         fileExtensions: UnsupportedImportFormat.kindle.fileExtensions),
            DeclaredType(identifier: "software.tactile.texts.djvu", fileExtensions: UnsupportedImportFormat.djvu.fileExtensions),
            DeclaredType(identifier: "net.daringfireball.markdown", fileExtensions: ImportFormat.markdown.allFileExtensions),
            DeclaredType(identifier: "com.apple.iwork.pages.pages", fileExtensions: ImportFormat.pages.allFileExtensions),
            DeclaredType(identifier: "com.apple.iwork.keynote.key", fileExtensions: ImportFormat.keynote.allFileExtensions),
        ]
    }
}

/// The converter that handles a format.
public enum ConverterFamily: String, Codable, Sendable, CaseIterable, Hashable {
    /// Not converted (PDF).
    case none
    /// Pictures laid out one per page (comic archives, single images).
    case images
    /// Rendered as a web page and paginated (EPUB, text, Office and iWork documents).
    case web
}

/// The groups the import sheet explains limitations for. Each converted format belongs to one.
public enum LimitationGroup: String, Codable, Sendable, CaseIterable, Hashable {
    case epub
    case comicsAndImages
    /// Word, RTF and Pages.
    case wordProcessing
    /// Plain text, Markdown, HTML and web archives.
    case textAndWeb
    /// PowerPoint and Keynote.
    case presentations

    /// The formats in this group, in `ImportFormat.allCases` order.
    public var formats: [ImportFormat] {
        ImportFormat.allCases.filter { $0.limitationGroup == self }
    }

    /// Whether the import sheet offers a text-size choice for this group (reflowable text only).
    public var offersTextSizeChoice: Bool {
        switch self {
        case .epub, .textAndWeb: true
        case .comicsAndImages, .wordProcessing, .presentations: false
        }
    }

    /// The limitations of converting a file in this group: the group's own, then the common ones.
    public var limitations: [ConversionLimitation] { ConversionLimitation.limitations(for: self) }
}
