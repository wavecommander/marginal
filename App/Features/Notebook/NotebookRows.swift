import ReaderCore
import SwiftUI

/// Accessibility identifiers of the Notebook (mirrored in `UITests/NotebookUITests.swift`).
nonisolated enum NotebookAccessibilityID {
    static let screen = "notebook.screen"
    static let feed = "notebook.feed"
    static let scopeColumn = "notebook.scopes"
    static let scopeMenu = "notebook.scopeMenu"
    static let typeFilter = "notebook.typeFilter"
    static let exportMenu = "notebook.export"
    static let exportMarkdown = "notebook.export.markdown"
    static let exportPDF = "notebook.export.pdf"
    static let exportProgress = "notebook.export.progress"
    static let exportCancel = "notebook.export.cancel"
    static let openBook = "notebook.openBook"
    static let empty = "notebook.empty"
    /// "Delete Note" in a note row's context menu.
    static let deleteNote = "notebook.deleteNote"

    /// A scope entry in the filter column: `notebook.scope.<title>`.
    static func scope(_ title: String) -> String { "notebook.scope.\(title)" }
    /// A header row: `notebook.header.<title>`.
    static func header(_ title: String) -> String { "notebook.header.\(title)" }
    /// A heading's note: `notebook.headingNote.<heading title>`.
    static func headingNote(_ title: String) -> String { "notebook.headingNote.\(title)" }
    /// A page note: `notebook.pageNote.<1-based page>`.
    static func pageNote(_ displayPage: Int) -> String { "notebook.pageNote.\(displayPage)" }
    /// A highlight: `notebook.highlight.<1-based page>.<index on page>`.
    static func highlight(_ displayPage: Int, _ index: Int) -> String { "notebook.highlight.\(displayPage).\(index)" }
}

/// Colours of highlights in the Notebook: forwards to the app's highlight palette
/// (`HighlightPalette`, WP7), so the Notebook, the reader and the notes panel share one set.
nonisolated enum NotebookHighlightStyle {
    static func color(_ color: HighlightColor) -> Color { HighlightPalette.swatchColor(color) }

    static func border(_ color: HighlightColor) -> Color { HighlightPalette.swatchBorderColor(color) }

    static func name(_ color: HighlightColor) -> String { HighlightPalette.name(color) }
}

/// What a row does when tapped or chosen from its context menu. `heading` is set for a heading
/// note's row: the reader then opens with the notes panel on the Section tab at that heading.
struct NotebookRowActions {
    var open: (_ page: Int, _ heading: HeadingAnchor?) -> Void
    var openInNewWindow: (_ page: Int, _ heading: HeadingAnchor?) -> Void
    /// Asks to delete a note (the screen confirms first, with the notes panel's wording).
    var deleteNote: (Note) -> Void
}

/// One row of the feed: a header, a heading note, a page note or a highlight. Tapping opens the
/// reader at the row's page (a header: its heading's start page; a heading note: its heading's
/// start page with that heading's note in the notes panel); the context menu also offers
/// "Open in New Window", and on a note's row "Delete Note" (also a VoiceOver action).
struct NotebookRowView: View {
    @Environment(\.accentTheme) private var accentTheme
    let row: NotebookFeedRow
    let model: NotebookModel
    let actions: NotebookRowActions

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var labelWidth: CGFloat = 62

    var body: some View {
        let target = row.targetPage
        let heading = row.noteHeading
        Button {
            if let target { actions.open(target, heading) }
        } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotebookRowButtonStyle())
        .hoverEffect(.highlight)
        .disabled(target == nil)
        .contextMenu {
            if let target {
                Button("Open", systemImage: "book") { actions.open(target, heading) }
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { actions.openInNewWindow(target, heading) }
            }
            if let note = row.note {
                Divider()
                Button(role: .destructive) { actions.deleteNote(note) } label: {
                    Label("Delete Note", systemImage: "trash")
                }
                .accessibilityIdentifier(NotebookAccessibilityID.deleteNote)
            }
        }
        // Modifiers on the button itself (no wrapping element): one element per row, read as
        // section, page and note text, with handwriting announced.
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(target == nil ? "" : (heading == nil ? "Opens the book at this page" : "Opens the book at this section's note"))
        .accessibilityAddTraits(row.isHeader ? .isHeader : [])
        .accessibilityIdentifier(identifier)
        .modifier(DeleteNoteAccessibilityAction(note: row.note, delete: actions.deleteNote))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .header(let header):
            NotebookHeaderView(header: header)
        case .headingNote(let note, let heading):
            labelled { textLabel(NotebookFeed.headingNoteLabel(level: heading.level)) } body: { noteBody(note) }
        case .unfiledHeadingNote(let note, let title):
            labelled { textLabel("Section") } body: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    noteBody(note)
                }
            }
        case .pageNote(let note, let page):
            labelled { pagePill(page) } body: { noteBody(note) }
        case .highlight(let highlight, _):
            labelled { pagePill(highlight.pageIndex) } body: { highlightBody(highlight) }
        case .handwriting(let page):
            labelled { pagePill(page) } body: { NotebookHandwritingPreview(pageIndex: page, model: model) }
        }
    }

    /// The mockup's two columns (label, content); stacked at accessibility text sizes.
    @ViewBuilder
    private func labelled<Label: View, Body: View>(@ViewBuilder _ label: () -> Label,
                                                    @ViewBuilder body: () -> Body) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                label()
                body()
            }
            .padding(.vertical, 6)
        } else {
            HStack(alignment: .top, spacing: 14) {
                label().frame(width: labelWidth, alignment: .leading)
                body()
            }
            .padding(.vertical, 6)
        }
    }

    private func textLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func pagePill(_ pageIndex: Int) -> some View {
        Text(PageNumbering.label(forPageIndex: pageIndex))
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(accentTheme.accent)
            .background(accentTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func noteBody(_ note: Note) -> some View {
        if note.hasInk {
            NotebookInkedNoteView(note: note, model: model)
        } else {
            Text(note.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        }
    }

    private func highlightBody(_ highlight: Highlight) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(NotebookHighlightStyle.color(highlight.color))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(NotebookHighlightStyle.border(highlight.color), lineWidth: 1))
                .frame(width: 14, height: 14)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(OutlineText.normalizedTitle(highlight.text))
                .font(.system(.body, design: .serif))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Accessibility

    private var identifier: String {
        switch row.kind {
        case .header(let header): NotebookAccessibilityID.header(header.title)
        case .headingNote(_, let heading): NotebookAccessibilityID.headingNote(heading.title)
        case .unfiledHeadingNote(_, let title): NotebookAccessibilityID.headingNote(title)
        case .pageNote(_, let page): NotebookAccessibilityID.pageNote(PageNumbering.displayNumber(forPageIndex: page))
        case .highlight(let highlight, let index):
            NotebookAccessibilityID.highlight(PageNumbering.displayNumber(forPageIndex: highlight.pageIndex), index)
        case .handwriting(let page): NotebookAccessibilityID.handwriting(PageNumbering.displayNumber(forPageIndex: page))
        }
    }

    /// Section, page and note text, and whether the note has handwriting.
    private var accessibilityLabel: String {
        switch row.kind {
        case .header(let header):
            var label = header.title
            if let range = header.pageRange {
                let first = PageNumbering.displayNumber(forPageIndex: range.lowerBound)
                let last = PageNumbering.displayNumber(forPageIndex: range.upperBound)
                label += first == last ? ", page \(first)" : ", pages \(first) to \(last)"
            }
            return label
        case .headingNote(let note, let heading):
            return "\(NotebookFeed.headingNoteLabel(level: heading.level)) note, \(heading.title). " + Self.noteSpeech(note)
        case .unfiledHeadingNote(let note, let title):
            return "Unfiled section note, \(title). " + Self.noteSpeech(note)
        case .pageNote(let note, let page):
            return "Page \(PageNumbering.displayNumber(forPageIndex: page)) note. " + Self.noteSpeech(note)
        case .highlight(let highlight, _):
            return "\(NotebookHighlightStyle.name(highlight.color)) highlight, page "
                + "\(PageNumbering.displayNumber(forPageIndex: highlight.pageIndex)). "
                + OutlineText.normalizedTitle(highlight.text)
        case .handwriting(let page):
            return NotebookHandwriting.accessibilityLabel(pageIndex: page)
        }
    }

    static func noteSpeech(_ note: Note) -> String {
        let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (text.isEmpty, note.hasInk) {
        case (true, true): return "Handwritten note."
        case (false, true): return text + (text.last.map { ".!?".contains($0) } == true ? "" : ".") + " Has handwriting."
        default: return text
        }
    }
}

/// "Delete Note" as a VoiceOver action, on note rows only.
private struct DeleteNoteAccessibilityAction: ViewModifier {
    let note: Note?
    let delete: (Note) -> Void

    func body(content: Content) -> some View {
        if let note {
            content.accessibilityAction(named: "Delete Note") { delete(note) }
        } else {
            content
        }
    }
}

extension NotebookFeedRow {
    /// The heading whose note this row shows (a heading note under a live heading), else `nil`.
    var noteHeading: HeadingAnchor? {
        if case .headingNote(_, let header) = kind, case .section(let anchor) = header.kind { return anchor }
        return nil
    }
}

/// A heading in the feed: the chapter style (large, heavy rule) at level 1, smaller below.
struct NotebookHeaderView: View {
    let header: NotebookHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(header.title)
                    .font(header.level <= 1 ? .title2.bold() : (header.level == 2 ? .headline : .subheadline.weight(.semibold)))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                if !header.pageRangeLabel.isEmpty {
                    Text(header.pageRangeLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .layoutPriority(1)
                }
            }
            Rectangle()
                .fill(header.level <= 1 ? Color.primary : Color(uiColor: .separator))
                .frame(height: header.level <= 1 ? 1 : 0.75)
        }
        .padding(.top, header.level <= 1 ? 18 : 10)
        .padding(.bottom, 2)
    }
}

/// A note with ink, drawn with `NotePageReadOnlyView` (ink over the text, exactly as written) at
/// the note page's own scale, adjusted by Dynamic Type like the editor's default zoom. The ink is
/// loaded only while the row is on screen (`.task` is cancelled when it scrolls away); a text
/// placeholder holds the row until then.
struct NotebookInkedNoteView: View {
    let note: Note
    let model: NotebookModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var snapshot: NotePageSnapshot?
    @State private var loadedKey: String?

    private var key: String {
        "\(note.id)-\(note.modifiedAt.timeIntervalSinceReferenceDate)-\(model.inkVersions[note.id] ?? 0)-\(note.text.hashValue)"
    }

    var body: some View {
        let zoom = NotePageStyle.defaultZoom(for: UIContentSizeCategory(dynamicTypeSize))
        let width = NotePageStyle.pageWidth * zoom
        Group {
            if let snapshot {
                NotePageReadOnlyView(snapshot: snapshot)
                    .frame(maxWidth: width, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(uiColor: .separator), lineWidth: 0.75))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(note.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ProgressView().controlSize(.small)
                }
                .frame(maxWidth: width, minHeight: 60, alignment: .topLeading)
            }
        }
        .task(id: key) {
            let currentKey = key
            guard loadedKey != currentKey else { return }
            if let loaded = await model.snapshot(for: note), !Task.isCancelled {
                snapshot = loaded
                loadedKey = currentKey
            }
        }
    }
}

/// Plain rows with a pressed highlight (the mockup's rows have no chrome).
struct NotebookRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
                    .padding(.horizontal, -6)
            )
    }
}
