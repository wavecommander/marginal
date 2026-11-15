import Foundation
import UIKit

/// What a text, Office or slide conversion measured, for tests and diagnostics: each printed
/// part's print report, how the outline and links were placed, the page the document was printed
/// on, which resources were requested, and notes on decisions taken on the way. Thread-safe.
nonisolated final class WebConversionDiagnostics: @unchecked Sendable {
    struct Part: Sendable {
        var pageCount: Int
        var print: WebPrintReport
    }

    private let lock = NSLock()
    private var storedParts: [Part] = []
    private var storedOutline = WebOutlineStatistics()
    private var storedLinks = WebLinkStatistics()
    private var storedRequests: [WebResourceRequestRecord] = []
    private var storedPage: (size: CGSize, margins: UIEdgeInsets)?
    private var storedNotes: [String] = []
    private var storedLoadSeconds: TimeInterval = 0

    init() {}

    var parts: [Part] { lock.withLock { storedParts } }
    var outline: WebOutlineStatistics { lock.withLock { storedOutline } }
    var links: WebLinkStatistics { lock.withLock { storedLinks } }
    var requests: [WebResourceRequestRecord] { lock.withLock { storedRequests } }
    var pageSize: CGSize? { lock.withLock { storedPage?.size } }
    var margins: UIEdgeInsets? { lock.withLock { storedPage?.margins } }
    var notes: [String] { lock.withLock { storedNotes } }
    /// Seconds from starting the load to the document being ready to print.
    var loadSeconds: TimeInterval { lock.withLock { storedLoadSeconds } }
    /// The longest the main thread was held by printing, over all parts.
    var longestMainThreadSlice: TimeInterval { parts.map(\.print.longestMainThreadSlice).max() ?? 0 }

    func record(parts: [WebPrintedPart]) {
        lock.withLock { storedParts += parts.map { Part(pageCount: $0.pageCount, print: $0.report) } }
    }

    func record(outline: WebOutlineStatistics, links: WebLinkStatistics) {
        lock.withLock { storedOutline = outline; storedLinks = links }
    }

    func record(requests: [WebResourceRequestRecord]) { lock.withLock { storedRequests = requests } }
    func record(pageSize: CGSize, margins: UIEdgeInsets) { lock.withLock { storedPage = (pageSize, margins) } }
    func note(_ text: String) { lock.withLock { storedNotes.append(text) } }
    func record(loadSeconds: TimeInterval) { lock.withLock { storedLoadSeconds = loadSeconds } }
}
