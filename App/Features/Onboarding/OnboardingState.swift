import Foundation

/// Device-local onboarding state, kept in `UserDefaults` (not in the book store: it describes
/// this install, not the library).
///
/// Launch arguments (`LaunchOptions.onboarding`, applied by `applyLaunch`):
/// - `-resetState` clears everything here and then **suppresses** onboarding, and the
///   suppression is stored, so a UI test's later relaunches (which pass no arguments) stay free
///   of the welcome sheet too. Every existing UI test starts with `-resetState`.
/// - `-onboarding reset` clears everything, suppression included: the next launch behaves like
///   a first launch. With `-resetState` it gives a true fresh install.
/// - `-onboarding skip` suppresses onboarding without touching the library (screenshots).
nonisolated struct OnboardingState {
    enum Key {
        static let welcomeSeen = "onboarding.welcomeSeen"
        static let guideBookID = "onboarding.guideBookID"
        static let suppressed = "onboarding.suppressed"
        static let all = [welcomeSeen, guideBookID, suppressed]
    }

    var defaults: UserDefaults = .standard

    // MARK: Launch

    func applyLaunch(resetState: Bool, option: LaunchOptions.Onboarding?) {
        if resetState {
            clear()
            defaults.set(true, forKey: Key.suppressed)
        }
        switch option {
        case .reset: clear()
        case .skip: defaults.set(true, forKey: Key.suppressed)
        case nil: break
        }
    }

    /// Back to a first launch.
    func clear() {
        for key in Key.all { defaults.removeObject(forKey: key) }
    }

    // MARK: Welcome sheet

    /// Test-only: no welcome sheet.
    var isSuppressed: Bool { defaults.bool(forKey: Key.suppressed) }

    var hasSeenWelcome: Bool { defaults.bool(forKey: Key.welcomeSeen) }

    func markWelcomeSeen() { defaults.set(true, forKey: Key.welcomeSeen) }

    /// Whether the first window to land on the Library shows the welcome sheet. A library that
    /// already has books is not a first launch (an install from before onboarding existed, or a
    /// PDF that arrived through "Open in"): the caller marks the sheet as seen instead.
    func shouldShowWelcome(libraryIsEmpty: Bool) -> Bool {
        !isSuppressed && !hasSeenWelcome && libraryIsEmpty
    }

    // MARK: Quick Guide

    /// The Library book that is the Quick Guide, once it has been opened. It may since have
    /// been deleted; nothing here checks.
    var guideBookID: UUID? {
        get { defaults.string(forKey: Key.guideBookID).flatMap(UUID.init(uuidString:)) }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: Key.guideBookID) }
    }
}
