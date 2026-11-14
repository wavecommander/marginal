import Foundation
import UniformTypeIdentifiers

/// What happens when a PDF arrives from outside the app (Files "Open in", AirDrop, another app):
/// it is imported through the shared `ImportService` (so with the same fingerprint check, copy,
/// cover and errors as the Files picker) and shown in the window that received it. A PDF
/// already in the Library opens the existing book.
///
/// Called on the main actor by `AppEnvironment.handleIncomingPDF(_:in:)` from the `.onOpenURL`
/// of the window that received the URL. A failure is shown as an alert in that window's Library
/// (the window first returns to its Library).
@MainActor
enum IncomingPDFHandler {
    static func handle(_ url: URL, environment: AppEnvironment, window: WindowContext) {
        guard url.isFileURL, isPDF(url) else { return }
        Task {
            let service = await environment.readyImportService()
            let results = await service.importFiles([url], consumeSources: isInInbox(url))
            if let book = results.first?.book {
                window.openReader(bookID: book.id)
            } else if let error = results.first?.error, error != .cancelled {
                window.backToLibrary()
                service.present([error], in: ObjectIdentifier(window))
            }
        }
    }

    /// A `.pdf` name, or a type the system resolves to PDF. (Content is checked by the import.)
    static func isPDF(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "pdf" { return true }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) ?? false
    }

    /// "Open in" copies the file into `<Documents>/Inbox` (the app does not open documents in
    /// place); that copy is the app's to consume.
    static func isInInbox(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "Inbox"
    }
}
