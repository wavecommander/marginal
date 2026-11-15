import ReaderCore
import SwiftUI

/// The notes panel (WP8): Page note and Section note tabs around the WP13 note editor.
///
/// The shell hosts it as the right-hand pane (wide windows: its width is
/// `session.notesPanelWidth`, dragged with `reader.notesDivider`), as the system sheet with
/// detents (narrow windows, iPadOS 26+) or as the inline bottom panel (narrow windows, earlier
/// systems). Everything here is laid out from the panel's own size (`NotesPanelMetrics`).
///
/// Laid out as the design's "Notes panel layout" rule says:
/// - **Header:** the tab picker, Delete Note, and the shrink button while the pane is wider than
///   its default; then the title and the "Saved" status.
/// - **Page note:** "Page 312", the note editor, and "Highlights on this page" only while the page
///   has any (with none, the note takes the whole panel).
/// - **Section note:** the heading's title and pages, the note editor, then the collapsible level
///   picker over the heading path and "Open in Notebook" at the bottom.
///
/// The note is zoomed only by pinching it (100%–200%; there is no zoom button); widening the
/// pane widens the note page (the text re-wraps at the same size) but never zooms it. Which note is shown, deferral while typing, the level
/// choice and the zoom live in the window's `NotesPanelController`. One `NotePageView` stays on
/// screen; it is given a new model when the target changes.
struct NotesPanel: View {
    @Bindable var session: ReaderSession
    private let controller: NotesPanelController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(WindowContext.self) private var window: WindowContext?
    /// The note the reader asked to delete (confirmation shown while set).
    @State private var deleteCandidate: NotePageModel?
    /// The shown page's highlights (Page note tab; empty on the Section tab).
    @State private var highlights: [Highlight] = []

    private struct HighlightsKey: Equatable {
        /// `nil` on the Section tab.
        var page: Int?
        var revision: Int
    }

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
        // Loaded here, not in the list, so the region under the note can go when there are none.
        // Re-read whenever highlights change in any window (`revisions.highlights`).
        .task(id: highlightsKey) {
            guard let page = highlightsKey.page else { highlights = []; return }
            highlights = (try? session.store.highlights.highlights(bookID: session.book.id, pageIndex: page)) ?? []
        }
        // A pinched zoom is dropped when the text size changes, so the note follows Dynamic Type
        // again (there is no zoom menu to return to the default).
        .onChange(of: dynamicTypeSize) { controller.chosenBaseZoom = nil }
        .alert("Delete This Note?", isPresented: Binding(get: { deleteCandidate != nil },
                                                         set: { if !$0 { deleteCandidate = nil } }),
               presenting: deleteCandidate) { model in
            Button("Delete", role: .destructive) {
                Task { await controller.delete(model) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text(Self.deleteMessage(hasInk: model.hasInk))
        }
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
                .onboardingTip(.sectionNote, session: session)
                Spacer(minLength: 0)
                if let model = controller.model {
                    deleteButton(model)
                }
                if metrics.presentation == .pane && session.notesPanelWidth > ReaderSession.defaultNotesPanelWidth + 0.5 {
                    shrinkButton
                }
            }
            switch session.notesTab {
            case .page: pageTitle
            case .section: sectionHeader
            }
        }
        // The header (tabs, Delete Note, title) sits above the note in a 330 pt pane and cannot
        // scroll: at the largest text sizes its titles were cut to "5.2…" and the tabs to
        // "Page…" / "Sectio…". Capped like toolbar controls; the note itself and the region
        // below it keep the full size, and VoiceOver reads the same labels.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
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
    private var sectionHeader: some View {
        if let heading = controller.shownHeading {
            VStack(alignment: .leading, spacing: 2) {
                // At accessibility text sizes the page range goes under the title, which
                // otherwise had no room left beside it.
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionTitle(heading)
                        pagesButton(heading)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        sectionTitle(heading)
                        Spacer(minLength: 8)
                        pagesButton(heading)
                    }
                }
                HStack {
                    deferredCaption
                    Spacer(minLength: 8)
                    statusLabel
                }
            }
        }
    }

    private func sectionTitle(_ heading: OutlineNode) -> some View {
        Text(heading.title)
            .font(.title3.bold())
            .lineLimit(3)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(NotesPanelAccessibilityID.title)
    }

    /// "pp. 310–328": jumps to the heading's first page (the shown heading's, as a jump).
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

    /// Delete Note (design: "Deleting a note"): in the header on both tabs, disabled while the
    /// note is empty. The model to delete is captured at the tap, so a page-following switch while
    /// the confirmation is up cannot redirect it to another note.
    private func deleteButton(_ model: NotePageModel) -> some View {
        Button(role: .destructive) {
            deleteCandidate = model
        } label: {
            Label("Delete Note", systemImage: "trash")
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(!model.isLoaded || NotesPanelController.isEmpty(model))
        .hoverEffect(.highlight)
        .accessibilityIdentifier(NotesPanelAccessibilityID.deleteNote)
    }

    /// The confirmation's message: what goes and what stays.
    static func deleteMessage(hasInk: Bool) -> String {
        (hasInk ? "The typed text and the handwriting on this note will be deleted."
                : "The typed text of this note will be deleted.")
            + " Ink on the PDF page and highlights are not affected."
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

    /// The zoom on screen; pinching the note writes the reader's choice back.
    private func zoomBinding(_ metrics: NotesPanelMetrics) -> Binding<CGFloat> {
        Binding(get: { metrics.zoom(base: baseZoom) },
                set: { controller.chosenBaseZoom = metrics.base(forZoom: $0) })
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

    private var highlightsKey: HighlightsKey {
        HighlightsKey(page: session.notesTab == .page ? controller.shownPage ?? session.currentPageIndex : nil,
                      revision: session.revisions.highlights)
    }

    /// Whether anything goes under (or beside) the note: on the Page tab only while the page has
    /// highlights.
    private var hasLowerRegion: Bool {
        switch session.notesTab {
        case .page: !highlights.isEmpty
        case .section: controller.shownHeading != nil || window != nil
        }
    }

    @ViewBuilder
    private func content(_ metrics: NotesPanelMetrics) -> some View {
        let columns = metrics.usesColumns && hasLowerRegion
        // One layout value for both arrangements keeps the editor's identity (and so its
        // UIKit view) when the panel switches between stacked and two-column, and when the
        // region under the note comes and goes.
        let layout = metrics.usesColumns
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
        layout {
            editorArea(metrics)
                .frame(width: columns ? metrics.noteColumnWidth : nil)
                .frame(maxWidth: columns ? nil : .infinity, maxHeight: .infinity)
            if columns {
                Divider()
                ScrollView(.vertical) {
                    lowerRegion
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasLowerRegion {
                Divider()
                NotesBoundedScroll(maximumHeight: metrics.lowerRegionMaximumHeight) {
                    lowerRegion
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func editorArea(_ metrics: NotesPanelMetrics) -> some View {
        if let model = controller.model {
            NotePageView(model: model, session: session, zoom: zoomBinding(metrics), pageWidth: metrics.notePageWidth)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .accessibilityLabel(session.notesTab == .page ? "Page note" : "Section note")
        } else {
            NotesSectionEmptyState(session: session, controller: controller)
        }
    }

    /// Under the note (beside it in a wide sheet): the page's highlights, or the level picker and
    /// "Open in Notebook".
    private var lowerRegion: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch session.notesTab {
            case .page:
                NotesHighlightsSection(session: session, highlights: highlights)
            case .section:
                if let heading = controller.shownHeading {
                    NotesLevelPicker(levels: NotesSectionSelection.levels(showing: heading, page: session.currentPageIndex,
                                                                          outline: session.outline),
                                     shown: heading,
                                     hasNote: { session.notebook?.section(for: $0)?.note != nil },
                                     choose: { controller.chooseLevel($0) })
                        .padding(.top, 12)
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
