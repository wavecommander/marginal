import Foundation
import Testing
@testable import TactileTexts

/// The time left shown while a marked-up PDF export runs (progress card and status pill).
struct MarkedUpExportTimeEstimateTests {
    @Test func waitsUntilThereIsEnoughToGoOn() {
        #expect(MarkedUpExportTimeEstimate.remaining(elapsed: 1, fraction: 0.5) == nil)
        #expect(MarkedUpExportTimeEstimate.remaining(elapsed: 10, fraction: 0.01) == nil)
        #expect(MarkedUpExportTimeEstimate.remaining(elapsed: 10, fraction: 1) == nil)
        #expect(MarkedUpExportTimeEstimate.text(remaining: nil) == "Working out how long this will take…")
    }

    @Test func projectsFromTheRateSoFar() {
        // A quarter done in 60 s: three more quarters, 180 s.
        #expect(MarkedUpExportTimeEstimate.remaining(elapsed: 60, fraction: 0.25) == 180)
    }

    @Test func saysItInWords() {
        #expect(MarkedUpExportTimeEstimate.text(remaining: 20) == "Less than a minute left")
        #expect(MarkedUpExportTimeEstimate.text(remaining: 70) == "About a minute left")
        #expect(MarkedUpExportTimeEstimate.text(remaining: 180) == "About 3 minutes left")
        #expect(MarkedUpExportTimeEstimate.text(remaining: 3600) == "About 1 hour left")
        #expect(MarkedUpExportTimeEstimate.text(remaining: 4800) == "About 1 hour 20 min left")
        #expect(MarkedUpExportTimeEstimate.text(remaining: 7500) == "About 2 hours 5 min left")
    }
}
