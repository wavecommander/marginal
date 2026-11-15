import Foundation
import Observation
import ReaderCore
import ReaderStore
import SwiftUI

/// The composition root: created once per process by `MarginalApp` and shared by every window
/// through the SwiftUI environment (`@Environment(AppEnvironment.self)`). Holds only app-wide
/// things: the one `LibraryStore`, the launch options, and launch-time work. Nothing per window
/// lives here (that is `WindowContext` and `ReaderSession`).
@Observable
@MainActor
final class AppEnvironment {
    /// The shared store (one `ModelContainer` for the app).
    let store: LibraryStore
    /// Parsed launch arguments.
    let launchOptions: LaunchOptions
    /// Set when the persistent store failed to open and an in-memory store is used instead.
    let storeErrorMessage: String?
    /// The fixture importer (`-importFixture`); WP3 owns the real import pipeline.
    @ObservationIgnored let fixtureImporter: FixtureImporter
    /// First-run onboarding: the welcome sheet, the Quick Guide and tip resets.
    let onboarding: OnboardingCoordinator

    @ObservationIgnored private var launchTask: Task<LaunchPlan, Never>?
    @ObservationIgnored private var launchPlanClaimed = false

    /// What the first window does after launch (from the launch arguments).
    struct LaunchPlan: Sendable {
        /// The first window's navigation path (empty: the Library).
        var path: [WindowRoute] = []
        /// Overrides for the reader opened by `-openBook` (page, markup, notes tab).
        var readerOverrides: ReaderOverrides?
        /// `-alsoOpenWindow`: open a second reader window on this book.
        var alsoOpenBookID: UUID?
        /// `-alsoOpenWindowPage`: the zero-based page that window opens at.
        var alsoOpenPageIndex: Int?
        /// Import failures, for diagnostics.
        var errors: [String] = []
    }

    init(store: LibraryStore, launchOptions: LaunchOptions, storeErrorMessage: String? = nil) {
        self.store = store
        self.launchOptions = launchOptions
        self.storeErrorMessage = storeErrorMessage
        self.fixtureImporter = FixtureImporter(store: store)
        self.onboarding = OnboardingCoordinator()
    }

    /// The live environment: `LibraryStore.live(reset: -resetState)`, falling back to an
    /// in-memory store (with `storeErrorMessage` set) if the persistent store cannot open.
    static func makeLive(launchOptions: LaunchOptions = .current) -> AppEnvironment {
        PerfMarks.mark("storeOpening")
        defer { PerfMarks.mark("storeOpen") }
        if launchOptions.resetState {
            // The notes panel's level picker starts collapsed in a fresh state, as on a first launch.
            UserDefaults.standard.removeObject(forKey: NotesLevelPicker.expandedKey)
            UserDefaults.standard.removeObject(forKey: AccentChoice.storageKey)
            ReaderScrollDirectionStore().removeAll()
        }
        OnboardingState().applyLaunch(resetState: launchOptions.resetState, option: launchOptions.onboarding)
        if let accent = launchOptions.accent {
            UserDefaults.standard.set(accent.rawValue, forKey: AccentChoice.storageKey)
        }
        do {
            let store = try LibraryStore.live(reset: launchOptions.resetState)
            return AppEnvironment(store: store, launchOptions: launchOptions)
        } catch {
            return AppEnvironment(store: .inMemory(), launchOptions: launchOptions,
                                  storeErrorMessage: String(describing: error))
        }
    }

    // MARK: Launch

    /// Launch work, run once per process and shared by every caller: sweep orphaned book
    /// directories (before any import), import `-importFixture` files in order, then resolve
    /// `-openBook`, `-screen` and `-alsoOpenWindow` into a plan.
    func launchPlan() async -> LaunchPlan {
        if let launchTask { return await launchTask.value }
        let task = Task { await self.runLaunchTasks() }
        launchTask = task
        return await task.value
    }

    /// `true` for the first caller only: the first window applies the launch plan.
    func claimLaunchPlan() -> Bool {
        defer { launchPlanClaimed = true }
        return !launchPlanClaimed
    }

    /// The book whose title matches (case-insensitively), most recently added first.
    func book(titled title: String) -> Book? {
        let books = (try? store.books.allBooks()) ?? []
        return books
            .filter { $0.title.compare(title, options: [.caseInsensitive]) == .orderedSame }
            .max { $0.addedAt < $1.addedAt }
    }

    private func runLaunchTasks() async -> LaunchPlan {
        PerfMarks.mark("launchTasks")
        defer { PerfMarks.mark("launchPlan") }
        var plan = LaunchPlan()
        _ = try? await store.sweepOrphanedBookDirectories()
        PerfMarks.mark("sweepDone")
        var imported: [Book] = []
        for url in launchOptions.importFixtures {
            do {
                imported.append(try await fixtureImporter.importPDF(at: url))
            } catch {
                plan.errors.append("\(url.lastPathComponent): \(error)")
            }
        }

        var target: Book?
        if let title = launchOptions.openBook {
            target = book(titled: title)
        } else if launchOptions.screen == .reader || launchOptions.screen == .notebook {
            target = imported.first ?? ((try? store.books.allBooks()) ?? []).max {
                ($0.lastOpenedAt ?? $0.addedAt) < ($1.lastOpenedAt ?? $1.addedAt)
            }
        }
        if let target {
            switch launchOptions.screen ?? .reader {
            case .library:
                break
            case .reader:
                plan.path = [.reader(bookID: target.id)]
                plan.readerOverrides = ReaderOverrides(
                    pageIndex: launchOptions.openPage.map(PageNumbering.pageIndex(forDisplayNumber:)),
                    startInMarkup: launchOptions.markup,
                    notesTab: launchOptions.notesPanel.flatMap { ReaderSession.NotesTab(rawValue: $0.rawValue) })
            case .notebook:
                plan.path = [.notebook(bookID: target.id)]
            }
        }
        if let title = launchOptions.alsoOpenWindow {
            plan.alsoOpenBookID = book(titled: title)?.id
            plan.alsoOpenPageIndex = launchOptions.alsoOpenWindowPage.map(PageNumbering.pageIndex(forDisplayNumber:))
        }
        return plan
    }

    // MARK: Incoming documents (WP3 hook)

    /// "A PDF URL arrived from outside" (Files "Open in", a document opened from another app).
    /// Every window root forwards `.onOpenURL` here. WP3 implements the behaviour in
    /// `IncomingPDFHandler` (in its own folder); this method does not change.
    func handleIncomingPDF(_ url: URL, in window: WindowContext) {
        onboarding.documentArrived()
        IncomingPDFHandler.handle(url, environment: self, window: window)
    }
}

/// One-shot overrides for a reader opened by a launch argument or by a link to a page.
nonisolated struct ReaderOverrides: Sendable, Equatable {
    var pageIndex: Int?
    var startInMarkup = false
    var notesTab: ReaderSession.NotesTab?
    /// A heading whose note the notes panel shows on the Section tab (a Notebook heading-note
    /// row); applied with `ReaderSession.showNotes(.section, heading:)`.
    var notesHeading: HeadingAnchor?
}
