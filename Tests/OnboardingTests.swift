import Foundation
import PDFKit
import ReaderCore
import ReaderStore
import Testing
@testable import Marginal

/// First-run onboarding: stored state and launch arguments, the tip rules, the welcome-sheet
/// decision, and the bundled Quick Guide with its seeded content. App-hosted on the simulator.
@MainActor
struct OnboardingTests {
    /// A private defaults domain, removed when the test ends.
    private final class Scratch {
        let name = "onboarding-tests-\(UUID().uuidString)"
        let defaults: UserDefaults
        var state: OnboardingState { OnboardingState(defaults: defaults) }
        init() { defaults = UserDefaults(suiteName: name)! }
        deinit { defaults.removePersistentDomain(forName: name) }
    }

    // MARK: State and launch arguments

    @Test func welcomeShowsOnlyOnAFirstLaunchWithAnEmptyLibrary() {
        let scratch = Scratch()
        let state = scratch.state
        #expect(state.shouldShowWelcome(libraryIsEmpty: true))
        #expect(!state.shouldShowWelcome(libraryIsEmpty: false))
        state.markWelcomeSeen()
        #expect(!state.shouldShowWelcome(libraryIsEmpty: true))
    }

    @Test func launchArgumentsParse() {
        #expect(LaunchOptions(arguments: ["app", "-onboarding", "reset"]).onboarding == .reset)
        #expect(LaunchOptions(arguments: ["app", "-onboarding", "skip"]).onboarding == .skip)
        #expect(LaunchOptions(arguments: ["app", "-onboarding", "nonsense"]).onboarding == nil)
        #expect(LaunchOptions(arguments: ["app", "-resetState"]).onboarding == nil)
    }

    @Test func resetStateSuppressesOnboardingUnlessOnboardingIsReset() {
        let scratch = Scratch()
        let state = scratch.state
        state.markWelcomeSeen()
        state.markTipDone(.markup)
        state.guideBookID = UUID()

        state.applyLaunch(resetState: true, option: nil)
        #expect(state.isSuppressed)
        #expect(!state.shouldShowWelcome(libraryIsEmpty: true))
        #expect(state.guideBookID == nil)
        #expect(state.doneTips.isEmpty)

        // A relaunch with no arguments (as UI tests do) stays suppressed.
        state.applyLaunch(resetState: false, option: nil)
        #expect(state.isSuppressed)

        state.applyLaunch(resetState: true, option: .reset)
        #expect(!state.isSuppressed)
        #expect(state.shouldShowWelcome(libraryIsEmpty: true))

        state.applyLaunch(resetState: false, option: .skip)
        #expect(state.isSuppressed)
    }

    @Test func resettingTipsForgetsThemAndChangesTheirIdentity() {
        let scratch = Scratch()
        let state = scratch.state
        state.markTipDone(.markup)
        state.markTipDone(.sectionNote)
        state.countNotesPanelSession()
        let generation = state.tipGeneration
        state.resetTips()
        #expect(state.doneTips.isEmpty)
        #expect(state.notesPanelSessions == 0)
        #expect(state.tipGeneration == generation + 1)
    }

    // MARK: Tip rules

    private func context(guide: Bool = false, settled: Bool = true, notes: Bool = true, heading: Bool = true,
                         sessions: Int = 1, suppressed: Bool = false) -> ReaderTipContext {
        ReaderTipContext(isSuppressed: suppressed, isGuide: guide, isSettled: settled, isNotesVisible: notes,
                         hasHeadingPath: heading, notesPanelSessions: sessions)
    }

    @Test func markupTipComesFirstInARealBook() {
        #expect(ReaderTipRules.next(in: context(), done: [], chosen: nil) == .markup)
        #expect(ReaderTipRules.next(in: context(settled: false), done: [], chosen: nil) == nil)
        #expect(ReaderTipRules.next(in: context(guide: true), done: [], chosen: nil) == nil)
        #expect(ReaderTipRules.next(in: context(suppressed: true), done: [], chosen: nil) == nil)
    }

    @Test func sectionNoteTipWaitsForTheSecondNotesPanelSession() {
        #expect(ReaderTipRules.next(in: context(sessions: 1), done: [.markup], chosen: nil) == nil)
        #expect(ReaderTipRules.next(in: context(sessions: 2), done: [.markup], chosen: nil) == .sectionNote)
        #expect(ReaderTipRules.next(in: context(notes: false, sessions: 2), done: [.markup], chosen: nil) == nil)
        #expect(ReaderTipRules.next(in: context(heading: false, sessions: 2), done: [.markup], chosen: nil) == nil)
        #expect(ReaderTipRules.next(in: context(sessions: 2), done: [.markup, .sectionNote], chosen: nil) == nil)
    }

    @Test func aSessionShowsAtMostOneTip() {
        #expect(ReaderTipRules.next(in: context(sessions: 2), done: [.markup], chosen: .markup) == nil)
    }

    // MARK: Welcome decision

    @Test func onlyTheFirstWindowDecidesAndTheSheetIsMarkedSeenWhenShown() {
        let scratch = Scratch()
        let coordinator = OnboardingCoordinator(state: scratch.state)
        let first = ObjectIdentifier(NSObject()), second = ObjectIdentifier(NSObject())
        coordinator.considerWelcome(in: first, libraryIsEmpty: true)
        #expect(coordinator.welcomeWindow == first)
        #expect(scratch.state.hasSeenWelcome)
        coordinator.considerWelcome(in: second, libraryIsEmpty: true)
        #expect(coordinator.welcomeWindow == first)
        coordinator.dismissWelcome()
        #expect(coordinator.welcomeWindow == nil)
        // The next launch: seen, so no sheet.
        let relaunched = OnboardingCoordinator(state: scratch.state)
        relaunched.considerWelcome(in: first, libraryIsEmpty: true)
        #expect(relaunched.welcomeWindow == nil)
    }

    @Test func aLibraryWithBooksOrAnArrivingPDFMeansNoSheetEver() {
        let withBooks = Scratch()
        let existing = OnboardingCoordinator(state: withBooks.state)
        existing.considerWelcome(in: ObjectIdentifier(NSObject()), libraryIsEmpty: false)
        #expect(existing.welcomeWindow == nil)
        #expect(withBooks.state.hasSeenWelcome)

        let openIn = Scratch()
        let arriving = OnboardingCoordinator(state: openIn.state)
        arriving.documentArrived()
        arriving.considerWelcome(in: ObjectIdentifier(NSObject()), libraryIsEmpty: true)
        #expect(arriving.welcomeWindow == nil)
        #expect(openIn.state.hasSeenWelcome)
    }

    // MARK: Quick Guide

    @Test func theBundledGuideHasSixPagesAndTheOutlineTheSeedRelyOn() throws {
        let url = try #require(QuickGuide.bundledURL)
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == QuickGuide.pageCount)
        let entries = ReaderDocumentLoader.flatten(try #require(document.outlineRoot), in: document)
        #expect(entries.count == 9)
        #expect(entries.contains { $0.title == QuickGuide.sectionNoteHeading && $0.pageIndex == 2 })
        #expect(document.findString(QuickGuide.highlightedSentence, withOptions: []).count == 1)
    }

    @Test func openingTheGuideSeedsItOnceAndNeverOverwritesEdits() async throws {
        let scratch = Scratch()
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let service = ImportService(store: store)

        let first = try await QuickGuide.open(with: service, state: scratch.state)
        #expect(first.isNew)
        #expect(first.book.title == QuickGuide.title)
        #expect(first.book.pageCount == QuickGuide.pageCount)
        #expect(scratch.state.guideBookID == first.book.id)

        // Page note with ink.
        let pageNote = try #require(try store.notes.note(bookID: first.book.id, target: .page(0)))
        #expect(pageNote.text == QuickGuide.pageNoteText)
        let ink = try await store.noteInk(bookID: first.book.id, noteID: pageNote.id)
        #expect((ink?.count ?? 0) > 0)
        // Section note on "2 Writing", and nothing else.
        let notes = try store.notes.notes(bookID: first.book.id)
        #expect(notes.count == 2)
        #expect(notes.contains { note in
            if case .heading = note.target { note.text == QuickGuide.sectionNoteText } else { false }
        })
        // One highlight on page 2, with geometry.
        let highlights = try store.highlights.highlights(bookID: first.book.id)
        #expect(highlights.count == 1)
        #expect(highlights.first?.pageIndex == QuickGuide.highlightPageIndex)
        #expect(highlights.first?.text == QuickGuide.highlightedSentence)
        #expect(highlights.first?.rects.isEmpty == false)

        // The reader edits the note; opening the guide again finds the same book, untouched.
        var edited = pageNote
        edited.text = "Mine now."
        _ = try store.notes.save(edited)
        let again = try await QuickGuide.open(with: service, state: scratch.state)
        #expect(!again.isNew)
        #expect(again.book.id == first.book.id)
        #expect(try store.notes.note(bookID: first.book.id, target: .page(0))?.text == "Mine now.")
        #expect(try store.books.allBooks().count == 1)

        // Deleted, it comes back as new, seeded again.
        try await store.deleteBook(id: first.book.id, origin: nil)
        let restored = try await QuickGuide.open(with: service, state: scratch.state)
        #expect(restored.isNew)
        #expect(restored.book.id != first.book.id)
        #expect(try store.notes.note(bookID: restored.book.id, target: .page(0))?.text == QuickGuide.pageNoteText)
        #expect(scratch.state.guideBookID == restored.book.id)
    }
}
