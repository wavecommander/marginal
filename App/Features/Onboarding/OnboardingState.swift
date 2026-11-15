import Foundation

/// The reader tips (docs/DESIGN.md, "First-run onboarding").
nonisolated enum OnboardingTipKind: String, CaseIterable, Sendable {
    /// Points at the toolbar's Markup toggle.
    case markup
    /// Points at the notes panel's Page note / Section note tabs.
    case sectionNote
}

/// Device-local onboarding state, kept in `UserDefaults` (not in the book store: it describes
/// this install, not the library).
///
/// Launch arguments (`LaunchOptions.onboarding`, applied by `applyLaunch`):
/// - `-resetState` clears everything here and then **suppresses** onboarding, and the
///   suppression is stored, so a UI test's later relaunches (which pass no arguments) stay free
///   of the welcome sheet and tips too. Every existing UI test starts with `-resetState`.
/// - `-onboarding reset` clears everything, suppression included: the next launch behaves like
///   a first launch. With `-resetState` it gives a true fresh install.
/// - `-onboarding skip` suppresses onboarding without touching the library (screenshots).
nonisolated struct OnboardingState {
    enum Key {
        static let welcomeSeen = "onboarding.welcomeSeen"
        static let guideBookID = "onboarding.guideBookID"
        static let suppressed = "onboarding.suppressed"
        static let tipsDone = "onboarding.tips.done"
        static let tipGeneration = "onboarding.tips.generation"
        static let notesPanelSessions = "onboarding.notesPanelSessions"
        static let all = [welcomeSeen, guideBookID, suppressed, tipsDone, notesPanelSessions]
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

    /// Back to a first launch. The tip generation goes up instead of away, so tips the reader
    /// closed (which TipKit remembers by tip ID) can show again.
    func clear() {
        for key in Key.all { defaults.removeObject(forKey: key) }
        bumpTipGeneration()
    }

    // MARK: Welcome sheet

    /// Test-only: no welcome sheet and no tips.
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

    // MARK: Tips

    /// Tips that have been shown once or whose action the reader has performed. Neither kind
    /// is offered again.
    var doneTips: Set<OnboardingTipKind> {
        Set((defaults.stringArray(forKey: Key.tipsDone) ?? []).compactMap(OnboardingTipKind.init(rawValue:)))
    }

    func markTipDone(_ kind: OnboardingTipKind) {
        var done = doneTips
        guard done.insert(kind).inserted else { return }
        defaults.set(done.map(\.rawValue).sorted(), forKey: Key.tipsDone)
    }

    /// "Show Tips Again": every tip is offered once more.
    func resetTips() {
        defaults.removeObject(forKey: Key.tipsDone)
        defaults.removeObject(forKey: Key.notesPanelSessions)
        bumpTipGeneration()
    }

    /// Part of each tip's TipKit ID (see `clear`).
    var tipGeneration: Int { defaults.integer(forKey: Key.tipGeneration) }

    private func bumpTipGeneration() { defaults.set(tipGeneration + 1, forKey: Key.tipGeneration) }

    /// How many reader sessions have had the notes panel open on a page inside a heading.
    var notesPanelSessions: Int { defaults.integer(forKey: Key.notesPanelSessions) }

    func countNotesPanelSession() { defaults.set(notesPanelSessions + 1, forKey: Key.notesPanelSessions) }
}

/// What a reader looks like to the tip rules at one moment.
nonisolated struct ReaderTipContext: Equatable, Sendable {
    /// Onboarding is switched off (UI tests).
    var isSuppressed = false
    /// The open book is the Quick Guide, whose pages teach what the tips say.
    var isGuide = false
    /// The first page has been on screen for a moment.
    var isSettled = false
    var isNotesVisible = false
    /// The current page lies inside at least one heading.
    var hasHeadingPath = false
    /// `OnboardingState.notesPanelSessions`, this session included.
    var notesPanelSessions = 0
}

/// Which tip, if any, a reader session shows. Pure, so the rules are unit-tested without TipKit.
nonisolated enum ReaderTipRules {
    /// Offered in this order: Markup is the idea a new reader most needs.
    static let order: [OnboardingTipKind] = [.markup, .sectionNote]

    static func isEligible(_ kind: OnboardingTipKind, in context: ReaderTipContext) -> Bool {
        guard !context.isSuppressed, !context.isGuide, context.isSettled else { return false }
        switch kind {
        case .markup:
            return true
        case .sectionNote:
            // Not the first time the panel is seen: by the second the page note is familiar.
            return context.isNotesVisible && context.hasHeadingPath && context.notesPanelSessions >= 2
        }
    }

    /// The one tip of a session: the first eligible tip that is not done. `nil` once a session
    /// has had its tip (`chosen`), whatever became of it.
    static func next(in context: ReaderTipContext, done: Set<OnboardingTipKind>,
                     chosen: OnboardingTipKind?) -> OnboardingTipKind? {
        guard chosen == nil else { return nil }
        return order.first { !done.contains($0) && isEligible($0, in: context) }
    }
}
