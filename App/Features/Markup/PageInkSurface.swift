import os
import PencilKit
import ReaderCore
import UIKit

/// Accessibility identifiers of page ink (UI tests mirror these strings). `n` is the 1-based
/// page number.
nonisolated enum PageInkAccessibilityID {
    /// The overlay of page `n` (an accessibility container laid over the page).
    static func page(_ n: Int) -> String { "pageInk.page.\(n)" }
    /// The handwriting on page `n`: label "Handwriting on page n", value "k strokes", framed on
    /// the strokes; absent when the page has no ink.
    static func ink(_ n: Int) -> String { "pageInk.ink.\(n)" }
}

/// One displayed page's ink: its canvas, loading, saving, undo and reconciling with other
/// windows. Created by `PageInkOverlayProvider` when PDFKit asks for the page's overlay and
/// finished when the page leaves the screen; owned by its overlay view (so PDFKit's release of
/// the overlay releases the canvas and the drawing).
///
/// ## Lifecycle
/// 1. `init` + `startLoading()`: the canvas is created empty and read-only; the page's stored
///    drawing is read and decoded off the main actor and applied when ready (a result for a
///    surface that already finished is ignored).
/// 2. `register()` (PDFKit's `willDisplay`): registers with the window's `ReaderMarkupController`.
/// 3. Editing in markup mode: every user change marks the page dirty and schedules a save
///    `saveDelay` after the last change (never mid-stroke).
/// 4. `finish()` (the page left the screen): saves now if dirty, unregisters, and detaches the
///    canvas so nothing per page survives the page.
///
/// ## Saving and other windows
/// Every load, save and reconcile of a page runs through `PageInkQueue` (one at a time per page,
/// across windows). A save first merges whatever another window stored since this page's
/// `base` (`PageInkMerge`), so concurrent writes never drop strokes. When another window stores
/// this page while it is on screen, the change is merged into the canvas at once, or after the
/// stroke in progress ends and PencilKit has committed it; unsaved local strokes are kept and
/// saved. Applying another window's change clears this page's undo stack.
@MainActor
final class PageInkSurface: NSObject, MarkupSurface {
    enum LoadState: Equatable {
        case loading
        case ready
        /// Stored ink this system cannot read: shown as nothing, read-only, never overwritten.
        case unreadable
        case failed
    }

    // MARK: Identity

    let pageIndex: Int
    let geometry: PageInkGeometry
    let markupSurfaceID: String
    var canvasView: PKCanvasView { canvas }
    var markupUndoManager: UndoManager? { canvas.pageUndoManager }

    // MARK: State (internal for tests)

    private(set) var loadState: LoadState = .loading
    /// The stored state this page last synchronised with (loaded, saved or merged).
    private(set) var base = PageInkVersion.empty
    /// The canvas holds local changes not yet handed to a save.
    private(set) var isDirty = false
    /// The page left the screen; nothing more is applied to it.
    private(set) var isFinished = false
    /// Number of strokes on the canvas.
    var strokeCount: Int { canvas.drawing.strokes.count }

    // MARK: Collaborators

    let canvas: PageInkCanvasView
    private(set) weak var overlay: PageInkOverlayView?
    private let context: PageInkContext
    private weak var markup: ReaderMarkupController?
    private let saveDelay: Duration

    private var isMarkup = false
    private var isRegistered = false
    private var isApplying = false
    /// A tool is in use (`canvasViewDidBeginUsingTool` … `DidEndUsingTool`).
    private var isUsingTool = false
    /// The tool ended but PencilKit may not have committed the stroke yet (it waits for final
    /// Pencil pressure before `canvasViewDrawingDidChange`).
    private var isAwaitingCommit = false
    private var commitTimeout: Task<Void, Never>?
    /// Another window's change arrived while busy; reconcile when the stroke is committed.
    private var remoteChangePending = false
    /// Store results to merge into the canvas once the stroke is committed: (result, the canvas
    /// drawing the result was computed from).
    private var deferredMerges: [(result: PKDrawing, from: PKDrawing)] = []
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    /// Busy: a stroke is being drawn or has not been committed yet.
    var isStrokeBusy: Bool { isUsingTool || isAwaitingCommit }

    init(pageIndex: Int, geometry: PageInkGeometry, overlay: PageInkOverlayView?, context: PageInkContext,
         markup: ReaderMarkupController?, saveDelay: Duration) {
        self.pageIndex = pageIndex
        self.geometry = geometry
        self.markupSurfaceID = "page-\(pageIndex)"
        self.context = context
        self.markup = markup
        self.saveDelay = saveDelay
        self.overlay = overlay
        canvas = PageInkCanvasView(frame: CGRect(origin: .zero, size: geometry.size))
        canvas.contentSize = geometry.size
        super.init()
        canvas.delegate = self
        canvas.drawingPolicy = markup?.drawingPolicy ?? .default
        overlay?.attach(self)
        updateInteraction()
    }

    // MARK: Lifecycle

    /// Reads the page's drawing (through the page's queue) and shows it when ready.
    func startLoading() {
        guard loadTask == nil else { return }
        let context = context
        let pageIndex = pageIndex
        let operation: @MainActor () async -> Void = { [weak self] in
            // Stale: the page left the screen before its turn came.
            guard let self, !self.isFinished else { return }
            let result = await PageInkPersistence.load(context, pageIndex: pageIndex)
            self.didLoad(result)
        }
        loadTask = PageInkQueue.shared.enqueue(bookID: context.bookID, pageIndex: pageIndex, operation)
    }

    /// Registers with the window's markup controller (PDFKit is about to show the overlay).
    func register() {
        guard !isRegistered, !isFinished, let markup else { return }
        isRegistered = true
        markup.register(self)
    }

    /// The page left the screen: save now if anything is unsaved, unregister, detach the canvas.
    func finish() {
        guard !isFinished else { return }
        saveTask?.cancel()
        saveTask = nil
        commitTimeout?.cancel()
        if isDirty, loadState == .ready { submitSave() }
        isFinished = true
        resumeCommitWaiters()
        if isRegistered {
            isRegistered = false
            markup?.unregister(self)
        }
        if canvas.isFirstResponder { canvas.resignFirstResponder() }
        canvas.delegate = nil
        canvas.removeFromSuperview()
        overlay?.detach(self)
        PageInkOverlayProvider.debugLog("finish page \(pageIndex)")
    }

    /// The overlay left (or rejoined) the window: a safety net in case PDFKit drops an overlay
    /// without ending its display.
    func overlayDidMove(toWindow inWindow: Bool) {
        if !inWindow, isDirty, loadState == .ready, !isFinished { submitSave() }
    }

    // MARK: MarkupSurface

    func markupModeDidChange(_ isMarkup: Bool) {
        self.isMarkup = isMarkup
        updateInteraction()
    }

    func flushPendingMarkup() async {
        if isAwaitingCommit { await waitForCommit() }
        saveTask?.cancel()
        saveTask = nil
        if isDirty, loadState == .ready, !isFinished { submitSave() }
        await PageInkQueue.shared.drain(bookID: context.bookID)
    }

    // MARK: Other windows

    /// Another window stored this page: reconcile now, or once the stroke in progress is done.
    func remoteDidChange() {
        guard !isFinished else { return }
        let busy = isStrokeBusy || (markup.map { $0.isStrokeInProgress(on: self) } ?? false)
        if busy || loadState == .loading {
            remoteChangePending = true
            return
        }
        enqueueReconcile()
    }

    // MARK: Saving

    /// Hands the canvas's drawing to a save now (debounce elapsed, flush, or leaving the screen).
    func submitSave() {
        guard isDirty, loadState == .ready else { return }
        isDirty = false
        saveTask?.cancel()
        saveTask = nil
        let snapshot = canvas.drawing
        let fallbackBase = base
        let context = context
        let pageIndex = pageIndex
        let operation: @MainActor () async -> Void = { [weak self] in
            // The base is read when the save runs: an earlier save of this page may have moved
            // it on.
            let base = self?.base ?? fallbackBase
            let outcome = await PageInkPersistence.write(context, pageIndex: pageIndex, local: snapshot, base: base)
            self?.didSave(outcome, snapshot: snapshot)
        }
        PageInkQueue.shared.enqueue(bookID: context.bookID, pageIndex: pageIndex, operation)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            if self.isStrokeBusy {
                self.scheduleSave()
            } else {
                self.submitSave()
            }
        }
    }

    private func didSave(_ outcome: PageInkPersistence.WriteOutcome, snapshot: PKDrawing) {
        switch outcome {
        case .stored(let stored):
            base = stored
            guard !isFinished else { return }
            if !PageInkMerge.sameStrokes(stored.drawing, snapshot) {
                // The save merged in another window's strokes: show them, keep newer local ones.
                mergeIntoCanvas(stored.drawing, from: snapshot)
            }
        case .skipped:
            pageInkLog.error("page \(self.pageIndex): save skipped (unreadable store data or book gone)")
        case .failed(let message):
            pageInkLog.error("page \(self.pageIndex): save failed: \(message)")
            guard !isFinished else { return }
            isDirty = true
            scheduleSave()
        }
    }

    // MARK: Loading and reconciling

    private func didLoad(_ result: PageInkPersistence.LoadResult) {
        guard !isFinished else { return }
        switch result {
        case .loaded(let version):
            base = version
            apply(version.drawing)
            loadState = .ready
            if remoteChangePending { remoteChangePending = false }
        case .unreadable:
            pageInkLog.error("page \(self.pageIndex): stored ink is unreadable on this system; left untouched")
            loadState = .unreadable
        case .failed(let message):
            pageInkLog.error("page \(self.pageIndex): load failed: \(message)")
            loadState = .failed
        }
        updateInteraction()
        overlay?.inkDidChange()
    }

    private func enqueueReconcile() {
        let context = context
        let pageIndex = pageIndex
        let operation: @MainActor () async -> Void = { [weak self] in
            guard let self, !self.isFinished, self.loadState == .ready else { return }
            guard let stored = await PageInkPersistence.read(context, pageIndex: pageIndex) else { return }
            guard stored != self.base.data else { return }
            var remote = PKDrawing()
            if let stored {
                guard let decoded = await PageInkPersistence.decode(stored) else { return }
                remote = decoded
            }
            guard !self.isFinished else { return }
            let previousBase = self.base.drawing
            self.base = PageInkVersion(data: stored, drawing: remote)
            // Canvas = merge(canvas, remote, previous base): remote changes in, local kept.
            self.mergeIntoCanvas(remote, from: previousBase)
        }
        PageInkQueue.shared.enqueue(bookID: context.bookID, pageIndex: pageIndex, operation)
    }

    /// Brings `result` (a stored state computed from the canvas state `from`) into the canvas,
    /// keeping any change made on the canvas since `from`. Deferred while a stroke is busy.
    private func mergeIntoCanvas(_ result: PKDrawing, from: PKDrawing) {
        if isStrokeBusy {
            deferredMerges.append((result, from))
            return
        }
        let current = canvas.drawing
        let merged = PageInkMerge.merge(local: current, remote: result, base: from)
        if !PageInkMerge.sameStrokes(merged, current) {
            apply(merged)
            // PencilKit's undo steps refer to drawings that no longer exist.
            canvas.pageUndoManager.removeAllActions()
            overlay?.inkDidChange()
        }
        if !PageInkMerge.sameStrokes(canvas.drawing, base.drawing) {
            isDirty = true
            scheduleSave()
        }
    }

    private func apply(_ drawing: PKDrawing) {
        isApplying = true
        canvas.drawing = drawing
        isApplying = false
    }

    /// The stroke is committed (or the wait timed out): apply what waited for it.
    private func strokeDidCommit() {
        guard isAwaitingCommit else { return }
        isAwaitingCommit = false
        commitTimeout?.cancel()
        commitTimeout = nil
        resumeCommitWaiters()
        guard !isFinished else { return }
        let merges = deferredMerges
        deferredMerges = []
        for merge in merges { mergeIntoCanvas(merge.result, from: merge.from) }
        if remoteChangePending {
            remoteChangePending = false
            enqueueReconcile()
        }
    }

    private func waitForCommit() async {
        guard isAwaitingCommit else { return }
        await withCheckedContinuation { continuation in commitWaiters.append(continuation) }
    }

    private func resumeCommitWaiters() {
        let waiters = commitWaiters
        commitWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Interaction

    private func updateInteraction() {
        let editable = isMarkup && loadState == .ready && !isFinished
        canvas.isUserInteractionEnabled = editable
        canvas.drawingGestureRecognizer.isEnabled = editable
        overlay?.isUserInteractionEnabled = isMarkup
        if !editable, canvas.isFirstResponder { canvas.resignFirstResponder() }
    }

    /// Debug description for logs and tests.
    var debugSummary: String {
        "PageInkSurface(page \(pageIndex), \(loadState), \(strokeCount) strokes, dirty \(isDirty))"
    }
}

// MARK: - PKCanvasViewDelegate

extension PageInkSurface: PKCanvasViewDelegate {
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        isUsingTool = true
        isAwaitingCommit = false
        commitTimeout?.cancel()
        markup?.surfaceDidBeginStroke(self)
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        isUsingTool = false
        markup?.surfaceDidEndStroke(self)
        // PencilKit may still be waiting for the stroke's final values; anything that replaces
        // the canvas's drawing waits for `canvasViewDrawingDidChange` (or a short timeout, as
        // the change is not reported for a cancelled stroke).
        isAwaitingCommit = true
        commitTimeout?.cancel()
        commitTimeout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.strokeDidCommit()
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isApplying, !isFinished else { return }
        if loadState == .ready {
            isDirty = true
            scheduleSave()
        }
        overlay?.inkDidChange()
        if !isUsingTool { strokeDidCommit() }
    }
}

// MARK: - Views

/// The page's canvas: transparent, never scrolls, ink in ink space (`PageInkGeometry`), drawn
/// as stored in every appearance (the page stays white), its own undo stack.
final class PageInkCanvasView: PKCanvasView {
    /// The page's undo stack (PencilKit registers with the responder's `undoManager`; without
    /// this override every canvas of the window would share the window's).
    let pageUndoManager = UndoManager()

    nonisolated private static let liveCounter = OSAllocatedUnfairLock(initialState: 0)

    /// Number of page canvases alive in the process (tests and diagnostics).
    nonisolated static var liveCount: Int { liveCounter.withLock { $0 } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        Self.liveCounter.withLock { $0 += 1 }
        backgroundColor = .clear
        isOpaque = false
        isScrollEnabled = false
        bounces = false
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        overrideUserInterfaceStyle = .light
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        pageUndoManager.levelsOfUndo = 100
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        Self.liveCounter.withLock { $0 -= 1 }
    }

    override var undoManager: UndoManager? { pageUndoManager }
}

/// The view PDFKit lays over one page. PDFKit sizes it to the display box unrotated and rotates
/// and zooms it with the page (`PageInkGeometry.inkToOverlay`); it hosts the page's canvas in
/// ink space, upright on screen, and exposes the page's handwriting to accessibility.
final class PageInkOverlayView: UIView {
    let pageIndex: Int
    /// Ink space → this view's space.
    private let inkToOverlay: CGAffineTransform
    private let inkSize: CGSize
    private(set) var surface: PageInkSurface?

    init(pageIndex: Int, geometry: PageInkGeometry, displayBox: CGRect) {
        self.pageIndex = pageIndex
        inkToOverlay = geometry.inkToOverlay(displayBox: displayBox)
        inkSize = geometry.size
        super.init(frame: CGRect(origin: .zero, size: PageInkGeometry.overlaySize(displayBox: displayBox)))
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        accessibilityIdentifier = PageInkAccessibilityID.page(pageIndex + 1)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func attach(_ surface: PageInkSurface) {
        self.surface = surface
        let canvas = surface.canvas
        // A view maps p to center + T·(p − size/2); with T the linear part of inkToOverlay and
        // center the image of the canvas's centre, that is exactly inkToOverlay(p).
        let t = inkToOverlay
        canvas.bounds = CGRect(origin: .zero, size: inkSize)
        canvas.contentSize = inkSize
        canvas.transform = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0)
        canvas.center = CGPoint(x: inkSize.width / 2, y: inkSize.height / 2).applying(t)
        addSubview(canvas)
    }

    func detach(_ surface: PageInkSurface) {
        guard self.surface === surface else { return }
        self.surface = nil
        inkDidChange()
    }

    /// Called when the page's ink changed (load, stroke, merge) so accessibility can follow.
    var onInkChange: (() -> Void)?

    func inkDidChange() {
        onInkChange?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        surface?.overlayDidMove(toWindow: window != nil)
    }

    /// Only the canvas takes touches, and only in markup mode (`isUserInteractionEnabled`);
    /// the overlay itself never does, so PDFKit gets every touch beside the canvas.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
