import UIKit
import XCTest

/// Host paths of the generated fixture PDFs (see `Fixtures/make-fixtures.swift`).
/// The simulator can read host paths, so these go straight into `-importFixture`.
/// `scripts/test.sh` generates them before running; run `scripts/fixtures.sh` manually otherwise.
enum Fixtures {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // UITests
        .deletingLastPathComponent()  // repo root

    static var small: String { path("small.pdf") }
    /// `small.pdf`'s pages and outline plus links between sections.
    static var links: String { path("links.pdf") }
    /// `small.pdf`'s pages and outline with links encoded as real textbooks encode them
    /// (named destinations, hyperref GoTo actions, /Fit and null /XYZ views; written by hand).
    static var linkForms: String { path("link-forms.pdf") }
    static var large: String { path("large.pdf") }
    static var noOutline: String { path("no-outline.pdf") }
    /// A scanned book: 30 pages, a typed cover (page 1, real text) and 29 page images with no
    /// text layer; "The quiet heron measures tidewater." is the first body line of page 17.
    static var scanned: String { path("scanned.pdf") }

    /// "iPhone" or "iPad": the kind of simulator the tests run on, for text that names the device.
    static var deviceName: String {
        MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad" }
    }

    static func path(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/out/\(name)").path
    }
}

extension XCUIApplication {
    /// Launches with `-resetState` followed by `arguments`.
    @discardableResult
    static func launchFresh(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-pagePillStaysVisible", "-resetState"] + arguments
        app.launch()
        return app
    }

    /// Argument pair that imports a fixture at launch.
    static func importing(_ path: String) -> [String] { ["-importFixture", path] }
}
