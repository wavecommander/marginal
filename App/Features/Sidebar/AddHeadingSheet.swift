import ReaderCore
import SwiftUI

/// The one sheet for the reader's own headings.
///
/// - **Add** ("Add Heading at Page N" from Contents, its empty state, a thumbnail, the
///   selection menu's "Add as Heading", or `SidebarHeadingActions`): a title (a standard text
///   field, so Scribble works; pre-filled from a selection), the page (defaults to N), and the
///   placement: top level or under any heading that contains the page. The placement defaults
///   to the one used last in this window when it fits the page, else the deepest heading that
///   contains the page, else top level.
/// - **Edit** a reader's heading: rename, move to another page, change level/parent (promote to
///   top level, or demote under any heading containing the page). The heading itself and its
///   sub-headings are never offered as its parent.
///
/// Saving never moves the PDF; the new or edited heading is revealed and selected in Contents.
struct HeadingSheet: View {
    let session: ReaderSession
    let model: ContentsSidebarModel
    let request: ContentsSidebarModel.HeadingSheetRequest

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var pageText: String
    @State private var parent: HeadingParentChoice
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    /// The edited heading (`nil` when adding).
    private let editing: HeadingAnchor?

    init(session: ReaderSession, model: ContentsSidebarModel, request: ContentsSidebarModel.HeadingSheetRequest) {
        self.session = session
        self.model = model
        self.request = request
        let outline = session.outline
        switch request.mode {
        case .add(let pageIndex, let suggested):
            editing = nil
            _title = State(initialValue: suggested)
            _pageText = State(initialValue: "\(PageNumbering.displayNumber(forPageIndex: pageIndex))")
            let choices = UserHeadingEditor.parentChoices(outline: outline, pageIndex: pageIndex)
            _parent = State(initialValue: UserHeadingEditor.rememberedParent(model.lastPlacement, choices: choices)
                ?? UserHeadingEditor.defaultParent(outline: outline, pageIndex: pageIndex))
        case .edit(let anchor):
            editing = anchor
            let node = outline.node(for: anchor)
            let page = node?.startPage ?? session.currentPageIndex
            _title = State(initialValue: node?.title ?? "")
            _pageText = State(initialValue: "\(PageNumbering.displayNumber(forPageIndex: page))")
            let choices = UserHeadingEditor.parentChoices(outline: outline, pageIndex: page, excluding: anchor)
            _parent = State(initialValue: choices.first { $0.anchor == node?.parentAnchor }
                ?? UserHeadingEditor.defaultParent(outline: outline, pageIndex: page, excluding: anchor))
        }
    }

    /// The zero-based page typed, if valid.
    private var pageIndex: Int? {
        guard let number = Int(pageText.trimmingCharacters(in: .whitespaces)) else { return nil }
        let index = PageNumbering.pageIndex(forDisplayNumber: number)
        return PageNumbering.isValid(index, pageCount: session.pageCount) ? index : nil
    }

    private var choices: [HeadingParentChoice] {
        UserHeadingEditor.parentChoices(outline: session.outline, pageIndex: pageIndex ?? 0, excluding: editing)
    }

    /// The placement actually used: the reader's choice while it contains the typed page, else
    /// the choice at the same level, else the default. The choice itself is kept, so typing a
    /// page number digit by digit (passing through pages it does not contain) never loses it.
    private var placement: HeadingParentChoice {
        let choices = choices
        if choices.contains(parent) { return parent }
        return choices.first { $0.childLevel == parent.childLevel }
            ?? UserHeadingEditor.defaultParent(outline: session.outline, pageIndex: pageIndex ?? 0, excluding: editing)
    }

    private var placementBinding: Binding<HeadingParentChoice> {
        Binding(get: { placement }, set: { parent = $0 })
    }

    private var canSave: Bool {
        pageIndex != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Heading title", text: $title)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier(SidebarAccessibilityID.addHeadingTitle)
                } header: {
                    Text("Title")
                }
                Section {
                    HStack {
                        TextField("Page", text: $pageText)
                            .keyboardType(.numbersAndPunctuation)
                            .accessibilityLabel("Page number")
                            .accessibilityIdentifier(SidebarAccessibilityID.addHeadingPage)
                        Text(verbatim: "of \(session.pageCount)").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Starts on page")
                } footer: {
                    if pageIndex == nil {
                        Text("Enter a page from 1 to \(session.pageCount).").foregroundStyle(.red)
                    }
                }
                Section {
                    Picker("Place", selection: placementBinding) {
                        ForEach(choices) { choice in
                            HeadingChoiceLabel(choice: choice).tag(choice)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier(SidebarAccessibilityID.addHeadingParent)
                } header: {
                    Text("Place")
                } footer: {
                    Text("Level \(placement.childLevel). A heading can go at the top level or under any heading that contains its page.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(editing == nil ? "Add Heading" : "Edit Heading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(SidebarAccessibilityID.addHeadingCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save", action: save)
                        .disabled(!canSave)
                        .accessibilityIdentifier(SidebarAccessibilityID.addHeadingSave)
                }
            }
        }
        .onAppear { if editing == nil { titleFocused = true } }
    }

    private func save() {
        guard canSave, let pageIndex else { return }
        do {
            if let editing {
                try UserHeadingEditor.update(editing, title: title, pageIndex: pageIndex, parent: placement, session: session)
                model.headingSaved(editing, placement: placement, isNew: false)
            } else {
                let anchor = try UserHeadingEditor.add(title: title, pageIndex: pageIndex, parent: placement, session: session)
                model.headingSaved(anchor, placement: placement, isNew: true)
            }
            dismiss()
        } catch {
            errorMessage = "The heading could not be saved."
        }
    }
}

/// A placement choice, indented by level, with the reader's own headings marked.
private struct HeadingChoiceLabel: View {
    let choice: HeadingParentChoice

    var body: some View {
        HStack(spacing: 6) {
            Text(choice.title)
            if choice.isUserHeading {
                ReaderHeadingMark()
            }
        }
        .padding(.leading, CGFloat(choice.childLevel - 1) * 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(choice.isUserHeading ? "\(choice.title), your heading" : choice.title)
    }
}

/// The subtle mark of a heading the reader added (VoiceOver says "your heading" on the row).
struct ReaderHeadingMark: View {
    var body: some View {
        Image(systemName: "person.crop.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}
