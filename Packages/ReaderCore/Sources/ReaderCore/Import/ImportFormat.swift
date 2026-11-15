import Foundation

/// A file format the app can import. PDFs are imported as they are; every other format is
/// converted to a PDF at import. The raw values are stored, so never change them.
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
    /// one). Detection does not rely on these alone; see `ImportFormatDetector`.
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
