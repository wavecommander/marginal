import Foundation

/// Something a reader should know before converting a file to a PDF. Identifiers only: the
/// words are written and localised in the app.
public enum ConversionLimitation: String, Codable, Sendable, CaseIterable, Hashable {
    // Common to every converted format.
    case fixedPages
    case reconvertingMakesNewBook
    case originalKeptUsesStorage

    // EPUB.
    case pageNumbersDiffer
    case contentsFromBook
    case someLinksMayNotWork
    case mediaLeftOut

    // Comics and images.
    case pagesArePictures

    // Word, RTF and Pages.
    case layoutMayDiffer
    case commentsNotShown

    // Plain text, Markdown, HTML and web archives.
    case appChoosesTypography
    case remoteImagesNotLoaded

    // Presentations.
    case oneSlidePerPage
    case animationsAndMediaLeftOut
    case speakerNotesNotIncluded
    case fontsMayDiffer

    /// The limitations every converted format shares, in display order.
    public static let common: [ConversionLimitation] = [.fixedPages, .reconvertingMakesNewBook, .originalKeptUsesStorage]

    /// The limitations specific to a group, in display order (without the common ones).
    public static func specific(to group: LimitationGroup) -> [ConversionLimitation] {
        switch group {
        case .epub: [.pageNumbersDiffer, .contentsFromBook, .someLinksMayNotWork, .mediaLeftOut]
        case .comicsAndImages: [.pagesArePictures]
        case .wordProcessing: [.layoutMayDiffer, .commentsNotShown]
        case .textAndWeb: [.appChoosesTypography, .remoteImagesNotLoaded]
        case .presentations: [.oneSlidePerPage, .animationsAndMediaLeftOut, .speakerNotesNotIncluded, .fontsMayDiffer]
        }
    }

    /// Everything that applies to a group, in display order: the group's own, then `common`.
    public static func limitations(for group: LimitationGroup) -> [ConversionLimitation] {
        specific(to: group) + common
    }

}

extension ImportFormat {
    /// Everything that applies to converting this format; empty for PDF, which is not converted.
    public var conversionLimitations: [ConversionLimitation] {
        limitationGroup.map { ConversionLimitation.limitations(for: $0) } ?? []
    }
}
