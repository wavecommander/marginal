import Foundation

/// What restoring one backed-up book does. The restore preview offers a choice for a book already
/// in the Library; a new book can only be restored. `rawValue` is the stored form.
public enum RestoreAction: String, CaseIterable, Hashable, Codable, Sendable {
    /// A book not in the Library: add it as it is in the backup.
    case restore
    /// A book already in the Library: keep the local book and add what the backup has
    /// (`BookMerge` for the records; nothing local is removed).
    case merge
    /// A book already in the Library: replace all its notes, highlights, bookmarks, headings and
    /// ink with the backup's.
    case replace
}
