import SwiftUI

/// Launch-argument contract shared by every UI test and screenshot script.
///
/// This is the single place that parses `ProcessInfo.arguments`. It is read once at startup
/// (`LaunchOptions.current`) and placed in the SwiftUI environment (`\.launchOptions`).
/// Unknown arguments are ignored. A flag that needs a value is ignored if the value is missing
/// or malformed.
///
/// Packages implement the behaviour behind each option; WP0 only defines and parses them.
nonisolated struct LaunchOptions: Equatable, Sendable {
    /// The screens `-screen` can name.
    enum Screen: String, Sendable {
        case library, reader, notebook
    }

    /// The notes inspector tabs `-notesPanel` can name.
    enum NotesTab: String, Sendable {
        case page, section
    }

    /// `-resetState`: wipe the app's store and files at launch (WP2/WP3 implement the wipe).
    var resetState = false

    /// `-importFixture <absolute path>`, repeatable: import the PDF at that host path at launch
    /// through the normal import pipeline. Order is preserved.
    var importFixtures: [URL] = []

    /// `-openBook <title>`: open the reader on the book with that title after launch.
    var openBook: String?

    /// `-openPage <n>`: 1-based page number to go to (values below 1 are ignored).
    var openPage: Int?

    /// `-screen <library|reader|notebook>`: which screen to land on, for screenshots.
    var screen: Screen?

    /// `-inkAnyInput`: PencilKit drawing policy "any input", so UI tests can draw with touches.
    var inkAnyInput = false

    /// `-markup`: start the reader in markup mode.
    var markup = false

    /// `-notesPanel <page|section>`: open the notes inspector on that tab.
    var notesPanel: NotesTab?

    init() {}

    init(arguments: [String]) {
        var index = 1  // arguments[0] is the executable path
        func value(after i: Int) -> String? {
            i + 1 < arguments.count ? arguments[i + 1] : nil
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-resetState":
                resetState = true
            case "-inkAnyInput":
                inkAnyInput = true
            case "-markup":
                markup = true
            case "-importFixture":
                if let path = value(after: index) {
                    importFixtures.append(URL(fileURLWithPath: path))
                    index += 1
                }
            case "-openBook":
                if let title = value(after: index) { openBook = title; index += 1 }
            case "-openPage":
                if let text = value(after: index) {
                    index += 1
                    if let page = Int(text), page >= 1 { openPage = page }
                }
            case "-screen":
                if let text = value(after: index) { screen = Screen(rawValue: text); index += 1 }
            case "-notesPanel":
                if let text = value(after: index) { notesPanel = NotesTab(rawValue: text); index += 1 }
            default:
                break
            }
            index += 1
        }
    }

    /// Parsed once from the process arguments.
    static let current = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
}

extension EnvironmentValues {
    @Entry var launchOptions = LaunchOptions()
}
