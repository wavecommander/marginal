import ReaderCore
import SwiftUI

/// The search UI (WP10): a search field, progress, and results grouped by heading. The shell
/// presents it in a popover from the toolbar's search button (a sheet at narrow widths) while
/// `session.isSearchVisible`. State lives in the window's `SearchModel`
/// (`session.searchModel`), which outlives the panel.
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
                searchField
                statusBar
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
        .frame(minWidth: 340, idealWidth: 420, maxWidth: .infinity,
               minHeight: 320, idealHeight: 640, maxHeight: .infinity)
        .presentationCompactAdaptation(.sheet)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SearchAccessibilityID.panel)
        .task {
            model.outlineDidChange()
            try? await Task.sleep(for: .milliseconds(150))
            fieldFocused = true
        }
        .onDisappear { model.panelDidClose() }
        .onChange(of: session.isOutlineLoaded) { _, _ in model.outlineDidChange() }
        .onChange(of: session.outline.nodes.count) { _, _ in model.outlineDidChange() }
        .onChange(of: session.revisions.notes) { _, _ in model.refreshAnnotations() }
        .onChange(of: session.revisions.highlights) { _, _ in model.refreshAnnotations() }
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
                .accessibilityIdentifier(SearchAccessibilityID.field)
            if !model.query.isEmpty {
                Button { model.clear(); fieldFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier(SearchAccessibilityID.clear)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Status

    @ViewBuilder
    private var statusBar: some View {
        if let text = statusText {
            VStack(alignment: .leading, spacing: 6) {
                if model.isSearching, model.totalPages > 0 {
                    ProgressView(value: Double(model.pagesSearched), total: Double(max(model.totalPages, 1)))
                        .accessibilityHidden(true)
                        .accessibilityIdentifier(SearchAccessibilityID.progress)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(SearchAccessibilityID.status)
                    statusButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var statusButton: some View {
        switch model.phase {
        case .searching:
            Button("Stop") { model.stop() }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier(SearchAccessibilityID.stop)
        case .capped:
            Button("Show More Results…") { model.continueSearch() }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier(SearchAccessibilityID.resume)
        case .stopped:
            Button("Continue") { model.continueSearch() }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier(SearchAccessibilityID.resume)
        default:
            EmptyView()
        }
    }

    private var statusText: String? {
        let results = model.resultCount.formatted()
        let noun = model.resultCount == 1 ? "result" : "results"
        switch model.phase {
        case .idle:
            return model.isQueryTooShort ? "Type at least \(SearchModel.minimumQueryLength) characters." : nil
        case .searching:
            let total = model.totalPages.formatted()
            return "Searching… \(model.pagesSearched.formatted()) of \(total) pages · \(results) \(noun)"
        case .finished:
            return model.resultCount == 0 ? "No results" : "\(results) \(noun)"
        case .capped:
            return "\(results) \(noun) so far; showing the first \(model.textHitCount.formatted()) text matches"
        case .stopped(let next):
            let page = PageNumbering.displayNumber(forPageIndex: max(next - 1, 0)).formatted()
            return "Stopped at page \(page) · \(results) \(noun)"
        case .failed:
            return "The book could not be searched."
        }
    }

    // MARK: Results

    @ViewBuilder
    private var content: some View {
        if model.groups.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.results) { result in
                                SearchResultRow(result: result, isSelected: result.id == model.selectedResultID) {
                                    choose(result)
                                }
                            }
                        } header: {
                            SearchGroupHeader(group: group)
                        }
                    }
                }
                .listStyle(.plain)
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
        case .finished, .failed:
            ContentUnavailableView.search(text: model.searchedQuery)
        case .searching, .stopped, .capped:
            Spacer()
        }
    }

    private func choose(_ result: SearchResult) {
        if result.kind == .note {
            // Let this panel finish dismissing before the notes panel (a sheet when narrow) opens.
            session.isSearchVisible = false
            let model = model
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                model.select(result)
            }
        } else {
            model.select(result)
            session.isSearchVisible = false
        }
    }
}

// MARK: - Rows

private struct SearchGroupHeader: View {
    let group: SearchGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(group.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
            Spacer(minLength: 8)
            Text(group.results.count.formatted())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.title), \(group.results.count) \(group.results.count == 1 ? "result" : "results")")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(SearchAccessibilityID.group(group.id))
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributedSnippet)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if let kindLabel {
                        Text(kindLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(pageLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenKind), \(pageLabel). \(result.snippet.text)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(SearchAccessibilityID.result(result.id))
        .id(result.id)
    }

    private var pageLabel: String { PageNumbering.label(forPageIndex: result.pageIndex) }

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

    private var attributedSnippet: AttributedString {
        var before = AttributedString(result.snippet.before)
        var match = AttributedString(result.snippet.match)
        let after = AttributedString(result.snippet.after)
        match.font = .subheadline.bold()
        match.backgroundColor = Color.yellow.opacity(0.4)
        before.append(match)
        before.append(after)
        return before
    }
}
