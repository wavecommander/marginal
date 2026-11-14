import ReaderCore
import SwiftUI

/// The Contents tab: the merged outline as a lazily rendered, flattened tree (only expanded
/// branches are rows), note badges, the current section marked and followed (rule:
/// `ContentsTree.shouldFollow`), and "Add Heading at Page N" at the bottom.
struct ContentsOutlineView: View {
    let session: ReaderSession
    let model: ContentsSidebarModel
    let actions: SidebarActions

    var body: some View {
        VStack(spacing: 0) {
            if !session.isOutlineLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading contents")
            } else if session.outline.isEmpty {
                EmptyContentsView(session: session, actions: actions)
            } else {
                ContentsList(session: session, model: model, actions: actions)
            }
            Divider()
            AddHeadingFooter(session: session, actions: actions)
        }
    }
}

/// The list itself. Kept apart from anything that changes with the current page, so scrolling
/// the book re-renders only the rows whose marking changes.
private struct ContentsList: View {
    let session: ReaderSession
    let model: ContentsSidebarModel
    let actions: SidebarActions

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.rows) { row in
                    ContentsRowView(row: row, session: session, model: model, actions: actions)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .onAppear { model.rowAppeared(row.anchor) }
                        .onDisappear { model.rowDisappeared(row.anchor) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if row.node.isEditable {
                                Button(role: .destructive) { actions.delete(row.node) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { actions.rename(row.node) } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 36)
            .accessibilityIdentifier(SidebarAccessibilityID.contentsList)
            .onAppear {
                model.start()
                model.contentsAppeared()
            }
            .onDisappear { model.contentsDisappeared() }
            .onChange(of: model.scrollRequest) { _, request in
                guard let request else { return }
                // Let the list apply any rows inserted by the same change first.
                Task { @MainActor in
                    await Task.yield()
                    if request.animated {
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(request.anchor, anchor: .center) }
                    } else {
                        proxy.scrollTo(request.anchor, anchor: .center)
                    }
                }
            }
        }
    }
}

/// One heading: disclosure chevron, title, note badge, start page.
private struct ContentsRowView: View {
    let row: ContentsRow
    let session: ReaderSession
    let model: ContentsSidebarModel
    let actions: SidebarActions

    @ScaledMetric(relativeTo: .body) private var indentStep: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var chevronWidth: CGFloat = 22

    var body: some View {
        let node = row.node
        let isCurrent = model.currentRow == row.anchor
        let isOnPath = model.currentPath.contains(row.anchor)
        let counts = session.notebook?.counts(for: row.anchor)
        let hasBadge = counts?.hasBadge ?? false

        HStack(spacing: 2) {
            disclosure
            Button { model.select(node) } label: {
                HStack(spacing: 6) {
                    Text(node.title)
                        .font(.body)
                        .fontWeight(isCurrent || row.depth == 0 ? .semibold : .regular)
                        .foregroundStyle(isCurrent || isOnPath ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if hasBadge {
                        Image(systemName: "note.text")
                            .font(.footnote)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    Text(pageText)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .padding(.vertical, 6)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(node.title)
            .accessibilityValue(accessibilityValue(isCurrent: isCurrent, isOnPath: isOnPath, counts: counts))
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityHint("Goes to this heading")
            .accessibilityActions { accessibilityActions }
            .accessibilityIdentifier(SidebarAccessibilityID.heading(node.title))
        }
        .padding(.leading, CGFloat(row.depth) * indentStep)
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contextMenu { contextMenu }
    }

    private var pageText: String {
        node.startPage.map { "\(PageNumbering.displayNumber(forPageIndex: $0))" } ?? "–"
    }

    private var node: OutlineNode { row.node }

    @ViewBuilder
    private var disclosure: some View {
        if row.hasChildren {
            Button { withAnimation(.easeInOut(duration: 0.2)) { model.toggle(row.anchor) } } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: chevronWidth, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(row.isExpanded ? "Collapse \(node.title)" : "Expand \(node.title)")
            .accessibilityValue(row.isExpanded ? "expanded" : "collapsed")
            .accessibilityIdentifier(SidebarAccessibilityID.disclosure(node.title))
        } else {
            Color.clear.frame(width: chevronWidth, height: 1).accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var accessibilityActions: some View {
        if row.hasChildren {
            Button(row.isExpanded ? "Collapse" : "Expand") { model.toggle(row.anchor) }
        }
        if node.isEditable {
            Button("Rename") { actions.rename(node) }
            Button("Delete") { actions.delete(node) }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button { model.select(node) } label: { Label("Go to Heading", systemImage: "arrow.right.circle") }
            .disabled(node.startPage == nil)
        if let start = node.startPage {
            Button { actions.addHeading(start) } label: {
                Label("Add Heading at Page \(PageNumbering.displayNumber(forPageIndex: start))", systemImage: "plus")
            }
        }
        if node.isEditable {
            Divider()
            Button { actions.rename(node) } label: { Label("Rename…", systemImage: "pencil") }
            Button(role: .destructive) { actions.delete(node) } label: { Label("Delete…", systemImage: "trash") }
        }
    }

    private func accessibilityValue(isCurrent: Bool, isOnPath: Bool, counts: NotebookCounts?) -> String {
        var parts: [String] = []
        if let start = node.startPage {
            parts.append("page \(PageNumbering.displayNumber(forPageIndex: start))")
        }
        parts.append("level \(node.level)")
        if row.hasChildren { parts.append(row.isExpanded ? "expanded" : "collapsed") }
        if let counts, counts.hasBadge { parts.append("has notes") }
        if isCurrent { parts.append("current section") } else if isOnPath { parts.append("contains current page") }
        if node.isUserHeading { parts.append("your heading") }
        return parts.joined(separator: ", ")
    }
}

/// "Add Heading at Page N" (N follows the current page).
private struct AddHeadingFooter: View {
    let session: ReaderSession
    let actions: SidebarActions

    var body: some View {
        let page = session.currentPageIndex
        Button { actions.addHeading(page) } label: {
            Label("Add Heading at Page \(PageNumbering.displayNumber(forPageIndex: page))", systemImage: "plus")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .hoverEffect(.highlight)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .disabled(session.loadState != .ready)
        .accessibilityIdentifier(SidebarAccessibilityID.addHeading)
    }
}

/// A book with no outline: say so and point at "Add heading".
private struct EmptyContentsView: View {
    let session: ReaderSession
    let actions: SidebarActions

    var body: some View {
        let page = session.currentPageIndex
        ContentUnavailableView {
            Label("No Contents", systemImage: "list.bullet.indent")
        } description: {
            Text("This PDF has no outline. Add your own headings as you read to build one.")
        } actions: {
            Button("Add Heading at Page \(PageNumbering.displayNumber(forPageIndex: page))") {
                actions.addHeading(page)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(SidebarAccessibilityID.emptyAddHeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SidebarAccessibilityID.emptyContents)
    }
}
