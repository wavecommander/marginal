import Foundation

/// Entry paths inside a `.ttbackup` archive.
///
///     manifest.json
///     books/<bookID>/records.json
///     books/<bookID>/<path relative to the book's directory>   (ink/12.drawing, cover.jpg, …)
///     pdfs/<sha256>.pdf                                        (only when embedded)
///
/// Book IDs are written with `uuidString` (upper case), as `BookStorageLayout` does on disk.
public enum BackupArchiveLayout {
    /// `manifest.json`
    public static let manifestPath = "manifest.json"
    /// File name of a book's records inside its archive folder. Reserved: a book file with this
    /// path at the top of the book's directory cannot be backed up.
    public static let recordsFileName = "records.json"

    /// `books/<bookID>`
    public static func bookDirectory(bookID: UUID) -> String {
        "books/\(bookID.uuidString)"
    }
    /// `books/<bookID>/records.json`
    public static func recordsPath(bookID: UUID) -> String {
        "\(bookDirectory(bookID: bookID))/\(recordsFileName)"
    }
    /// `books/<bookID>/<relativePath>`
    public static func bookFilePath(bookID: UUID, relativePath: String) -> String {
        "\(bookDirectory(bookID: bookID))/\(relativePath)"
    }
    /// `pdfs/<sha256>.pdf`
    public static func embeddedPDFPath(sha256: String) -> String {
        "pdfs/\(sha256).pdf"
    }
}

/// Paths of the folder layout shared by every folder-like destination (a picked folder, a
/// bucket):
///
///     Backups/<snapshot name>.ttbackup   (never embeds PDFs)
///     PDFs/<sha256>.pdf                  (written once per PDF, never deleted automatically)
public enum BackupFolderLayout {
    /// `Backups`: where snapshots go in every destination except the local ones, and where the
    /// local ones kept them before `localBackupsDirectory`.
    public static let backupsDirectory = "Backups"
    /// `Tactile Texts Backups`: where a picked folder (the local, reader-visible destination)
    /// puts new snapshots. It still lists, restores and deletes snapshots already in `Backups/`.
    public static let localBackupsDirectory = "Tactile Texts Backups"
    /// `PDFs`
    public static let pdfsDirectory = "PDFs"

    /// `Backups/<name>`
    public static func snapshotPath(name: String) -> String {
        "\(backupsDirectory)/\(name)"
    }
    /// `<sha256>.pdf`
    public static func pdfFileName(sha256: String) -> String {
        "\(sha256).pdf"
    }
    /// `PDFs/<sha256>.pdf`
    public static func pdfPath(sha256: String) -> String {
        "\(pdfsDirectory)/\(pdfFileName(sha256: sha256))"
    }
}

/// Snapshot file names: `<UTC timestamp> <device name>.ttbackup`, for example
/// `2026-11-15T09-30-05Z Ben’s iPad.ttbackup`.
///
/// The timestamp comes first and is fixed-width, so names sort by date in any file browser; it
/// uses `-` instead of `:` because `:` is not allowed in file names everywhere. The device name
/// is sanitised so the name is a single safe path component on every destination.
public enum SnapshotName {
    /// Longest device-name part kept (characters).
    static let maximumDeviceNameLength = 60

    /// The snapshot name for a backup made at `createdAt` (to the second) on `deviceName`.
    public static func make(createdAt: Date, deviceName: String) -> String {
        "\(timestamp(createdAt)) \(sanitizedDeviceName(deviceName)).\(BackupFormat.fileExtension)"
    }

    /// The date (to the second) and device name encoded in `name`, or `nil` when `name` is not
    /// a snapshot name.
    public static func parse(_ name: String) -> (createdAt: Date, deviceName: String)? {
        let suffix = ".\(BackupFormat.fileExtension)"
        guard name.hasSuffix(suffix) else { return nil }
        let stem = name.dropLast(suffix.count)
        guard let space = stem.firstIndex(of: " ") else { return nil }
        let device = String(stem[stem.index(after: space)...])
        guard !device.isEmpty, let date = parseTimestamp(String(stem[..<space])) else { return nil }
        return (date, device)
    }

    /// `deviceName` made safe for a file name: path separators, characters other systems
    /// forbid (`\ / : * ? " < > |`) and control characters become `-`; leading and trailing
    /// spaces and dots are trimmed (a leading dot would hide the file); at most 60 characters;
    /// `iPad` when nothing is left.
    public static func sanitizedDeviceName(_ deviceName: String) -> String {
        let forbidden = Set("\\/:*?\"<>|")
        var result = ""
        for character in deviceName {
            if forbidden.contains(character) || character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                result.append("-")
            } else {
                result.append(character)
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        let limited = String(trimmed.prefix(maximumDeviceNameLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        return limited.isEmpty ? "iPad" : limited
    }

    // MARK: - Timestamp

    private static let utc = TimeZone(identifier: "UTC")!

    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d-%02d-%02dZ", p.year ?? 0, p.month ?? 0, p.day ?? 0,
                      p.hour ?? 0, p.minute ?? 0, p.second ?? 0)
    }

    /// Parses exactly `YYYY-MM-DDTHH-MM-SSZ`.
    static func parseTimestamp(_ string: String) -> Date? {
        let bytes = Array(string.utf8)
        guard bytes.count == 20 else { return nil }
        let template = Array("0000-00-00T00-00-00Z".utf8)
        for (byte, expected) in zip(bytes, template) {
            if expected == UInt8(ascii: "0") {
                guard (48...57).contains(byte) else { return nil }
            } else if byte != expected {
                return nil
            }
        }
        func number(_ range: Range<Int>) -> Int { range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) } }
        var parts = DateComponents()
        parts.year = number(0..<4)
        parts.month = number(5..<7)
        parts.day = number(8..<10)
        parts.hour = number(11..<13)
        parts.minute = number(14..<16)
        parts.second = number(17..<19)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        guard let date = calendar.date(from: parts), timestamp(date) == string else { return nil }
        return date
    }
}
