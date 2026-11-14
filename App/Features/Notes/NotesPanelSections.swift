import ReaderCore
import SwiftUI

// The parts of the notes panel around the editor: the level picker, the lists below the note,
// and the Section tab's empty state (WP8).

// MARK: - Level picker

/// The level picker over the heading path (Section note tab): one row per level, shallowest
/// first, the shown heading selected. Choosing a row shows that heading's note and keeps it while
/// the reader scrolls within its range (`NotesSectionSelection`). In short panels it is a menu.
struct NotesLevelPicker: View {
    let levels: [OutlineNode]
    let selected: HeadingAnchor
    let isCompact: Bool
    let hasNote: (HeadingAnchor) -> Bool
    let choose: (OutlineNode) -> Void

    var body: some View {
        if isCompact {
            compactMenu
        } else {
            VStack(spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.element.id) { index, node in
                    row(node, depth: index)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
        }
    }

    private func row(_ node: OutlineNode, depth: Int) -> some View {
        let isSelected = node.anchor == selected
        let noted = hasNote(node.anchor)
        return Button { choose(node) } label: {
            HStack(spacing: 8) {
                Text(node.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if noted {
                    Image(systemName: "note.text").font(.caption).foregroundStyle(Color.accentColor)
                }
                if isSelected {
                    Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
                }
            }
            .padding(.leading, 10 + CGFloat(depth) * 14)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.title)
        .accessibilityValue(noted ? "Level \(node.level), has a note" : "Level \(node.level)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Shows this heading's note")
        .accessibilityIdentifier(NotesPanelAccessibilityID.level)
    }

    private var compactMenu: some View {
        let current = levels.first { $0.anchor == selected }
        return Menu {
            ForEach(levels) { node in
                Button { choose(node) } label: {
                    if node.anchor == selected {
                        Label(node.title, systemImage: "checkmark")
                    } else {
                        Text(node.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.indent")
                Text(current?.title ?? "Level")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .font(.subheadline.weight(.medium))
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Heading level")
        .accessibilityValue(current?.title ?? "")
        .accessibilityIdentifier(NotesPanelAccessibilityID.levelMenu)
    }
}

// MARK: - Highlights on this page

/// "Highlights on this page": the page's highlights in reading order, coloured and quoted.
/// Tapping one jumps to it (a jump, so it goes through the session). Hidden while the page has
/// none. Re-read whenever highlights change in any window (`revisions.highlights`).
struct NotesHighlightsSection: View {
    let session: ReaderSession
    let pageIndex: Int
    @State private var highlights: [Highlight] = []

    private struct LoadKey: Equatable {
        var page: Int
        var revision: Int
    }

    var body: some View {
        Group {
            if !highlights.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    NotesSectionHeader("Highlights on this page")
                    ForEach(highlights) { highlight in
                        row(highlight)
                    }
                }
            }
        }
        .task(id: LoadKey(page: pageIndex, revision: session.revisions.highlights)) {
            highlights = (try? session.store.highlights.highlights(bookID: session.book.id, pageIndex: pageIndex)) ?? []
        }
    }

    private func row(_ highlight: Highlight) -> some View {
        Button {
            session.jump(toPage: highlight.pageIndex, revealing: highlight.rects, mark: false)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(highlight.color.swatch)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black.opacity(0.25)))
                    .frame(width: 14, height: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                Text("\u{201C}\(highlight.text)\u{201D}")
                    .font(.subheadline)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(highlight.color.name) highlight")
        .accessibilityValue(highlight.text)
        .accessibilityHint("Goes to the highlight")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(NotesPanelAccessibilityID.highlight)
    }
}

extension HighlightColor {
    /// The swatch colour in lists.
    var swatch: Color {
        switch self {
        case .yellow: Color(red: 1, green: 0.84, blue: 0.04)
        case .green: Color(red: 0.2, green: 0.78, blue: 0.35)
        case .blue: Color(red: 0.35, green: 0.68, blue: 0.98)
        case .pink: Color(red: 1, green: 0.45, blue: 0.68)
        }
    }

    /// Spoken name.
    var name: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .pink: "Pink"
        }
    }
}

// MARK: - This page is in

/// "This page is in": the page's heading path, shallowest first; each row opens the Section note
/// tab on that heading (one tap from a page note to its chapter's or section's note).
struct NotesPageIsInSection: View {
    let session: ReaderSession
    let controller: NotesPanelController
    let pageIndex: Int

    var body: some View {
        let path = session.outline.headingPath(forPage: pageIndex)
        VStack(alignment: .leading, spacing: 0) {
            NotesSectionHeader("This page is in")
            if path.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(path.enumerated()), id: \.element.id) { depth, node in
                    row(node, depth: depth)
                }
            }
        }
    }

    private var emptyText: String {
        if !session.isOutlineLoaded { return "Loading contents…" }
        if session.outline.isEmpty { return "This book has no contents yet." }
        return "No heading contains this page."
    }

    private func row(_ node: OutlineNode, depth: Int) -> some View {
        let noted = session.notebook?.section(for: node.anchor)?.note != nil
        return Button { controller.openSectionNote(for: node) } label: {
            HStack(spacing: 8) {
                Text(node.title)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if noted {
                    Image(systemName: "note.text").font(.caption).foregroundStyle(Color.accentColor)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Section note for \(node.title)")
        .accessibilityValue(noted ? "Has a note" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(NotesPanelAccessibilityID.pageIsIn)
    }
}

// MARK: - Page notes in this section

/// "Page notes in this section": every page note inside the heading's page range (its nested
/// headings included), ascending, each drawn with its ink (`NotePageReadOnlyView`) at the row's
/// width. Rows are built lazily (a chapter may have hundreds) and their layout is cached per note
/// version. Tapping one jumps to its page through the session, so section history records it.
struct NotesSectionPageNotes: View {
    let session: ReaderSession
    let controller: NotesPanelController
    let heading: OutlineNode
    /// Width available to a row's rendering.
    let rowWidth: CGFloat
    @State private var notes: [Note] = []

    private struct LoadKey: Equatable {
        var range: ClosedRange<Int>?
        var revision: Int
    }

    var body: some View {
        let range = NotesSectionSelection.pageNoteRange(of: heading)
        LazyVStack(alignment: .leading, spacing: 10) {
            NotesSectionHeader("Page notes in this section")
            if range == nil {
                Text("This heading starts on the same page as the next one, so its pages are listed under that heading.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if notes.isEmpty {
                Text("No page notes in this section yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(notes) { note in
                NotesSectionPageNoteRow(session: session, controller: controller, note: note, rowWidth: rowWidth)
            }
        }
        .task(id: LoadKey(range: range, revision: session.revisions.notes)) {
            guard let range else { notes = []; return }
            notes = (try? session.store.notes.pageNotes(bookID: session.book.id, in: range)) ?? []
        }
    }
}

/// One page note in "Page notes in this section".
struct NotesSectionPageNoteRow: View {
    let session: ReaderSession
    let controller: NotesPanelController
    let note: Note
    let rowWidth: CGFloat
    @State private var snapshot: NotePageSnapshot?

    /// Long notes are clipped in the list (the whole note is one tap away).
    static let maximumRenderedHeight: CGFloat = 300

    private var pageIndex: Int { note.target.pageIndex ?? 0 }
    private var displayNumber: Int { PageNumbering.displayNumber(forPageIndex: pageIndex) }

    var body: some View {
        let key = NotesPanelController.SnapshotKey(noteID: note.id, modifiedAt: note.modifiedAt,
                                                   inkRevision: controller.inkRevisions[note.id] ?? 0)
        let isCurrent = pageIndex == session.currentPageIndex
        Button { session.jump(toPage: pageIndex) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(verbatim: "p. \(displayNumber)")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .frame(minHeight: 24)
                        .foregroundStyle(isCurrent ? Color.white : Color.accentColor)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isCurrent ? Color.accentColor : Color.accentColor.opacity(0.14)))
                    if note.hasInk {
                        Label("Handwriting", systemImage: "scribble")
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                rendering
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .task(id: key) {
            if let cached = controller.cachedSnapshot(key) {
                snapshot = cached
                return
            }
            var inkData: Data?
            if note.hasInk {
                inkData = try? await session.store.noteInk(bookID: note.bookID, noteID: note.id)
            }
            guard !Task.isCancelled else { return }
            let made = NotePageRenderer.snapshot(note: note, inkData: inkData)
            controller.storeSnapshot(made, for: key)
            snapshot = made
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(note.hasInk ? "Page \(displayNumber) note with handwriting" : "Page \(displayNumber) note")
        .accessibilityValue(note.text)
        .accessibilityHint("Goes to page \(displayNumber)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(NotesPanelAccessibilityID.pageNote(displayNumber: displayNumber))
    }

    @ViewBuilder
    private var rendering: some View {
        let width = max(rowWidth, 1)
        if let snapshot {
            let height = width * snapshot.size.height / max(snapshot.size.width, 1)
            NotePageReadOnlyView(snapshot: snapshot)
                .frame(width: width, height: height)
                .frame(width: width, height: min(height, Self.maximumRenderedHeight), alignment: .top)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(uiColor: .separator)))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(uiColor: .separator)))
                .frame(width: width, height: 56)
        }
    }
}

// MARK: - Empty state

/// The Section note tab when no heading contains the page (front matter, a book without an
/// outline) or while the outline loads. The way forward: Contents (where "Add heading at page N"
/// lives, WP5) or the page note.
struct NotesSectionEmptyState: View {
    let session: ReaderSession
    let controller: NotesPanelController

    var body: some View {
        let number = PageNumbering.displayNumber(forPageIndex: session.currentPageIndex)
        VStack(spacing: 12) {
            if !session.isOutlineLoaded {
                ProgressView()
                Text("Loading contents…").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Image(systemName: "list.bullet.indent")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(session.outline.isEmpty ? "No Contents in This Book" : "Page \(number) Is Before the First Heading")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(session.outline.isEmpty
                     ? "Section notes belong to headings. Add a heading at page \(number) from Contents, and its note appears here."
                     : "Section notes belong to headings, and no heading contains this page. Add a heading at page \(number) from Contents, or write a page note.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { buttons }
                    VStack(spacing: 10) { buttons }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(NotesPanelAccessibilityID.sectionEmpty)
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            if !session.isContentsShown { withAnimation { session.toggleContents() } }
        } label: {
            Label("Show Contents", systemImage: "sidebar.leading")
        }
        .buttonStyle(.bordered)
        Button { controller.selectTab(.page) } label: {
            Label("Page Note", systemImage: "note.text")
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Shared

/// A small section header inside the panel ("Highlights on this page").
struct NotesSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Content that takes its own height up to `maximumHeight`, then scrolls (with a finger, in either
/// mode). Used for the lists below the note.
struct NotesBoundedScroll<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 1), maximumHeight))
    }
}
