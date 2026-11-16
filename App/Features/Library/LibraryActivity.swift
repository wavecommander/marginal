import Foundation
import UniformTypeIdentifiers

/// The `NSUserActivity` that carries a book from a dragged cover to a new window.
///
/// Dragging a cover out of the grid lifts an item provider holding this activity; dropping it
/// outside the window (or on the edge, with Stage Manager or Split View) makes the system create
/// a new scene and deliver the activity to it, where `LibraryScreen.onContinueUserActivity`
/// opens the reader in place. The type must be listed in the app's `NSUserActivityTypes`
/// (Info.plist, via `project.yml`) for the system to route it to this app's scenes.
nonisolated enum LibraryActivity {
    /// `software.tactile.texts.openBook`
    static let openBookType = "software.tactile.texts.openBook"
    static let bookIDKey = "bookID"

    static func makeActivity(bookID: UUID, title: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: openBookType)
        activity.title = title
        activity.userInfo = [bookIDKey: bookID.uuidString]
        activity.targetContentIdentifier = bookID.uuidString
        activity.isEligibleForHandoff = false
        activity.isEligibleForSearch = false
        return activity
    }

    static func bookID(from activity: NSUserActivity) -> UUID? {
        if let text = activity.userInfo?[bookIDKey] as? String, let id = UUID(uuidString: text) { return id }
        return activity.targetContentIdentifier.flatMap { UUID(uuidString: $0) }
    }

    /// The drag item for a book cover.
    static func itemProvider(bookID: UUID, title: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerObject(makeActivity(bookID: bookID, title: title), visibility: .all)
        provider.suggestedName = title
        return provider
    }
}
