import Foundation

/// PLACEHOLDER owned by WP3: what happens when a PDF arrives from outside the app (Files
/// "Open in", AirDrop, another app). Keep the type name and the `handle` signature; replace the
/// body with the real import pipeline (progress, dedupe, security-scoped access, errors).
///
/// Called on the main actor by `AppEnvironment.handleIncomingPDF(_:in:)` from the `.onOpenURL`
/// of the window that received the URL.
@MainActor
enum IncomingPDFHandler {
    static func handle(_ url: URL, environment: AppEnvironment, window: WindowContext) {
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return }
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let book = try? await environment.fixtureImporter.importPDF(at: url) {
                window.openReader(bookID: book.id)
            }
        }
    }
}
