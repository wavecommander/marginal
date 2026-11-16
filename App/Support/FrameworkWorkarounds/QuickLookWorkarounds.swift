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
        switch ext.lowercased() {
        case "docx", "docm", "dotx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "doc", "dot": "application/msword"
        case "pptx", "pptm", "ppsx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "ppt", "pps", "pot": "application/vnd.ms-powerpoint"
        case "pages": "application/x-iwork-pages-sffpages"
        case "key": "application/x-iwork-keynote-sffkey"
        case "rtf": "application/rtf"
        default:
            switch format {
            case .word: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            case .powerPoint: "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            case .pages: "application/x-iwork-pages-sffpages"
            case .keynote: "application/x-iwork-keynote-sffkey"
            default: "application/octet-stream"
            }
        }
    }
}
