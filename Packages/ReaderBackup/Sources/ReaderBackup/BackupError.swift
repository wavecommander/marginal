import Foundation

/// Every failure this package reports, with a message a reader can act on.
///
/// The messages avoid format jargon (no "ZIP", "CRC", "manifest"): the reader sees them in an
/// alert after tapping Back Up or Restore. Associated `String`s that name a file are the file's
/// name or its path inside the backup, which is what the reader would recognise. Cancellation is
/// not a case here: cancelled work throws `CancellationError`, which callers treat as "stopped",
/// not as a failure.
public enum BackupError: LocalizedError, Hashable, Sendable {
    // MARK: Archive structure

    /// The file ends early (it did not finish copying or downloading) or is not an archive.
    case archiveIncomplete
    /// The archive's structure is inconsistent. `detail` is for logs, not shown to the reader.
    case archiveDamaged(detail: String)
    /// An item is compressed. This package only reads the stored archives it writes.
    case compressedEntry(name: String)
    /// An item is encrypted.
    case encryptedEntry(name: String)
    /// An item's name could escape the folder it is extracted into (absolute, `..`, a backslash
    /// or a NUL), or is otherwise not a plain relative path.
    case unsafeEntryName(name: String)
    /// Two items have the same name.
    case duplicateEntryName(name: String)
    /// The archive has no item with this name.
    case entryNotFound(name: String)
    /// An item's bytes do not match the checksum recorded for it: the file was damaged.
    case entryChecksumMismatch(name: String)
    /// An item is larger than the caller allows reading into memory.
    case entryTooLarge(name: String)

    // MARK: Writing

    /// A file changed size while it was being backed up.
    case sourceFileChanged(name: String)
    /// The archive writer was used after it finished or failed (a programming error).
    case writerClosed

    // MARK: Backup contents

    /// The file is not a Tactile Texts backup (no manifest, or the wrong format name).
    case notABackup
    /// The backup was made by a newer version of the app, with this format version.
    case newerFormatVersion(Int)
    /// The manifest could not be decoded or breaks a rule. `detail` is for logs.
    case manifestInvalid(detail: String)
    /// A book's saved notes, highlights, bookmarks or headings could not be read, or belong to a
    /// different book.
    case recordsInvalid(bookTitle: String)
    /// The backup does not contain this book.
    case bookNotInBackup(UUID)
    /// The backup does not contain a PDF with this SHA-256.
    case pdfNotInBackup(sha256: String)
    /// A file's size or SHA-256 differs from what the backup recorded for it.
    case contentMismatch(name: String)
    /// A file the backup lists is not in it.
    case missingFile(name: String)
    /// The backup holds a file it does not list.
    case unexpectedFile(name: String)
    /// A book's records do not all belong to it (`BookArchive.isConsistent` is false).
    case inconsistentBook(bookTitle: String)
    /// A book was given twice to the backup writer.
    case duplicateBook(bookTitle: String)
    /// A book's PDF is not on disk and its hash was not supplied, so the backup cannot say which
    /// PDF the book needs.
    case pdfHashUnavailable(bookTitle: String)

    // MARK: Destinations

    /// The destination cannot be used now. `reason` is reader-facing.
    case destinationUnavailable(reason: String)
    /// The snapshot is no longer at the destination.
    case snapshotNotFound(name: String)
    /// A snapshot name is not a valid backup file name.
    case invalidSnapshotName(name: String)
    /// The destination holds no PDF with this SHA-256.
    case pdfNotAtDestination(sha256: String)

    // MARK: Files

    /// A file or folder does not exist.
    case fileNotFound(name: String)
    /// The app is not allowed to read or write this file or folder.
    case permissionDenied(name: String)
    /// The disk is full.
    case notEnoughSpace
    /// Any other file-system failure. `code` is the POSIX or Cocoa error code, for logs.
    case fileAccessFailed(name: String, code: Int)

    public var errorDescription: String? {
        switch self {
        case .archiveIncomplete:
            "The backup file is incomplete or isn’t a Tactile Texts backup. If it was being copied or downloaded, wait until that finishes and try again."
        case .archiveDamaged:
            "The backup file is damaged and can’t be read."
        case .compressedEntry(let name):
            "The backup file has been changed by another app (“\(name)” was compressed), so Tactile Texts can’t read it. Use the original backup file."
        case .encryptedEntry(let name):
            "Part of the backup file (“\(name)”) is password-protected, so Tactile Texts can’t read it. Use the original backup file."
        case .unsafeEntryName(let name):
            "The backup file contains an item with an unsafe name (“\(name)”), so Tactile Texts won’t open it."
        case .duplicateEntryName(let name):
            "The backup file contains “\(name)” twice, so it can’t be trusted. Use the original backup file."
        case .entryNotFound(let name):
            "Part of the backup (“\(name)”) is missing."
        case .entryChecksumMismatch(let name):
            "Part of the backup (“\(name)”) is damaged."
        case .entryTooLarge(let name):
            "Part of the backup (“\(name)”) is too large to read."
        case .sourceFileChanged(let name):
            "“\(name)” changed while it was being backed up. Try backing up again."
        case .writerClosed:
            "The backup could not be finished. Try backing up again."
        case .notABackup:
            "This file isn’t a Tactile Texts backup."
        case .newerFormatVersion:
            "This backup was made by a newer version of Tactile Texts. Update the app to restore it."
        case .manifestInvalid:
            "The backup’s list of books is damaged, so it can’t be restored."
        case .recordsInvalid(let title):
            "The notes and highlights saved for “\(title)” are damaged, so that book can’t be restored."
        case .bookNotInBackup:
            "That book isn’t in this backup."
        case .pdfNotInBackup:
            "This backup doesn’t contain that PDF."
        case .contentMismatch(let name):
            "Part of the backup (“\(name)”) doesn’t match what was saved. The backup may be damaged."
        case .missingFile(let name):
            "Part of the backup (“\(name)”) is missing. The backup may be damaged."
        case .unexpectedFile(let name):
            "The backup contains something it doesn’t list (“\(name)”). The backup may have been changed by another app."
        case .inconsistentBook(let title):
            "The notes and highlights for “\(title)” are mixed up with another book’s, so it can’t be backed up."
        case .duplicateBook(let title):
            "“\(title)” was included in the backup twice."
        case .pdfHashUnavailable(let title):
            "The PDF for “\(title)” is missing, so the backup can’t record which PDF the book needs."
        case .destinationUnavailable(let reason):
            reason
        case .snapshotNotFound(let name):
            "The backup “\(name)” is no longer there. It may have been moved or deleted."
        case .invalidSnapshotName(let name):
            "“\(name)” isn’t a valid backup name."
        case .pdfNotAtDestination:
            "The PDF isn’t in the backup location."
        case .fileNotFound(let name):
            "“\(name)” can’t be found. It may have been moved or deleted."
        case .permissionDenied(let name):
            "Tactile Texts doesn’t have permission to use “\(name)”."
        case .notEnoughSpace:
            "There isn’t enough free space. Free up some space and try again."
        case .fileAccessFailed(let name, _):
            "Tactile Texts couldn’t read or write “\(name)”."
        }
    }
}

// MARK: - Mapping file-system errors

extension BackupError {
    /// Maps a POSIX `errno` for `url` to a reader-facing case.
    static func posix(_ code: Int32, _ url: URL) -> BackupError {
        let name = url.lastPathComponent
        switch code {
        case ENOENT, ENOTDIR: return .fileNotFound(name: name)
        case EACCES, EPERM, EROFS: return .permissionDenied(name: name)
        case ENOSPC, EDQUOT: return .notEnoughSpace
        default: return .fileAccessFailed(name: name, code: Int(code))
        }
    }

    /// Maps any error thrown by Foundation for `url`; `BackupError` and `CancellationError` pass
    /// through unchanged.
    static func wrapping(_ error: any Error, _ url: URL) -> any Error {
        if error is BackupError || error is CancellationError { return error }
        let name = url.lastPathComponent
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileNoSuchFile, .fileReadNoSuchFile: return BackupError.fileNotFound(name: name)
            case .fileReadNoPermission, .fileWriteNoPermission, .fileWriteVolumeReadOnly:
                return BackupError.permissionDenied(name: name)
            case .fileWriteOutOfSpace: return BackupError.notEnoughSpace
            default:
                if let posix = cocoa.userInfo[NSUnderlyingErrorKey] as? POSIXError {
                    return BackupError.posix(posix.code.rawValue, url)
                }
                return BackupError.fileAccessFailed(name: name, code: cocoa.code.rawValue)
            }
        }
        if let posix = error as? POSIXError { return BackupError.posix(posix.code.rawValue, url) }
        return BackupError.fileAccessFailed(name: name, code: (error as NSError).code)
    }
}

/// Runs a Foundation file operation on `url`, mapping its errors (see `BackupError.wrapping`).
func mappingFileErrors<T>(_ url: URL, _ body: () throws -> T) throws -> T {
    do { return try body() } catch { throw BackupError.wrapping(error, url) }
}
