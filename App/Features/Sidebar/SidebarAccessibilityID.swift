/// Accessibility identifiers of the sidebar, kept in the feature folder so the shell's
/// `AccessibilityID` is untouched. `UITests/SidebarUITests.swift` mirrors these strings.
nonisolated enum SidebarAccessibilityID {
    /// The whole sidebar (inside the shell's pane container).
    static let root = "sidebar"
    /// The Contents / Pages / Bookmarks segmented control.
    static let tabs = "sidebar.tabs"

    // Contents
    static let contentsList = "sidebar.contents.list"
    /// A heading row's main button: `sidebar.heading.<title>`.
    static func heading(_ title: String) -> String { "sidebar.heading.\(title)" }
    /// A heading row's disclosure chevron: `sidebar.disclosure.<title>`.
    static func disclosure(_ title: String) -> String { "sidebar.disclosure.\(title)" }
    static let addHeading = "sidebar.addHeading"
    static let emptyContents = "sidebar.contents.empty"
    static let emptyAddHeading = "sidebar.contents.empty.addHeading"

    // Add-heading sheet and rename alert
    static let addHeadingTitle = "sidebar.addHeading.title"
    static let addHeadingPage = "sidebar.addHeading.page"
    static let addHeadingParent = "sidebar.addHeading.parent"
    static let addHeadingSave = "sidebar.addHeading.save"
    static let addHeadingCancel = "sidebar.addHeading.cancel"
    static let renameField = "sidebar.rename.field"

    // Pages
    static let pagesGrid = "sidebar.pages.grid"
    /// A thumbnail cell: `sidebar.page.<1-based number>`.
    static func page(_ number: Int) -> String { "sidebar.page.\(number)" }

    // Bookmarks
    static let bookmarksList = "sidebar.bookmarks.list"
    static let emptyBookmarks = "sidebar.bookmarks.empty"
    /// A bookmark row: `sidebar.bookmark.<1-based number>`.
    static func bookmark(_ number: Int) -> String { "sidebar.bookmark.\(number)" }

    /// DEBUG `-sidebarDebugStats`: thumbnail and memory figures as the element's value.
    static let debugStats = "sidebar.debugStats"
}
