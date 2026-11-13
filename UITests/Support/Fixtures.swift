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
    static var large: String { path("large.pdf") }
    static var noOutline: String { path("no-outline.pdf") }

    static func path(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/out/\(name)").path
    }
}

extension XCUIApplication {
    /// Launches with `-resetState` followed by `arguments`.
    @discardableResult
    static func launchFresh(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState"] + arguments
        app.launch()
        return app
    }

    /// Argument pair that imports a fixture at launch.
    static func importing(_ path: String) -> [String] { ["-importFixture", path] }
}
