import CoreGraphics
import Foundation
import ReaderCore

/// The time source of `ReadingPositionKeeper`'s two windows: seconds that only ever increase.
/// Tests inject their own (`ReadingPositionKeeperTests`).
nonisolated struct ReadingPositionClock: Sendable {
    var now: @Sendable () -> TimeInterval

    init(now: @escaping @Sendable () -> TimeInterval) {
        self.now = now
    }

    /// Time since boot: not moved by a change of the device's date or time zone.
    static let system = ReadingPositionClock { ProcessInfo.processInfo.systemUptime }
}

/// The rule behind "the reading position is stable" (design), with no view in it: which changes
/// of the PDF view's scroll offset are the reader reading (they move the reading anchor) and
/// which are layout (the anchor is put back after them).
///
/// `ReaderPDFController` owns one, tells it what happens (a document attached, a size change's
/// layout pass, an offset change, a touch, a zoom command, a navigation) and does what it
/// answers: record the place on screen as the new anchor, or put the anchor back. The keeper
/// never touches PDFKit, and its clock is injected, so the whole rule is unit-tested.
///
/// The state is a phase, plus whose the scale changes are for a short while:
///
/// - `phase` says where the view is: it has no place yet (`positioning`), the reader's place is
///   known and offset changes are judged (`reading`), or a layout pass is putting the anchor
///   back and every offset change inside it is layout (`restoring`).
/// - `scaleOwner` says who is changing the scale. In fit width (`autoScales`: a double tap or
///   Fit Width) PDFKit refits the scale on its own, outside the size-change layout pass: a
///   moment after each width change, and on the next layout after a double tap. Taken as
///   reading, those offset changes moved the reader pages away when a panel opened (TSOFT-223).
///   So a scale change the reader did not make (no touch on the page, pinch or zoom command)
///   is layout: the anchor is put back after it, and after every other offset change PDFKit
///   makes while it settles.
nonisolated struct ReadingPositionKeeper {
    /// Where the view is.
    enum Phase: Equatable, Sendable {
        /// The view has no place yet: a document was just attached, or its pages are being laid
        /// out again (scroll direction, overlay provider). PDFKit's page reports are ignored and
        /// there is no anchor to keep. Ends when the pending page has been shown (`didPosition`).
        case positioning
        /// The reader's place is known. An offset change moves the anchor unless `scaleOwner`
        /// says PDFKit made it.
        case reading
        /// From the start of a layout pass that puts the anchor back (a size change, or the
        /// restore after a refit) until it has. Offset changes and page reports inside it are
        /// layout, not reading.
        case restoring
    }

    /// Whose the scale changes are, until a time on the keeper's clock.
    enum ScaleOwner: Equatable, Sendable {
        /// Nobody is known to be changing the scale: a scale that differs from the anchor's is
        /// PDFKit refitting.
        case none
        /// The reader touched the page or chose a zoom command: scale changes are theirs, and the
        /// place they leave is reading. Long enough for PDFKit's double-tap zoom animation.
        case reader(until: TimeInterval)
        /// PDFKit is settling a fit-width refit (opened by a width change in fit width, or by a
        /// refit): offset changes the reader did not make are layout. A touch, a zoom command or
        /// a navigation ends it.
        case pdfKit(until: TimeInterval)
    }

    /// What an offset change is, and so what the controller does about it.
    enum OffsetChange: Equatable, Sendable {
        /// Inside a restoring layout pass: nothing to do.
        case layout
        /// PDFKit refitting or settling a refit: put the anchor back once it has finished
        /// (`scheduleRefitRestore`).
        case refit
        /// The page moved before the view has a place: there is no anchor to move.
        case positioning
        /// The reader moved the page: the place on screen is the new anchor (`recordReading`).
        case reading
    }

    /// How long PDFKit is given to settle a refit.
    static let refitSettleInterval: TimeInterval = 0.5
    /// How long after a touch or zoom command scale changes are the reader's.
    static let readerZoomInterval: TimeInterval = 0.8
    /// Scales closer than this are the same scale.
    static let scaleTolerance: CGFloat = 0.0001

    private let clock: ReadingPositionClock

    private(set) var phase: Phase = .positioning
    /// As last set: a window that has run out is still stored. Read `currentScaleOwner`.
    private var storedScaleOwner: ScaleOwner = .none
    /// Page to show once the view has a size and a document.
    private(set) var pendingPageIndex: Int?
    /// The reader's place: the page point at the top-left of the view. Moved only by reading
    /// (scrolling, zooming, jumps, links, accessibility scrolling); restored, never re-derived,
    /// after every size change and fit-width refit, so no rounding or transient layout can
    /// accumulate into drift.
    private(set) var anchor: ReadingAnchor?
    /// The scale `anchor` was taken or last put back at.
    private(set) var anchorScale: CGFloat = 0
    /// The position moved since PDFKit's last page report was honoured. A page report with no
    /// movement behind it (PDFKit re-deriving "current" for a new width) is ignored, so the
    /// current page, subtitle, pill and last-read save never flicker during a size change.
    private(set) var hasMovedSincePageReport = false
    /// Bumped by everything that makes a scheduled refit restore stale.
    private var refitRestoreGeneration = 0
    /// A refit restore is waiting for its turn of the run loop (one at a time).
    private(set) var isRefitRestoreScheduled = false

    init(clock: ReadingPositionClock = .system) {
        self.clock = clock
    }

    /// The view has a place (it may be in the middle of restoring it).
    var isPositioned: Bool { phase != .positioning }

    /// Whose the scale changes are now (a window that has run out is `.none`).
    var currentScaleOwner: ScaleOwner {
        let now = clock.now()
        switch storedScaleOwner {
        case .none: return .none
        case .reader(let until), .pdfKit(let until): return now < until ? storedScaleOwner : .none
        }
    }

    // MARK: Positioning

    /// The page to show once the view can show it.
    mutating func setPendingPage(_ pageIndex: Int) {
        pendingPageIndex = pageIndex
    }

    /// The pending page is about to be shown.
    mutating func clearPendingPage() {
        pendingPageIndex = nil
    }

    /// The view lost its place (its pages are laid out again): back to `positioning`, with no
    /// anchor. A scheduled refit restore is stale.
    mutating func invalidatePosition() {
        phase = .positioning
        anchor = nil
        refitRestoreGeneration += 1
    }

    /// The pending page has been shown: the view has a place, `anchor` at `scale`.
    mutating func didPosition(anchor: ReadingAnchor?, scale: CGFloat) {
        phase = .reading
        self.anchor = anchor
        anchorScale = scale
    }

    // MARK: The reader's own moves

    /// The reader touched the page or chose a zoom command: the scale changes that follow are
    /// theirs, and the place they leave is reading.
    mutating func readerDidZoom() {
        storedScaleOwner = .reader(until: clock.now() + Self.readerZoomInterval)
        refitRestoreGeneration += 1
    }

    /// A navigation is about to move the view from `scale`: its offset change is reading even if
    /// a refit restore is still pending (which it cancels), and it ends PDFKit's settling.
    mutating func willNavigate(scale: CGFloat) {
        anchorScale = scale
        if case .pdfKit = storedScaleOwner { storedScaleOwner = .none }
        refitRestoreGeneration += 1
    }

    /// The place on screen after a `.reading` offset change.
    mutating func recordReading(anchor: ReadingAnchor, scale: CGFloat) {
        self.anchor = anchor
        anchorScale = scale
        hasMovedSincePageReport = true
    }

    // MARK: Offset changes

    /// Judges a change of the scroll offset. `scale` is the view's scale now;
    /// `isReaderGesturing` is whether the scroll view is being dragged, pinched or is bouncing
    /// back from a pinch.
    mutating func offsetDidChange(scale: CGFloat, isReaderGesturing: Bool) -> OffsetChange {
        switch phase {
        case .restoring: return .layout
        case .positioning: return .positioning
        case .reading: break
        }
        guard anchor != nil, !isReaderZooming(isReaderGesturing: isReaderGesturing) else { return .reading }
        if abs(scale - anchorScale) > Self.scaleTolerance {
            // A new refit opens the settle window.
            storedScaleOwner = .pdfKit(until: clock.now() + Self.refitSettleInterval)
            return .refit
        }
        if case .pdfKit = currentScaleOwner { return .refit }
        return .reading
    }

    /// Whether PDFKit's report of a new current page is honoured: only with a place, outside a
    /// restoring pass, and with movement behind it (which the report uses up).
    mutating func takePageReport() -> Bool {
        guard phase == .reading, hasMovedSincePageReport else { return false }
        hasMovedSincePageReport = false
        return true
    }

    // MARK: Size changes

    /// Before PDFKit lays out for a new size (offset and page frames are still the old ones).
    /// With no anchor yet, `placeOnScreen` is the place the reader is looking at (the caller
    /// captures it first: the view must not be asked anything while the keeper is being
    /// changed). A panel or a rotation is not a zoom, so PDFKit's refit for the new width is
    /// layout: the reader's zoom window ends. Returns whether a restoring pass has begun
    /// (`false` while positioning).
    @discardableResult
    mutating func beginSizeChange(scale: CGFloat, placeOnScreen: ReadingAnchor?) -> Bool {
        guard isPositioned else { return false }
        if anchor == nil {
            anchor = placeOnScreen
            anchorScale = scale
        }
        if case .reader = storedScaleOwner { storedScaleOwner = .none }
        phase = .restoring
        return true
    }

    /// After PDFKit has laid out for the new size and the anchor has been put back, at `scale`.
    /// In fit width PDFKit goes on refitting for a moment: the settle window opens.
    mutating func endSizeChange(scale: CGFloat, isFitWidth: Bool) {
        guard phase == .restoring else { return }
        anchorScale = scale
        if isFitWidth { storedScaleOwner = .pdfKit(until: clock.now() + Self.refitSettleInterval) }
        phase = .reading
    }

    // MARK: Refit restores

    /// After a `.refit` offset change: a ticket for the restore to run on the next turn of the
    /// run loop (PDFKit sets the zoom, then the offset), or `nil` when one is already waiting.
    mutating func scheduleRefitRestore() -> Int? {
        guard !isRefitRestoreScheduled else { return nil }
        isRefitRestoreScheduled = true
        return refitRestoreGeneration
    }

    /// The scheduled restore's turn has come. `true`: put the anchor back, then call
    /// `endRefitRestore`. `false`: the restore is stale (the reader zoomed or navigated since),
    /// a size change is restoring already, the reader is zooming, or the view lost its place.
    mutating func beginRefitRestore(ticket: Int, isReaderGesturing: Bool) -> Bool {
        isRefitRestoreScheduled = false
        guard ticket == refitRestoreGeneration, phase == .reading,
              !isReaderZooming(isReaderGesturing: isReaderGesturing) else { return false }
        phase = .restoring
        return true
    }

    /// The anchor is back in place at `scale`.
    mutating func endRefitRestore(scale: CGFloat) {
        guard phase == .restoring else { return }
        anchorScale = scale
        phase = .reading
    }

    // MARK: Private

    private func isReaderZooming(isReaderGesturing: Bool) -> Bool {
        if case .reader = currentScaleOwner { return true }
        return isReaderGesturing
    }
}
