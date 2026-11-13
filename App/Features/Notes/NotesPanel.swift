import ReaderCore
import SwiftUI

/// PLACEHOLDER owned by WP8 (notes panel). Keep the type name and `init(session:)`; replace
/// the body.
///
/// The shell hosts this as the right-hand pane (wide) or in a sheet with medium/large detents
/// (narrow), owns the panel width (`session.notesPanelWidth`, drag handle) and visibility, and
/// provides no header: the Page note / Section note picker (`session.notesTab`) is yours.
///
/// WP13 host (minimal, for its tests and screenshots): shows the WP13 `NotePageView` for the
/// current page's note (or the deepest heading's note on the Section tab), switching models as
/// the target changes, with the "Saved" status and a zoom control. WP8 builds the real panel.
struct NotesPanel: View {
    @Bindable var session: ReaderSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var state = NotesPanelNoteState()

    init(session: ReaderSession) {
        self.session = session
    }

    private var target: NoteTarget? {
        switch session.notesTab {
        case .page: .page(session.currentPageIndex)
        case .section: session.deepestHeading.map { .heading($0.anchor) }
        }
    }

    private var title: String {
        switch session.notesTab {
        case .page: "Page \(PageNumbering.displayNumber(forPageIndex: session.currentPageIndex))"
        case .section: session.deepestHeading?.title ?? "No section"
        }
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Picker("Note", selection: $session.notesTab) {
                            Text("Page note").tag(ReaderSession.NotesTab.page)
                            Text("Section note").tag(ReaderSession.NotesTab.section)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 300)
                        Spacer(minLength: 0)
                        zoomMenu(panelWidth: proxy.size.width)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.title3.bold())
                        Spacer()
                        statusLabel
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                if let model = state.model {
                    NotePageView(model: model, session: session, zoom: zoomBinding(panelWidth: proxy.size.width))
                } else {
                    Text("No section here").foregroundStyle(.secondary).padding(14)
                    Spacer()
                }
            }
        }
        .onChange(of: target, initial: true) { _, newTarget in
            state.show(newTarget, session: session)
        }
        .onChange(of: state.model?.isEditingText) { _, _ in
            state.show(target, session: session)
        }
        .onAppear {
            if state.baseZoom == nil { state.baseZoom = NotePageStyle.defaultZoom(for: dynamicTypeSize) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Placeholder.notes)
    }

    private var statusLabel: some View {
        let status = state.model?.statusText ?? ""
        let empty = state.model?.saveState == .empty
        return Text(status.isEmpty ? " " : status)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityLabel(empty ? "Empty" : status)
            .accessibilityIdentifier("notePage.status")
    }

    private func effectiveZoom(panelWidth: CGFloat) -> CGFloat {
        NotePageZoom.zoom(base: state.baseZoom ?? 1, panelWidth: panelWidth)
    }

    private func zoomBinding(panelWidth: CGFloat) -> Binding<CGFloat> {
        Binding(get: { effectiveZoom(panelWidth: panelWidth) },
                set: { state.baseZoom = NotePageZoom.base(forZoom: $0, panelWidth: panelWidth) })
    }

    private func zoomMenu(panelWidth: CGFloat) -> some View {
        let percent = Int((effectiveZoom(panelWidth: panelWidth) * 100).rounded())
        return Menu {
            ForEach([100, 125, 140, 150, 175, 200], id: \.self) { value in
                Button("\(value)%") {
                    state.baseZoom = NotePageZoom.base(forZoom: CGFloat(value) / 100, panelWidth: panelWidth)
                }
            }
        } label: {
            Text("\(percent)%").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }
        .accessibilityLabel("Note zoom, \(percent) percent")
        .accessibilityIdentifier("notePage.zoom")
    }
}

/// The panel's current note model (one per target) and the reader's chosen zoom.
@Observable
@MainActor
final class NotesPanelNoteState {
    private(set) var model: NotePageModel?
    var baseZoom: CGFloat?

    func show(_ target: NoteTarget?, session: ReaderSession) {
        guard model?.target != target || model?.bookID != session.book.id else { return }
        // Never swap the note under the reader while they type in it (e.g. the keyboard scrolled
        // the page); switch when editing ends.
        if model?.isEditingText == true { return }
        // The editor view switches to the new model after any stroke in progress and flushes the
        // old one; with no editor on screen, flush it here.
        if let old = model, old.editor == nil { Task { await old.flush() } }
        model = target.map { NotePageModel(session: session, target: $0) }
    }
}
