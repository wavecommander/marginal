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

    var body: some View {
        GeometryReader { geometry in
            let wide = ReaderLayout.isWide(width: geometry.size.width, horizontalSizeClass: horizontalSizeClass)
            Group {
                if wide {
                    wideLayout(width: geometry.size.width)
                } else {
                    narrowLayout
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
                .accessibilityIdentifier(AccessibilityID.Reader.notesSheet)
                .environment(session)
        }
        .environment(session)
        .focusedSceneValue(session)
        .accessibilityIdentifier(AccessibilityID.Reader.screen)
    }

    // MARK: Layouts

    private func wideLayout(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if session.isContentsVisible {
                ContentsSidebar(session: session)
                    .frame(width: ReaderSession.contentsSidebarWidth)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AccessibilityID.Reader.contentsPane)
                Divider()
            }
            pageArea
            if session.isNotesVisible {
                NotesDivider(session: session, windowWidth: width)
                NotesPanel(session: session)
                    .frame(width: ReaderLayout.notesWidth(requested: session.notesPanelWidth, windowWidth: width))
                    .background(Color(uiColor: .systemBackground))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AccessibilityID.Reader.notesPane)
            }
        }
    }

    private var narrowLayout: some View {
        ZStack(alignment: .leading) {
            pageArea
            if session.isContentsOverlayVisible {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .onTapGesture { session.isContentsOverlayVisible = false }
                    .accessibilityHidden(true)
                ContentsSidebar(session: session)
                    .frame(width: min(320, ReaderSession.contentsSidebarWidth + 20))
                    .background(Color(uiColor: .systemGroupedBackground))
                    .shadow(radius: 12)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AccessibilityID.Reader.contentsOverlay)
                    .transition(.move(edge: .leading))
                    .onChange(of: session.currentPageIndex) { _, _ in session.isContentsOverlayVisible = false }
            }
        }
        .animation(.default, value: session.isContentsOverlayVisible)
    }

    private var pageArea: some View {
        ZStack(alignment: .bottom) {
            ReaderPDFViewRepresentable(session: session)
                .ignoresSafeArea(.container, edges: .bottom)
            switch session.loadState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(AccessibilityID.Reader.loading)
            case .failed(let message):
                ContentUnavailableView("Cannot Open Book", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .ready:
                PagePill(session: session)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var notesSheetBinding: Binding<Bool> {
        Binding(get: { session.isNarrowLayout && session.isNotesVisible && session.closeReason == nil },
                set: { if session.isNarrowLayout { session.isNotesVisible = $0 } })
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
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { session.isSearchVisible = true } label: {
                    Label("Search Book and Notes", systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier(AccessibilityID.Reader.search)
                .popover(isPresented: $session.isSearchVisible) {
                    SearchPanel(session: session).environment(session)
                }
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

/// Back / Forward through section history. Tap steps once; press and hold lists the entries in
/// that direction ("section · p. N") and jumps straight to the chosen one. Arrows, not the
/// chevron of the "‹ Library" back button.
private struct SectionHistoryButton: View {
    enum Direction { case back, forward }

    let session: ReaderSession
    let direction: Direction

    var body: some View {
        let entries = direction == .back ? session.history.backList : session.history.forwardList
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
/// up to half the window; VoiceOver can adjust it.
private struct NotesDivider: View {
    let session: ReaderSession
    let windowWidth: CGFloat
    @State private var startWidth: Double?

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
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let start = startWidth ?? Double(ReaderLayout.notesWidth(requested: session.notesPanelWidth,
                                                                             windowWidth: windowWidth))
                    startWidth = start
                    let proposed = start - Double(value.translation.width)
                    session.notesPanelWidth = Double(ReaderLayout.notesWidth(requested: proposed, windowWidth: windowWidth))
                }
                .onEnded { _ in startWidth = nil }
        )
        .accessibilityElement()
        .accessibilityLabel("Notes panel width")
        .accessibilityValue("\(Int(session.notesPanelWidth)) points")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 40.0 : -40.0
            session.notesPanelWidth = Double(ReaderLayout.notesWidth(requested: session.notesPanelWidth + step,
                                                                     windowWidth: windowWidth))
        }
        .accessibilityIdentifier(AccessibilityID.Reader.notesDivider)
    }
}

/// "312 of 742": tap to type a page number (a standard text field, so Scribble works).
private struct PagePill: View {
    @Bindable var session: ReaderSession
    @State private var text = ""
    @FocusState private var isFieldFocused: Bool

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
                    Text("of \(session.pageCount)").foregroundStyle(.white)
                    Button("Cancel") { session.isGoToPageVisible = false }
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .onAppear {
                    text = ""
                    isFieldFocused = true
                }
            } else {
                Button { session.isGoToPageVisible = true } label: {
                    Text("\(number) of \(session.pageCount)")
                        .monospacedDigit()
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                }
                .foregroundStyle(.white)
                .accessibilityLabel("Page \(number) of \(session.pageCount)")
                .accessibilityHint("Go to page")
                .accessibilityIdentifier(AccessibilityID.Reader.pagePill)
            }
        }
        .font(.subheadline.weight(.medium))
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .onChange(of: isFieldFocused) { _, focused in
            if !focused {
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
    /// The title with its subtitle (the current section). iPadOS 26+: the system subtitle.
    /// Earlier: a two-line principal toolbar item. The block's accessibility label is the
    /// title and its value the subtitle on both paths.
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
