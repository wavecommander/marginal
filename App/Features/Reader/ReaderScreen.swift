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
    /// Search panels on screen (each counts from its appearance until its dismissal has
    /// finished). A count, not a flag: when search reopens while the last panel is still going,
    /// the new panel's appearance and the old one's disappearance can come in either order.
    @State private var searchPanelsOnScreen = 0
    /// Re-presentations the search watchdog has tried since search was last asked for.
    @State private var searchPresentationRetries = 0
    /// `represent()` has lowered `isSearchVisible` for one turn of the run loop; the notes
    /// sheet must not start coming back in that gap.
    @State private var isRepresentingSearch = false

    /// The search panel is on screen (from its appearance until its dismissal has finished).
    private var isSearchPanelOnScreen: Bool { searchPanelsOnScreen > 0 }
    /// The search button's frame in the reader's coordinates, as last measured. Kept after search
    /// closes so the popover does not move while it is dismissed.
    @State private var searchAnchor = CGRect.zero
    /// `searchAnchor` has been measured since search last opened.
    @State private var isSearchAnchored = false
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
        // The search popover hangs from the reader, pointing at the toolbar's search button (see
        // `SearchAnchorReader`), so the button is never its source. It presents once the button
        // has been measured for this opening.
        //
        // A closing popover takes a moment to go, and it cannot open again until it has gone.
        // Raising `isSearchVisible` in that window (a tap, ⇧⌘F) left SwiftUI treating the old
        // popover as presented, so nothing showed and later taps were no change. The closing
        // window is marked (`isSearchDismissing`), a request in it is queued
        // (`ReaderSession.showSearch`), and the queued request opens search once the old panel
        // has disappeared. UIKit can also drop a presentation asked for while another one
        // animates (the narrow notes sheet coming back, say): the watchdog below re-asks every
        // quarter second until the panel appears, and after a few seconds clears the flag.
        .background(SearchAnchorReader(isActive: session.isSearchVisible) { frame in
            searchAnchor = frame
            isSearchAnchored = true
        })
        .popover(isPresented: searchPopoverBinding, attachmentAnchor: .rect(.rect(searchAnchor)), arrowEdge: .top) {
            SearchPanel(session: session)
                .environment(session)
                .onAppear {
                    searchPanelsOnScreen += 1
                    searchPresentationRetries = 0
                }
                .onDisappear {
                    searchPanelsOnScreen = max(0, searchPanelsOnScreen - 1)
                    guard searchPanelsOnScreen == 0 else { return }
                    session.isSearchDismissing = false
                    if session.isSearchReopenQueued {
                        session.isSearchReopenQueued = false
                        session.isSearchVisible = true
                    }
                }
        }
        .onChange(of: session.isSearchVisible) { _, visible in
            guard !visible else { return }
            isSearchAnchored = false
            if isSearchPanelOnScreen, !isRepresentingSearch { session.isSearchDismissing = true }
        }
        .task(id: session.isSearchDismissing) {
            // A backstop in case the closing popover never reports its disappearance.
            guard session.isSearchDismissing else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, session.isSearchDismissing else { return }
            session.isSearchDismissing = false
            searchPanelsOnScreen = 0
            if session.isSearchReopenQueued {
                session.isSearchReopenQueued = false
                session.isSearchVisible = true
            }
        }
        .task(id: session.isSearchVisible) {
            guard session.isSearchVisible else { return }
            // Each re-ask restarts this task (the flag drops and rises), so this is a poll.
            // The first check comes after a presentation has had time to start (onAppear
            // arrives about 0.1 s after the request).
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, session.isSearchVisible, !isSearchPanelOnScreen else { return }
            if searchPresentationRetries < 12 {
                searchPresentationRetries += 1
                represent()
            } else {
                // Something else holds the screen: drop the request so the button works later.
                searchPresentationRetries = 0
                session.isSearchVisible = false
            }
        }
        .navigationTitle(session.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .readerSubtitle(title: session.book.title, subtitle: subtitle)
        .toolbar { toolbarContent }
        .readerOnboardingTips(session)
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
                // The divider and the pane come and go as one, sliding in from and out to the
                // trailing edge when the notes button shows or hides them.
                HStack(spacing: 0) {
                    // Neither the divider nor the pane starts the system back swipe: a rightward
                    // drag that misses the divider's pill must not leave the book (TSOFT-225).
                    NotesDivider(session: session, windowWidth: width, collapsingWidth: $notesCollapsingWidth)
                        .backSwipeGuard()
                        .zIndex(1)  // the handle's hit area overlaps the note
                    // While the handle slides the pane shut, the pane (laid out at its narrowest
                    // width, so the note does not re-wrap) is cut from its leading edge.
                    NotesPanel(session: session)
                        .frame(width: notesWidth)
                        .frame(width: notesCollapsingWidth ?? notesWidth, alignment: .leading)
                        .clipped()
                        .background(Color(uiColor: .systemBackground))
                        .backSwipeGuard()
                        .paneContainer(AccessibilityID.Reader.notesPane)
                }
                .transition(.move(edge: .trailing))
                .zIndex(1)  // the handle's hit area overlaps the page
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
                // Scrolling sideways, a rightward drag back through the pages must not leave
                // the book (as on the notes pane, TSOFT-225). The left-edge swipe still goes back.
                .modifier(BackSwipeGuardIf(isActive: session.scrollDirection == .horizontal))
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

    private var searchPopoverBinding: Binding<Bool> {
        Binding(get: { session.isSearchVisible && isSearchAnchored },
                set: { shown in if !shown { session.isSearchVisible = false } })
    }

    private var notesSheetBinding: Binding<Bool> {
        // While search is up the sheet steps aside (one presentation at a time) without
        // changing `isNotesVisible`, and it comes back once the search panel's dismissal has
        // finished (presenting earlier would be dropped). Only a dismissal by the reader (swipe
        // down) hides the notes. The note page saves on disappearing, so nothing is lost.
        Binding(get: {
                    ReaderLayout.usesSystemNotesSheet && session.isNarrowLayout && session.isNotesVisible
                        && !session.isSearchVisible && !isSearchPanelOnScreen && !isRepresentingSearch
                        && !session.isSearchReopenQueued && session.closeReason == nil
                },
                set: { shown in
                    guard session.isNarrowLayout, !session.isSearchVisible, !isSearchPanelOnScreen,
                          !isRepresentingSearch, !session.isSearchReopenQueued else { return }
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
        // One toolbar in both modes (design, "Markup controls"). Find works in markup mode too
        // (⇧⌘F or the search button); markup stays on.
        ToolbarItemGroup(placement: .topBarTrailing) {
            searchButton
            if !session.isNarrowLayout {
                BookmarkButton(session: session)
            }
            // Ink undo/redo are the system tool picker's own buttons, except at compact width,
            // where the picker has none.
            if session.isMarkupMode && horizontalSizeClass == .compact {
                Button { session.markup.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!session.markup.canUndo)
                    .accessibilityIdentifier(AccessibilityID.Reader.undo)
                Button { session.markup.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!session.markup.canRedo)
                    .accessibilityIdentifier(AccessibilityID.Reader.redo)
            }
            markupToggle
            notesToggle
            moreMenu
        }
    }

    /// The only switch for markup mode: outlined while off, filled (and selected) while on.
    /// Turning it off does everything leaving markup does (flushes every surface).
    ///
    /// A `Toggle`, not a `Button` with `.accessibilityAddTraits(.isSelected)`: SwiftUI turns a
    /// toolbar `Button` into a bar button item that keeps only its title, image, identifier and
    /// enabled state, so traits and values added to it never reach VoiceOver or XCUITest
    /// (measured on iPadOS 27 with the button grouped, alone, with and without the More menu).
    /// A button-style `Toggle` becomes a bar item with a selection state, which UIKit exposes as
    /// the Selected trait. The label also says the state ("Done with Markup" while on). Tests
    /// read the tool picker's visibility from `ReaderStateProbe` (`-exposeMarkupState`).
    private var markupToggle: some View {
        let isOn = session.isMarkupMode
        return Toggle(isOn: Binding(get: { session.isMarkupMode },
                                    set: { on in if on != session.isMarkupMode { session.toggleMarkup() } })) {
            Label(isOn ? "Done with Markup" : "Markup",
                  systemImage: isOn ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
        }
        .toggleStyle(.button)
        .accessibilityIdentifier(AccessibilityID.Reader.markupToggle)
    }

    /// The search button, in both modes. The search popover points at it but is not attached to
    /// it (see `SearchAnchorReader`, and the popover in `body` for the closing window and the
    /// watchdog).
    private var searchButton: some View {
        Button { openSearch() } label: {
            Label(SearchAnchorReader.searchTitle, systemImage: "magnifyingglass")
        }
        .accessibilityIdentifier(AccessibilityID.Reader.search)
    }

    private func openSearch() {
        searchPresentationRetries = 0
        if session.isSearchVisible && !isSearchPanelOnScreen && !session.isSearchDismissing {
            represent()  // a dropped presentation: nothing is on screen
        } else {
            session.showSearch()
        }
    }

    /// Lowers `isSearchVisible` and raises it on the next turn of the run loop, so SwiftUI sees
    /// a change and presents the popover again.
    private func represent() {
        isRepresentingSearch = true
        session.isSearchVisible = false
        DispatchQueue.main.async {
            session.isSearchVisible = true
            isRepresentingSearch = false
        }
    }

    /// The label says the state ("Hide Notes" while shown); an accessibility value here would not
    /// reach VoiceOver (see `markupToggle`). Tests read it from `ReaderStateProbe`.
    private var notesToggle: some View {
        Button { withAnimation { session.toggleNotes() } } label: {
            Label(session.isNotesVisible ? "Hide Notes" : "Show Notes", systemImage: "note.text")
        }
        .accessibilityIdentifier(AccessibilityID.Reader.notesToggle)
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
            scrollDirectionPicker
            Divider()
            Button { session.zoomToFitWidth() } label: { Label("Fit Width", systemImage: "arrow.left.and.right") }
            Button { session.zoomToActualSize() } label: { Label("Actual Size", systemImage: "1.magnifyingglass") }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier(AccessibilityID.Reader.more)
    }

    /// Per book: pages one above the other, or side by side. Shown inline in the More menu with
    /// a checkmark on the current choice.
    private var scrollDirectionPicker: some View {
        Picker("Scrolling", selection: Binding(get: { session.scrollDirection },
                                               set: { session.setScrollDirection($0) })) {
            Label("Scroll Vertically", systemImage: "arrow.up.and.down.text.horizontal")
                .tag(ReaderScrollDirection.vertical)
            Label("Scroll Horizontally", systemImage: "arrow.left.and.right.text.vertical")
                .tag(ReaderScrollDirection.horizontal)
        }
        .pickerStyle(.inline)
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
                .hoverEffect(.highlight)
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

/// Measures the toolbar's search button for the search popover (TSOFT-216).
///
/// A popover attached to a toolbar button has the bar button item as its source, and on
/// iPadOS 26+ the system then morphs the button's whole Liquid Glass group (search, bookmark,
/// Markup, notes, More) into the popover: the popover covers the bar while it is open (those
/// buttons are gone), and on the owner's iPad the button was left looking selected after the
/// morph back. Attached to the reader with the button's frame as its anchor rect, it is a plain
/// popover under the bar whose arrow points at the button, and the toolbar is left alone.
///
/// SwiftUI gives no toolbar item's frame, so this invisible view, laid out over the reader,
/// finds the bar button item by its title in its view controller's navigation item and reports
/// `frame(in:)` in its own (the reader's) coordinates: once after search opens (the toolbar is
/// laid out by then) and again on every layout while it is open (window resized).
private struct SearchAnchorReader: UIViewRepresentable {
    /// The search button's label, which is also its bar button item's title.
    static let searchTitle = "Search Book and Notes"

    let isActive: Bool
    let onMeasure: (CGRect) -> Void

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.onMeasure = onMeasure
        view.isActive = isActive
    }

    final class AnchorView: UIView {
        var onMeasure: ((CGRect) -> Void)?
        var isActive = false {
            didSet {
                guard isActive && !oldValue else { return }
                reported = nil
                scheduleMeasure()
            }
        }
        /// The frame last reported in this opening (only changes are reported again).
        private var reported: CGRect?

        override func layoutSubviews() {
            super.layoutSubviews()
            if isActive { scheduleMeasure() }
        }

        /// After the current update pass (SwiftUI state must not change during one).
        private func scheduleMeasure() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive else { return }
                let frame = self.searchItemFrame()
                guard frame != self.reported else { return }
                self.reported = frame
                self.onMeasure?(frame)
            }
        }

        /// The search item's frame. Should the system ever lay the toolbar out without it (none
        /// seen), the popover hangs from the reader's top trailing corner instead.
        private func searchItemFrame() -> CGRect {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController {
                    let navigationItem = controller.navigationItem
                    let items = navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
                        + (navigationItem.rightBarButtonItems ?? [])
                    if let item = items.first(where: { $0.title == SearchAnchorReader.searchTitle }),
                       let frame = item.frame(in: self) {
                        return frame
                    }
                }
                responder = next
            }
            return CGRect(x: bounds.maxX, y: bounds.minY, width: 0, height: 0)
        }
    }
}
