import ReaderCore
import SwiftUI

/// The notes panel (WP8): Page note and Section note tabs around the WP13 note editor.
///
/// The shell hosts it as the right-hand pane (wide windows: its width is
/// `session.notesPanelWidth`, dragged with `reader.notesDivider`), as the system sheet with
/// detents (narrow windows, iPadOS 26+) or as the inline bottom panel (narrow windows, earlier
/// systems). Everything here is laid out from the panel's own size (`NotesPanelMetrics`).
///
/// - **Page note:** "Page 312", the "Saved" status, the note editor, "Highlights on this page",
///   and "This page is in" (the page's heading path; a row opens the Section tab on it).
/// - **Section note:** the level picker over the heading path, the heading's title and pages, the
///   note editor, and "Page notes in this section" drawn with their ink.
/// - **Header:** the tab picker, the zoom control (100%–200%; pinch works too), and the shrink
///   button while the pane is wider than its default.
///
/// Which note is shown, deferral while typing, the level choice and the zoom live in the
/// window's `NotesPanelController`. One `NotePageView` stays on screen; it is given a new model
/// when the target changes.
struct NotesPanel: View {
    @Bindable var session: ReaderSession
    private let controller: NotesPanelController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(WindowContext.self) private var window: WindowContext?

    init(session: ReaderSession) {
        self.session = session
        self.controller = NotesPanelController.forSession(session)
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = NotesPanelMetrics(presentation: session.isNarrowLayout ? .narrow : .pane, size: proxy.size)
            VStack(alignment: .leading, spacing: 0) {
                header(metrics)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                content(metrics)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        // The editor insets itself for the keyboard and scrolls the cursor into view; SwiftUI's
        // own avoidance would also push the whole panel up.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear { controller.refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(NotesPanelAccessibilityID.panel)
    }

    // MARK: Header

    private func header(_ metrics: NotesPanelMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Picker("Note", selection: Binding(get: { session.notesTab }, set: { controller.selectTab($0) })) {
                    Text("Page note").tag(ReaderSession.NotesTab.page)
                    Text("Section note").tag(ReaderSession.NotesTab.section)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .accessibilityIdentifier(NotesPanelAccessibilityID.tabs)
                Spacer(minLength: 0)
                if controller.model != nil {
                    zoomMenu(metrics)
                }
                if metrics.presentation == .pane && session.notesPanelWidth > ReaderSession.defaultNotesPanelWidth + 0.5 {
                    shrinkButton
                }
            }
            switch session.notesTab {
            case .page: pageTitle
            case .section: sectionHeader(metrics)
            }
        }
    }

    private var pageTitle: some View {
        let page = controller.shownPage ?? session.currentPageIndex
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "Page \(PageNumbering.displayNumber(forPageIndex: page))")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(NotesPanelAccessibilityID.title)
                Spacer(minLength: 8)
                statusLabel
            }
            deferredCaption
        }
    }

    @ViewBuilder
    private func sectionHeader(_ metrics: NotesPanelMetrics) -> some View {
        if let heading = controller.shownHeading {
            let levels = NotesSectionSelection.levels(showing: heading, page: session.currentPageIndex,
                                                      outline: session.outline)
            NotesLevelPicker(levels: levels, selected: heading.anchor, isCompact: metrics.isCompactHeight,
                             hasNote: { session.notebook?.section(for: $0)?.note != nil },
                             choose: { controller.chooseLevel($0) })
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(heading.title)
                        .font(.title3.bold())
                        .lineLimit(3)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(NotesPanelAccessibilityID.title)
                    Spacer(minLength: 8)
                    pagesButton(heading)
                }
                HStack {
                    deferredCaption
                    Spacer(minLength: 8)
                    statusLabel
                }
            }
        }
    }

    /// "pp. 310–328": jumps to the heading's first page (the level picker's heading, as a jump).
    @ViewBuilder
    private func pagesButton(_ heading: OutlineNode) -> some View {
        if let text = Self.pagesText(heading), heading.startPage != nil {
            Button { session.jump(to: heading) } label: {
                Text(verbatim: text).font(.footnote).monospacedDigit()
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 32)
            .accessibilityLabel("\(text), go to the start of \(heading.title)")
            .accessibilityIdentifier(NotesPanelAccessibilityID.sectionRange)
        }
    }

    static func pagesText(_ heading: OutlineNode) -> String? {
        if let range = heading.pageRange {
            let first = PageNumbering.displayNumber(forPageIndex: range.lowerBound)
            let last = PageNumbering.displayNumber(forPageIndex: range.upperBound)
            return first == last ? "p. \(first)" : "pp. \(first)\u{2013}\(last)"
        }
        return heading.startPage.map { "p. \(PageNumbering.displayNumber(forPageIndex: $0))" }
    }

    private var statusLabel: some View {
        let status = controller.model?.statusText ?? ""
        let empty = controller.model?.saveState == .empty
        return Text(status.isEmpty ? " " : status)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityLabel(empty ? "Empty" : status)
            .accessibilityIdentifier(NotesPanelAccessibilityID.status)
    }

    @ViewBuilder
    private var deferredCaption: some View {
        if controller.isSwitchDeferred {
            Text("Stays open while you type")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Zoom and width

    private var baseZoom: CGFloat {
        controller.chosenBaseZoom ?? NotePageStyle.defaultZoom(for: dynamicTypeSize)
    }

    private func zoomBinding(_ metrics: NotesPanelMetrics) -> Binding<CGFloat> {
        Binding(get: { metrics.zoom(base: baseZoom) },
                set: { controller.chosenBaseZoom = metrics.base(forZoom: $0) })
    }

    private func zoomMenu(_ metrics: NotesPanelMetrics) -> some View {
        let percent = NotesPanelMetrics.percent(metrics.zoom(base: baseZoom))
        return Menu {
            ForEach([100, 125, 140, 150, 175, 200], id: \.self) { value in
                Button {
                    controller.chosenBaseZoom = metrics.base(forZoom: CGFloat(value) / 100)
                } label: {
                    if value == percent {
                        Label("\(value)%", systemImage: "checkmark")
                    } else {
                        Text(verbatim: "\(value)%")
                    }
                }
            }
            Divider()
            Button("Match Text Size") { controller.chosenBaseZoom = nil }
        } label: {
            Text(verbatim: "\(percent)%")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Note zoom, \(percent) percent")
        .accessibilityIdentifier(NotesPanelAccessibilityID.zoom)
    }

    private var shrinkButton: some View {
        Button {
            withAnimation { session.notesPanelWidth = ReaderSession.defaultNotesPanelWidth }
        } label: {
            Label("Shrink Notes Panel", systemImage: "arrow.right.to.line")
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .hoverEffect(.highlight)
        .accessibilityIdentifier(NotesPanelAccessibilityID.shrink)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ metrics: NotesPanelMetrics) -> some View {
        // One layout value for both arrangements keeps the editor's identity (and so its
        // UIKit view) when the panel switches between stacked and two-column.
        let layout = metrics.usesColumns
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
        layout {
            editorArea(metrics)
                .frame(width: metrics.usesColumns ? metrics.noteColumnWidth : nil)
                .frame(maxWidth: metrics.usesColumns ? nil : .infinity, maxHeight: .infinity)
            if metrics.usesColumns {
                Divider()
                ScrollView(.vertical) {
                    lists(rowWidth: metrics.size.width - metrics.noteColumnWidth - 40)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Divider()
                NotesBoundedScroll(maximumHeight: metrics.lowerRegionMaximumHeight) {
                    lists(rowWidth: metrics.size.width - 28)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func editorArea(_ metrics: NotesPanelMetrics) -> some View {
        if let model = controller.model {
            NotePageView(model: model, session: session, zoom: zoomBinding(metrics))
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .accessibilityLabel(session.notesTab == .page ? "Page note" : "Section note")
        } else {
            NotesSectionEmptyState(session: session, controller: controller)
        }
    }

    @ViewBuilder
    private func lists(rowWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch session.notesTab {
            case .page:
                let page = controller.shownPage ?? session.currentPageIndex
                NotesHighlightsSection(session: session, pageIndex: page)
                NotesPageIsInSection(session: session, controller: controller, pageIndex: page)
            case .section:
                if let heading = controller.shownHeading {
                    NotesSectionPageNotes(session: session, controller: controller, heading: heading,
                                          rowWidth: max(rowWidth, 120))
                }
                if let window {
                    Button { window.openNotebook(bookID: session.book.id) } label: {
                        Label("Open in Notebook", systemImage: "book.pages")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(NotesPanelAccessibilityID.openNotebook)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
