import SwiftUI

@main
struct MarginalApp: App {
    private let launchOptions = LaunchOptions.current

    var body: some Scene {
        WindowGroup {
            LibraryScreen()
                .environment(\.launchOptions, launchOptions)
        }
    }
}
