import Foundation
import ReaderBackup
import UIKit
import UniformTypeIdentifiers

/// What happens when a file arrives from outside the app (Files "Open With", the share sheet,
/// AirDrop, another app).
///
/// - A **document** is imported through the shared `ImportService` (so with the same detection,
///   fingerprint check, copy, cover, Convert to PDF sheet and errors as the Files picker) and
///   shown in the window that received it, after the scanned-book notice when detection finds
///   it scanned (S3). A document already in the Library opens the existing book; one that
///   needs converting shows the Convert to PDF sheet in that window's Library, and the
///   converted book opens there once the reader chooses Convert.
/// - A **backup** (`.ttbackup`) opens the restore sheet in the window that received it; an
///   Inbox copy is deleted when the sheet closes.
///
/// Called on the main actor by `AppEnvironment.handleIncomingPDF(_:in:)` from the `.onOpenURL`
/// of the window that received the URL. A failure is shown as an alert in that window's Library
/// (the window first returns to its Library).
@MainActor
enum IncomingDocumentHandler {
    static func handle(_ url: URL, environment: AppEnvironment, window: WindowContext) {
        guard url.isFileURL else { return }
        if isBackup(url) {
            window.openRestore(RestoreRequest(source: .file(url, consume: isInInbox(url))))
            return
        }
        Task {
            let service = await environment.readyImportService()
            let results = await service.importFiles([url], consumeSources: isInInbox(url),
                                                    requester: ObjectIdentifier(window), opensBookWhenDone: true)
            guard let result = results.first else { return }
            if let book = result.book {
                // A scanned book: its notice comes first, in this window's Library (S3).
                if let notice = service.scanNotices.notice(about: book.id) {
                    window.backToLibrary()
                    // The window may be closed with the notice unanswered: the notice is then
                    // dropped, so this wait ends and no notice is left for a window that is gone.
                    let notices = service.scanNotices
                    let closed = window.scene.map { scene in
                        NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification,
                                                               object: scene, queue: .main) { _ in
                            MainActor.assumeIsolated { notices.drop(notice.id) }
                        }
                    }
                    await notices.waitUntilAnswered(notice.id)
                    if let closed { NotificationCenter.default.removeObserver(closed) }
                    // Closed meanwhile: there is no window left to open the book in.
                    if closed != nil, window.scene.map({ $0.activationState == .unattached }) ?? true { return }
                }
                window.openReader(bookID: book.id)
            } else if result.conversionRequestID != nil {
                window.backToLibrary()  // the sheet is the Library's
            } else if let error = result.alertError, error != .cancelled {
                window.backToLibrary()
                service.present([error], in: ObjectIdentifier(window))
            }
        }
    }

    /// A `.ttbackup` name, or a type the system resolves to the backup type. Checked before
    /// anything is imported: a backup is a ZIP by content, and must never reach the importer,
    /// which would take it for a comic archive.
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
