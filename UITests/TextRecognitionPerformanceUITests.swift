import XCTest

/// Scrolling `scanned.pdf` while the text-recognition queue runs (S2, principle 3), through the
/// same DEBUG probe as `PerformanceUITests` (`-perfProbe -perfAutoScroll`: the app scrolls its
/// own PDF view, 8 s slow then 8 s fast, and reports frame gaps). Each configuration is launched
/// fresh: without recognition, then with it started at launch (`-recognizeBook scanned`).
/// Runs alternate so a drift in the machine's load affects both alike.
///
/// Figures are printed (`PERF …`) and written to `build/perf-recognition-scroll.txt`. The
/// recognising run's own marks (`recognised<n>`, ms since launch) show recognition ran through
/// the scroll window.
@MainActor
final class TextRecognitionPerformanceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    private func stats(_ app: XCUIApplication) -> XCUIElement { app.buttons["reader.perfStats"].firstMatch }

    private func value(_ app: XCUIApplication) -> String { stats(app).value as? String ?? "" }

    /// Launches into the reader on page 2 and lets the probe scroll; returns its final value.
    private func measure(recognising: Bool) -> String {
        var arguments = XCUIApplication.importing(Fixtures.scanned)
            + ["-openBook", "scanned", "-openPage", "2", "-perfProbe", "-perfAutoScroll"]
        if recognising { arguments += ["-recognizeBook", "scanned"] }
        let app = XCUIApplication.launchFresh(arguments)
        XCTAssertTrue(app.buttons["reader.pagePill"].firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(stats(app).waitForExistence(timeout: 60))
        let deadline = Date().addingTimeInterval(60)
        while !value(app).contains("openToFirstPageMS"), Date() < deadline { usleep(250_000) }
        // 3 s wait + 8 s slow + 1 s pause + 8 s fast; no queries meanwhile.
        sleep(24)
        var result = value(app)
        let end = Date().addingTimeInterval(20)
        while !result.contains("phase done"), Date() < end {
            sleep(1)
            result = value(app)
        }
        app.terminate()
        return result
    }

    /// The probe's `marks` entry as name → ms since launch.
    static func marks(_ value: String) -> [String: Double] {
        guard let range = value.range(of: "marks ") else { return [:] }
        let list = value[range.upperBound...].split(separator: " ").first ?? ""
        var result: [String: Double] = [:]
        for pair in list.split(separator: ",") {
            let parts = pair.split(separator: ":")
            if parts.count == 2, let ms = Double(parts[1]) { result[String(parts[0])] = ms }
        }
        return result
    }

    func testScrollingWhileRecognitionRuns() {
        var lines: [String] = []
        var baseline: [[String: Double]] = []
        var recognising: [[String: Double]] = []
        for round in 1...2 {
            for running in [false, true] {
                let value = measure(recognising: running)
                NSLog("%@", "PERF-STEP round \(round) recognising \(running): \(value)")
                let figures = PerformanceUITests.parse(value)
                XCTAssertTrue(value.contains("phase done"), value)
                let label = running ? "with recognition" : "without recognition"
                func f(_ key: String) -> String { "\(Int((figures[key] ?? -1).rounded()))" }
                lines.append("round \(round) \(label): slow frames \(f("slowFrames")) maxGap \(f("slowMaxGapMS")) ms "
                             + "long \(f("slowLong")) dropped \(f("slowDropped")) | fast frames \(f("fastFrames")) "
                             + "maxGap \(f("fastMaxGapMS")) ms long \(f("fastLong")) dropped \(f("fastDropped")) "
                             + "pages \(f("fastPages")) | footprint max \(f("fastFootprintMB")) MB")
                if running {
                    recognising.append(figures)
                    // Recognition ran through the scroll window: first page shown + 3 s to + 20 s.
                    let marks = Self.marks(value)
                    let firstPage = figures["launchToFirstPageMS"] ?? 0
                    lines.append("  recognition marks \(marks.sorted { $0.value < $1.value }.map { "\($0.key)@\(Int($0.value))" }.joined(separator: " ")) (scroll from \(Int(firstPage + 3000)) to about \(Int(firstPage + 20000)) ms)")
                    XCTAssertNotNil(marks["recognised1"], "recognition ran")
                    if let first = marks["recognised1"] {
                        XCTAssertLessThan(first, firstPage + 11_000, "recognition was running during the slow phase")
                    }
                    let last = marks.filter { $0.key.hasPrefix("recognised") }.values.max() ?? 0
                    XCTAssertGreaterThan(last, firstPage + 12_000, "recognition was still running during the fast phase")
                } else {
                    baseline.append(figures)
                }
                lines.append("  raw: \(value)")
            }
        }
        func mean(_ runs: [[String: Double]], _ key: String) -> Double {
            let values = runs.compactMap { $0[key] }
            return values.isEmpty ? -1 : values.reduce(0, +) / Double(values.count)
        }
        for key in ["slowMaxGapMS", "slowDropped", "slowLong", "fastMaxGapMS", "fastDropped", "fastLong"] {
            lines.append("mean \(key): without \(mean(baseline, key)), with \(mean(recognising, key))")
        }
        record(lines)
        // Leave no book in progress behind: the next process on this simulator (a unit-test
        // host, which does not reset state) would otherwise resume recognising it.
        XCUIApplication.launchFresh().terminate()
        // The bound (WORK_PACKAGES S2: "stays within the bound it has without it"), on the slow
        // phase, where the view scrolls throughout (the 30-page book runs out early in the fast
        // phase): no more frames over 50 ms, and at most two more dropped frames per run on
        // average, than without recognition.
        XCTAssertLessThanOrEqual(mean(recognising, "slowLong"), mean(baseline, "slowLong"))
        XCTAssertLessThanOrEqual(mean(recognising, "slowDropped"), mean(baseline, "slowDropped") + 2)
    }

    private func record(_ lines: [String]) {
        let text = lines.joined(separator: "\n")
        print("PERF recognition-scroll:\n\(text)")
        try? text.write(to: Fixtures.repoRoot.appendingPathComponent("build/perf-recognition-scroll.txt"), atomically: true,
                        encoding: .utf8)
        let attachment = XCTAttachment(string: text)
        attachment.name = "recognition-scroll"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
