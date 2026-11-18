import ReaderCore
import SwiftUI

/// The notes panel: Page note and Section note tabs around the note page editor.
///
/// The shell hosts it as the right-hand pane (wide windows: its width is
/// `session.notesPanelWidth`, dragged with `reader.notesDivider`), as the system sheet with
/// detents (narrow windows, iPadOS 26+) or as the inline bottom panel (narrow windows, earlier
/// systems). Everything here is laid out from the panel's own size (`NotesPanelMetrics`).
///
/// Laid out as the design's "Notes panel layout" rule says:
/// - **Header:** the tab picker, Delete Note, and the shrink button while the pane is wider than
///   its default; then the title and the "Saved" status. A narrow panel on a compact screen
///   adds Markup and, while it is on, ink Undo and Redo only when expanded to full screen
///   (covering the toolbar); a narrow panel with lists under or beside the note adds a button
///   that hides and shows them.
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
    /// The reader hid the lists under (or beside) the note in a narrow panel. Remembered, like
    /// the level picker's own collapse.
    @AppStorage(NotesPanelRegions.collapsedKey) private var isLowerRegionCollapsed = false
    /// The note the reader asked to delete (confirmation shown while set).
    @State private var deleteCandidate: NotePageModel?
    /// The shown page's highlights (Page note tab; empty on the Section tab).
    @State private var highlights: [Highlight] = []
    /// Height of the padded header, used to end the sheet's translucent-to-paper gradient smoothly
    /// just into the top of the note area.
    @State private var headerHeight: CGFloat = 96
    /// Top container safe area inside the sheet (measured before `.ignoresSafeArea`).
    @State private var sheetTopInset: CGFloat = 0

    private struct HighlightsKey: Equatable {
        /// `nil` on the Section tab.
        var page: Int?
        var revision: Int
    }

    /// The reader's window is compact in either direction (an iPhone, or a compact-width iPad
    /// window). Given by the shell from the window's own size classes: inside a sheet the
    /// environment's are the sheet's (compact in a regular iPad window too).
    private let isCompactWindow: Bool
    /// Presented inside the iOS 26+ system `.sheet`: blends the sheet's translucent Liquid Glass
    /// top smoothly into `NotePageStyle.paperColor` instead of leaving a sharp cut around the editor.
    private let isSystemSheet: Bool
    /// Whether the notes panel has been expanded to full screen (the large sheet detent on a
    /// compact screen, or compact vertical size class where a system sheet always fills the screen).
    private let isExpandedToFullScreen: Bool

    init(session: ReaderSession,
         isCompactWindow: Bool = false,
         isSystemSheet: Bool = false,
         isExpandedToFullScreen: Bool = false) {
        self.session = session
        self.controller = session.notesPanel
        self.isCompactWindow = isCompactWindow
        self.isSystemSheet = isSystemSheet
        self.isExpandedToFullScreen = isExpandedToFullScreen
    }

    var body: some View {
        GeometryReader { proxy in
            // No lists to show (a page without highlights) counts as hidden: the note has the
            // whole width either way, so its page widens to fill it the same.
            let metrics = NotesPanelMetrics(presentation: session.isNarrowLayout ? .narrow : .pane, size: proxy.size,
                                            listsHidden: session.isNarrowLayout && (!hasLowerRegion || isLowerRegionCollapsed))
            VStack(alignment: .leading, spacing: 0) {
                header(metrics)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if height > 0 { headerHeight = height }
                    }
                content(metrics)
            }
            .onChange(of: proxy.safeAreaInsets.top, initial: true) { _, inset in
                sheetTopInset = inset
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        // The editor insets itself for the keyboard and scrolls the cursor into view; SwiftUI's
        // own avoidance would also push the whole panel up.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background {
            if isSystemSheet {
                sheetGradientBackground
            }
        }
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
                Task {
                    if await controller.delete(model) {
                        session.finishMarkup()
                    } else if session.isMarkupMode {
                        session.markup.reassertToolPicker()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                if session.isMarkupMode {
                    session.markup.reassertToolPicker()
                }
            }
        } message: { model in
            Text(Self.deleteMessage(hasInk: model.hasInk))
        }
        .onChange(of: controller.model?.revision) { _, _ in
            if let pending = controller.undoController.pending,
               let model = controller.model,
               model.target == pending.note.target,
               !NotesPanelController.isEmpty(model) {
                controller.undoController.dismiss()
            }
        }
        .onChange(of: session.saveToken.isRevoked) { _, revoked in
            if revoked { controller.undoController.dismiss() }
        }
        .overlay(alignment: .bottom) {
            DeletedNoteUndoPill(controller: controller.undoController)
                .padding(.bottom, Space.l)
                .padding(.horizontal, Space.m)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(NotesPanelAccessibilityID.panel)
    }

    // MARK: Header

    private func header(_ metrics: NotesPanelMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Picker("Note", selection: Binding(get: { session.notesTab }, set: { controller.selectTab($0) })) {
                    // Beside the markup controls in a phone-width panel the full names were cut
                    // to "Page n…" / "Section…"; VoiceOver still reads them in full.
                    let short = showsMarkupControls && metrics.size.width < 500
                    Text(short ? "Page" : "Page note").tag(ReaderSession.NotesTab.page)
                        .accessibilityLabel("Page note")
                    Text(short ? "Section" : "Section note").tag(ReaderSession.NotesTab.section)
                        .accessibilityLabel("Section note")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .accessibilityIdentifier(NotesPanelAccessibilityID.tabs)
                Spacer(minLength: 0)
                if showsMarkupControls {
                    markupControls
                }
                if showsLowerRegionToggle(metrics) {
                    lowerRegionToggle(metrics)
                }
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

    /// Only when a narrow panel on a compact screen is expanded to full screen (the large sheet
    /// detent, or landscape on an iPhone where the sheet takes the whole screen) does it cover the
    /// toolbar, so only then does the panel carry the Markup switch and ink Undo / Redo itself.
    private var showsMarkupControls: Bool {
        NotesPanelMarkupControls.isShown(presentation: session.isNarrowLayout ? .narrow : .pane,
                                         isCompactWindow: isCompactWindow,
                                         isExpandedToFullScreen: isExpandedToFullScreen)
    }

    /// Markup, as in the toolbar (outlined while off, filled while on), and ink Undo / Redo
    /// while it is on: the tool picker has none on a compact screen.
    @ViewBuilder
    private var markupControls: some View {
        if session.isMarkupMode {
            headerButton("Undo", systemImage: "arrow.uturn.backward", id: NotesPanelAccessibilityID.undo) {
                session.markup.undo()
            }
            .disabled(!session.markup.canUndo)
            headerButton("Redo", systemImage: "arrow.uturn.forward", id: NotesPanelAccessibilityID.redo) {
                session.markup.redo()
            }
            .disabled(!session.markup.canRedo)
        }
        headerButton(session.isMarkupMode ? "Done with Markup" : "Markup",
                     systemImage: session.isMarkupMode ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                     id: NotesPanelAccessibilityID.markup) {
            session.toggleMarkup()
        }
    }

    private func showsLowerRegionToggle(_ metrics: NotesPanelMetrics) -> Bool {
        metrics.presentation == .narrow && hasLowerRegion
    }

    /// Hides and shows the lists under (or beside) the note, so the note can have the panel.
    private func lowerRegionToggle(_ metrics: NotesPanelMetrics) -> some View {
        let name = session.notesTab == .page ? "Highlights" : "Section Levels"
        return headerButton(isLowerRegionCollapsed ? "Show \(name)" : "Hide \(name)",
                            systemImage: metrics.usesColumns ? "sidebar.trailing" : "rectangle.bottomhalf.inset.filled",
                            id: NotesPanelAccessibilityID.lowerRegionToggle) {
            withAnimation { isLowerRegionCollapsed.toggle() }
        }
        .accessibilityValue(isLowerRegionCollapsed ? "Collapsed" : "Expanded")
    }

    private func headerButton(_ title: String, systemImage: String, id: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(minWidth: 40, minHeight: 44)
        }
        // In the label colour, like the toolbar's glyphs (design, "Toolbar glyphs"): Markup
        // shows its state by its glyph alone.
        .tint(Color.primary)
        .hoverEffect(.highlight)
        .accessibilityIdentifier(id)
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
        let showsLowerRegion = hasLowerRegion && !(showsLowerRegionToggle(metrics) && isLowerRegionCollapsed)
        let columns = metrics.usesColumns && showsLowerRegion
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
            } else if showsLowerRegion {
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
            NotePageView(model: model, session: session, zoom: zoomBinding(metrics),
                         pageWidth: metrics.notePageWidth, showsPaperBackground: !isSystemSheet)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .accessibilityLabel(session.notesTab == .page ? "Page note" : "Section note")
        } else {
            NotesSectionEmptyState(session: session, controller: controller)
        }
    }

    /// Smoothly blends the sheet's translucent Liquid Glass header into `NotePageStyle.paperColor`
    /// so the note area and bottom/side safe areas have no abrupt tonal seams before expanding.
    private var sheetGradientBackground: some View {
        GeometryReader { proxy in
            let transitionEnd = max(sheetTopInset + headerHeight + 12, 1)
            let totalHeight = max(proxy.size.height, transitionEnd)
            let endFraction = min(transitionEnd / totalHeight, 1)
            let paper = Color(uiColor: NotePageStyle.paperColor)
            let steps = 8
            let stops: [Gradient.Stop] = (0...steps).map { step in
                let t = Double(step) / Double(steps)
                let smooth = t * t * (3 - 2 * t)
                let alpha = 0.2 + 0.8 * smooth
                return Gradient.Stop(color: paper.opacity(alpha), location: CGFloat(t) * endFraction)
            }
            LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
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
