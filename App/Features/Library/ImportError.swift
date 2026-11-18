import Foundation
import ReaderCore

/// Why an import did not produce a book. `errorDescription` is the text shown in the alert;
/// `shortReason` is the line shown under the file's name in the Convert to PDF sheet's
/// "can't be imported" list.
nonisolated enum ImportError: Error, Equatable, LocalizedError, Sendable {
    /// Neither a PDF nor a format the app recognises (or a PDF that does not open).
    case notAPDF(fileName: String)
    case locked(fileName: String)
    case noPages(fileName: String)
    case unreadable(fileName: String, reason: String)
    case storage(fileName: String, reason: String)
    /// The file is not the PDF the book's notes were made on: its fingerprint, or its full
    /// SHA-256 (the book's `document.sha256`), differs. Refused; nothing is linked or imported.
    case pdfMismatch(bookTitle: String)
    /// Locate PDF…: the file is the PDF another book in the Library already holds (one book per
    /// PDF, owner decision 8, 17 November 2026). `otherTitle` is that book's title.
    case pdfInAnotherBook(bookTitle: String, otherTitle: String)
    /// A format the app recognises but cannot import. `kind` names it; `nil` is a format the app
    /// could convert but has no converter for (yet), or one a converter turned down.
    case unsupportedFormat(fileName: String, kind: UnsupportedImportFormat?)
    /// Copy-protected (DRM): only the seller's app can read it.
    case protected(fileName: String)
    /// The converter could not turn the file into a PDF.
    case conversionFailed(fileName: String, reason: String)
    case cancelled

    /// The file the error is about (empty for `cancelled`, and for `pdfMismatch`, which names the book).
    var fileName: String {
        switch self {
        case .notAPDF(let name), .locked(let name), .noPages(let name), .protected(let name),
             .unreadable(let name, _), .storage(let name, _), .unsupportedFormat(let name, _),
             .conversionFailed(let name, _):
            name
        case .cancelled, .pdfMismatch, .pdfInAnotherBook:
            ""
        }
    }

    /// What a conversion error means for the import of `fileName`.
    static func from(_ error: ConversionError, fileName: String) -> ImportError {
        switch error {
        case .protected: .protected(fileName: fileName)
        case .unsupported: .unsupportedFormat(fileName: fileName, kind: nil)
        case .failed(let reason): .conversionFailed(fileName: fileName, reason: reason)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notAPDF(let name):
            String(localized: "“\(name)” isn't a PDF or another kind of document Tactile Texts can import.",
                   comment: "Import alert message. The argument is the file name.")
        case .locked(let name):
            String(localized: "“\(name)” is password-protected. Remove the password in another app, then import it again.",
                   comment: "Import alert message for a PDF with a password. The argument is the file name.")
        case .noPages(let name):
            String(localized: "“\(name)” has no pages, so there is nothing to read.",
                   comment: "Import alert message. The argument is the file name.")
        case .unreadable(let name, let reason):
            String(localized: "“\(name)” could not be read (\(reason)).",
                   comment: "Import alert message. Arguments: the file name, then the system's reason.")
        case .storage(let name, let reason):
            String(localized: "“\(name)” could not be saved to the Library (\(reason)). Check that the device has enough free space.",
                   comment: "Import alert message. Arguments: the file name, then the system's reason.")
        case .unsupportedFormat(let name, let kind):
            Self.unsupportedDescription(name: name, kind: kind)
        case .protected(let name):
            String(localized: "“\(name)” is copy-protected (DRM), so only the app it came from can open it.",
                   comment: "Import alert message for a DRM-protected book. The argument is the file name.")
        case .conversionFailed(let name, let reason):
            String(localized: "“\(name)” could not be converted to PDF (\(reason)).",
                   comment: "Import alert message. Arguments: the file name, then the converter's reason.")
        case .pdfMismatch(let title):
            String(localized: "This file isn’t the PDF the notes in “\(title)” were made on, so it can’t be linked to that book. Choose the original PDF.",
                   comment: "Alert message when a file chosen with Locate PDF is not the book's PDF. The argument is the book's title.")
        case .pdfInAnotherBook(let title, let other):
            String(localized: "This PDF is already in your Library as “\(other)”, so it can’t also be linked to “\(title)”.",
                   comment: "Alert message when a file chosen with Locate PDF is the PDF of another book. Arguments: the book's title, then the other book's title.")
        case .cancelled:
            String(localized: "The import was cancelled.", comment: "Import alert message.")
        }
    }

    private static func unsupportedDescription(name: String, kind: UnsupportedImportFormat?) -> String {
        switch kind {
        case .kindle:
            String(localized: "“\(name)” is a Kindle book. Tactile Texts can't import Kindle formats such as MOBI and AZW3.",
                   comment: "Import alert message. The argument is the file name.")
        case .djvu:
            String(localized: "“\(name)” is a DjVu document. Tactile Texts can't import DjVu files.",
                   comment: "Import alert message. The argument is the file name.")
        case .comicRar:
            String(localized: "“\(name)” is a RAR archive. Tactile Texts can import comics saved as CBZ or ZIP, but not as CBR or RAR.",
                   comment: "Import alert message. The argument is the file name.")
        case .spreadsheet:
            String(localized: "“\(name)” is a spreadsheet. Tactile Texts can't import spreadsheets.",
                   comment: "Import alert message. The argument is the file name.")
        case .fixedLayoutEPUB:
            String(localized: "“\(name)” is a fixed-layout EPUB. Tactile Texts can import only EPUB books whose text can reflow.",
                   comment: "Import alert message. The argument is the file name.")
        case .protectedEPUB:
            String(localized: "“\(name)” is copy-protected (DRM), so only the app it came from can open it.",
                   comment: "Import alert message for a DRM-protected book. The argument is the file name.")
        case nil:
            String(localized: "Tactile Texts can't convert “\(name)” to PDF.",
                   comment: "Import alert message for a recognised format the app cannot convert. The argument is the file name.")
        }
    }

    /// Short title for the alert.
    var alertTitle: String {
        switch self {
        case .notAPDF:
            String(localized: "Can't Import This File", comment: "Import alert title: the file is not a supported kind.")
        case .locked:
            String(localized: "PDF Is Locked", comment: "Import alert title.")
        case .noPages:
            String(localized: "Empty Document", comment: "Import alert title: the file has no pages.")
        case .unreadable, .storage:
            String(localized: "Couldn't Import", comment: "Import alert title.")
        case .unsupportedFormat:
            String(localized: "Can't Import This Kind of File", comment: "Import alert title.")
        case .protected:
            String(localized: "Copy-Protected Book", comment: "Import alert title: the file has DRM.")
        case .conversionFailed:
            String(localized: "Couldn't Convert", comment: "Import alert title: converting the file to PDF failed.")
        case .pdfMismatch, .pdfInAnotherBook:
            String(localized: "Wrong PDF", comment: "Import alert title: the chosen file is not the book's PDF.")
        case .cancelled:
            String(localized: "Import Cancelled", comment: "Import alert title.")
        }
    }

    /// One sentence for the Convert to PDF sheet's "can't be imported" list, shown under the
    /// file's name (so it does not repeat the name).
    var shortReason: String {
        switch self {
        case .notAPDF:
            String(localized: "Not a PDF or another kind of document Tactile Texts can import.",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name.")
        case .locked:
            String(localized: "The PDF is password-protected.",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name.")
        case .noPages:
            String(localized: "It has no pages.",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name.")
        case .unreadable(_, let reason):
            String(localized: "It could not be read (\(reason)).",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name. The argument is the system's reason.")
        case .storage(_, let reason):
            String(localized: "It could not be saved (\(reason)).",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name. The argument is the system's reason.")
        case .unsupportedFormat(_, let kind):
            Self.unsupportedShortReason(kind)
        case .protected:
            String(localized: "Copy-protected (DRM): only the app it came from can open it.",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name.")
        case .conversionFailed(_, let reason):
            String(localized: "It could not be converted (\(reason)).",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name. The argument is the converter's reason.")
        case .pdfMismatch:
            String(localized: "It isn’t the PDF this book’s notes were made on.",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name.")
        case .pdfInAnotherBook(_, let other):
            String(localized: "It’s already in your Library as “\(other)”.",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name. The argument is the other book's title.")
        case .cancelled:
            String(localized: "Cancelled.", comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name.")
        }
    }

    private static func unsupportedShortReason(_ kind: UnsupportedImportFormat?) -> String {
        switch kind {
        case .kindle:
            String(localized: "Kindle books (MOBI, AZW3) can't be imported.",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name.")
        case .djvu:
            String(localized: "DjVu documents can't be imported.",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name.")
        case .comicRar:
            String(localized: "RAR archives (CBR) can't be imported. CBZ and ZIP comics can.",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name.")
        case .spreadsheet:
            String(localized: "Spreadsheets can't be imported.",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name.")
        case .fixedLayoutEPUB:
            String(localized: "Fixed-layout EPUB books can't be imported.",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name.")
        case .protectedEPUB:
            String(localized: "Copy-protected (DRM): only the app it came from can open it.",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name.")
        case nil:
            String(localized: "Tactile Texts can't convert this kind of file to PDF.",
                   comment: "Convert to PDF sheet, 'can't be imported' list: reason under a file name.")
        }
    }
}
