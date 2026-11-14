import Foundation

/// Why an import did not produce a book. `errorDescription` is the text shown in the alert.
nonisolated enum ImportError: Error, Equatable, LocalizedError, Sendable {
    case notAPDF(fileName: String)
    case locked(fileName: String)
    case noPages(fileName: String)
    case unreadable(fileName: String, reason: String)
    case storage(fileName: String, reason: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notAPDF(let name):
            "“\(name)” is not a PDF document, so it can't be added to the Library."
        case .locked(let name):
            "“\(name)” is password-protected. Remove the password in another app, then import it again."
        case .noPages(let name):
            "“\(name)” has no pages, so there is nothing to read."
        case .unreadable(let name, let reason):
            "“\(name)” could not be read (\(reason))."
        case .storage(let name, let reason):
            "“\(name)” could not be saved to the Library (\(reason)). Check that the device has enough free space."
        case .cancelled:
            "The import was cancelled."
        }
    }

    /// Short title for the alert.
    var alertTitle: String {
        switch self {
        case .notAPDF: "Not a PDF"
        case .locked: "PDF Is Locked"
        case .noPages: "Empty PDF"
        case .unreadable, .storage: "Couldn't Import"
        case .cancelled: "Import Cancelled"
        }
    }
}
