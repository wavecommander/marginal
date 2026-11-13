import SwiftUI

/// PLACEHOLDER owned by WP10 (search). Keep the type name and `init(session:)`; replace the body.
///
/// The shell presents it in a popover from the toolbar's search button (a sheet at narrow
/// widths) while `session.isSearchVisible`. Keep search state that must survive closing the
/// popover in `session.featureState { … }`. Search on your own background `PDFDocument`
/// (`session.documentURL`), then show a hit with `session.pdf.reveal(pageIndex:rects:mark:)`.
struct SearchPanel: View {
    let session: ReaderSession

    init(session: ReaderSession) {
        self.session = session
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Search (placeholder, WP10)").font(.headline)
            Button("Close") { session.isSearchVisible = false }
        }
        .padding()
        .frame(minWidth: 320, minHeight: 200)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Placeholder.search)
    }
}
