import Foundation
import Testing
@testable import TactileTexts

/// `LibraryActivity`: the user activity that opens a book in a new window.
struct LibraryActivityTests {
    @Test func activityRoundTripsTheBookID() {
        let id = UUID()
        let activity = LibraryActivity.makeActivity(bookID: id, title: "T")
        #expect(activity.activityType == LibraryActivity.openBookType)
        #expect(LibraryActivity.bookID(from: activity) == id)
    }
}
