import Foundation

/// Creates and resolves the bookmark that remembers the picked folder. Injected so tests can
/// produce stale and unresolvable bookmarks.
nonisolated protocol BackupFolderBookmarking: Sendable {
    /// Bookmark data for `url`, made while the caller holds security-scoped access to it.
    func bookmarkData(for url: URL) throws -> Data
    /// The URL `data` resolves to now, and whether the bookmark should be recreated.
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
}

/// The system's bookmarks, as Apple's "Providing access to directories" describes for a folder
/// from the document picker: a `.minimalBookmark` made while accessing the security-scoped URL,
/// resolved with `URL(resolvingBookmarkData:bookmarkDataIsStale:)`. (`.withSecurityScope` is a
/// macOS option; on iOS the picker's URL carries the scope and a bookmark of it keeps it.)
nonisolated struct SystemFolderBookmarking: BackupFolderBookmarking {
    init() {}

    func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }
}

/// Where the picked folder is now.
nonisolated enum BackupFolderResolution: Sendable, Equatable {
    /// The folder's URL (security-scoped when it came from the picker) and name.
    case resolved(URL, name: String)
    /// No usable folder; `reason` is reader-facing.
    case unavailable(reason: String)
}

/// Remembers the folder the reader picked for backups, as a bookmark in `UserDefaults`.
///
/// `setFolder(_:)` takes the document picker's URL. Resolving refreshes a stale bookmark; one
/// that no longer resolves makes the folder unavailable with a reason that asks the reader to
/// choose it again. The bookmark is resolved for every operation (it is cheap), so a folder
/// that is moved or comes back online is picked up without relaunching. Safe to use from any
/// thread; resolution can involve the Files provider, so the destinations call it off the main
/// actor.
nonisolated final class BackupFolderStore: Sendable {
    static let defaultKey = "backupFolder"

    /// Shown when no folder has been chosen.
    static let notChosenReason = "Choose a folder in Files to back up to."

    static func notFoundReason(_ name: String?) -> String {
        if let name {
            return "The backup folder “\(name)” can’t be found. It may have been moved or deleted, or be on storage that isn’t connected. Choose the backup folder again."
        }
        return "The backup folder can’t be found. Choose the backup folder again."
    }

    private nonisolated(unsafe) let defaults: UserDefaults
    private let key: String
    private let bookmarking: any BackupFolderBookmarking

    /// `defaults` and `key` say where the bookmark is kept (tests pass their own suite).
    init(defaults: UserDefaults = .standard, key: String = BackupFolderStore.defaultKey,
         bookmarking: any BackupFolderBookmarking = SystemFolderBookmarking()) {
        self.defaults = defaults
        self.key = key
        self.bookmarking = bookmarking
    }

    /// Remembers `url` (the document picker's result) as the backup folder, replacing any
    /// earlier choice. Throws when no bookmark can be made for it.
    func setFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try bookmarking.bookmarkData(for: url)
        save(bookmark: data, name: Self.name(of: url))
    }

    /// `true` when a folder has been chosen (whether or not it can be reached now).
    var hasFolder: Bool { saved?.bookmark != nil }

    /// The chosen folder's name as last seen, or `nil` when none is chosen.
    var folderName: String? { saved?.name }

    /// Resolves the bookmark, refreshing it when the system says it is stale.
    func resolveFolder() -> BackupFolderResolution {
        guard let saved, let bookmark = saved.bookmark else { return .unavailable(reason: Self.notChosenReason) }
        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try bookmarking.resolve(bookmark)
        } catch {
            return .unavailable(reason: Self.notFoundReason(saved.name))
        }
        let name = Self.name(of: resolved.url)
        if resolved.isStale {
            refresh(resolved.url, name: name)
        } else if name != saved.name {
            save(bookmark: bookmark, name: name)
        }
        return .resolved(resolved.url, name: name)
    }

    // MARK: - Internals

    /// Recreates a stale bookmark from the URL it resolved to. If that fails the old bookmark is
    /// kept: it still resolved this time.
    private func refresh(_ url: URL, name: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? bookmarking.bookmarkData(for: url) {
            save(bookmark: data, name: name)
        }
    }

    private var saved: (bookmark: Data?, name: String?)? {
        guard let entry = defaults.dictionary(forKey: key) else { return nil }
        return (entry["bookmark"] as? Data, entry["name"] as? String)
    }

    private func save(bookmark: Data, name: String) {
        defaults.set(["bookmark": bookmark, "name": name] as [String: Any], forKey: key)
    }

    private static func name(of url: URL) -> String {
        if let localized = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName, !localized.isEmpty {
            return localized
        }
        return url.lastPathComponent
    }
}
