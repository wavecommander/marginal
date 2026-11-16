import CoreGraphics
import Foundation
import ReaderCore
import Testing
@testable import Marginal

/// The rule behind "the reading position is stable", as phase transitions of
/// `ReadingPositionKeeper` on a clock the test moves by hand: which offset changes are the reader
/// reading (they move the anchor) and which are layout (the anchor is kept and put back).
struct ReadingPositionKeeperTests {
    typealias Keeper = ReadingPositionKeeper

    /// A clock that only moves when the test says so.
    final class ManualClock: @unchecked Sendable {
        var time: TimeInterval = 1000
        var clock: ReadingPositionClock { ReadingPositionClock { [self] in time } }
        func advance(_ seconds: TimeInterval) { time += seconds }
    }

    let clock = ManualClock()
    let place = ReadingAnchor(pageIndex: 4, point: CGPoint(x: 0, y: 500))
    let elsewhere = ReadingAnchor(pageIndex: 9, point: CGPoint(x: 0, y: 120))
    let fitNarrow: CGFloat = 0.9
    let fitWide: CGFloat = 1.4

    /// A keeper whose view has been positioned at `place`, at scale `fitNarrow`.
    private func positionedKeeper() -> Keeper {
        var keeper = Keeper(clock: clock.clock)
        keeper.setPendingPage(place.pageIndex)
        keeper.clearPendingPage()
        keeper.willNavigate(scale: fitNarrow)
        keeper.didPosition(anchor: place, scale: fitNarrow)
        return keeper
    }

    // MARK: Positioning

    @Test func startsWithNoPlaceAndIgnoresPDFKitUntilPositioned() {
        var keeper = Keeper(clock: clock.clock)
        #expect(keeper.phase == .positioning)
        #expect(!keeper.isPositioned)
        #expect(keeper.anchor == nil)

        keeper.setPendingPage(7)
        #expect(keeper.pendingPageIndex == 7)
        // PDFKit moving the view while it lays out is not reading, and its page reports are not
        // the reader's page.
        #expect(keeper.offsetDidChange(scale: fitNarrow, isReaderGesturing: false) == .positioning)
        #expect(keeper.takePageReport() == false)
        #expect(keeper.beginSizeChange(scale: fitNarrow, placeOnScreen: elsewhere) == false)
        #expect(keeper.anchor == nil, "a size change before the first page is shown captures nothing")
        #expect(keeper.phase == .positioning)

        keeper.clearPendingPage()
        keeper.willNavigate(scale: fitNarrow)
        keeper.didPosition(anchor: place, scale: fitNarrow)
        #expect(keeper.phase == .reading)
        #expect(keeper.isPositioned)
        #expect(keeper.pendingPageIndex == nil)
        #expect(keeper.anchor == place)
        #expect(keeper.anchorScale == fitNarrow)
    }

    @Test func layingThePagesOutAgainGoesBackToPositioning() {
        var keeper = positionedKeeper()
        keeper.invalidatePosition()
        keeper.setPendingPage(place.pageIndex)
        #expect(keeper.phase == .positioning)
        #expect(keeper.anchor == nil)
        #expect(keeper.pendingPageIndex == place.pageIndex)
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .positioning)

        keeper.clearPendingPage()
        keeper.willNavigate(scale: fitWide)
        keeper.didPosition(anchor: elsewhere, scale: fitWide)
        #expect(keeper.phase == .reading)
        #expect(keeper.anchor == elsewhere)
    }

    @Test func aRefitRestoreScheduledBeforeThePagesWereLaidOutAgainIsDropped() throws {
        var keeper = positionedKeeper()
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .refit)
        let scheduled = keeper.scheduleRefitRestore()
        let ticket = try #require(scheduled)
        keeper.invalidatePosition()
        #expect(keeper.beginRefitRestore(ticket: ticket, isReaderGesturing: false) == false)
        #expect(keeper.phase == .positioning)
    }

    // MARK: Reading

    @Test func scrollingMovesTheAnchorAndEachMovementAllowsOnePageReport() {
        var keeper = positionedKeeper()
        #expect(keeper.takePageReport() == false, "a page report with no movement behind it is ignored")

        #expect(keeper.offsetDidChange(scale: fitNarrow, isReaderGesturing: true) == .reading)
        keeper.recordReading(anchor: elsewhere, scale: fitNarrow)
        #expect(keeper.anchor == elsewhere)
        #expect(keeper.takePageReport() == true)
        #expect(keeper.takePageReport() == false, "the movement is used up by the report it allowed")

        // A programmatic move (a jump, a link, accessibility scrolling) at the same scale is
        // reading too.
        #expect(keeper.offsetDidChange(scale: fitNarrow, isReaderGesturing: false) == .reading)
    }

    // MARK: Size changes

    @Test func aSizeChangeIsLayoutAndKeepsTheAnchor() {
        var keeper = positionedKeeper()
        #expect(keeper.offsetDidChange(scale: fitNarrow, isReaderGesturing: true) == .reading)
        keeper.recordReading(anchor: place, scale: fitNarrow)

        #expect(keeper.beginSizeChange(scale: fitNarrow, placeOnScreen: elsewhere) == true)
        #expect(keeper.phase == .restoring)
        #expect(keeper.anchor == place, "an existing anchor is restored, never re-derived")
        // Everything PDFKit does inside the pass is layout.
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .layout)
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: true) == .layout)
        #expect(keeper.takePageReport() == false, "PDFKit re-deriving the current page for a new width")
        keeper.endSizeChange(scale: fitWide, isFitWidth: false)

        #expect(keeper.phase == .reading)
        #expect(keeper.anchor == place)
        #expect(keeper.anchorScale == fitWide)
        #expect(keeper.currentScaleOwner == .none)
        #expect(keeper.takePageReport() == true, "the reader's earlier movement still allows its report")
    }

    @Test func aSizeChangeCapturesThePlaceOnScreenOnlyWhenThereIsNoAnchor() {
        var keeper = Keeper(clock: clock.clock)
        keeper.didPosition(anchor: nil, scale: fitNarrow)  // PDFKit had no scroll view yet
        #expect(keeper.beginSizeChange(scale: fitNarrow, placeOnScreen: elsewhere) == true)
        #expect(keeper.anchor == elsewhere)
        #expect(keeper.anchorScale == fitNarrow)
        keeper.endSizeChange(scale: fitWide, isFitWidth: false)
        #expect(keeper.anchor == elsewhere)
    }

    @Test func panelsOpenedAndClosedAnyNumberOfTimesNeverMoveTheAnchor() {
        var keeper = positionedKeeper()
        for round in 0..<20 {
            let scale = round.isMultiple(of: 2) ? fitWide : fitNarrow
            #expect(keeper.beginSizeChange(scale: keeper.anchorScale, placeOnScreen: elsewhere) == true)
            #expect(keeper.offsetDidChange(scale: scale, isReaderGesturing: false) == .layout)
            keeper.endSizeChange(scale: scale, isFitWidth: true)
            // PDFKit refits a moment later, outside the pass: still layout.
            clock.advance(0.1)
            #expect(keeper.offsetDidChange(scale: scale, isReaderGesturing: false) == .refit)
            clock.advance(1)
        }
        #expect(keeper.anchor == place)
        #expect(keeper.takePageReport() == false)
    }

    // MARK: Fit-width refits (TSOFT-223)

    @Test func afterAWidthChangeInFitWidthPDFKitSettlesForHalfASecond() {
        var keeper = positionedKeeper()
        #expect(keeper.beginSizeChange(scale: fitNarrow, placeOnScreen: nil) == true)
        keeper.endSizeChange(scale: fitWide, isFitWidth: true)
        #expect(keeper.currentScaleOwner == .pdfKit(until: clock.time + Keeper.refitSettleInterval))

        clock.advance(0.49)
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .refit)
        clock.advance(0.02)
        #expect(keeper.currentScaleOwner == .none)
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .reading)
    }

    @Test func aScaleChangeTheReaderDidNotMakeIsARefitAndOpensTheSettleWindow() {
        var keeper = positionedKeeper()
        // PDFKit refits on its own (the next layout after a double tap, long after any touch).
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .refit)
        #expect(keeper.currentScaleOwner == .pdfKit(until: clock.time + Keeper.refitSettleInterval))
        #expect(keeper.anchor == place)
        #expect(keeper.anchorScale == fitNarrow, "the anchor's scale changes only when it is put back")

        // Each further refit keeps the window open.
        clock.advance(0.4)
        #expect(keeper.offsetDidChange(scale: fitWide + 0.1, isReaderGesturing: false) == .refit)
        clock.advance(0.4)
        #expect(keeper.offsetDidChange(scale: fitWide + 0.1, isReaderGesturing: false) == .refit)
    }

    @Test func scalesWithinTheToleranceAreTheSameScale() {
        var keeper = positionedKeeper()
        #expect(keeper.offsetDidChange(scale: fitNarrow + 0.00005, isReaderGesturing: false) == .reading)
        #expect(keeper.offsetDidChange(scale: fitNarrow + 0.001, isReaderGesturing: false) == .refit)
    }

    @Test func afterATouchOrZoomCommandScaleChangesAreTheReaders() {
        var keeper = positionedKeeper()
        keeper.readerDidZoom()
        #expect(keeper.currentScaleOwner == .reader(until: clock.time + Keeper.readerZoomInterval))
        // PDFKit's double-tap zoom animation: no finger down, the scale moving.
        clock.advance(0.7)
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .reading)
        keeper.recordReading(anchor: elsewhere, scale: fitWide)
        #expect(keeper.anchor == elsewhere)
        #expect(keeper.anchorScale == fitWide)

        // Once the window has run out, a scale change with no touch behind it is a refit again.
        clock.advance(0.2)
        #expect(keeper.currentScaleOwner == .none)
        #expect(keeper.offsetDidChange(scale: fitNarrow, isReaderGesturing: false) == .refit)
    }

    @Test func aPinchInProgressIsReadingWhateverTheScale() {
        var keeper = positionedKeeper()
        #expect(keeper.offsetDidChange(scale: 2.5, isReaderGesturing: true) == .reading)
        #expect(keeper.currentScaleOwner == .none)
    }

    @Test func aTouchEndsPDFKitsSettling() {
        var keeper = positionedKeeper()
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .refit)
        keeper.readerDidZoom()
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .reading)
    }

    @Test func aSizeChangeEndsTheReadersZoomWindow() {
        var keeper = positionedKeeper()
        keeper.readerDidZoom()
        // A panel or rotation is not a zoom: PDFKit's refit for the new width is layout.
        #expect(keeper.beginSizeChange(scale: fitNarrow, placeOnScreen: nil) == true)
        #expect(keeper.currentScaleOwner == .none)
        keeper.endSizeChange(scale: fitWide, isFitWidth: false)
        #expect(keeper.offsetDidChange(scale: fitNarrow, isReaderGesturing: false) == .refit)
    }

    @Test func aSizeChangeOutsideFitWidthLeavesASettleWindowAsItWas() {
        var keeper = positionedKeeper()
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .refit)
        let window = keeper.currentScaleOwner
        clock.advance(0.1)
        #expect(keeper.beginSizeChange(scale: fitWide, placeOnScreen: nil) == true)
        keeper.endSizeChange(scale: fitWide, isFitWidth: false)
        #expect(keeper.currentScaleOwner == window)
    }

    @Test func aNavigationIsReadingAndEndsTheSettleWindowButNotTheReadersZoom() {
        var keeper = positionedKeeper()
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .refit)
        keeper.willNavigate(scale: fitWide)
        #expect(keeper.currentScaleOwner == .none)
        #expect(keeper.anchorScale == fitWide)
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .reading)

        keeper.readerDidZoom()
        let window = keeper.currentScaleOwner
        keeper.willNavigate(scale: fitWide)
        #expect(keeper.currentScaleOwner == window)
    }

    // MARK: Refit restores

    @Test func aRefitRestorePutsTheAnchorBackOncePerTurn() throws {
        var keeper = positionedKeeper()
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .refit)
        let scheduled = keeper.scheduleRefitRestore()
        let ticket = try #require(scheduled)
        // PDFKit sets the zoom, then the offset: one restore for both.
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .refit)
        #expect(keeper.scheduleRefitRestore() == nil)
        #expect(keeper.isRefitRestoreScheduled)

        #expect(keeper.beginRefitRestore(ticket: ticket, isReaderGesturing: false) == true)
        #expect(keeper.phase == .restoring)
        #expect(!keeper.isRefitRestoreScheduled)
        // Putting the anchor back moves the offset: layout.
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .layout)
        keeper.endRefitRestore(scale: fitWide)

        #expect(keeper.phase == .reading)
        #expect(keeper.anchor == place)
        #expect(keeper.anchorScale == fitWide)
        // Still settling: whatever PDFKit does next is put back too.
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .refit)
        #expect(keeper.scheduleRefitRestore() != nil)
    }

    @Test func aRefitRestoreIsDroppedWhenTheReaderZoomedOrNavigatedSince() throws {
        var keeper = positionedKeeper()
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .refit)
        let beforeTouchTicket = keeper.scheduleRefitRestore()
        let beforeTouch = try #require(beforeTouchTicket)
        keeper.readerDidZoom()
        #expect(keeper.beginRefitRestore(ticket: beforeTouch, isReaderGesturing: false) == false)
        #expect(keeper.phase == .reading)
        #expect(!keeper.isRefitRestoreScheduled, "the next refit can schedule a restore again")

        clock.advance(1)
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .refit)
        let beforeJumpTicket = keeper.scheduleRefitRestore()
        let beforeJump = try #require(beforeJumpTicket)
        keeper.willNavigate(scale: fitWide)
        #expect(keeper.beginRefitRestore(ticket: beforeJump, isReaderGesturing: false) == false)
        #expect(keeper.phase == .reading)
    }

    @Test func aRefitRestoreDoesNotRunWhileTheReaderIsZoomingOrASizeChangeIsRestoring() throws {
        var keeper = positionedKeeper()
        #expect(keeper.offsetDidChange(scale: fitWide, isReaderGesturing: false) == .refit)
        let whilePinchingTicket = keeper.scheduleRefitRestore()
        let whilePinching = try #require(whilePinchingTicket)
        #expect(keeper.beginRefitRestore(ticket: whilePinching, isReaderGesturing: true) == false)
        #expect(keeper.phase == .reading)

        let duringSizeChangeTicket = keeper.scheduleRefitRestore()
        let duringSizeChange = try #require(duringSizeChangeTicket)
        #expect(keeper.beginSizeChange(scale: fitWide, placeOnScreen: nil) == true)
        #expect(keeper.beginRefitRestore(ticket: duringSizeChange, isReaderGesturing: false) == false)
        #expect(keeper.phase == .restoring, "the size change's own pass goes on")
        keeper.endSizeChange(scale: fitWide, isFitWidth: true)
        #expect(keeper.phase == .reading)
    }

    @Test func endingAPassThatNeverBeganChangesNothing() {
        var keeper = positionedKeeper()
        keeper.endSizeChange(scale: fitWide, isFitWidth: true)
        keeper.endRefitRestore(scale: fitWide)
        #expect(keeper.phase == .reading)
        #expect(keeper.anchorScale == fitNarrow)
        #expect(keeper.currentScaleOwner == .none)
    }
}
