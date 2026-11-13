import Foundation
import ReaderCore

/// Placeholder so the package builds. WP2 replaces this with the SwiftData schema and ink store.
public enum ReaderStore {
    public static let placeholder = "ReaderStore"
}

extension LibraryStore {
    /// The app's persistent store: SwiftData records plus file-backed ink under `rootDirectory`
    /// (default: the Application Support directory). `reset: true` wipes records and files first.
    ///
    /// TEMPORARY: until WP2 lands this returns an in-memory store, so nothing survives relaunch.
    /// The signature is the contract WP2 implements and the app's composition root calls.
    @MainActor
    public static func live(rootDirectory: URL? = nil, reset: Bool = false) throws -> LibraryStore {
        .inMemory(rootDirectory: rootDirectory)
    }
}
