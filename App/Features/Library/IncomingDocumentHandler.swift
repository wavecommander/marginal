import Foundation

/// What happens when a document arrives from outside the app (Files "Open in", AirDrop, another
/// app): it is imported through the shared `ImportService` (so with the same detection,
/// fingerprint check, copy, cover, Convert to PDF sheet and errors as the Files picker) and
/// shown in the window that received it. A document already in the Library opens the existing
/// book; one that needs converting shows the Convert to PDF sheet in that window's Library, and
/// the converted book opens there once the reader chooses Convert.
///
/// Called on the main actor by `AppEnvironment.handleIncomingPDF(_:in:)` from the `.onOpenURL`
/// of the window that received the URL. A failure is shown as an alert in that window's Library
/// (the window first returns to its Library).
@MainActor
enum IncomingDocumentHandler {
    static func handle(_ url: URL, environment: AppEnvironment, window: WindowContext) {
        guard url.isFileURL else { return }
        Task {
            let service = await environment.readyImportService()
            let results = await service.importFiles([url], consumeSources: isInInbox(url),
                                                    requester: ObjectIdentifier(window), opensBookWhenDone: true)
            guard let result = results.first else { return }
            if let book = result.book {
                window.openReader(bookID: book.id)
            } else if result.conversionRequestID != nil {
                window.backToLibrary()  // the sheet is the Library's
            } else if let error = result.alertError, error != .cancelled {
                window.backToLibrary()
                service.present([error], in: ObjectIdentifier(window))
            }
        }
    }

    /// "Open in" copies the file into `<Documents>/Inbox` (the app does not open documents in
    /// place); that copy is the app's to consume.
    static func isInInbox(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "Inbox"
    }
}
