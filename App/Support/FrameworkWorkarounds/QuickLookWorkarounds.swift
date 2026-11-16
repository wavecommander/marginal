import Foundation
import ReaderCore

/// Everything the app does that depends on how QuickLook converts Office and iWork documents
/// inside WebKit, rather than on a documented API: one function per workaround, each saying what
/// it works around. What each one leans on is pinned by `FrameworkWorkaroundCanaryTests`.
///
/// Not here: what the converters read out of the page QuickLook produces (its page boxes and
/// slide boxes), which is the converters' own work (`OfficeDocumentConverter`,
/// `SlidesConverter`).
nonisolated enum QuickLookWorkarounds {
    /// The URL scheme the pictures of a converted Office or iWork document are served under.
    ///
    /// Works around: when WebKit converts such a document itself (through QuickLook), the pictures
    /// of the converted page are served from the converted package in memory under this private
    /// scheme. The converters' network block has to let it through
    /// (`WebKitWorkarounds.ruleListBlockingEverything(except:)`): blocked, every picture in a Word
    /// file or a slide is lost. Nothing under it reaches the network.
    static let convertedResourceScheme = "x-apple-ql-id"

    /// The MIME type that makes WebKit hand a file to QuickLook's converter.
    ///
    /// Works around: WebKit decides by the response's MIME type whether to convert an Office or
    /// iWork file to a web page, and the types that work are not documented. Found on the
    /// iOS 27 simulator: `text/rtf` shows the RTF source as text and
    /// `application/vnd.apple.pages`/`…keynote` fail the load, so these are the ones that work.
    static func mimeType(forFileExtension ext: String, format: ImportFormat) -> String {
        let ext = ext.lowercased()
        // The extension decides when it names one of these formats (`ImportFormat`'s one list of
        // extensions); a file with any other name goes by the format it was detected as.
        let named = ImportFormat.format(forFileExtension: ext, among: [.word, .powerPoint, .pages, .keynote, .rtf])
        let isBinary = named?.binaryOfficeFileExtensions.contains(ext) ?? false
        switch named ?? format {
        case .word: return isBinary ? "application/msword" : "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .powerPoint:
            return isBinary ? "application/vnd.ms-powerpoint" : "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case .pages: return "application/x-iwork-pages-sffpages"
        case .keynote: return "application/x-iwork-keynote-sffkey"
        case .rtf where named != nil: return "application/rtf"
        default: return "application/octet-stream"
        }
    }
}
