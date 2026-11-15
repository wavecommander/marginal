import SwiftUI
import UIKit

extension View {
    /// Keeps the navigation stack's back swipe from starting on this view (TSOFT-225).
    ///
    /// On iPadOS 26+ the navigation controller's `interactiveContentPopGestureRecognizer` pops
    /// the reader on a left-to-right swipe that starts anywhere in it, so a rightward drag on the
    /// notes pane (a drag meant for the divider's pill that misses it, a sideways flick on the
    /// note) went back to the Library. Behind the view sits an anchor that installs a
    /// `BackSwipeGuardRecognizer` on the navigation controller's view: the content back swipe is
    /// made to require the guard's failure, and the guard recognizes the moment a touch lands
    /// inside the anchor (so the back swipe fails) and fails at once for touches anywhere else
    /// (so it works as before). The guard cancels and delays no touches and prevents no other
    /// recognizer, so the view's own scrolling, text editing, ink and gestures are unaffected.
    /// The left-edge swipe and the "‹ Library" button still go back. Earlier systems have no
    /// content back swipe, and their edge swipe never starts on a trailing pane: no-op there.
    func backSwipeGuard() -> some View {
        background { BackSwipeGuardAnchor().accessibilityHidden(true) }
    }
}

private struct BackSwipeGuardAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> BackSwipeGuardView { BackSwipeGuardView() }
    func updateUIView(_ uiView: BackSwipeGuardView, context: Context) {}
}

/// The guarded region: lays out with the view it backs and never takes touches itself.
final class BackSwipeGuardView: UIView {
    private var recognizer: BackSwipeGuardRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizer = nil
        guard #available(iOS 26.0, *), window != nil,
              let navigationController = enclosingNavigationController,
              let host = navigationController.view else { return }
        let guardRecognizer = BackSwipeGuardRecognizer(region: self, navigationController: navigationController)
        host.addGestureRecognizer(guardRecognizer)
        recognizer = guardRecognizer
    }

    private var enclosingNavigationController: UINavigationController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController, let navigation = controller.navigationController {
                return navigation
            }
            responder = current.next
        }
        return nil
    }
}

/// See `View.backSwipeGuard()`. Discrete: recognized on touch-down inside the region, failed on
/// touch-down outside it.
final class BackSwipeGuardRecognizer: UIGestureRecognizer {
    private weak var region: UIView?
    private weak var navigationController: UINavigationController?

    init(region: UIView, navigationController: UINavigationController) {
        self.region = region
        self.navigationController = navigationController
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    private var contentPop: UIGestureRecognizer? {
        guard #available(iOS 26.0, *) else { return nil }
        return navigationController?.interactiveContentPopGestureRecognizer
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible else { return }
        guard let region, region.window != nil, !region.isHidden else {
            state = .failed
            return
        }
        let inside = touches.contains { region.bounds.contains($0.location(in: region)) }
        state = inside ? .recognized : .failed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible { state = .failed }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible { state = .failed }
    }

    /// The content back swipe waits for the guard (which decides on touch-down).
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer === contentPop
    }

    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        preventedGestureRecognizer === contentPop
    }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
