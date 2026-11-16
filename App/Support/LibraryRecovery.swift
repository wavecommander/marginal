import Foundation
import Observation
import ReaderStore

/// The ways back into a library the app could not open (docs/DESIGN.md "A library from a newer
/// version"): open a newer library in this version, or put back a kept copy. One per app, held by
/// `AppEnvironment` when the store failed, so every window's `LibraryUnavailableView` shows the
/// same state and only one change runs.
///
/// The app is then running on its stand-in store, and the services built on it stay bound to
/// it, so a change here takes effect at the next launch: the screen says to close and reopen.
@Observable
@MainActor
final class LibraryRecovery {
    enum Phase: Equatable {
        case idle
        case working
        /// The library was changed; it opens at the next launch.
        case ready
        case failed(String)
    }

    /// The store's error, for a support request.
    let details: String
    /// The store was written by a newer version of the app.
    let isFromNewerVersion: Bool
    /// The app's root directory (the real one, not the stand-in store's).
    let rootDirectory: URL
    private(set) var phase: Phase = .idle
    /// Copies this version can open, newest first.
    private(set) var copies: [LibraryDatabase.Copy]

    init(error: Error, rootDirectory: URL) {
        details = String(describing: error)
        isFromNewerVersion = (error as? ReaderStoreError) == .libraryFromNewerVersion
        self.rootDirectory = rootDirectory
        copies = LibraryDatabase.copies(rootDirectory: rootDirectory).filter(\.canBeUsed)
    }

    /// Converts the newer library to this version (a copy of it as it was is kept).
    func openInThisVersion() async {
        let root = rootDirectory
        await run { try LibraryDatabase.openInThisVersion(rootDirectory: root) }
    }

    /// Puts `copy` back as the library (the library as it is now is kept as a copy).
    func putBack(_ copy: LibraryDatabase.Copy) async {
        let root = rootDirectory
        await run { try LibraryDatabase.putBack(copy, rootDirectory: root) }
    }

    private func run(_ work: @escaping @Sendable () throws -> Void) async {
        guard phase != .working, phase != .ready else { return }
        phase = .working
        do {
            try await Task.detached(priority: .userInitiated) { try work() }.value
            phase = .ready
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? ReaderStoreError {
        case .cannotOpenInThisVersion?:
            "This version can't convert your library. Nothing was changed. Install the newer version of Tactile Texts to open it."
        case .copyFailed?:
            "A copy of your library couldn't be made, so nothing was changed. Free up some space on your iPad and try again."
        case .copyCannotBeUsed?:
            "This version can't open that copy. Nothing was changed."
        default:
            "Nothing was changed. \(String(describing: error))"
        }
    }

    /// How a copy is described in the list.
    static func label(for copy: LibraryDatabase.Copy) -> String {
        let date = copy.date.formatted(date: .abbreviated, time: .shortened)
        switch copy.reason {
        case .beforeUpdate:
            return "\(date), before an update"
        case .beforeOpeningInThisVersion:
            return "\(date), before opening in an older version"
        case .setAside:
            return "\(date), set aside when a copy was used"
        }
    }
}
