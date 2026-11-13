import ReaderCore
import SwiftUI

/// PLACEHOLDER owned by WP5 (Contents / Pages / Bookmarks). Keep the type name and
/// `init(session:)`; replace the body.
///
/// Shown as the left pane at wide widths and as an overlay at narrow widths (the shell owns
/// the container, its width and visibility). Read `session.outline`, `session.headingPath`,
/// `session.notebook` (badges), `session.currentPageIndex`; jump with `session.jump(to:)` /
/// `session.jump(toPage:)` (never move the PDF view directly: jumps record section history). At narrow widths the shell closes the overlay after a jump.
struct ContentsSidebar: View {
    let session: ReaderSession

    init(session: ReaderSession) {
        self.session = session
    }

    var body: some View {
        let current = Set(session.headingPath.map(\.anchor))
        List {
            Section {
                if !session.isOutlineLoaded {
                    ProgressView()
                } else if session.outline.isEmpty {
                    Text("No contents").foregroundStyle(.secondary)
                }
                ForEach(session.outline.nodes.prefix(400)) { node in
                    Button {
                        session.jump(to: node)
                    } label: {
                        HStack {
                            Text(node.title)
                                .fontWeight(node.level == 1 ? .semibold : .regular)
                                .padding(.leading, CGFloat(node.level - 1) * 14)
                            Spacer()
                            if let start = node.startPage {
                                Text("\(PageNumbering.displayNumber(forPageIndex: start))")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(current.contains(node.anchor) ? Color.accentColor : Color.primary)
                }
            } header: {
                Text("Contents (placeholder, WP5)")
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier(AccessibilityID.Placeholder.contents)
    }
}
