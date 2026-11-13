import ReaderCore
import SwiftUI

/// PLACEHOLDER owned by WP8 (notes panel). Keep the type name and `init(session:)`; replace
/// the body.
///
/// The shell hosts this as the right-hand pane (wide) or in a sheet with medium/large detents
/// (narrow), owns the panel width (`session.notesPanelWidth`, drag handle) and visibility, and
/// provides no header: the Page note / Section note picker (`session.notesTab`) is yours.
struct NotesPanel: View {
    @Bindable var session: ReaderSession

    init(session: ReaderSession) {
        self.session = session
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Note", selection: $session.notesTab) {
                Text("Page note").tag(ReaderSession.NotesTab.page)
                Text("Section note").tag(ReaderSession.NotesTab.section)
            }
            .pickerStyle(.segmented)
            switch session.notesTab {
            case .page:
                Text("Page \(PageNumbering.displayNumber(forPageIndex: session.currentPageIndex))")
                    .font(.title3.bold())
            case .section:
                Text(session.deepestHeading?.title ?? "No section")
                    .font(.title3.bold())
            }
            Text("Notes panel placeholder (WP8)").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Placeholder.notes)
    }
}
