import ReaderCore
import SwiftUI

// The parts of the notes panel around the editor: the level picker, the highlights under the
// note, and the Section tab's empty state (WP8).

// MARK: - Level picker

/// The level picker (Section note tab, at the bottom of the panel; design: "Notes panel layout").
/// Collapsed, it is one disclosure row naming the shown heading. Expanded, the heading path
/// follows it: one row per level, shallowest first, the shown heading checked and a mark on each
/// level that has a note. Choosing a row shows that heading's note and keeps it while the reader
/// scrolls within its range (`NotesSectionSelection`).
///
/// It starts collapsed, and the reader's choice is remembered across launches (`expandedKey`, one
/// setting for every window). The region it sits in scrolls, so one form works at every panel
/// height and text size.
struct NotesLevelPicker: View {
    /// The `UserDefaults` key of the expanded/collapsed choice (`-resetState` clears it).
    static let expandedKey = "notesPanel.levelPickerExpanded"

    let levels: [OutlineNode]
    /// The heading whose note is shown.
    let shown: OutlineNode
    let hasNote: (HeadingAnchor) -> Bool
    let choose: (OutlineNode) -> Void
    @AppStorage(Self.expandedKey) private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            disclosureRow
            if isExpanded {
                ForEach(Array(levels.enumerated()), id: \.element.id) { index, node in
                    row(node, depth: index)
                }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
    }

    private var disclosureRow: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.indent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(shown.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The row is one element with its own label; never a bare title element.
                    .accessibilityHidden(true)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heading level, \(shown.title)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? "Hides the heading levels" : "Shows the headings this page is in")
        .accessibilityIdentifier(NotesPanelAccessibilityID.levelToggle)
    }

    private func row(_ node: OutlineNode, depth: Int) -> some View {
        let isSelected = node.anchor == shown.anchor
        let noted = hasNote(node.anchor)
        return Button { choose(node) } label: {
            HStack(spacing: 8) {
                Text(node.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The row is one element with its own label; never a bare title element.
                    .accessibilityHidden(true)
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
}

// MARK: - Highlights on this page

/// "Highlights on this page": the page's highlights in reading order, coloured and quoted.
/// Tapping one jumps to it (a jump, so it goes through the session). The panel loads them and
/// shows this only while there are any.
struct NotesHighlightsSection: View {
    let session: ReaderSession
    let highlights: [Highlight]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            NotesSectionHeader("Highlights on this page")
            ForEach(highlights) { highlight in
                row(highlight)
            }
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
                    // The row is one element with its own label; never a bare title element.
                    .accessibilityHidden(true)
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

// MARK: - Empty state

/// The Section note tab when no heading contains the page (front matter, a book without an
/// outline) or while the outline loads. The way forward: "Add Heading at This Page…" (the
/// session's add-heading request; the Contents sidebar presents the sheet) or the page note. The
/// tab picks a new heading up as soon as the outline is rebuilt.
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
                     ? "Section notes belong to headings, and this book has none yet. Add a heading of your own at page \(number), and its note appears here."
                     : "Section notes belong to headings, and no heading contains this page. Add a heading of your own at page \(number), or write a page note.")
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
        NotesAddHeadingButton(session: session)
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Color(.onAccent))
        Button { controller.selectTab(.page) } label: {
            Label("Page Note", systemImage: "note.text")
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Shared

/// "Add Heading at This Page…" (design: "The reader's own headings"), offered where the current
/// page is in no section. Asks the session; the Contents sidebar presents the add-heading sheet.
struct NotesAddHeadingButton: View {
    let session: ReaderSession

    var body: some View {
        Button { session.requestAddHeading() } label: {
            Label("Add Heading at This Page\u{2026}", systemImage: "text.badge.plus")
        }
        .accessibilityIdentifier(NotesPanelAccessibilityID.addHeading)
    }
}

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
/// mode). Used for the region below the note.
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
