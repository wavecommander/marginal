import ReaderCore
import SwiftUI

/// The search UI (WP10): a search field, progress, and results grouped by heading. The shell
/// presents it in a popover from the toolbar's search button (⇧⌘F opens it too) while
/// `session.isSearchVisible`; at compact width the popover adapts to a sheet. State lives in the
/// window's `SearchModel` (`session.searchModel`), which outlives the panel.
struct SearchPanel: View {
    let session: ReaderSession
    @Bindable private var model: SearchModel
    @FocusState private var fieldFocused: Bool

    init(session: ReaderSession) {
        self.session = session
        self.model = session.searchModel
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Scanned books (S3): where recognition stands, and the "partial" line.
                SearchRecognitionStatus(session: session, model: model)
                searchField
                statusBar
                SearchPartialResultsLine(model: model)
                Divider()
                content
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { session.isSearchVisible = false }
                        .accessibilityIdentifier(SearchAccessibilityID.done)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.selectPrevious() } label: {
                        Label("Previous Result", systemImage: "chevron.up")
                    }
                    .disabled(!model.canStep)
                    .accessibilityIdentifier(SearchAccessibilityID.previous)
                    Button { model.selectNext() } label: {
                        Label("Next Result", systemImage: "chevron.down")
                    }
                    .disabled(!model.canStep)
                    .accessibilityIdentifier(SearchAccessibilityID.next)
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 420, maxWidth: .infinity,
               minHeight: 320, idealHeight: 640, maxHeight: .infinity)
        .presentationCompactAdaptation(.sheet)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SearchAccessibilityID.panel)
        .task {
            model.panelDidAppear()
            // Focus once the popover has finished presenting (focusing during the presentation
            // is dropped on iPadOS 17).
            try? await Task.sleep(for: .milliseconds(150))
            fieldFocused = true
        }
        .onDisappear { model.panelDidDisappear() }
        .onChange(of: model.phase) { _, phase in announce(phase) }
    }

    // MARK: Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            // A standard text field: Scribble and dictation work in it without extra code.
            TextField("Search book, notes and highlights", text: $model.query)
                .focused($fieldFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { model.submit() }
                .accessibilityLabel("Search book, notes and highlights")
                .accessibilityIdentifier(SearchAccessibilityID.field)
            if !model.query.isEmpty {
                Button { model.clear(); fieldFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier(SearchAccessibilityID.clear)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Status

    @ViewBuilder
    private var statusBar: some View {
        if let text = statusText {
            VStack(alignment: .leading, spacing: 6) {
                if model.isSearching, model.totalPages > 0 {
                    ProgressView(value: Double(min(model.pagesSearched, model.totalPages)),
                                 total: Double(max(model.totalPages, 1)))
                        .accessibilityHidden(true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        statusLabel(text)
                        Spacer(minLength: 0)
                        statusButton
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        statusLabel(text)
                        statusButton
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func statusLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(SearchAccessibilityID.status)
    }

    @ViewBuilder
    private var statusButton: some View {
        switch model.phase {
        case .searching:
            Button("Cancel") { model.cancel() }
                .font(.footnote.weight(.semibold))
                .accessibilityLabel("Cancel search")
                .accessibilityIdentifier(SearchAccessibilityID.cancel)
        case .capped:
            Button("Show More Results") { model.continueSearch() }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier(SearchAccessibilityID.resume)
        case .cancelled:
            Button("Continue") { model.continueSearch() }
                .font(.footnote.weight(.semibold))
                .accessibilityLabel("Continue search")
                .accessibilityIdentifier(SearchAccessibilityID.resume)
        default:
            EmptyView()
        }
    }

    private var resultsPhrase: String {
        let count = model.resultCount
        return "\(count.formatted()) \(count == 1 ? "result" : "results")"
    }

    private var statusText: String? {
        switch model.phase {
        case .idle:
            return model.isQueryTooShort ? "Type at least \(SearchModel.minimumQueryLength) characters." : nil
        case .searching:
            let searched = min(model.pagesSearched, model.totalPages).formatted()
            return "Searching… \(searched) of \(model.totalPages.formatted()) pages · \(resultsPhrase)"
        case .finished:
            return model.resultCount == 0 ? "No results" : resultsPhrase
        case .capped(let next):
            let page = PageNumbering.displayNumber(forPageIndex: max(next - 1, 0)).formatted()
            return "First \(model.textHitCount.formatted()) matches, up to page \(page) of "
                + "\(model.totalPages.formatted())"
        case .cancelled(let next):
            return "Cancelled after \(next.formatted()) of \(model.totalPages.formatted()) pages · \(resultsPhrase)"
        case .failed:
            return "This book could not be searched."
        }
    }

    /// VoiceOver hears how a search ended (the status line changes silently otherwise).
    private func announce(_ phase: SearchModel.Phase) {
        let message: String
        switch phase {
        case .finished: message = model.resultCount == 0 ? "No results" : resultsPhrase
        case .capped: message = "Showing the first \(model.textHitCount.formatted()) matches. More results are available."
        case .failed: message = "This book could not be searched."
        default: return
        }
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: Results

    @ViewBuilder
    private var content: some View {
        if model.groups.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.results) { result in
                                SearchResultRow(result: result, isSelected: result.id == model.selectedResultID) {
                                    model.choose(result)
                                }
                            }
                        } header: {
                            SearchGroupHeader(group: group)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.immediately)
                .accessibilityIdentifier(SearchAccessibilityID.results)
                .onAppear {
                    if let id = model.selectedResultID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.phase {
        case .idle:
            ContentUnavailableView {
                Label("Search This Book", systemImage: "magnifyingglass")
            } description: {
                Text("Finds text in the pages, your notes and your highlights.")
            }
        case .finished:
            ContentUnavailableView.search(text: model.searchedQuery)
        case .searching:
            ProgressView()
                .accessibilityLabel("Searching")
        case .cancelled, .capped, .failed:
            Spacer()
        }
    }
}

// MARK: - Rows

/// "Set 3" with "14 Numerical Methods › Exercises" under it, and the group's count.
private struct SearchGroupHeader: View {
    let group: SearchGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if !group.ancestorTitles.isEmpty {
                    Text(group.ancestorTitles.joined(separator: " › "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .textCase(nil)
            Spacer(minLength: 8)
            Text(group.results.count.formatted())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textCase(nil)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(SearchAccessibilityID.group(group.id))
    }

    private var accessibilityText: String {
        let count = group.results.count
        let path = group.ancestorTitles.isEmpty ? "" : ", in \(group.ancestorTitles.joined(separator: ", "))"
        return "\(group.title)\(path), \(count) \(count == 1 ? "result" : "results")"
    }
}

private struct SearchResultRow: View {
    @Environment(\.accentTheme) private var accentTheme
    let result: SearchResult
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributedSnippet)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 6 : 3)
                        .multilineTextAlignment(.leading)
                    if dynamicTypeSize.isAccessibilitySize {
                        Text(detailLine).font(.caption).foregroundStyle(.secondary)
                    } else if let kindLabel {
                        Text(kindLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 8)
                    Text(pageLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .listRowBackground(isSelected ? accentTheme.accent.opacity(0.15) : Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenKind), \(pageLabel). \(result.snippet.text)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(SearchAccessibilityID.result(result.id))
        .id(result.id)
    }

    private var pageLabel: String { PageNumbering.label(forPageIndex: result.pageIndex) }

    private var detailLine: String {
        [kindLabel, pageLabel].compactMap { $0 }.joined(separator: " · ")
    }

    private var iconName: String {
        switch result.kind {
        case .text: "text.alignleft"
        case .note: "note.text"
        case .highlight: "highlighter"
        }
    }

    private var kindLabel: String? {
        switch result.kind {
        case .text: nil
        case .highlight: "Highlight"
        case .note: result.noteTarget?.headingAnchor != nil ? "Section note" : "Page note"
        }
    }

    private var spokenKind: String { kindLabel ?? "Text" }

    /// The match in bold on a yellow wash; the wash is translucent so it reads in dark mode.
    private var attributedSnippet: AttributedString {
        var before = AttributedString(result.snippet.before)
        var match = AttributedString(result.snippet.match)
        let after = AttributedString(result.snippet.after)
        match.font = .subheadline.bold()
        match.backgroundColor = Color.yellow.opacity(0.35)
        before.append(match)
        before.append(after)
        return before
    }
}
