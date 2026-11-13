import Foundation
import Testing
@testable import ReaderCore

@Suite("Section history")
struct SectionHistoryTests {
    /// Ch1 10…39 (1.1 10…19, 1.2 20…39), Ch2 40…69 (2.1 45…69), Ch3 70…99; pages 0…9 front matter.
    let outline = Outline(pdfEntries: [
        e("Ch1", 1, 10), e("1.1", 2, 10), e("1.2", 2, 20), e("Ch2", 1, 40), e("2.1", 2, 45), e("Ch3", 1, 70),
    ], pageCount: 100)

    func place(_ page: Int) -> SectionPlace { SectionPlace(pageIndex: page, in: outline) }

    @Test func placesUseTheDeepestHeadingOrThePage() {
        #expect(place(12).title == "1.1")
        #expect(place(12).isSameSection(as: place(19)))
        #expect(!place(12).isSameSection(as: place(20)))
        #expect(place(41).title == "Ch2")              // Ch2 before 2.1 starts
        #expect(place(3).heading == nil && place(3).title == nil)
        #expect(!place(3).isSameSection(as: place(4)))  // each front-matter page is its own place
        #expect(place(3).isSameSection(as: place(3)))
        #expect(place(311).menuTitle == "Page 312")     // outside the outline: page-keyed
        #expect(place(20).menuTitle == "1.2 · p. 21")
        #expect(SectionPlace(pageIndex: 5, heading: nil, title: "ignored").title == nil)
    }

    @Test func jumpToAnotherSectionRecordsLeftPlaceAndDestination() {
        var history = SectionHistory()
        #expect(!history.canGoBack && !history.canGoForward && history.current == nil)
        do { let r = history.recordJump(from: place(12), to: place(50)); #expect(r) }
        #expect(history.entries.map(\.pageIndex) == [12, 50])
        #expect(history.current == place(50))
        #expect(history.canGoBack && !history.canGoForward)
    }

    @Test func jumpWithinTheSameSectionAddsNothing() {
        var history = SectionHistory()
        do { let r = history.recordJump(from: place(10), to: place(15)); #expect(!r) }  // both in 1.1
        #expect(history.entries.map(\.pageIndex) == [15])
        #expect(!history.canGoBack)
        history.recordJump(from: place(15), to: place(50))
        do { let r = history.recordJump(from: place(52), to: place(60)); #expect(!r) }  // both in 2.1
        #expect(history.entries.map(\.pageIndex) == [15, 60])
    }

    /// The owner's acceptance rule: Back and Forward return to the exact page left, not the
    /// section start; before moving, the current entry takes the page on screen.
    @Test func backAndForwardReturnToThePageTheReaderLeft() {
        var history = SectionHistory()
        history.recordJump(from: place(0), to: place(10))   // jump to A (1.1), lands p10
        // The reader scrolls within A to 14, then jumps to B (2.1).
        history.recordJump(from: place(14), to: place(45))
        // Scrolls within B to 48, then Back.
        let back = history.back(from: place(48))
        #expect(back == place(14))
        #expect(back?.pageIndex == 14)
        // Forward returns to 48, the page left in B.
        let forward = history.forward(from: place(14))
        #expect(forward?.pageIndex == 48)
        // Back then forward from the same spot returns to the same spot.
        let again = history.back(from: place(48))
        #expect(again?.pageIndex == 14)
        do { let r = history.forward(from: place(16)); #expect(r?.pageIndex == 48) }
        do { let r = history.back(from: place(48)); #expect(r?.pageIndex == 16) }  // updated on the way out
    }

    @Test func newJumpAfterBackTruncatesForwardEntries() {
        var history = SectionHistory()
        history.recordJump(from: place(12), to: place(25))
        history.recordJump(from: place(25), to: place(50))
        history.recordJump(from: place(50), to: place(75))
        do { let r = history.back(from: place(75)); #expect(r?.pageIndex == 50) }
        do { let r = history.back(from: place(50)); #expect(r?.pageIndex == 25) }
        do { let r = history.forward(from: place(25)); #expect(r?.pageIndex == 50) }
        #expect(history.canGoForward)
        history.recordJump(from: place(52), to: place(3))
        #expect(!history.canGoForward)
        #expect(history.entries.map(\.pageIndex) == [12, 25, 52, 3])
        #expect(history.backList.map(\.place.pageIndex) == [52, 25, 12])
    }

    @Test func listsAreNearestFirstAndGoToEntryJumpsStraightThere() {
        var history = SectionHistory()
        for (from, to) in [(0, 12), (12, 25), (25, 50), (50, 75)] { history.recordJump(from: place(from), to: place(to)) }
        #expect(history.backList.map(\.index) == [3, 2, 1, 0])
        #expect(history.forwardList.isEmpty)
        let target = history.goToEntry(at: 1, from: place(80))
        #expect(target?.pageIndex == 12)
        #expect(history.forwardList.map(\.place.pageIndex) == [25, 50, 80])
        #expect(history.backList.map(\.place.pageIndex) == [0])
        do { let r = history.goToEntry(at: 9, from: place(12)); #expect(r == nil) }
        #expect(history.cursor == 1)
    }

    @Test func capDropsOldestEntries() {
        var history = SectionHistory(capacity: 3)
        history.recordJump(from: place(0), to: place(12))
        history.recordJump(from: place(12), to: place(25))
        history.recordJump(from: place(25), to: place(50))
        history.recordJump(from: place(50), to: place(75))
        #expect(history.entries.map(\.pageIndex) == [25, 50, 75])
        #expect(history.cursor == 2)
        do { let r = history.back(from: place(75)); #expect(r?.pageIndex == 50) }
        do { let r = history.back(from: place(50)); #expect(r?.pageIndex == 25) }
        #expect(!history.canGoBack)
        #expect(SectionHistory(capacity: 0).capacity == 2)
    }

    @Test func booksWithoutOutlineArePageKeyed() {
        let empty = Outline(pdfEntries: [], pageCount: 40)
        var history = SectionHistory()
        let p = { SectionPlace(pageIndex: $0, in: empty) }
        do { let r = history.recordJump(from: p(0), to: p(20)); #expect(r) }
        do { let r = history.recordJump(from: p(21), to: p(30)); #expect(r) }  // every page is its own place
        do { let r = history.back(from: p(30)); #expect(r?.menuTitle == "Page 22") }
        do { let r = history.back(from: p(21)); #expect(r?.pageIndex == 0) }
    }

    @Test func entriesStayValidByPageWhenTheirHeadingIsGone() {
        var history = SectionHistory()
        history.recordJump(from: place(12), to: place(50))
        // The outline changes (e.g. user headings deleted); places still carry their page.
        let rebuilt = Outline(pdfEntries: [], pageCount: 100)
        let back = history.back(from: SectionPlace(pageIndex: 51, in: rebuilt))
        #expect(back?.pageIndex == 12)
        #expect(back?.title == "1.1")  // snapshot kept for the menu
    }

    @Test func codableRoundTripAndCursorValidation() throws {
        var history = SectionHistory(capacity: 10)
        history.recordJump(from: place(12), to: place(50))
        history.recordJump(from: place(50), to: place(3))
        _ = history.back(from: place(3))
        let data = try JSONEncoder().encode(history)
        let decoded = try JSONDecoder().decode(SectionHistory.self, from: data)
        #expect(decoded == history)
        #expect(decoded.cursor == 1 && decoded.canGoForward)

        let corrupt = #"{"entries":[{"pageIndex":4}],"cursor":7}"#.data(using: .utf8)!
        let fixed = try JSONDecoder().decode(SectionHistory.self, from: corrupt)
        #expect(fixed.cursor == 0 && fixed.capacity == SectionHistory.defaultCapacity)
        let empty = try JSONDecoder().decode(SectionHistory.self, from: #"{"entries":[],"cursor":3}"#.data(using: .utf8)!)
        #expect(empty.cursor == -1 && empty.current == nil)
    }
}
