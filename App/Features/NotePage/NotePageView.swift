import Observation
import ReaderCore
import SwiftUI
import UIKit

/// Bridges SwiftUI rich-text formatting controls to the active `NotePageEditorView` in one panel.
@Observable
@MainActor
final class NoteFormattingController {
    private(set) var attributes: NoteTextAttributes = .default
    private(set) var isEditable = false
    @ObservationIgnored weak var editor: NotePageEditorView?

    func attach(_ editor: NotePageEditorView) {
        self.editor = editor
        attributes = editor.currentFormattingAttributes
        isEditable = editor.textView.isEditable
    }

    func update(attributes: NoteTextAttributes, isEditable: Bool) {
        if self.attributes != attributes { self.attributes = attributes }
        if self.isEditable != isEditable { self.isEditable = isEditable }
    }

    func toggleBold() { editor?.toggleBold() }
    func toggleItalic() { editor?.toggleItalic() }
    func toggleUnderline() { editor?.toggleUnderline() }
    func toggleStrikethrough() { editor?.toggleStrikethrough() }
    func clearFormatting() { editor?.clearFormatting() }
}

/// The editable note page for SwiftUI (the notes panel's editor). Wraps `NotePageEditorView`.
///
/// - `model`: the note shown. Pass a different model to switch targets; a stroke in progress
///   finishes on the old note first, which is then flushed.
/// - `session`: the reader window's session (markup mode, the shared tool picker, undo routing,
///   flush on leaving markup mode, background and close). `nil` only outside a reader (previews, tests).
/// - `zoom`: 1 = 100%, clamped to 1...2. Pinching writes it back. Zoom never changes line breaks.
/// - `pageWidth`: the page's width before zoom, at least `NotePageStyle.pageWidth` (the default).
///   A host with more room passes a wider page: the text re-wraps to it at the same size
///   (TSOFT-226) and ink moves with its paragraph.
/// - `isMarkup`: markup mode when `session` is `nil` (ignored with a session).
struct NotePageView: UIViewRepresentable {
    let model: NotePageModel
    var session: ReaderSession?
    @Binding var zoom: CGFloat
    var pageWidth: CGFloat = NotePageStyle.pageWidth
    var isMarkup = false
    var showsPaperBackground = true
    var formatting: NoteFormattingController?

    init(model: NotePageModel, session: ReaderSession?, zoom: Binding<CGFloat>,
         pageWidth: CGFloat = NotePageStyle.pageWidth, isMarkup: Bool = false,
         showsPaperBackground: Bool = true, formatting: NoteFormattingController? = nil) {
        self.model = model
        self.session = session
        self._zoom = zoom
        self.pageWidth = pageWidth
        self.isMarkup = isMarkup
        self.showsPaperBackground = showsPaperBackground
        self.formatting = formatting
    }

    func makeUIView(context: Context) -> NotePageEditorView {
        let view = NotePageEditorView(session: session)
        view.model = model
        view.pageWidth = pageWidth
        view.zoom = zoom
        view.isMarkupStandalone = isMarkup
        view.showsPaperBackground = showsPaperBackground
        formatting?.attach(view)
        view.onFormattingChange = { [weak formatting] attrs, editable in
            formatting?.update(attributes: attrs, isEditable: editable)
        }
        return view
    }

    func updateUIView(_ view: NotePageEditorView, context: Context) {
        view.model = model
        view.pageWidth = pageWidth
        if abs(view.zoom - NotePageStyle.clampZoom(zoom)) > 0.001 { view.zoom = zoom }
        view.isMarkupStandalone = isMarkup
        view.showsPaperBackground = showsPaperBackground
        let binding = $zoom
        view.onZoomChange = { newZoom in
            if abs(binding.wrappedValue - newZoom) > 0.001 { binding.wrappedValue = newZoom }
        }
        formatting?.attach(view)
        let formattingController = formatting
        view.onFormattingChange = { [weak formattingController] attrs, editable in
            formattingController?.update(attributes: attrs, isEditable: editable)
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
