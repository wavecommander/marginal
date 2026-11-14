import UIKit

/// Test hook (`-exposeMarkupState`): accessibility elements in the reader content that UI tests
/// read and tap instead of the toolbar, whose bar items do not carry accessibility values to
/// XCUITest on iPadOS 26+ (see `ReaderScreen.markupToggle`). Never created in normal runs.
///
/// - `reader.markupState`: value read live on every query, space-separated `key=value` tokens:
///   `markup=on|off picker=shown|hidden shows=N notes=shown|hidden`
///   `responder=markup|surface|auxiliary|other undo=yes|no redo=yes|no heardUndo=yes|no`
///   `heardRedo=yes|no posts=N`. `shows` counts the tool picker's appearances. `undo`/`redo` are the
///   markup responder's undo manager (`MarkupRoutingUndoManager`) now; `heard…` is what a listener
///   of that manager's notifications (as the tool picker is) read in the last one, and `posts`
///   how many it has heard.
/// - `reader.markupUndo` / `reader.markupRedo`: tapping calls `undo()` / `redo()` on the markup
///   responder's `undoManager`, the call the tool picker's own buttons make.
@MainActor
enum ReaderStateProbe {
    static func makeViews(session: ReaderSession) -> [UIView] {
        [StateView(session: session),
         ActionView(identifier: AccessibilityID.Reader.markupUndoProbe, label: "Probe Undo") { [weak session] in
             session?.markup.responderView.undoManager?.undo()
         },
         ActionView(identifier: AccessibilityID.Reader.markupRedoProbe, label: "Probe Redo") { [weak session] in
             session?.markup.responderView.undoManager?.redo()
         }]
    }

    private final class StateView: UIView {
        private weak var session: ReaderSession?
        private var heard: (undo: Bool, redo: Bool) = (false, false)
        private var posts = 0

        init(session: ReaderSession) {
            self.session = session
            super.init(frame: .zero)
            isAccessibilityElement = true
            // A button trait keeps XCUITest queries fast (they skip PDFKit's page elements).
            accessibilityTraits = .button
            accessibilityLabel = "Markup state"
            accessibilityIdentifier = AccessibilityID.Reader.markupState
            let proxy = session.markup.routingUndoManager
            for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                         .NSUndoManagerDidRedoChange] {
                // Read synchronously as the post happens (no queue), as a listener would.
                NotificationCenter.default.addObserver(forName: name, object: proxy, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.didHear() }
                }
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        private func didHear() {
            guard let proxy = session?.markup.routingUndoManager else { return }
            heard = (proxy.canUndo, proxy.canRedo)
            posts += 1
        }

        override var accessibilityValue: String? {
            get {
                guard let session, let markup = session.markup else { return "none" }
                let manager = markup.responderView.undoManager
                func word(_ value: Bool) -> String { value ? "yes" : "no" }
                return ["markup=\(session.isMarkupMode ? "on" : "off")",
                        "picker=\(markup.isToolPickerVisible ? "shown" : "hidden")",
                        "shows=\(markup.toolPickerShowCount)",
                        "notes=\(session.isNotesVisible ? "shown" : "hidden")",
                        "responder=\(markup.firstResponderKind)",
                        "undo=\(word(manager?.canUndo ?? false))", "redo=\(word(manager?.canRedo ?? false))",
                        "heardUndo=\(word(heard.undo))", "heardRedo=\(word(heard.redo))",
                        "posts=\(posts)"].joined(separator: " ")
            }
            set {}
        }
    }

    private final class ActionView: UIView {
        private let action: @MainActor () -> Void

        init(identifier: String, label: String, action: @escaping @MainActor () -> Void) {
            self.action = action
            super.init(frame: .zero)
            isAccessibilityElement = true
            accessibilityTraits = .button
            accessibilityLabel = label
            accessibilityIdentifier = identifier
            // A tap here never makes anything first responder, as a tap on a picker button does not.
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        @objc private func tapped() { action() }

        override func accessibilityActivate() -> Bool {
            action()
            return true
        }
    }
}
