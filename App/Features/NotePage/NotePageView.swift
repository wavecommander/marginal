import ReaderCore
import SwiftUI
import UIKit

/// The editable note page for SwiftUI (WP8's editor). Wraps `NotePageEditorView`.
///
/// - `model`: the note shown. Pass a different model to switch targets; a stroke in progress
///   finishes on the old note first, which is then flushed.
/// - `session`: the reader window's session (markup mode, the shared tool picker, undo routing,
///   flush on Done/background/close). `nil` only outside a reader (previews, tests).
/// - `zoom`: 1 = 100%, clamped to 1...2. Pinching writes it back. Widening the panel should
///   change `zoom` (`NotePageZoom.zoom(...)`), never the page's width: the page is always
///   `NotePageStyle.pageWidth` points wide before zoom, so line breaks never change.
/// - `isMarkup`: markup mode when `session` is `nil` (ignored with a session).
struct NotePageView: UIViewRepresentable {
    let model: NotePageModel
    var session: ReaderSession?
    @Binding var zoom: CGFloat
    var isMarkup = false

    init(model: NotePageModel, session: ReaderSession?, zoom: Binding<CGFloat>, isMarkup: Bool = false) {
        self.model = model
        self.session = session
        self._zoom = zoom
        self.isMarkup = isMarkup
    }

    func makeUIView(context: Context) -> NotePageEditorView {
        let view = NotePageEditorView(session: session)
        view.model = model
        view.zoom = zoom
        view.isMarkupStandalone = isMarkup
        return view
    }

    func updateUIView(_ view: NotePageEditorView, context: Context) {
        view.model = model
        if abs(view.zoom - NotePageStyle.clampZoom(zoom)) > 0.001 { view.zoom = zoom }
        view.isMarkupStandalone = isMarkup
        let binding = $zoom
        view.onZoomChange = { newZoom in
            if abs(binding.wrappedValue - newZoom) > 0.001 { binding.wrappedValue = newZoom }
        }
    }

    static func dismantleUIView(_ view: NotePageEditorView, coordinator: ()) {
        let model = view.model
        Task { await model?.flush() }
    }
}

/// Zoom helpers for hosts of `NotePageView`.
enum NotePageZoom {
    /// The zoom for a panel: `base × panelWidth / defaultPanelWidth`, clamped to 100%–200%.
    /// `base` is the reader's chosen zoom at the default width (initially
    /// `NotePageStyle.defaultZoom(for:)` from Dynamic Type).
    static func zoom(base: CGFloat, panelWidth: CGFloat,
                     defaultPanelWidth: CGFloat = CGFloat(ReaderSession.defaultNotesPanelWidth)) -> CGFloat {
        guard panelWidth > 0, defaultPanelWidth > 0 else { return NotePageStyle.clampZoom(base) }
        return NotePageStyle.clampZoom(base * panelWidth / defaultPanelWidth)
    }

    /// The base zoom that gives `zoom` at `panelWidth` (inverse of `zoom(base:panelWidth:)`).
    static func base(forZoom zoom: CGFloat, panelWidth: CGFloat,
                     defaultPanelWidth: CGFloat = CGFloat(ReaderSession.defaultNotesPanelWidth)) -> CGFloat {
        guard panelWidth > 0 else { return zoom }
        return zoom * defaultPanelWidth / panelWidth
    }
}

extension NotePageStyle {
    /// `defaultZoom(for:)` for a SwiftUI `DynamicTypeSize`.
    @MainActor
    static func defaultZoom(for size: DynamicTypeSize) -> CGFloat {
        defaultZoom(for: UIContentSizeCategory(size))
    }
}
