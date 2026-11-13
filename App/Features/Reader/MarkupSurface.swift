import Foundation
import Observation
import PencilKit
import UIKit

/// An ink canvas that takes part in the reader window's markup mode: a page canvas (WP6, one per
/// visible page) or the note canvas (WP13).
///
/// ## The sequence a surface must follow
/// 1. **Create** your `PKCanvasView` (a subclass is fine). Set `canvasView.delegate` yourself.
///    Do **not** create a `PKToolPicker`, do not set `drawingPolicy` (the session does), do not
///    add gesture recognisers for Pencil double-tap / squeeze / hover.
/// 2. **Register** once the canvas is in the view hierarchy (for a page overlay: in
///    `overlayWillAppear`; for the note: when the note view moves to a window):
///    `session.markup.register(self)`. The session then sets `canvasView.drawingPolicy`, adds
///    the canvas as an observer of the window's tool picker (so it gets the selected tool and
///    ruler), registers it with `setVisible(_:forFirstResponder:)`, and calls
///    `markupModeDidChange(_:)` with the current mode.
/// 3. **Mode.** In `markupModeDidChange(_:)` make the canvas editable (`true`) or read-only
///    (`false`): e.g. `canvasView.isUserInteractionEnabled = isMarkup` for a page canvas;
///    WP13 routes touches itself. Ink stays visible in both modes.
/// 4. **Activity.** When a stroke begins (`canvasViewDidBeginUsingTool`) call
///    `session.markup.surfaceDidBeginStroke(self)`; when it ends (`canvasViewDidEndUsingTool`)
///    call `session.markup.surfaceDidEndStroke(self)`. Undo/Redo (toolbar and ⌘Z) go to the
///    surface that most recently began a stroke. While `isStrokeInProgress(on:)` is true, do not
///    reload the surface from a change made in another window; reconcile after the stroke.
/// 5. **Saving.** Save on your own debounce and when the page leaves the screen. Implement
///    `flushPendingMarkup()` to write anything pending **now**; the session awaits it on Done,
///    on backgrounding/close, and on memory warnings. Write through `LibraryStore` with
///    `origin: session.origin`.
/// 6. **Unregister** before the canvas is released (page overlay: in `overlayDidDisappear`,
///    after starting your save): `session.markup.unregister(self)`.
///
/// ## Undo
/// Return a per-surface `UndoManager` from `markupUndoManager`, and make the canvas use it:
/// `PKCanvasView` registers its undo actions with its responder `undoManager`, which by default
/// is the **window's** shared one. Subclass `PKCanvasView` and override `undoManager` to return
/// your surface's manager, or every canvas in the window will share one stack.
@MainActor
protocol MarkupSurface: AnyObject {
    /// Unique within the session and stable while registered, e.g. `"page-311"` or
    /// `"note-<noteID>"`.
    var markupSurfaceID: String { get }
    /// The canvas the shared tool picker drives.
    var canvasView: PKCanvasView { get }
    /// The undo stack of this surface's strokes (see the type documentation).
    var markupUndoManager: UndoManager? { get }
    /// The window entered (`true`) or left (`false`) markup mode. Also called on registration.
    func markupModeDidChange(_ isMarkup: Bool)
    /// Write pending ink now. Must be safe to call repeatedly and when nothing is pending.
    func flushPendingMarkup() async
}

/// One per reader window (`ReaderSession.markup`): the registry of `MarkupSurface`s, the one
/// system `PKToolPicker` of the window, and undo/redo routing.
///
/// **Tool picker rules (verified on iOS 27 and 17.5):** a `PKToolPicker` is shown in the window
/// of the first responder it was made visible for. This controller owns a zero-size
/// `MarkupResponderView` (inserted by the PDF host view) that becomes first responder in markup
/// mode, so the picker appears even before any canvas exists. Every registered canvas is also
/// made visible-for, so the picker stays when a canvas becomes first responder (e.g. lasso).
/// A responder that is *not* registered (the go-to-page field, search field) hides the picker
/// while it is first responder; when it resigns, call `reassertToolPicker()` (the shell does
/// this for its own fields). A note's text view (WP13) should be registered with
/// `registerAuxiliaryResponder(_:)` so typing in markup mode keeps the picker.
@Observable
@MainActor
final class ReaderMarkupController: NSObject, PKToolPickerObserver {
    /// The window's tool picker. Do not call `setVisible` on it yourself; use the session.
    @ObservationIgnored let toolPicker = PKToolPicker()
    /// The drawing policy canvases use (`.default`, or `.anyInput` under `-inkAnyInput`).
    let drawingPolicy: PKCanvasViewDrawingPolicy
    /// Whether the tool picker is currently on screen.
    private(set) var isToolPickerVisible = false
    /// Whether Undo / Redo can act on the routed surface.
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// The surface that most recently began a stroke (undo/redo target), if still registered.
    private(set) var activeSurfaceID: String?
    /// IDs of registered surfaces (for diagnostics and tests).
    private(set) var registeredSurfaceIDs: [String] = []

    @ObservationIgnored weak var session: ReaderSession?
    /// The first responder that carries the tool picker in markup mode. Inserted into the view
    /// hierarchy by the PDF host view.
    @ObservationIgnored let responderView = MarkupResponderView()

    @ObservationIgnored private var surfaces: [String: WeakSurface] = [:]
    /// Surface IDs in order of last activity (most recent last).
    @ObservationIgnored private var activity: [String] = []
    @ObservationIgnored private var strokesInProgress: Set<String> = []
    @ObservationIgnored private var auxiliaryResponders: [WeakResponder] = []
    @ObservationIgnored private var isMarkup = false

    init(drawingPolicy: PKCanvasViewDrawingPolicy) {
        self.drawingPolicy = drawingPolicy
        super.init()
        responderView.controller = self
        toolPicker.addObserver(self)
        toolPicker.setVisible(false, forFirstResponder: responderView)
        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange, .NSUndoManagerWillCloseUndoGroup] {
            center.addObserver(self, selector: #selector(undoManagerChanged(_:)), name: name, object: nil)
        }
    }

    // MARK: Registration

    /// Registers a surface (step 2 of the `MarkupSurface` sequence). Re-registering is a no-op.
    func register(_ surface: any MarkupSurface) {
        let id = surface.markupSurfaceID
        if let existing = surfaces[id]?.value, existing === surface { return }
        surfaces[id] = WeakSurface(surface)
        if !registeredSurfaceIDs.contains(id) { registeredSurfaceIDs.append(id) }
        let canvas = surface.canvasView
        canvas.drawingPolicy = drawingPolicy
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(isMarkup, forFirstResponder: canvas)
        surface.markupModeDidChange(isMarkup)
        refreshUndoState()
    }

    /// Unregisters a surface (step 6). Unknown surfaces are ignored.
    func unregister(_ surface: any MarkupSurface) {
        let id = surface.markupSurfaceID
        guard let existing = surfaces[id]?.value, existing === surface else { return }
        toolPicker.removeObserver(surface.canvasView)
        toolPicker.setVisible(false, forFirstResponder: surface.canvasView)
        surfaces[id] = nil
        registeredSurfaceIDs.removeAll { $0 == id }
        activity.removeAll { $0 == id }
        strokesInProgress.remove(id)
        if activeSurfaceID == id { activeSurfaceID = activity.last }
        if surface.canvasView.isFirstResponder { reassertToolPicker() }
        refreshUndoState()
    }

    /// Registers a non-canvas responder that may become first responder during markup mode
    /// (WP13's note text view), so the tool picker stays visible while it is first responder.
    func registerAuxiliaryResponder(_ responder: UIResponder) {
        auxiliaryResponders.removeAll { $0.value == nil || $0.value === responder }
        auxiliaryResponders.append(WeakResponder(responder))
        toolPicker.setVisible(isMarkup, forFirstResponder: responder)
    }

    func unregisterAuxiliaryResponder(_ responder: UIResponder) {
        auxiliaryResponders.removeAll { $0.value == nil || $0.value === responder }
        toolPicker.setVisible(false, forFirstResponder: responder)
    }

    // MARK: Activity and undo

    /// Step 4: a stroke began on `surface`; it becomes the undo/redo target.
    func surfaceDidBeginStroke(_ surface: any MarkupSurface) {
        let id = surface.markupSurfaceID
        guard surfaces[id] != nil else { return }
        strokesInProgress.insert(id)
        activity.removeAll { $0 == id }
        activity.append(id)
        activeSurfaceID = id
    }

    /// Step 4: the stroke on `surface` ended.
    func surfaceDidEndStroke(_ surface: any MarkupSurface) {
        strokesInProgress.remove(surface.markupSurfaceID)
        refreshUndoState()
    }

    /// `true` while a stroke is in progress on that surface.
    func isStrokeInProgress(on surface: any MarkupSurface) -> Bool {
        strokesInProgress.contains(surface.markupSurfaceID)
    }

    /// The undo manager Undo/Redo act on: the most recently active registered surface's.
    var routedUndoManager: UndoManager? {
        for id in activity.reversed() {
            if let surface = surfaces[id]?.value { return surface.markupUndoManager }
        }
        return nil
    }

    func undo() {
        guard let manager = routedUndoManager, manager.canUndo else { return }
        manager.undo()
        refreshUndoState()
    }

    func redo() {
        guard let manager = routedUndoManager, manager.canRedo else { return }
        manager.redo()
        refreshUndoState()
    }

    // MARK: Flush

    /// Awaits `flushPendingMarkup()` on every registered surface.
    func flushAll() async {
        let live = surfaces.values.compactMap(\.value)
        for surface in live {
            await surface.flushPendingMarkup()
        }
    }

    // MARK: Mode

    /// Called by the session when the mode changes.
    func modeDidChange(to mode: ReaderSession.Mode) {
        isMarkup = mode == .markup
        toolPicker.setVisible(isMarkup, forFirstResponder: responderView)
        for surface in surfaces.values.compactMap(\.value) {
            toolPicker.setVisible(isMarkup, forFirstResponder: surface.canvasView)
            surface.markupModeDidChange(isMarkup)
        }
        for responder in auxiliaryResponders.compactMap(\.value) {
            toolPicker.setVisible(isMarkup, forFirstResponder: responder)
        }
        if isMarkup {
            reassertToolPicker()
        } else if responderView.isFirstResponder {
            responderView.resignFirstResponder()
        }
    }

    /// In markup mode, makes the responder view first responder again if no registered
    /// responder is (call after a text field you own ends editing).
    func reassertToolPicker() {
        guard isMarkup, responderView.window != nil else { return }
        let registeredFirst = surfaces.values.contains { $0.value?.canvasView.isFirstResponder == true }
            || auxiliaryResponders.contains { $0.value?.isFirstResponder == true }
        if !registeredFirst && !responderView.isFirstResponder {
            responderView.becomeFirstResponder()
        }
    }

    /// The responder view moved into a window (called by `MarkupResponderView`).
    func responderViewDidMoveToWindow() {
        guard isMarkup else { return }
        reassertToolPicker()
        // The window may not accept a first responder until the current update has finished.
        DispatchQueue.main.async { [weak self] in self?.reassertToolPicker() }
    }

    // MARK: PKToolPickerObserver

    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        isToolPickerVisible = toolPicker.isVisible
    }

    // MARK: Private

    @objc private func undoManagerChanged(_ notification: Notification) {
        refreshUndoState()
    }

    private func refreshUndoState() {
        let manager = routedUndoManager
        let undo = manager?.canUndo ?? false
        let redo = manager?.canRedo ?? false
        if undo != canUndo { canUndo = undo }
        if redo != canRedo { canRedo = redo }
    }

    private final class WeakSurface {
        weak var value: (any MarkupSurface)?
        init(_ value: any MarkupSurface) { self.value = value }
    }

    private final class WeakResponder {
        weak var value: UIResponder?
        init(_ value: UIResponder) { self.value = value }
    }
}

/// The invisible first responder that carries the tool picker in markup mode. Its `undoManager`
/// is the routed surface's, so the system Undo/Redo commands (⌘Z, ⇧⌘Z, Edit menu) act on the
/// surface last drawn on while it is first responder.
final class MarkupResponderView: UIView {
    weak var controller: ReaderMarkupController?

    override var canBecomeFirstResponder: Bool { true }

    override var undoManager: UndoManager? {
        controller?.routedUndoManager ?? super.undoManager
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { controller?.responderViewDidMoveToWindow() }
    }
}
