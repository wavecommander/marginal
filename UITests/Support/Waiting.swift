import XCTest

/// Waits on a condition, for every UI test: use these instead of `sleep`. A wait returns as soon
/// as its condition holds, so a passing test spends no fixed time, and a failing one says what it
/// was waiting for.
///
/// What to wait on in place of the usual sleeps:
/// - before typing into a field that has just appeared: `waitForKeyboardFocus()`;
/// - after a tap that starts an animation: the element it ends with (`waitForExistence`,
///   `waitForGone()`, `waitUntilHittable()`), or `waitForStableFrame()` when only the motion
///   itself can be seen;
/// - "this must not change": wait for whatever marks the end of the transition (a field gone,
///   a pane shown), or `UIWait.settled` on the value, then compare.
///
/// A pause with nothing to observe behind it (the debounced last-read save before a relaunch,
/// a hardware-key event that needs the window to have become key) stays a `sleep` with a comment
/// saying what it waits for.
enum UIWait {
    /// Polls `condition` until it is true or `timeout` passes. Returns its last result.
    @MainActor
    static func until(timeout: TimeInterval = 10, poll: TimeInterval = 0.1, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(poll))
        }
    }

    /// Reads `value` until two consecutive reads, `interval` apart, agree (an animation or a
    /// layout pass has finished), or `timeout` passes. Returns the last value read.
    @MainActor
    static func settled<Value: Equatable>(timeout: TimeInterval = 6, interval: TimeInterval = 0.25,
                                          _ value: () -> Value) -> Value {
        var last = value()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
            let next = value()
            if next == last { return next }
            last = next
        }
        return last
    }
}

extension XCUIElement {
    /// Waits until the `NSPredicate` `format` holds for this element (`label == %@`,
    /// `value CONTAINS %@`, `enabled == true`, …).
    @MainActor
    @discardableResult
    func wait(until format: String, _ arguments: Any..., timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: format, argumentArray: arguments)
        if exists, predicate.evaluate(with: self) { return true }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits until the element is no longer in the hierarchy.
    @MainActor
    @discardableResult
    func waitForGone(timeout: TimeInterval = 5) -> Bool {
        UIWait.until(timeout: timeout) { !self.exists }
    }

    /// Waits until the element exists and can be tapped (on screen, not covered).
    @MainActor
    @discardableResult
    func waitUntilHittable(timeout: TimeInterval = 10) -> Bool {
        UIWait.until(timeout: timeout) { self.exists && self.isHittable }
    }

    /// Waits until this text field or text view has keyboard focus, so typed text goes to it.
    @MainActor
    @discardableResult
    func waitForKeyboardFocus(timeout: TimeInterval = 5) -> Bool {
        UIWait.until(timeout: timeout) {
            self.exists && (self.value(forKey: "hasKeyboardFocus") as? Bool ?? false)
        }
    }

    /// Waits until the element's frame has stopped changing (a slide, a resize or a sheet's
    /// detent animation has finished) and returns it.
    @MainActor
    @discardableResult
    func waitForStableFrame(timeout: TimeInterval = 6) -> CGRect {
        UIWait.settled(timeout: timeout) { self.exists ? self.frame : .null }
    }
}

extension XCUIElementQuery {
    /// Waits until the query matches at least `count` elements.
    @MainActor
    @discardableResult
    func waitForCount(atLeast count: Int, timeout: TimeInterval = 30) -> Bool {
        UIWait.until(timeout: timeout, poll: 0.25) { self.count >= count }
    }
}
