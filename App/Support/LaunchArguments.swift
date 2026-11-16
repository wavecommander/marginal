import SwiftUI

/// Launch-argument contract shared by every UI test and screenshot script.
///
/// This is the only place that reads the process's arguments and environment. They are parsed
/// once at startup (`LaunchOptions.current`) and placed in the SwiftUI environment
/// (`\.launchOptions`); debug hooks that live outside SwiftUI read `LaunchOptions.current`.
/// Unknown arguments are ignored. A flag that needs a value is ignored if the value is missing
/// or malformed.
///
/// **Debug builds only.** Every option here exists for UI tests, screenshots and measurements,
/// which all run the Debug configuration (`scripts/test.sh`, `scripts/build.sh`,
/// `scripts/shot.sh`). A release build has no parser and no stored options: `current` is the
/// defaults, the options release code still reads are constants (see the `#else` list below),
/// and the rest do not exist, so no launch argument can wipe the library or switch a probe on.
///
/// What each option does (all are implemented; see `AppEnvironment.runLaunchTasks`
/// and `WindowRootView`): `-resetState` passes `reset: true` to `LibraryStore.live`;
/// `-importFixture` imports through `FixtureImporter`; `-openBook` opens that book in place in
/// the first Library window; `-openPage`, `-markup` and `-notesPanel` apply to that reader only;
/// `-screen` picks the first window's screen; `-inkAnyInput` is `ReaderSession.drawingPolicy`;
/// `-alsoOpenWindow` opens a second reader window; `-accent` sets the stored accent preset
/// (`-resetState` clears it first); `-stubConverters` and `-confirmConversions` are the import
/// flow's test switches (`FixtureImporter`); `-onboarding` is applied by
/// `OnboardingState.applyLaunch`; `-plantLibraryStore` is applied by `AppEnvironment.makeLive`.
nonisolated struct LaunchOptions: Equatable, Sendable {
    /// The screens `-screen` can name.
    enum Screen: String, Sendable {
        case library, reader, notebook
    }

    /// The notes inspector tabs `-notesPanel` can name.
    enum NotesTab: String, Sendable {
        case page, section
    }

    /// What `-onboarding` can ask for (see `OnboardingState`).
    enum Onboarding: String, Sendable {
        case skip, reset
    }

    #if DEBUG
    /// `-resetState`: wipe the app's store and files at launch (the store and the Library implement the wipe).
    /// Also switches first-run onboarding off, and keeps it off for later launches, unless
    /// `-onboarding reset` is passed too.
    var resetState = false

    /// `-plantLibraryStore <absolute path>`: test-only. Copies that store file in as the
    /// library's store before it opens (after `-resetState`'s wipe), for the newer-library and
    /// copy screens (`Tests/Fixtures/NewerVersionLibrary.store`).
    var plantLibraryStore: URL?

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

    /// `-alsoOpenWindow <title>`: after launch, open a second reader window (its own scene) on
    /// the book with that title, so UI tests can exercise two windows at once.
    var alsoOpenWindow: String?

    /// `-alsoOpenWindowPage <n>`: the 1-based page that `-alsoOpenWindow`'s window opens at.
    var alsoOpenWindowPage: Int?

    /// `-seedNotebook` (DEBUG, Notebook UI tests): seed the opened Notebook's book with the
    /// deterministic notes, highlights and headings described in `NotebookDebugSeed`.
    var seedNotebook = false

    /// `-seedNotebookLateNote` (DEBUG): also add a page note about four seconds after seeding.
    var seedNotebookLateNote = false

    /// `-seedNotebookPageInk` (DEBUG): with `-seedNotebook`, also put page ink on a few pages
    /// (see `NotebookDebugSeed.seedPageInk`).
    var seedNotebookPageInk = false

    /// `-notebookDebugWidth <points>` (DEBUG): the Notebook lays itself out at most this wide.
    var notebookDebugWidth: Double?

    /// `-selectionMenuProbe`: test-only. Adds a "Probe" action to the PDF text-selection edit
    /// menu through the same hook highlights use, so a UI test can prove the hook works on this OS.
    var selectionMenuProbe = false

    /// `-markupProbeSurface`: test-only. Registers a minimal `MarkupSurface` (a real
    /// `PKCanvasView` that becomes first responder) so UI tests can check the tool picker with a
    /// registered surface without page ink.
    var markupProbeSurface = false

    /// `-exposeViewportAnchor`: test-only. Publishes the reading anchor (page point at the top of
    /// the view, and the scale) as the accessibility value of a `reader.viewportAnchor` element.
    var exposeViewportAnchor = false

    /// `-exposeSelection`: test-only. Publishes the PDF's text selection as the accessibility
    /// label of a `reader.selectionProbe` element (value: its pages and the last Select All time).
    var exposeSelection = false

    /// `-exposeMarkupState`: test-only. Adds `ReaderStateProbe`'s elements to the reader: markup,
    /// tool picker, notes and undo state as an accessibility value (toolbar items do not carry
    /// values to XCUITest), and buttons that undo / redo through the markup responder.
    var exposeMarkupState = false

    /// `-hardwareKeyboard <yes|no>`: test-only. Readers act as if a hardware keyboard is (or is
    /// not) attached, whatever `GCKeyboard` reports: whether the tool picker stays up while a
    /// note is typed into in markup mode (`ReaderMarkupController.keepsPickerWhileTyping`).
    var hardwareKeyboard: Bool?

    /// `-accent <preset>`: start with that accent preset (`AccentChoice` raw value, e.g.
    /// `indigo`), written to the stored setting at launch. Unknown names are ignored.
    var accent: AccentChoice?

    /// `-backupFolder <absolute path>`: test-only. Registers a `FolderBackupDestination` rooted at
    /// that folder (created if missing) in the backup destination list, so UI tests can back up
    /// and restore without the system folder picker.
    var backupFolder: URL?
    /// `-scrollDirection <vertical|horizontal>`: readers open in that direction instead of the
    /// book's stored one (the stored choice is untouched). Unknown names are ignored.
    var scrollDirection: ReaderScrollDirection?

    #if DEBUG
    /// `-cloudBackupUITest <state>` (DEBUG, UI tests and screenshots): Tactile Texts Cloud built
    /// from fakes in that starting state (`CloudBackupUITestState`: `notSubscribed`, `active`,
    /// `readOnly`, `needsRecoveryKey`, …) instead of from the build's settings, so its screens
    /// work without a Worker or the App Store (`CloudBackupUITestMode`).
    var cloudBackupUITest: String?
    #endif

    /// `-exposeAccent`: test-only. Adds a `settings.accentProbe` element to every window whose
    /// value names the environment accent and the window's `UIWindow.tintColor` (`AccentProbe`).
    var exposeAccent = false

    /// `-onboarding <skip|reset>`: `skip` switches the welcome sheet off (and keeps
    /// them off); `reset` forgets all onboarding state, so this launch is a first launch.
    var onboarding: Onboarding?

    /// `-pagePillStaysVisible`: test-only. The reader's page pill never fades when the page stands
    /// still, so UI tests can tap it at any time (the fade has its own test without this flag).
    var pagePillStaysVisible = false

    /// `-confirmConversions`: test-only. An `-importFixture` file that needs converting is
    /// converted straight away (Medium text size), as if the reader had chosen Convert in the
    /// Convert to PDF sheet. Without it a fixture import shows the sheet like any other import.
    var confirmConversions = false

    /// `-stubConverters` (DEBUG): register `StubDocumentConverter` for every converted format, so
    /// UI tests can run the conversion flow without the real converters.
    var stubConverters = false

    /// `-stubConverterPageDelay <ms>` (DEBUG): with `-stubConverters`, pause this long after each
    /// stub page (so a test can see or cancel a conversion in progress).
    var stubConverterPageDelay: Int?

    /// `-readerSleepDelay <seconds>`: test-only. A reader two or more screens below the top of
    /// its window's navigation stack falls asleep after this long instead of
    /// `WindowContext.defaultReaderSleepDelay` (see `ReaderSlot`).
    var readerSleepDelay: Double?

    /// `-perfProbe`: add the reader's performance probe (`ReaderPerfProbe`, `PerfMarks`).
    var perfProbe = false

    /// `-perfAutoScroll` (with `-perfProbe`): the probe scrolls the PDF itself and measures frames.
    var perfAutoScroll = false

    /// `-sidebarDebugStats`: show the Pages grid's counters and frame figures (`SidebarDebugStats`).
    var sidebarDebugStats = false

    /// `-sidebarAutoScroll` (with `-sidebarDebugStats`): the Pages grid scrolls itself through
    /// the whole book and back.
    var sidebarAutoScroll = false

    /// `-seedSidebar`: seed the opened book with notes, highlights and bookmarks
    /// (`SidebarDebugSeed`).
    var seedSidebar = false

    /// `-seedSidebarHeadings`: seed the opened book with a reader's outline (`SidebarDebugSeed`).
    var seedSidebarHeadings = false

    /// `-searchPageDelayMs <ms>`: pause this long after each page of a text search, so a test can
    /// act while the search runs (`SearchModel`). Negative or malformed values are ignored.
    var searchPageDelayMs: Int?

    /// `-pageInkDebug`, or `PAGE_INK_DEBUG` set to anything in the environment: log the page ink
    /// overlay's work (`PageInkOverlayProvider.debugLog`).
    var pageInkDebug = false
    #else
    // Release: the options that code outside `#if DEBUG` reads, as constants at their defaults.
    // The optimiser drops the branches behind them. The other options do not exist here; the
    // compiler points at any release code that reads one.
    var resetState: Bool { false }
    var importFixtures: [URL] { [] }
    var openBook: String? { nil }
    var openPage: Int? { nil }
    var screen: Screen? { nil }
    var markup: Bool { false }
    var notesPanel: NotesTab? { nil }
    var alsoOpenWindow: String? { nil }
    var alsoOpenWindowPage: Int? { nil }
    var accent: AccentChoice? { nil }
    var backupFolder: URL? { nil }
    var onboarding: Onboarding? { nil }
    var pagePillStaysVisible: Bool { false }
    var confirmConversions: Bool { false }
    #endif

    init() {}

    #if DEBUG
    /// Parses a process's arguments (`arguments[0]` is the executable path) and environment.
    init(arguments: [String], environment: [String: String] = [:]) {
        pageInkDebug = environment["PAGE_INK_DEBUG"] != nil
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
            case "-plantLibraryStore":
                if let path = value(after: index) {
                    if path.hasPrefix("/") { plantLibraryStore = URL(fileURLWithPath: path) }
                    index += 1
                }
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
            case "-alsoOpenWindow":
                if let title = value(after: index) { alsoOpenWindow = title; index += 1 }
            case "-alsoOpenWindowPage":
                if let text = value(after: index) {
                    index += 1
                    if let page = Int(text), page >= 1 { alsoOpenWindowPage = page }
                }
            case "-seedNotebook":
                seedNotebook = true
            case "-seedNotebookLateNote":
                seedNotebookLateNote = true
            case "-seedNotebookPageInk":
                seedNotebookPageInk = true
            case "-notebookDebugWidth":
                if let text = value(after: index) {
                    index += 1
                    if let width = Double(text), width > 0 { notebookDebugWidth = width }
                }
            case "-selectionMenuProbe":
                selectionMenuProbe = true
            case "-markupProbeSurface":
                markupProbeSurface = true
            case "-exposeViewportAnchor":
                exposeViewportAnchor = true
            case "-exposeSelection":
                exposeSelection = true
            case "-exposeMarkupState":
                exposeMarkupState = true
            case "-hardwareKeyboard":
                if let text = value(after: index) {
                    index += 1
                    switch text {
                    case "yes": hardwareKeyboard = true
                    case "no": hardwareKeyboard = false
                    default: break
                    }
                }
            case "-exposeAccent":
                exposeAccent = true
            case "-backupFolder":
                if let path = value(after: index) {
                    index += 1
                    if path.hasPrefix("/") { backupFolder = URL(fileURLWithPath: path, isDirectory: true) }
                }
            case "-scrollDirection":
                if let text = value(after: index) { scrollDirection = ReaderScrollDirection(rawValue: text); index += 1 }
            case "-onboarding":
                if let text = value(after: index) { onboarding = Onboarding(rawValue: text); index += 1 }
            case "-pagePillStaysVisible":
                pagePillStaysVisible = true
            case "-confirmConversions":
                confirmConversions = true
            case "-stubConverters":
                stubConverters = true
            case "-stubConverterPageDelay":
                if let text = value(after: index) {
                    index += 1
                    if let ms = Int(text), ms >= 0 { stubConverterPageDelay = ms }
                }
            case "-readerSleepDelay":
                if let text = value(after: index) {
                    index += 1
                    if let seconds = Double(text), seconds >= 0 { readerSleepDelay = seconds }
                }
            #if DEBUG
            case "-cloudBackupUITest":
                if let state = value(after: index) { cloudBackupUITest = state; index += 1 }
            #endif
            case "-accent":
                if let text = value(after: index) { accent = AccentChoice(rawValue: text); index += 1 }
            case "-perfProbe":
                perfProbe = true
            case "-perfAutoScroll":
                perfAutoScroll = true
            case "-sidebarDebugStats":
                sidebarDebugStats = true
            case "-sidebarAutoScroll":
                sidebarAutoScroll = true
            case "-seedSidebar":
                seedSidebar = true
            case "-seedSidebarHeadings":
                seedSidebarHeadings = true
            case "-searchPageDelayMs":
                if let text = value(after: index) {
                    index += 1
                    if let ms = Int(text), ms >= 0 { searchPageDelayMs = ms }
                }
            case "-pageInkDebug":
                pageInkDebug = true
            default:
                break
            }
            index += 1
        }
    }

    /// Parsed once from the process's arguments and environment.
    static let current = LaunchOptions(arguments: ProcessInfo.processInfo.arguments,
                                       environment: ProcessInfo.processInfo.environment)
    #else
    /// A release build reads no launch arguments.
    static let current = LaunchOptions()
    #endif
}

extension EnvironmentValues {
    @Entry var launchOptions = LaunchOptions()
}
