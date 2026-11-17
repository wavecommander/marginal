import SwiftUI
import UIKit

// A throwaway prototype: the Reader's and the Notebook's bars only, so the push between them
// can be compared across ways of placing the Notebook's search. Not part of Tactile Texts.

@main
struct SearchTransitionDemoApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

enum Variant: Int, CaseIterable, Identifiable, Hashable {
    case current, minimize, ownCapsule, drawer, inContent, plainReaderSearch, zoom

    var id: Self { self }

    var title: String {
        switch self {
        case .current: "1. Current (toolbar search field)"
        case .minimize: "2. Minimized search button"
        case .ownCapsule: "3. Search in its own capsule"
        case .drawer: "4. Search drawer under the bar"
        case .inContent: "5. Search field in the content"
        case .plainReaderSearch: "6. Reader search without shared glass"
        case .zoom: "7. Zoom push from More"
        }
    }

    var detail: String {
        switch self {
        case .current:
            "What ships today: .searchable puts a field in the Notebook's trailing glass."
        case .minimize:
            ".searchToolbarBehavior(.minimize): the Notebook's search is a magnifying-glass button that expands when tapped."
        case .ownCapsule:
            "ToolbarSpacer(.fixed) splits search into its own capsule on both screens; the Notebook places it with DefaultToolbarItem(kind: .search), minimized."
        case .drawer:
            ".searchable(placement: .navigationBarDrawer(displayMode: .always)): a strip under the Notebook's bar."
        case .inContent:
            "No .searchable: a plain field at the top of the notes column, so it slides in with the content."
        case .plainReaderSearch:
            ".sharedBackgroundVisibility(.hidden) on the Reader's search button, so it is not part of the glass group."
        case .zoom:
            ".navigationTransition(.zoom) with the Reader's More button as the matchedTransitionSource."
        }
    }
}

enum Route: Hashable {
    case reader(Variant)
    case notebook(Variant)
}

struct RootView: View {
    @State private var path: [Route] = []
    @State private var slowMotion = false
    @Namespace private var zoomNamespace

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Toggle("Slow motion (¼ speed)", isOn: $slowMotion)
                } footer: {
                    Text("Slows every animation in the window, so the bar transitions can be watched closely.")
                }
                Section("Variants") {
                    ForEach(Variant.allCases) { variant in
                        NavigationLink(value: Route.reader(variant)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(variant.title).font(.headline)
                                Text(variant.detail).font(.callout).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .reader(let variant):
                    ReaderMock(variant: variant, zoomNamespace: zoomNamespace) {
                        path.append(.notebook(variant))
                    }
                case .notebook(let variant):
                    if variant == .zoom {
                        NotebookMock(variant: variant) { path.removeLast() }
                            .navigationTransition(.zoom(sourceID: ZoomSource.more, in: zoomNamespace))
                    } else {
                        NotebookMock(variant: variant) { path.removeLast() }
                    }
                }
            }
        }
        .onChange(of: slowMotion) { _, slow in
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows { window.layer.speed = slow ? 0.25 : 1 }
            }
        }
    }
}

enum ZoomSource: Hashable { case more }
