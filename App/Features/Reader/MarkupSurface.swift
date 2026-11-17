import Foundation
import GameController
import Observation
import PencilKit
import UIKit

/// An ink canvas that takes part in the reader window's markup mode: a page canvas (page ink, one per
/// visible page) or the note canvas (the note page).
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
///    The note page routes touches itself. Ink stays visible in both modes.
/// 4. **Activity.** When a stroke begins (`canvasViewDidBeginUsingTool`) call
///    `session.markup.surfaceDidBeginStroke(self)`; when it ends (`canvasViewDidEndUsingTool`)
///    call `session.markup.surfaceDidEndStroke(self)`. Undo/Redo (the tool picker's buttons,
///    ⌘Z / ⇧⌘Z, the Edit menu, and the toolbar at compact width) go to the surface that most
///    recently began a stroke. While `isStrokeInProgress(on:)` is true, do not
///    reload the surface from a change made in another window; reconcile after the stroke.
/// 5. **Saving.** Save on your own debounce and when the page leaves the screen. Implement
///    `flushPendingMarkup()` to write anything pending **now**; the session awaits it on leaving
///    markup mode,
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
/// **Tool picker rules (verified by UI tests on iOS 27.0 and 17.5, with and without a registered
/// surface):** a `PKToolPicker` is shown in the window of the first responder it was made
/// visible for. This controller owns a zero-size `MarkupResponderView` (inserted by the PDF host
/// view) that becomes first responder in markup mode, so the picker appears even before any
/// canvas exists; surfaces never need to become first responder to show it. Every registered
/// canvas is also made visible-for, so the picker stays when a canvas becomes first responder
/// (e.g. lasso). The shell re-asserts the responder after the reader appears, when the scene
/// becomes active and when its own text fields end editing.
/// A responder that is *not* registered (the go-to-page field, search field) hides the picker
/// while it is first responder; when it resigns, call `reassertToolPicker()` (the shell does
/// this for its own fields). A note's text view is registered with
/// `registerAuxiliaryResponder(_:)`: with a hardware keyboard attached, typing in markup mode
/// keeps the picker. Without one the picker steps aside while the text view is first responder,
/// so the on-screen keyboard has the bottom of the screen (the docked picker and the keyboard
/// share it: shown for the text view, the picker sat behind the keyboard), and comes back as it
/// was (same tool, colour and place: it is the same `PKToolPicker`) when typing ends.
@Observable
@MainActor
final class ReaderMarkupController: NSObject, PKToolPickerObserver {
    /// The window's tool picker. Do not call `setVisible` on it yourself; use the session.
    @ObservationIgnored let toolPicker = PKToolPicker()
    /// The drawing policy canvases use (`.default`, or `.anyInput` under `-inkAnyInput`).
    let drawingPolicy: PKCanvasViewDrawingPolicy
    /// Whether the tool picker is currently on screen.
    private(set) var isToolPickerVisible = false
    /// How many times the tool picker has come on screen (diagnostics and tests: entering markup
    /// once shows it once, with no hide and show in between).
    @ObservationIgnored private(set) var toolPickerShowCount = 0
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
    /// The responder view's undo manager for the life of the window: a stable stand-in for
    /// `routedUndoManager` (see `MarkupRoutingUndoManager`), so the tool picker's own Undo/Redo
    /// buttons, ⌘Z / ⇧⌘Z and Edit ▸ Undo/Redo follow the surface last drawn on.
    @ObservationIgnored let routingUndoManager = MarkupRoutingUndoManager()

    @ObservationIgnored private var surfaces: [String: WeakSurface] = [:]
    /// Surface IDs in order of last activity (most recent last).
    @ObservationIgnored private var activity: [String] = []
    @ObservationIgnored private var strokesInProgress: Set<String> = []
    @ObservationIgnored private var auxiliaryResponders: [WeakResponder] = []
    @ObservationIgnored private var isMarkup = false
    /// The window the tool picker has been on screen in (see `showingToolPicker(_:)`).
    @ObservationIgnored private weak var toolPickerWindow: UIWindow?
    /// A reassert is waiting for the navigation transition to finish.
    @ObservationIgnored private var isAwaitingTransition = false
    /// A hardware keyboard is attached (`GCKeyboard`), or the `-hardwareKeyboard` test override.
    @ObservationIgnored private var hasHardwareKeyboard: Bool
    /// `GCKeyboardDidConnect` / `DidDisconnect` observers (none under the test override).
    @ObservationIgnored private var keyboardObservers: [NSObjectProtocol] = []
    /// The routed manager the proxy last announced (to announce a change of routed surface).
    @ObservationIgnored private weak var announcedRoutedManager: UndoManager?
    @ObservationIgnored private var hasAnnouncedRouting = false
    /// `canUndo` / `canRedo` as read when the proxy last posted (see `scheduleStateCheck()`).
    @ObservationIgnored private var announcedState: (undo: Bool, redo: Bool) = (false, false)
    @ObservationIgnored private var isStateCheckScheduled = false

    /// `hardwareKeyboard`: `nil` follows the attached keyboards (`GCKeyboard`); `true` / `false`
    /// pins the answer (UI tests, `-hardwareKeyboard`).
    init(drawingPolicy: PKCanvasViewDrawingPolicy, hardwareKeyboard: Bool? = nil) {
        self.drawingPolicy = drawingPolicy
        self.hasHardwareKeyboard = hardwareKeyboard ?? (GCKeyboard.coalesced != nil)
        super.init()
        responderView.controller = self
        routingUndoManager.controller = self
        toolPicker.addObserver(self)
        toolPicker.setVisible(false, forFirstResponder: responderView)
        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange, .NSUndoManagerWillCloseUndoGroup] {
            center.addObserver(self, selector: #selector(undoManagerChanged(_:)), name: name, object: nil)
        }
        if hardwareKeyboard == nil {
            for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
                keyboardObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.keyboardConnectionChanged() }
                })
            }
        }
    }

    /// Whether the tool picker stays on screen while a note's text view is first responder:
    /// only with a hardware keyboard. Without one the on-screen keyboard takes the bottom of
    /// the screen, so the picker steps aside until typing ends (see the type documentation).
    var keepsPickerWhileTyping: Bool { hasHardwareKeyboard }

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
    /// (the note page's text view). With a hardware keyboard the tool picker stays visible while it
    /// is first responder; without one the picker steps aside for the on-screen keyboard
    /// (`keepsPickerWhileTyping`), and `reassertToolPicker()` brings it back when typing ends.
    func registerAuxiliaryResponder(_ responder: UIResponder) {
        auxiliaryResponders.removeAll { $0.value == nil || $0.value === responder }
        auxiliaryResponders.append(WeakResponder(responder))
        toolPicker.setVisible(showsPickerForAuxiliaryResponders, forFirstResponder: responder)
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
        // The routed surface may have changed: the picker's buttons follow it at once.
        refreshUndoState()
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

    /// The live registered surfaces (sync asks which pages the reader is drawing on).
    var registeredSurfaces: [any MarkupSurface] {
        surfaces.values.compactMap(\.value)
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
        showingToolPicker {
            toolPicker.setVisible(isMarkup, forFirstResponder: responderView)
            for surface in surfaces.values.compactMap(\.value) {
                toolPicker.setVisible(isMarkup, forFirstResponder: surface.canvasView)
                surface.markupModeDidChange(isMarkup)
            }
            for responder in auxiliaryResponders.compactMap(\.value) {
                toolPicker.setVisible(showsPickerForAuxiliaryResponders, forFirstResponder: responder)
            }
            if isMarkup {
                reassertToolPicker()
            } else if responderView.isFirstResponder {
                responderView.resignFirstResponder()
            }
        }
        updateBackSwipe()
    }

    /// Runs `body`, which may put the tool picker on screen. Until the picker has been on screen
    /// in this window it is shown so that it appears in its docked place instead of flying in
    /// (TSOFT-219, `PencilKitWorkarounds.showToolPickerForTheFirstTime`). Later shows keep
    /// PencilKit's own slide-in from that edge.
    private func showingToolPicker(_ body: () -> Void) {
        guard isMarkup, let window = responderView.window, window !== toolPickerWindow else {
            body()
            return
        }
        PencilKitWorkarounds.showToolPickerForTheFirstTime(in: window, body)
    }

    /// In markup mode the navigation stack's back-swipe gestures are disabled for this window:
    /// on iPadOS 26+ the full-width `interactiveContentPopGestureRecognizer` otherwise steals
    /// left-to-right strokes from every canvas (and the edge swipe from strokes starting at the
    /// left edge). The "‹ Library" button and ⇧⌘L still go back. Surfaces need not handle it.
    private func updateBackSwipe() {
        guard let navigationController = responderView.enclosingNavigationController else { return }
        navigationController.interactivePopGestureRecognizer?.isEnabled = !isMarkup
        if #available(iOS 26.0, *) {
            navigationController.interactiveContentPopGestureRecognizer?.isEnabled = !isMarkup
        }
    }

    /// In markup mode, makes the responder view first responder again if no registered
    /// responder is (call after a text field you own ends editing).
    func reassertToolPicker() {
        guard isMarkup, responderView.window != nil else { return }
        // While the reader is pushed (e.g. `-markup` at launch) its views move between the
        // transition's containers and drop first responder at the end, so a picker shown now
        // would show, hide and show again: take first responder once the transition is over.
        guard !isAwaitingTransition else { return }
        if let transition = responderView.enclosingNavigationController?.transitionCoordinator {
            isAwaitingTransition = transition.animate(alongsideTransition: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isAwaitingTransition = false
                    self.reassertToolPicker()
                }
            }
            if isAwaitingTransition { return }
        }
        let registeredFirst = surfaces.values.contains { $0.value?.canvasView.isFirstResponder == true }
            || auxiliaryResponders.contains { $0.value?.isFirstResponder == true }
        if !registeredFirst && !responderView.isFirstResponder {
            showingToolPicker { responderView.becomeFirstResponder() }
        }
    }

    /// The window's light/dark appearance changed (called by `MarkupResponderView`). A
    /// `PKToolPicker` on screen keeps the look it was shown with (its swatches stay in the old
    /// appearance while canvases already draw that ink in the new one) until it is next shown,
    /// so in markup mode hide it for every responder it is visible for and show it again on the
    /// next turn of the main queue.
    func appearanceDidChange() {
        guard isMarkup else { return }
        for responder in pickerResponders { toolPicker.setVisible(false, forFirstResponder: responder) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isMarkup else { return }
            for responder in self.pickerResponders { self.toolPicker.setVisible(true, forFirstResponder: responder) }
            self.reassertToolPicker()
        }
    }

    /// Every responder the tool picker is made visible for in markup mode (the auxiliary
    /// responders only while `keepsPickerWhileTyping`).
    private var pickerResponders: [UIResponder] {
        [responderView] + surfaces.values.compactMap { $0.value?.canvasView }
            + (hasHardwareKeyboard ? auxiliaryResponders.compactMap(\.value) : [])
    }

    /// The visibility the picker is given for the auxiliary responders.
    private var showsPickerForAuxiliaryResponders: Bool { isMarkup && hasHardwareKeyboard }

    /// A hardware keyboard was attached or detached. If a note's text view is first responder,
    /// the picker comes back (keyboard attached) or steps aside for the on-screen keyboard.
    private func keyboardConnectionChanged() {
        let attached = GCKeyboard.coalesced != nil
        guard attached != hasHardwareKeyboard else { return }
        hasHardwareKeyboard = attached
        for responder in auxiliaryResponders.compactMap(\.value) {
            toolPicker.setVisible(showsPickerForAuxiliaryResponders, forFirstResponder: responder)
        }
    }

    /// Which of this window's responders is first responder (test hook, `ReaderStateProbe`):
    /// `markup` (the responder view), `surface` (a registered canvas), `auxiliary`, or `other`.
    var firstResponderKind: String {
        if responderView.isFirstResponder { return "markup" }
        if surfaces.values.contains(where: { $0.value?.canvasView.isFirstResponder == true }) { return "surface" }
        if auxiliaryResponders.contains(where: { $0.value?.isFirstResponder == true }) { return "auxiliary" }
        return "other"
    }

    /// The responder view moved into a window (called by `MarkupResponderView`).
    func responderViewDidMoveToWindow() {
        updateBackSwipe()
        guard isMarkup else { return }
        reassertToolPicker()
        // The window may not accept a first responder until the current update has finished.
        DispatchQueue.main.async { [weak self] in self?.reassertToolPicker() }
    }

    // MARK: PKToolPickerObserver

    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        isToolPickerVisible = toolPicker.isVisible
        if toolPicker.isVisible {
            toolPickerShowCount += 1
            toolPickerWindow = responderView.window
        }
    }

    // MARK: Private

    /// Any undo manager in the process changed state. The proxy's own posts are ignored (they
    /// are echoes of the routed manager's); the routed manager's are re-posted by the proxy.
    @objc private func undoManagerChanged(_ notification: Notification) {
        if let manager = notification.object as? UndoManager, manager === routingUndoManager { return }
        refreshUndoState()
        if let routed = routedUndoManager, let manager = notification.object as? UndoManager, manager === routed,
           PencilKitWorkarounds.toolPickerUndoNotifications.contains(notification.name) {
            announce(notification.name, userInfo: notification.userInfo)
        }
    }

    private func refreshUndoState() {
        let manager = routedUndoManager
        let undo = manager?.canUndo ?? false
        let redo = manager?.canRedo ?? false
        if undo != canUndo { canUndo = undo }
        if redo != canRedo { canRedo = redo }
        // A different surface (or none) is now routed: tell the proxy's observers that its
        // state changed, as if its manager had just closed an undo group.
        if !hasAnnouncedRouting || manager !== announcedRoutedManager {
            hasAnnouncedRouting = true
            announcedRoutedManager = manager
            announce(.NSUndoManagerDidCloseUndoGroup, userInfo: nil)
        }
    }

    /// Posts `name` from the proxy (`PencilKitWorkarounds.postUndoNotification`: the tool picker
    /// follows the proxy through these) and remembers what its observers will read now.
    private func announce(_ name: Notification.Name, userInfo: [AnyHashable: Any]?) {
        PencilKitWorkarounds.postUndoNotification(name, as: routingUndoManager, userInfo: userInfo)
        announcedState = (routingUndoManager.canUndo, routingUndoManager.canRedo)
        scheduleStateCheck()
    }

    /// `NSUndoManagerDidCloseUndoGroup` is posted just before the group is closed, so an
    /// observer reading `canUndo` in it may see the old value. On the next turn of the main
    /// queue, re-read the routed state and, if it differs from what was announced, announce
    /// again (also refreshes `canUndo` / `canRedo` for the toolbar and menu).
    private func scheduleStateCheck() {
        guard !isStateCheckScheduled else { return }
        isStateCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isStateCheckScheduled = false
            self.refreshUndoState()
            let now = (undo: self.routingUndoManager.canUndo, redo: self.routingUndoManager.canRedo)
            if now != self.announcedState {
                self.announce(.NSUndoManagerDidCloseUndoGroup, userInfo: nil)
            }
        }
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

/// The undo manager of `MarkupResponderView`: one object for the life of the reader window that
/// stands in for whichever surface's manager is routed (`ReaderMarkupController.routedUndoManager`,
/// the surface last drawn on).
///
/// Why: the system tool picker drives its own Undo/Redo buttons from the `undoManager` of the
/// first responder it is shown for. It reads that manager when the first responder changes and
/// then follows it through its `NSUndoManagerDidCloseUndoGroup` / `DidUndoChange` /
/// `DidRedoChange` notifications. A responder whose `undoManager` jumps between per-surface
/// managers after it became first responder leaves the picker watching a manager nobody draws
/// into, so its buttons never enable. This proxy never changes identity; it answers `canUndo`,
/// `canRedo`, the action names and counts from the routed manager, forwards `undo()` / `redo()`
/// to it, and the controller re-posts the routed manager's state notifications (and a change of
/// routed surface) with the proxy as the object.
///
/// Nothing registers undo actions on the proxy (registration is disabled); surfaces keep
/// registering on their own managers.
final class MarkupRoutingUndoManager: UndoManager {
    weak var controller: ReaderMarkupController?

    override init() {
        super.init()
        disableUndoRegistration()
    }

    private var routed: UndoManager? { controller?.routedUndoManager }

    override var canUndo: Bool { routed?.canUndo ?? false }
    override var canRedo: Bool { routed?.canRedo ?? false }
    override var isUndoing: Bool { routed?.isUndoing ?? false }
    override var isRedoing: Bool { routed?.isRedoing ?? false }
    override var undoActionName: String { routed?.undoActionName ?? "" }
    override var redoActionName: String { routed?.redoActionName ?? "" }
    override var undoMenuItemTitle: String { routed?.undoMenuItemTitle ?? super.undoMenuItemTitle }
    override var redoMenuItemTitle: String { routed?.redoMenuItemTitle ?? super.redoMenuItemTitle }

    @available(iOS 17.4, *)
    override var undoCount: Int { routed?.undoCount ?? 0 }
    @available(iOS 17.4, *)
    override var redoCount: Int { routed?.redoCount ?? 0 }

    /// Undoes on the routed surface (the controller's `undo()`, which also refreshes its state).
    override func undo() { controller?.undo() }
    override func redo() { controller?.redo() }
    override func undoNestedGroup() { controller?.undo() }
}

/// The invisible first responder that carries the tool picker in markup mode. Its `undoManager`
/// is always the controller's `MarkupRoutingUndoManager`, so the tool picker's Undo/Redo buttons
/// and the system Undo/Redo commands (⌘Z, ⇧⌘Z, Edit menu) act on the surface last drawn on
/// while it is first responder.
final class MarkupResponderView: UIView {
    weak var controller: ReaderMarkupController?

    /// The navigation controller hosting the reader (for the back-swipe gestures).
    var enclosingNavigationController: UINavigationController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController, let navigation = controller.navigationController {
                return navigation
            }
            responder = current.next
        }
        return nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The system tool picker does not restyle itself when the appearance changes while it
        // is on screen; the controller re-shows it (see `appearanceDidChange()`).
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MarkupResponderView, _: UITraitCollection) in
            view.controller?.appearanceDidChange()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    override var undoManager: UndoManager? {
        controller?.routingUndoManager ?? super.undoManager
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { controller?.responderViewDidMoveToWindow() }
    }
}
