import ReaderCore
import SwiftUI

/// "Add Heading at Page N": a title (a standard text field, so Scribble works), the page
/// (defaults to N), and where it goes: "Top level" or inside one of the headings that contain the
/// page (the core's recommended choices), defaulting to the same level as the page's current
/// section. Saves through `UserHeadingEditor.add` (`session.perform`).
struct AddHeadingSheet: View {
    let session: ReaderSession
    let onAdded: (HeadingAnchor) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var pageText: String
    @State private var parent: HeadingParentChoice
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    init(session: ReaderSession, initialPageIndex: Int, onAdded: @escaping (HeadingAnchor) -> Void) {
        self.session = session
        self.onAdded = onAdded
        _pageText = State(initialValue: "\(PageNumbering.displayNumber(forPageIndex: initialPageIndex))")
        _parent = State(initialValue: UserHeadingEditor.defaultParent(outline: session.outline, pageIndex: initialPageIndex))
    }

    /// The zero-based page typed, if valid.
    private var pageIndex: Int? {
        guard let number = Int(pageText.trimmingCharacters(in: .whitespaces)) else { return nil }
        let index = PageNumbering.pageIndex(forDisplayNumber: number)
        return PageNumbering.isValid(index, pageCount: session.pageCount) ? index : nil
    }

    private var choices: [HeadingParentChoice] {
        UserHeadingEditor.parentChoices(outline: session.outline, pageIndex: pageIndex ?? 0)
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
                            .keyboardType(.numberPad)
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
                    Picker("Place", selection: $parent) {
                        ForEach(choices) { choice in
                            Text(choice.title)
                                .padding(.leading, CGFloat(choice.childLevel - 1) * 14)
                                .tag(choice)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier(SidebarAccessibilityID.addHeadingParent)
                } header: {
                    Text("Place inside")
                } footer: {
                    Text("The new heading will be at level \(parent.childLevel).")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Heading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(SidebarAccessibilityID.addHeadingCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save)
                        .disabled(!canSave)
                        .accessibilityIdentifier(SidebarAccessibilityID.addHeadingSave)
                }
            }
        }
        .onChange(of: pageIndex) { _, newPage in
            // Keep the choice only if it still contains the new page.
            guard let newPage, !choices.contains(parent) else { return }
            parent = UserHeadingEditor.defaultParent(outline: session.outline, pageIndex: newPage)
        }
        .onAppear { titleFocused = true }
    }

    private func save() {
        guard canSave, let pageIndex else { return }
        do {
            let anchor = try UserHeadingEditor.add(title: title, pageIndex: pageIndex, parent: parent, session: session)
            onAdded(anchor)
            dismiss()
        } catch {
            errorMessage = "The heading could not be saved."
        }
    }
}
