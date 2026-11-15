import Foundation
import ReaderBackup
import UniformTypeIdentifiers

/// What happens when a file arrives from outside the app (Files "Open With", the share sheet,
/// AirDrop, another app).
///
/// - A **PDF** is imported through the shared `ImportService` (so with the same fingerprint
///   check, copy, cover and errors as the Files picker) and shown in the window that received
///   it. A PDF already in the Library opens the existing book. A failure is shown as an alert in
///   that window's Library (the window first returns to its Library).
/// - A **backup** (`.ttbackup`) opens the restore sheet in the window that received it; the
///   Inbox copy is deleted when the sheet closes.
///
/// Called on the main actor by `AppEnvironment.handleIncomingPDF(_:in:)` from the `.onOpenURL`
/// of the window that received the URL.
@MainActor
enum IncomingPDFHandler {
    static func handle(_ url: URL, environment: AppEnvironment, window: WindowContext) {
        guard url.isFileURL else { return }
        if isBackup(url) {
            window.openRestore(RestoreRequest(source: .file(url, consume: isInInbox(url))))
            return
        }
        guard isPDF(url) else { return }
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

    /// A `.ttbackup` name, or a type the system resolves to the backup type.
    static func isBackup(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == BackupFormat.fileExtension { return true }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .tactileTextsBackup) ?? false
    }

    /// A file sent through the share sheet is copied into `<Documents>/Inbox`; that copy is the
    /// app's to consume. A file opened from Files ("Open With", or tapping a backup) arrives where
    /// it is, security-scoped: it is the reader's own file and is only read, never removed
    /// (`ImportService` and `BackupService.openBackup(at:)` hold the access they need).
    static func isInInbox(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "Inbox"
    }
}
