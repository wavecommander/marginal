import Foundation
import PencilKit
import UIKit

/// Everything the app does that depends on how PencilKit's system tool picker behaves inside,
/// rather than on its documented API: one function per workaround, each saying what it works
/// around. What each one leans on is pinned by `FrameworkWorkaroundCanaryTests`.
@MainActor
enum PencilKitWorkarounds {

    // MARK: The tool picker's Undo and Redo buttons

    /// The undo-manager notifications the system tool picker follows to enable its Undo and Redo
    /// buttons (its binary imports exactly these three).
    nonisolated static let toolPickerUndoNotifications: Set<Notification.Name> = [
        .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
    ]

    /// Posts an undo notification as if `undoManager` itself had posted it.
    ///
    /// Works around: the tool picker drives its own Undo/Redo buttons from the `undoManager` of
    /// the first responder it is shown for. It reads that manager when the first responder
    /// changes and then follows it through `toolPickerUndoNotifications`. A responder whose
    /// `undoManager` jumps between per-surface managers after it became first responder leaves
    /// the picker watching a manager nobody draws into, so its buttons never enable. The reader
    /// therefore gives the picker one stand-in manager for the life of the window
    /// (`MarkupRoutingUndoManager`), and announces the state of whichever surface's manager it
    /// stands in for by posting that manager's notifications under the stand-in's name: the
    /// stand-in never registers or performs an undo itself, so it would never post them.
    static func postUndoNotification(_ name: Notification.Name, as undoManager: UndoManager,
                                     userInfo: [AnyHashable: Any]?) {
        NotificationCenter.default.post(name: name, object: undoManager, userInfo: userInfo)
    }

    // MARK: Showing the tool picker

    /// Runs `body`, which puts the tool picker on screen for the first time in `window`, so that
    /// it appears in its docked place.
    ///
    /// Works around: the first time a `PKToolPicker` is shown in a window, PencilKit adds its
    /// palette host view (in the scene's text-effects window, not the reader's) centred on the
    /// window's origin and docks the palette inside it; the host gets its real frame on a later
    /// layout pass, and PencilKit animates its own layout when the host's safe area changes in
    /// between. Either one animated, and the palette flies in from the top centre of the screen
    /// instead of appearing at its docked edge (TSOFT-219; on the simulator, when a note's text
    /// view is first responder). So the first show is done without animation and the scene's
    /// windows are laid out at once. Later shows (host laid out) keep PencilKit's own slide-in
    /// from that edge: call `body` directly for those.
    static func showToolPickerForTheFirstTime(in window: UIWindow, _ body: () -> Void) {
        UIView.performWithoutAnimation {
            body()
            for sceneWindow in window.windowScene?.windows ?? [window] {
                sceneWindow.layoutIfNeeded()
            }
        }
    }
}
