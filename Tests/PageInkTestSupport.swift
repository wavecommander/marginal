import Foundation
import PDFKit
import PencilKit
import ReaderCore
import ReaderStore
import UIKit
@testable import Marginal

/// Helpers for the page-ink tests: an ephemeral store with a book, a reader session hosted
/// in a real window of the test host (so PDFKit creates overlays), strokes, and waiting.
@MainActor
enum PageInkTestSupport {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static func fixture(_ name: String) -> URL {
        repoRoot.appendingPathComponent("Fixtures/out/\(name)")
    }

    /// An ephemeral store holding one book whose document is a copy of `pdf`.
    static func makeStore(pdf: URL, pageCount: Int) throws -> (LibraryStore, Book) {
        let store = try LibraryStore.ephemeral()
        let book = Book(title: "Ink", fingerprint: "ink-test-\(UUID().uuidString)", fileName: "ink.pdf",
                        pageCount: pageCount, fileSize: 1)
        try store.books.save(book)
        let url = store.documentURL(for: book)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: pdf, to: url)
        return (store, book)
    }

    /// An ephemeral store with one book and no document (for surfaces without a PDF view).
    static func makeStore() throws -> (LibraryStore, Book) {
        let store = try LibraryStore.ephemeral()
        let book = Book(title: "Ink", fingerprint: "ink-test-\(UUID().uuidString)", fileName: "ink.pdf",
                        pageCount: 20, fileSize: 1)
        try store.books.save(book)
        return (store, book)
    }

    /// A reader session on `book`, hosted in its own window of the test host's scene.
    @MainActor
    final class Host {
        let session: ReaderSession
        let window: UIWindow
        let hostView: ReaderPDFHostView

        init(book: Book, store: LibraryStore, size: CGSize = CGSize(width: 800, height: 1000),
             configure: (inout ReaderSession.Configuration) -> Void = { _ in }) {
            var configuration = ReaderSession.Configuration()
            configuration.lastReadSaveDelay = .milliseconds(100)
            configure(&configuration)
            session = ReaderSession(book: book, store: store, configuration: configuration)
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            let controller = UIViewController()
            hostView = ReaderPDFHostView(controller: session.pdf, responderView: session.markup.responderView,
                                         anchorProbe: session.pdf.anchorProbe)
            hostView.frame = CGRect(origin: .zero, size: size)
            controller.view.addSubview(hostView)
            window.rootViewController = controller
            window.isHidden = false
            session.open()
        }

        var provider: PageInkOverlayProvider? {
            session.pageInk
        }

        var pdfView: ReaderPDFView { session.pdf.view }

        /// Resizes the window and the PDF view (as a window resize or rotation does).
        func resize(to size: CGSize) {
            window.frame = CGRect(origin: .zero, size: size)
            hostView.frame = CGRect(origin: .zero, size: size)
            hostView.layoutIfNeeded()
        }

        func close() async {
            await session.suspend()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// A straight stroke in ink space, with a unique creation date.
    static func stroke(from start: CGPoint, to end: CGPoint, ink: PKInk.InkType = .pen, width: CGFloat = 3,
                       color: UIColor = .systemBlue) -> PKStroke {
        NotePageTestSupport.stroke(from: start, to: end, ink: ink, width: width, color: color)
    }

    /// Polls `condition` on the main actor.
    static func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Lets the run loop turn for `seconds`.
    static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// Writes a PDF of `sizes.count` pages, page `i` sized `sizes[i]`, with text, then applies
    /// rotations and crop boxes through PDFKit (in the file: `/Rotate` and `/CropBox`).
    static func makePDF(sizes: [CGSize], rotations: [Int] = [], cropInsets: [UIEdgeInsets?] = []) throws -> URL {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for (index, size) in sizes.enumerated() {
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            UIGraphicsPushContext(context)
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            let text = "Page \(index + 1) top-left marker text for ink registration tests" as NSString
            text.draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            UIGraphicsPopContext()
            context.endPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else { throw CocoaError(.fileReadCorruptFile) }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if index < rotations.count { page.rotation = rotations[index] }
            if index < cropInsets.count, let insets = cropInsets[index] {
                let media = page.bounds(for: .mediaBox)
                let crop = CGRect(x: media.minX + insets.left, y: media.minY + insets.bottom,
                                  width: media.width - insets.left - insets.right,
                                  height: media.height - insets.top - insets.bottom)
                page.setBounds(crop, for: .cropBox)
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ink-\(UUID().uuidString).pdf")
        guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
