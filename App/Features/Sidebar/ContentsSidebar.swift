import ReaderCore
import SwiftUI

/// The sidebar's tabs.
enum SidebarTab: String, CaseIterable, Identifiable {
    case contents, pages, bookmarks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .contents: "Contents"
        case .pages: "Pages"
        case .bookmarks: "Bookmarks"
        }
    }
}

/// What the tabs ask the sidebar to present (sheets and alerts live at the sidebar's root so
/// they survive switching tabs).
@MainActor
struct SidebarActions {
    var addHeading: (_ pageIndex: Int) -> Void
    var rename: (_ node: OutlineNode) -> Void
    var delete: (_ node: OutlineNode) -> Void
}

/// The reader's sidebar (WP5): **Contents** (the merged outline with note badges and
/// current-section tracking, plus the reader's own headings), **Pages** (a lazy thumbnail grid)
/// and **Bookmarks**. The shell hosts it as the left pane at wide widths and as an overlay at
/// narrow widths, and owns the container, its width and visibility; this view lays itself out
/// from the size it is given.
///
/// - Reads and commands only its own window's `session`; per-window state lives in
///   `ContentsSidebarModel` (`session.featureState`), the selected tab in scene storage.
/// - Navigates only through `session.jump(…)` (section history), never the PDF view; showing,
///   hiding or switching tabs never touches the reading position.
struct ContentsSidebar: View {
    let session: ReaderSession
    private let model: ContentsSidebarModel

    /// Remembered per window (scene) and restored with it.
    @SceneStorage("sidebar.tab") private var tabRaw = SidebarTab.contents.rawValue
    @State private var addHeadingRequest: AddHeadingRequest?
    @State private var renaming: OutlineNode?
    @State private var renameText = ""
    @State private var deleting: PendingDeletion?

    init(session: ReaderSession) {
        self.session = session
        self.model = session.featureState { ContentsSidebarModel(session: session) }
    }

    private var tab: Binding<SidebarTab> {
        Binding(get: { SidebarTab(rawValue: tabRaw) ?? .contents }, set: { tabRaw = $0.rawValue })
    }

    private var actions: SidebarActions {
        SidebarActions(
            addHeading: { page in addHeadingRequest = AddHeadingRequest(pageIndex: page) },
            rename: { node in
                renameText = node.title
                renaming = node
            },
            delete: { node in
                guard let summary = try? UserHeadingEditor.deletionSummary(node.anchor, session: session) else { return }
                deleting = PendingDeletion(node: node, summary: summary)
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: tab) {
                ForEach(SidebarTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .accessibilityIdentifier(SidebarAccessibilityID.tabs)

            switch tab.wrappedValue {
            case .contents:
                ContentsOutlineView(session: session, model: model, actions: actions)
            case .pages:
                PagesGridView(session: session, model: model, actions: actions)
            case .bookmarks:
                BookmarksListView(session: session, model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { model.start() }
        .sheet(item: $addHeadingRequest) { request in
            AddHeadingSheet(session: session, initialPageIndex: request.pageIndex) { anchor in
                model.revealWhenAvailable(anchor)
            }
        }
        .alert("Rename Heading", isPresented: renamingBinding, presenting: renaming) { node in
            TextField("Title", text: $renameText)
                .accessibilityIdentifier(SidebarAccessibilityID.renameField)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { try? UserHeadingEditor.rename(node.anchor, to: renameText, session: session) }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(deleting.map { "Delete “\($0.summary.title)”?" } ?? "", isPresented: deletingBinding,
               presenting: deleting) { pending in
            Button("Cancel", role: .cancel) {}
            Button("Delete Heading", role: .destructive) {
                try? UserHeadingEditor.delete(pending.node.anchor, session: session)
            }
        } message: { pending in
            Text(pending.summary.message)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SidebarAccessibilityID.root)
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}

private struct AddHeadingRequest: Identifiable {
    let id = UUID()
    let pageIndex: Int
}

private struct PendingDeletion {
    let node: OutlineNode
    let summary: UserHeadingDeletionSummary
}
