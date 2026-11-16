import Foundation
import ReaderCore

/// Files in a book's directory that are **derived from its PDF** and so never in a backup
/// (design: "Scanned books" ▸ Backups: "Recognised text is not in a backup: it is derived from the
/// PDF and can be made again"): a scanned book's recognised text (`text/`) and its recognition
/// state (`recognition.json`), both at the top level of the book's directory
/// (`BookStorageLayout`).
///
/// The archive writer leaves them out of every snapshot it writes: single-file and folder
/// backups to every destination, and the safety copy a restore keeps for Undo Last Restore. A
/// restore removes any it finds in an archive (one written before they were left out), so a book
/// restored fresh starts with no recognition state; a restore that merges into or replaces a book
/// on this iPad keeps that book's own (the app's restore commit carries them across).
public enum BackupDerivedFiles {
    /// Top-level names inside a book's directory that are never backed up.
    public static let topLevelNames: Set<String> = [
        BookStorageLayout.recognisedTextDirectoryName,
        BookStorageLayout.recognitionStateFileName,
    ]

    /// Whether `name`, at the top level of a book's directory, is derived and never backed up.
    public static func isDerived(topLevelName name: String) -> Bool {
        topLevelNames.contains(name)
    }

    /// Whether a file's path relative to the book's directory (`/`-separated) is inside a derived
    /// entry (`text/16.json`, `recognition.json`).
    public static func isDerived(relativePath path: String) -> Bool {
        guard let first = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return false
        }
        return topLevelNames.contains(String(first))
    }
}
