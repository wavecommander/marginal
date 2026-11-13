import PencilKit
import UIKit

/// Test-only `MarkupSurface` (`-markupProbeSurface`): a small transparent `PKCanvasView` added
/// to the PDF view, registered with the session like a real canvas, which takes first responder
/// when markup mode starts (as a canvas does with the lasso). UI tests use it to check that the
/// window's tool picker stays visible with a registered surface that is first responder.
@MainActor
final class MarkupProbeSurface: MarkupSurface {
    let markupSurfaceID = "probe"
    let canvasView = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
    let markupUndoManager: UndoManager? = UndoManager()
    private weak var session: ReaderSession?

    init(session: ReaderSession) {
        self.session = session
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.accessibilityIdentifier = "reader.markupProbe"
        session.pdf.view.addSubview(canvasView)
        session.markup.register(self)
    }

    func markupModeDidChange(_ isMarkup: Bool) {
        canvasView.isUserInteractionEnabled = isMarkup
        guard isMarkup else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.canvasView.window != nil else { return }
            self.canvasView.becomeFirstResponder()
        }
    }

    func flushPendingMarkup() async {}
}
