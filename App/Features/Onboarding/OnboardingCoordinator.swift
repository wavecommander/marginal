import Foundation
import Observation
import ReaderCore
import TipKit

/// App-wide onboarding (docs/DESIGN.md, "First-run onboarding"): which window shows the welcome
/// sheet, opening the Quick Guide, and resetting tips. One per process, owned by
/// `AppEnvironment`; the per-reader tip logic is `ReaderTips`.
@Observable
@MainActor
final class OnboardingCoordinator {
    @ObservationIgnored let state: OnboardingState

    /// The window whose Library shows the welcome sheet, or `nil`.
    private(set) var welcomeWindow: ObjectIdentifier?
    /// Goes up when tips are reset, so open readers pick their tips again.
    private(set) var tipResetCount = 0

    @ObservationIgnored private var hasConsideredWelcome = false
    @ObservationIgnored private var isOpeningGuide = false

    init(state: OnboardingState = OnboardingState()) {
        self.state = state
    }

    /// Call once at startup, before any view shows a tip.
    static func configureTips() {
        try? Tips.configure([.displayFrequency(.immediate)])
    }

    // MARK: Welcome sheet

    /// Called by a Library that is on screen once launch work has finished. Only the first call
    /// in a process decides anything: the sheet belongs to the first window, and it is marked
    /// as seen the moment it is shown, so it never appears twice.
    func considerWelcome(in window: ObjectIdentifier, libraryIsEmpty: Bool) {
        guard !hasConsideredWelcome else { return }
        hasConsideredWelcome = true
        if state.shouldShowWelcome(libraryIsEmpty: libraryIsEmpty) {
            welcomeWindow = window
        }
        if !state.isSuppressed { state.markWelcomeSeen() }
    }

    func dismissWelcome() {
        welcomeWindow = nil
    }

    /// A PDF arrived from outside ("Open in", a drop on the app icon): the reader has a book in
    /// hand, so there is no welcome sheet, now or later.
    func documentArrived() {
        hasConsideredWelcome = true
        welcomeWindow = nil
        if !state.isSuppressed { state.markWelcomeSeen() }
    }

    // MARK: Quick Guide

    /// Opens the Quick Guide in `window`, importing and seeding it first if it is not in the
    /// Library. A new copy opens at page 1; an existing one where the reader left it.
    func openQuickGuide(environment: AppEnvironment, window: WindowContext) async {
        guard !isOpeningGuide else { return }
        isOpeningGuide = true
        defer { isOpeningGuide = false }
        let service = await environment.readyImportService()
        do {
            let guide = try await QuickGuide.open(with: service, state: state)
            if guide.isNew {
                window.setReaderOverrides(ReaderOverrides(pageIndex: 0, notesTab: .page), for: guide.book.id)
            }
            window.openReader(bookID: guide.book.id)
        } catch let error as ImportError {
            window.backToLibrary()
            service.present([error], in: ObjectIdentifier(window))
        } catch {
            // Cancelled, or the guide is missing from the bundle (a packaging error the
            // onboarding tests catch): nothing to show.
        }
    }

    // MARK: Tips

    func showTipsAgain() {
        state.resetTips()
        tipResetCount += 1
    }
}
