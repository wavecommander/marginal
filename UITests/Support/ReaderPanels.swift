import XCTest

/// The reader's two side panels, for tests that need one shown or hidden. A fresh launch decides
/// what is shown; a test changes that only where it matters to what it checks, and only through
/// `setPanel`, which does nothing when the panel is already as wanted.
enum ReaderPanel {
    /// The Contents sidebar (a pane in a wide window, an overlay in a narrow one).
    case contents
    /// The notes panel (a pane in a wide window, a sheet in a narrow one).
    case notes

    /// The toolbar button that shows and hides the panel.
    var toggleIdentifier: String {
        switch self {
        case .contents: "reader.toolbar.contents"
        case .notes: "reader.toolbar.notes"
        }
    }

    /// The toggle's label while the panel is shown (it reads "Show …" while hidden).
    var shownLabel: String {
        switch self {
        case .contents: "Hide Contents"
        case .notes: "Hide Notes"
        }
    }
}

extension XCUIApplication {
    /// The toolbar toggle of `panel` (the first one, when several reader windows are open).
    @MainActor
    func toggle(of panel: ReaderPanel) -> XCUIElement {
        buttons[panel.toggleIdentifier].firstMatch
    }

    /// Whether `panel` is shown, read from its toolbar toggle's label.
    @MainActor
    func isShown(_ panel: ReaderPanel) -> Bool {
        toggle(of: panel).label == panel.shownLabel
    }

    /// Shows or hides `panel` if it is not already so, and waits until the toolbar says it is.
    /// Returns `false` if the panel did not get there (the caller asserts where that matters).
    @MainActor
    @discardableResult
    func setPanel(_ panel: ReaderPanel, shown: Bool, timeout: TimeInterval = 10) -> Bool {
        let toggle = toggle(of: panel)
        guard toggle.waitForExistence(timeout: timeout) else { return false }
        if isShown(panel) == shown { return true }
        toggle.tap()
        return toggle.wait(until: shown ? "label == %@" : "label != %@", panel.shownLabel, timeout: timeout)
    }
}
