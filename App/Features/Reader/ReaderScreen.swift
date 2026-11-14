import ReaderCore
import SwiftUI

/// Layout decisions from the window's own width (never the screen or the orientation).
nonisolated enum ReaderLayout {
    /// Below this content width the reader is "narrow": Contents is an overlay and the notes
    /// panel a sheet (portrait, Split View, Slide Over, small Stage Manager windows). Three panes
    /// need 280 (Contents) + ~400 (page) + 330 (notes).
    static let wideThreshold: CGFloat = 1000

    static func isWide(width: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        horizontalSizeClass != .compact && width >= wideThreshold
    }

    /// The notes panel width actually used: at least the default, at most half the window.
    /// Narrow widths show the notes panel as a system sheet with medium/large detents and
    /// background interaction. iPadOS 26+ presents such a sheet attached to the bottom of a
    /// regular-width window; earlier systems present it as a centred, modal form sheet that
    /// ignores detents and blocks the page (seen on iPadOS 17.5), so they get
    /// `NotesBottomPanel` (an inline panel with the same two heights) instead. The only
    /// availability check for this feature.
    static var usesSystemNotesSheet: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    static func notesWidth(requested: Double, windowWidth: CGFloat) -> CGFloat {
        let maximum = max(CGFloat(ReaderSession.defaultNotesPanelWidth), windowWidth / 2)
        return min(max(CGFloat(requested), CGFloat(ReaderSession.defaultNotesPanelWidth)), maximum)
    }
}

/// The reader shell: toolbar, three panes (wide) or page + overlay + sheet (narrow), the page
/// pill and go-to-page field. Feature panes are the placeholders other packages replace.
struct ReaderScreen: View {
    @Bindable var session: ReaderSession
    @Environment(WindowContext.self) private var window
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The search panel is on screen (from its appearance until its dismissal has finished).
    @State private var isSearchPanelOnScreen = false
    /// The notes pane's width while its handle slides it shut (below its narrowest width).
    @State private var notesCollapsingWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let wide = ReaderLayout.isWide(width: geometry.size.width, horizontalSizeClass: horizontalSizeClass)
            Group {
                if wide {
                    wideLayout(width: geometry.size.width)
                } else {
                    narrowLayout(height: geometry.size.height)
                }
            }
            .onChange(of: wide, initial: true) { _, isWide in
                session.isNarrowLayout = !isWide
                if isWide { session.isContentsOverlayVisible = false }
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle(session.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .readerSubtitle(title: session.book.title, subtitle: subtitle)
        .toolbar { toolbarContent }
        .sheet(isPresented: notesSheetBinding) {
            NotesPanel(session: session)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .paneContainer(AccessibilityID.Reader.notesSheet)
                .environment(session)
        }
        .environment(session)
        .focusedSceneValue(session)
    }

    // MARK: Layouts

    private func wideLayout(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if session.isContentsVisible {
                ContentsSidebar(session: session)
                    .frame(width: ReaderSession.contentsSidebarWidth)
                    .paneContainer(AccessibilityID.Reader.contentsPane)
                Divider()
            }
            pageArea
            if session.isNotesVisible {
                let notesWidth = ReaderLayout.notesWidth(requested: session.notesPanelWidth, windowWidth: width)
                NotesDivider(session: session, windowWidth: width, collapsingWidth: $notesCollapsingWidth)
                    .zIndex(1)  // the handle's hit area overlaps the page and the note
                // While the handle slides the pane shut, the pane (laid out at its narrowest
                // width, so the note does not re-wrap) is cut from its leading edge.
                NotesPanel(session: session)
                    .frame(width: notesWidth)
                    .frame(width: notesCollapsingWidth ?? notesWidth, alignment: .leading)
                    .clipped()
                    .background(Color(uiColor: .systemBackground))
                    .paneContainer(AccessibilityID.Reader.notesPane)
            }
        }
    }

    private func narrowLayout(height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                pageArea
                if !ReaderLayout.usesSystemNotesSheet && session.isNotesVisible {
                    NotesBottomPanel(session: session, containerHeight: height)
                        .transition(.move(edge: .bottom))
                }
            }
            if session.isContentsOverlayVisible {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .onTapGesture { session.isContentsOverlayVisible = false }
                    .accessibilityHidden(true)
                ContentsSidebar(session: session)
                    .frame(width: min(320, ReaderSession.contentsSidebarWidth + 20))
                    .background(Color(uiColor: .systemGroupedBackground))
                    .shadow(radius: 12)
                    .paneContainer(AccessibilityID.Reader.contentsOverlay)
                    .transition(.move(edge: .leading))
                    .onChange(of: session.currentPageIndex) { _, _ in session.isContentsOverlayVisible = false }
            }
        }
        .animation(.default, value: session.isContentsOverlayVisible)
    }

    /// The pill sits at the bottom of the page (mockup), except at narrow widths while the notes
    /// sheet covers the bottom: then it moves to the top of the page so it stays reachable.
    private var pillAtTop: Bool {
        ReaderLayout.usesSystemNotesSheet && session.isNarrowLayout && session.isNotesVisible
    }

    private var pageArea: some View {
        ZStack(alignment: pillAtTop ? .top : .bottom) {
            // The keyboard (go-to-page field, search) must not resize the page: only the pill
            // moves above it.
            ReaderPDFViewRepresentable(session: session)
                .ignoresSafeArea(.container, edges: .bottom)
                .ignoresSafeArea(.keyboard)
            switch session.loadState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(AccessibilityID.Reader.loading)
            case .failed(let message):
                ContentUnavailableView("Cannot Open Book", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .ready:
                PagePill(session: session)
                    .padding(pillAtTop ? .top : .bottom, 14)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var notesSheetBinding: Binding<Bool> {
        // While search is up the sheet steps aside (one presentation at a time) without
        // changing `isNotesVisible`, and it comes back once the search panel's dismissal has
        // finished (presenting earlier would be dropped). Only a dismissal by the reader (swipe
        // down) hides the notes. The note page saves on disappearing, so nothing is lost.
        Binding(get: {
                    ReaderLayout.usesSystemNotesSheet && session.isNarrowLayout && session.isNotesVisible
                        && !session.isSearchVisible && !isSearchPanelOnScreen && session.closeReason == nil
                },
                set: { shown in
                    guard session.isNarrowLayout, !session.isSearchVisible, !isSearchPanelOnScreen else { return }
                    session.isNotesVisible = shown
                })
    }

    // MARK: Title

    private var subtitle: String {
        let place = session.deepestHeading?.title
            ?? PageNumbering.label(forPageIndex: session.currentPageIndex)
        return session.isMarkupMode ? "Markup · \(place)" : place
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                withAnimation { session.toggleContents() }
            } label: {
                Label(session.isContentsShown ? "Hide Contents" : "Show Contents", systemImage: "sidebar.leading")
            }
            .accessibilityIdentifier(AccessibilityID.Reader.contentsToggle)
            SectionHistoryButton(session: session, direction: .back)
            SectionHistoryButton(session: session, direction: .forward)
        }
        if session.isMarkupMode {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Find works in markup mode too (⇧⌘F or this button); markup stays on.
                searchButton
                Button { session.markup.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!session.markup.canUndo)
                    .accessibilityIdentifier(AccessibilityID.Reader.undo)
                Button { session.markup.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!session.markup.canRedo)
                    .accessibilityIdentifier(AccessibilityID.Reader.redo)
                notesToggle
                Button("Done") { session.finishMarkup() }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier(AccessibilityID.Reader.done)
                    // For UI tests: whether the window's tool picker is on screen.
                    .accessibilityValue(session.markup.isToolPickerVisible ? "tool picker shown" : "tool picker hidden")
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                searchButton
                if !session.isNarrowLayout {
                    BookmarkButton(session: session)
                }
                Button { session.setMode(.markup) } label: {
                    Label("Markup", systemImage: "pencil.tip.crop.circle")
                }
                .accessibilityIdentifier(AccessibilityID.Reader.markupToggle)
                notesToggle
                moreMenu
            }
        }
    }

    /// The search button and the anchor of the search popover, in both toolbars.
    private var searchButton: some View {
        Button { session.isSearchVisible = true } label: {
            Label("Search Book and Notes", systemImage: "magnifyingglass")
        }
        .accessibilityIdentifier(AccessibilityID.Reader.search)
        .popover(isPresented: $session.isSearchVisible) {
            SearchPanel(session: session)
                .environment(session)
                .onAppear { isSearchPanelOnScreen = true }
                .onDisappear { isSearchPanelOnScreen = false }
        }
    }

    private var notesToggle: some View {
        Button { withAnimation { session.toggleNotes() } } label: {
            Label(session.isNotesVisible ? "Hide Notes" : "Show Notes", systemImage: "note.text")
        }
        .accessibilityIdentifier(AccessibilityID.Reader.notesToggle)
        .accessibilityValue(session.isNotesVisible ? "shown" : "hidden")
    }

    private var moreMenu: some View {
        Menu {
            if session.isNarrowLayout {
                Button { BookmarkActions.toggle(session: session) } label: {
                    Label("Bookmark Page", systemImage: "bookmark")
                }
            }
            Button { session.showGoToPage() } label: { Label("Go to Page…", systemImage: "arrow.right.doc.on.clipboard") }
            Button { session.requestAddHeading() } label: {
                Label("Add Heading at This Page…", systemImage: "text.badge.plus")
            }
            Button { window.openReaderInNewWindow(bookID: session.book.id) } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
            Button { window.openNotebook(bookID: session.book.id) } label: {
                Label("Notebook", systemImage: "book.pages")
            }
            Button { window.openNotebookInNewWindow(bookID: session.book.id) } label: {
                Label("Open Notebook in New Window", systemImage: "rectangle.stack.badge.plus")
            }
            Divider()
            Button { session.zoomToFitWidth() } label: { Label("Fit Width", systemImage: "arrow.left.and.right") }
            Button { session.zoomToActualSize() } label: { Label("Actual Size", systemImage: "1.magnifyingglass") }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier(AccessibilityID.Reader.more)
    }
}

/// Narrow-width notes panel before iPadOS 26 (see `ReaderLayout.usesSystemNotesSheet`): an
/// inline panel under the page with a grabber and two heights matching the sheet's detents
/// (medium: half, large: 85% of the reader). Tap the grabber to switch; drag it up/down to
/// switch or, below medium, to hide the panel. The page above stays scrollable.
private struct NotesBottomPanel: View {
    let session: ReaderSession
    let containerHeight: CGFloat
    @State private var isLarge = false
    @State private var dragOffset: CGFloat = 0

    private var baseHeight: CGFloat { containerHeight * (isLarge ? 0.85 : 0.5) }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(uiColor: .tertiaryLabel))
                .frame(width: 40, height: 5)
                .frame(maxWidth: .infinity, minHeight: 22)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { isLarge.toggle() } }
                .gesture(
                    DragGesture()
                        .onChanged { dragOffset = $0.translation.height }
                        .onEnded { value in
                            let dy = value.translation.height
                            withAnimation {
                                if dy < -60 { isLarge = true }
                                else if dy > 60 && isLarge { isLarge = false }
                                else if dy > 60 { session.isNotesVisible = false }
                                dragOffset = 0
                            }
                        }
                )
                .accessibilityElement()
                .accessibilityLabel("Notes panel size")
                .accessibilityValue(isLarge ? "large" : "medium")
                .accessibilityAdjustableAction { direction in
                    withAnimation { isLarge = direction == .increment }
                }
            NotesPanel(session: session)
        }
        .frame(height: max(120, baseHeight - dragOffset))
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
        .paneContainer(AccessibilityID.Reader.notesSheet)
    }
}

/// Back / Forward through section history. Tap steps once; press and hold lists the entries in
/// that direction ("section · p. N") and jumps straight to the chosen one. Arrows, not the
/// chevron of the "‹ Library" back button.
private struct SectionHistoryButton: View {
    enum Direction { case back, forward }

    let session: ReaderSession
    let direction: Direction

    var body: some View {
        let entries = direction == .back ? session.history.backList : session.history.forwardList
        if entries.isEmpty {
            // `.disabled` on a `Menu(primaryAction:)` has no effect on iPadOS 17: use a button.
            Button {} label: { label }
                .disabled(true)
                .accessibilityIdentifier(identifier)
        } else {
            menu(entries)
        }
    }

    private var label: some View {
        Label(direction == .back ? "Back to Previous Section" : "Forward to Next Section",
              systemImage: direction == .back ? "arrow.backward" : "arrow.forward")
    }

    private var identifier: String {
        direction == .back ? AccessibilityID.Reader.historyBack : AccessibilityID.Reader.historyForward
    }

    private func menu(_ entries: [(index: Int, place: SectionPlace)]) -> some View {
        Menu {
            ForEach(entries, id: \.index) { entry in
                Button(entry.place.menuTitle) { session.goToHistoryEntry(at: entry.index) }
            }
        } label: {
            Label(direction == .back ? "Back to Previous Section" : "Forward to Next Section",
                  systemImage: direction == .back ? "arrow.backward" : "arrow.forward")
        } primaryAction: {
            if direction == .back { session.goBack() } else { session.goForward() }
        }
        .disabled(entries.isEmpty)
        .accessibilityIdentifier(direction == .back ? AccessibilityID.Reader.historyBack
                                                    : AccessibilityID.Reader.historyForward)
    }
}

/// The toolbar's bookmark toggle (state from WP5's `BookmarkActions`).
private struct BookmarkButton: View {
    let session: ReaderSession

    var body: some View {
        let _ = session.revisions.bookmarks
        let bookmarked = BookmarkActions.isBookmarked(session: session)
        Button { BookmarkActions.toggle(session: session) } label: {
            Label(bookmarked ? "Remove Bookmark" : "Bookmark This Page",
                  systemImage: bookmarked ? "bookmark.fill" : "bookmark")
        }
        .accessibilityIdentifier(AccessibilityID.Reader.bookmark)
    }
}

/// The draggable divider before the notes panel (wide layout). Dragging left widens the panel
/// up to half the window; dragging right narrows it, and past its narrowest width the pane
/// follows the finger towards its own edge and, on release, snaps shut (as the toolbar's notes
/// button closes it) or springs back (design: "Writing room"). VoiceOver can adjust it and has
/// a "Close notes" action.
private struct NotesDivider: View {
    let session: ReaderSession
    let windowWidth: CGFloat
    /// The pane's live width below its narrowest width, `nil` otherwise.
    @Binding var collapsingWidth: CGFloat?
    /// The pane's width when the current drag began.
    @State private var startWidth: Double?

    /// Collapse thresholds, as fractions of the narrowest width (330 pt): released more than
    /// 40 % of the way shut it closes, like the system sidebar's "past the middle-ish" snap; a
    /// flick closes from 24 pt past the narrowest width when its predicted end is 80 % shut.
    /// A slow slide that ends within 24 pt of the narrowest width never closes.
    static let closeFraction: CGFloat = 0.4
    static let flickFraction: CGFloat = 0.8
    static let flickMinimumDistance: CGFloat = 24

    private var minimumWidth: CGFloat { CGFloat(ReaderSession.defaultNotesPanelWidth) }

    var body: some View {
        ZStack {
            Rectangle().fill(Color(uiColor: .separator)).frame(width: 1)
            Capsule().fill(Color(uiColor: .tertiaryLabel)).frame(width: 5, height: 44)
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .gesture(drag)
        // The pill's comfortable hit area (44 x 96 pt): it overlaps the page and the note only
        // around the pill, so their edges keep their touches everywhere else.
        .overlay {
            Color.clear
                .frame(width: 44, height: 96)
                .contentShape(Rectangle())
                .gesture(drag)
                .accessibilityHidden(true)
        }
        .accessibilityElement()
        .accessibilityLabel("Notes panel width")
        .accessibilityValue("\(Int(session.notesPanelWidth)) points")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 40.0 : -40.0
            session.notesPanelWidth = Double(ReaderLayout.notesWidth(requested: session.notesPanelWidth + step,
                                                                     windowWidth: windowWidth))
        }
        .accessibilityAction(named: "Close notes") { session.isNotesVisible = false }
        .accessibilityIdentifier(AccessibilityID.Reader.notesDivider)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let start = startWidth ?? Double(ReaderLayout.notesWidth(requested: session.notesPanelWidth,
                                                                         windowWidth: windowWidth))
                startWidth = start
                let proposed = CGFloat(start) - value.translation.width
                if proposed < minimumWidth {
                    session.notesPanelWidth = Double(minimumWidth)
                    collapsingWidth = max(0, proposed)
                } else {
                    collapsingWidth = nil
                    session.notesPanelWidth = Double(ReaderLayout.notesWidth(requested: Double(proposed),
                                                                             windowWidth: windowWidth))
                }
            }
            .onEnded { value in
                guard let start = startWidth else { return }
                startWidth = nil
                let overshoot = minimumWidth - (CGFloat(start) - value.translation.width)
                let predicted = minimumWidth - (CGFloat(start) - value.predictedEndTranslation.width)
                let closes = overshoot > Self.closeFraction * minimumWidth
                    || (overshoot > Self.flickMinimumDistance && predicted > Self.flickFraction * minimumWidth)
                if closes {
                    // Slide the rest of the way shut, then close exactly as the toolbar's notes
                    // button does; reopening brings back the width from before this drag.
                    withAnimation(.snappy(duration: 0.22)) {
                        collapsingWidth = 0
                    } completion: {
                        session.isNotesVisible = false
                        collapsingWidth = nil
                        session.notesPanelWidth = start
                    }
                } else if collapsingWidth != nil {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { collapsingWidth = nil }
                }
            }
    }
}

/// "312 of 742": tap to type a page number (a standard text field, so Scribble works).
private struct PagePill: View {
    @Bindable var session: ReaderSession
    @State private var text = ""
    @FocusState private var isFieldFocused: Bool
    /// The field has held focus since it appeared (losing focus before that, e.g. while a menu
    /// that opened it is still closing, must not close it).
    @State private var hasHadFocus = false

    var body: some View {
        let number = PageNumbering.displayNumber(forPageIndex: session.currentPageIndex)
        Group {
            if session.isGoToPageVisible {
                HStack(spacing: 8) {
                    TextField("Page", text: $text)
                        .keyboardType(.numbersAndPunctuation)
                        .submitLabel(.go)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .focused($isFieldFocused)
                        .onSubmit(submit)
                        .accessibilityLabel("Go to page")
                        .accessibilityIdentifier(AccessibilityID.Reader.goToPageField)
                    Text(verbatim: "of \(session.pageCount)").foregroundStyle(.white)
                    Button("Cancel") { session.isGoToPageVisible = false }
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .onAppear {
                    text = ""
                    hasHadFocus = false
                    isFieldFocused = true
                }
                .task {
                    // Retry once the presenting menu or popover has finished dismissing.
                    try? await Task.sleep(for: .milliseconds(400))
                    if !isFieldFocused { isFieldFocused = true }
                }
            } else {
                Button { session.isGoToPageVisible = true } label: {
                    Text(verbatim: "\(number) of \(session.pageCount)")
                        .monospacedDigit()
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                }
                .foregroundStyle(.white)
                .accessibilityLabel(Text(verbatim: "Page \(number) of \(session.pageCount)"))
                .accessibilityHint("Go to page")
                .accessibilityIdentifier(AccessibilityID.Reader.pagePill)
            }
        }
        .font(.subheadline.weight(.medium))
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .onChange(of: isFieldFocused) { _, focused in
            if focused {
                hasHadFocus = true
            } else if hasHadFocus {
                hasHadFocus = false
                session.isGoToPageVisible = false
                session.markup.reassertToolPicker()
            }
        }
    }

    private func submit() {
        if let number = Int(text.trimmingCharacters(in: .whitespaces)) {
            session.jump(toDisplayNumber: number)
        }
        session.isGoToPageVisible = false
        isFieldFocused = false
    }
}

private extension View {
    /// Wraps a pane in its own accessibility container with a fixed identifier, so the
    /// identifiers inside the pane (owned by later packages) never replace the pane's.
    func paneContainer(_ identifier: String) -> some View {
        ZStack { self }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }

    /// The title with its subtitle (the current section). iPadOS 26+: the system subtitle.
    /// Earlier: a two-line principal toolbar item (`AccessibilityID.Reader.titleBlock`, one
    /// combined accessibility element "title, subtitle"). Gated path: the only place that uses
    /// `navigationSubtitle`.
    @ViewBuilder
    func readerSubtitle(title: String, subtitle: String) -> some View {
        if #available(iOS 26.0, *) {
            self.navigationSubtitle(subtitle)
        } else {
            self.toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(title).font(.headline).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.Reader.titleBlock)
                }
            }
        }
    }
}
