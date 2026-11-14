import XCTest

/// Keyboard shortcuts that share keys with text editing. While a note has the text cursor,
/// ⇧⌘↑ / ⇧⌘↓ (Go › First Page / Last Page) are the text view's "select to the start / end" and
/// must not move the book. ⌥⌘↑ / ⌥⌘↓ (Previous / Next Page) are not text-editing keys on
/// iPadOS, so as menu commands they act on the window's book even while typing (measured on
/// iOS 27: page 5 → 4 → 5); that is logged, not asserted.
@MainActor
final class KeyboardShortcutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    private func wait(_ element: XCUIElement, _ format: String, _ argument: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argument), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func testNavigationShortcutsWhileTypingInANote() {
        let app = XCUIApplication.launchFresh(XCUIApplication.importing(Fixtures.small)
                                              + ["-openBook", "small", "-openPage", "5", "-notesPanel", "page"])
        let pill = app.buttons["reader.pagePill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30))
        XCTAssertTrue(wait(pill, "label == %@", "Page 5 of 12"))
        let text = app.textViews["notePage.text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        text.typeText("First line\nSecond line\nThird line")
        XCTAssertTrue(wait(text, "value CONTAINS %@", "Third line"))
        sleep(1)
        for (key, flags, name) in [(XCUIKeyboardKey.upArrow, XCUIElement.KeyModifierFlags([.command, .shift]), "⇧⌘↑"),
                                   (.downArrow, [.command, .shift], "⇧⌘↓"),
                                   (.upArrow, [.command, .option], "⌥⌘↑"),
                                   (.downArrow, [.command, .option], "⌥⌘↓")] {
            app.typeKey(key, modifierFlags: flags)
            sleep(1)
            print("KEYS \(name) in a note: pill \(pill.label); note \((text.value as? String ?? "").replacingOccurrences(of: "\n", with: "⏎"))")
            if flags.contains(.shift) {
                XCTAssertEqual(pill.label, "Page 5 of 12", "\(name) while typing in a note moved the book")
            }
            XCTAssertEqual(text.value as? String, "First line\nSecond line\nThird line", "\(name) changed the note's text")
        }
    }
}
