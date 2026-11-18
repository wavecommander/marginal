import Foundation
import ReaderSync

// The words of Recently Deleted and Earlier Versions (C5), with no views of their own, so they
// are unit-tested directly (`Tests/SyncRecoveryAppTests.swift`). Text that names the device is
// written once per kind (`DeviceKind.pick`), as whole sentences, so it localises.

nonisolated enum SyncRecoveryText {
    // MARK: Recently Deleted

    static let recentlyDeletedTitle = String(localized: "Recently Deleted",
                                             comment: "Tactile Texts Cloud ▸ Sync: the list of deleted books that can be restored, and the row that opens it.")
    static let recentlyDeletedFooter = String(localized: "Books deleted on any of your devices stay here for 30 days and can be restored from any of them.",
                                              comment: "Tactile Texts Cloud ▸ Sync ▸ Recently Deleted: what the list holds.")
    static let emptyTitle = String(localized: "No Recently Deleted Books",
                                   comment: "Recently Deleted: title when nothing was deleted in the last 30 days.")
    static let emptyMessage = String(localized: "Books you delete on any of your devices stay here for 30 days, and you can restore them from any of them.",
                                     comment: "Recently Deleted: message when nothing was deleted in the last 30 days.")
    static let restoreButton = String(localized: "Restore", comment: "Recently Deleted: restores a deleted book; Earlier Versions: restores a version.")
    static let loadFailedTitle = String(localized: "Couldn’t Load", comment: "Recently Deleted or Earlier Versions: title when the list could not be read.")

    /// "Deleted on this iPad, 18 Nov 2026 at 10:02" or "Deleted on Reading Phone, …".
    static func deletedLine(_ book: SyncDeletedBook, thisDeviceID: UUID?, kind: DeviceKind = .current) -> String {
        let when = book.deletedAt.formatted(date: .abbreviated, time: .shortened)
        if book.deviceID == thisDeviceID {
            return kind.pick(iPad: String(localized: "Deleted on this iPad, \(when)",
                                          comment: "Recently Deleted: a book deleted on this iPad. The argument is a date and time."),
                             iPhone: String(localized: "Deleted on this iPhone, \(when)",
                                            comment: "Recently Deleted: a book deleted on this iPhone. The argument is a date and time."))
        }
        let name = book.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return String(localized: "Deleted on another device, \(when)",
                          comment: "Recently Deleted: a book deleted on a device with no name. The argument is a date and time.")
        }
        return String(localized: "Deleted on \(name), \(when)",
                      comment: "Recently Deleted: a book deleted on another device. The arguments are the device's name and a date and time.")
    }

    /// "29 days left", "1 day left", "Last day".
    static func daysLeft(_ days: Int) -> String {
        switch days {
        case ...0: String(localized: "Last day", comment: "Recently Deleted: the book can be restored only until the end of today.")
        case 1: String(localized: "1 day left", comment: "Recently Deleted: one day left to restore the book.")
        default: String(localized: "\(days) days left", comment: "Recently Deleted: days left to restore the book. The argument is a number above 1.")
        }
    }

    static func restoreTitle(_ title: String) -> String {
        String(localized: "Restore “\(title)”?", comment: "Recently Deleted: the restore confirmation's title. The argument is the book's title.")
    }

    static func restoreMessage(kind: DeviceKind = .current) -> String {
        kind.pick(iPad: String(localized: "It comes back on this iPad now with its notes, highlights, bookmarks and ink, and on your other devices when they next sync. Its PDF downloads as your Download PDFs setting says.",
                               comment: "Recently Deleted: the restore confirmation, on an iPad."),
                  iPhone: String(localized: "It comes back on this iPhone now with its notes, highlights, bookmarks and ink, and on your other devices when they next sync. Its PDF downloads as your Download PDFs setting says.",
                                 comment: "Recently Deleted: the restore confirmation, on an iPhone."))
    }

    static func restoredNotice(_ title: String) -> String {
        String(localized: "“\(title)” is back in your Library.", comment: "Recently Deleted: after a restore. The argument is the book's title.")
    }

    // MARK: Earlier versions

    static let earlierVersionsMenu = String(localized: "Earlier Versions…", comment: "Library: context menu item of a synced book that lists its earlier versions.")
    static let earlierVersionsTitle = String(localized: "Earlier Versions", comment: "Earlier Versions: the sheet's title.")
    static let earlierVersionsFooter = String(localized: "Tactile Texts Cloud keeps this book’s versions from the last 30 days, from all your devices. Restoring one changes the book on every device; Undo Last Restore on the Backup screen puts it back.",
                                              comment: "Earlier Versions: the list's footer.")
    static let noVersionsTitle = String(localized: "No Earlier Versions", comment: "Earlier Versions: title when none are kept.")
    static let noVersionsMessage = String(localized: "Versions of this book from the last 30 days appear here as it changes on any of your devices.",
                                          comment: "Earlier Versions: message when none are kept.")
    static let versionGone = String(localized: "No longer available", comment: "Earlier Versions: a version whose content is gone.")
    static let restoreVersionButton = String(localized: "Restore This Version", comment: "Earlier Versions: the confirmation's button.")

    /// "3 notes, 1 highlight, 4 pages with ink" (bookmarks and headings when there are any).
    static func summary(_ summary: SyncContentSummary) -> String {
        var parts = [count(summary.notes, one: String(localized: "1 note", comment: "A count of notes: one."),
                           many: { String(localized: "\($0) notes", comment: "A count of notes. The argument is a number other than 1.") }),
                     count(summary.highlights, one: String(localized: "1 highlight", comment: "A count of highlights: one."),
                           many: { String(localized: "\($0) highlights", comment: "A count of highlights. The argument is a number other than 1.") })]
        if summary.bookmarks > 0 {
            parts.append(count(summary.bookmarks, one: String(localized: "1 bookmark", comment: "A count of bookmarks: one."),
                               many: { String(localized: "\($0) bookmarks", comment: "A count of bookmarks. The argument is a number above 1.") }))
        }
        parts.append(count(summary.inkedPages, one: String(localized: "1 page with ink", comment: "A count of pages with ink: one."),
                           many: { String(localized: "\($0) pages with ink", comment: "A count of pages with ink. The argument is a number other than 1.") }))
        return parts.joined(separator: ", ")
    }

    private static func count(_ n: Int, one: String, many: (String) -> String) -> String {
        n == 1 ? one : many(n.formatted())
    }

    /// "18 Nov 2026 at 10:02 · this iPad" or "· Reading Phone".
    static func versionLine(_ version: SyncBookVersion, thisDeviceID: UUID?, kind: DeviceKind = .current) -> String {
        let device: String
        if version.deviceID == thisDeviceID {
            device = kind.pick(iPad: String(localized: "this iPad", comment: "Earlier Versions: the version was made on this iPad."),
                               iPhone: String(localized: "this iPhone", comment: "Earlier Versions: the version was made on this iPhone."))
        } else {
            let name = version.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            device = name.isEmpty ? String(localized: "another device", comment: "Earlier Versions: made on a device with no name.") : name
        }
        return "\(versionDate(version)) · \(device)"
    }

    static func versionDate(_ version: SyncBookVersion) -> String {
        (version.replacedAt ?? version.modifiedAt).formatted(date: .abbreviated, time: .shortened)
    }

    static func restoreVersionTitle(_ version: SyncBookVersion) -> String {
        String(localized: "Restore the Version of \(versionDate(version))?",
               comment: "Earlier Versions: the confirmation's title. The argument is a date and time.")
    }

    /// What will change, and that it reaches the other devices.
    static func restoreVersionMessage(title: String, current: SyncContentSummary, restored: SyncContentSummary,
                                      kind: DeviceKind = .current) -> String {
        let now = summary(current), then = summary(restored)
        return kind.pick(
            iPad: String(localized: "“\(title)” goes back to how it was then: \(then) (now \(now)). Its notes, highlights, bookmarks, headings and ink become as they were, here and on your other devices when they next sync; anything added since is removed. Undo Last Restore on the Backup screen puts the book back as it is now on this iPad.",
                         comment: "Earlier Versions: the confirmation's message, on an iPad. Arguments: the book's title, what the version holds, what the book holds now."),
            iPhone: String(localized: "“\(title)” goes back to how it was then: \(then) (now \(now)). Its notes, highlights, bookmarks, headings and ink become as they were, here and on your other devices when they next sync; anything added since is removed. Undo Last Restore on the Backup screen puts the book back as it is now on this iPhone.",
                           comment: "Earlier Versions: the confirmation's message, on an iPhone. Arguments: the book's title, what the version holds, what the book holds now."))
    }

    static func restoredVersionNotice(_ version: SyncBookVersion) -> String {
        String(localized: "The book is as it was on \(versionDate(version)). Undo Last Restore on the Backup screen puts it back.",
               comment: "Earlier Versions: after a restore. The argument is a date and time.")
    }
}
