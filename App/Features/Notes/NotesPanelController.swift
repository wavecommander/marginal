import Foundation
import Observation
import ReaderCore

/// The notes panel's per-window state (WP8): which note the editor shows, the Section tab's
/// level choice, the reader's zoom, and the note models kept alive. One per reader window,
/// stored in the session (`ReaderSession.notesPanel`), so it survives the panel being closed, reopened, or
/// moved between the pane and the narrow sheet, and dies with the window.
///
/// ## Following the page (design: "Page note tab", "Section note tab")
/// - Page note tab: the note of `.page(session.currentPageIndex)`.
/// - Section note tab: the note of `.heading(h)` where `h` is `NotesSectionSelection.heading`
///   (the pinned level while it holds, else the deepest heading of the current page); no note
///   (an empty state) before the first heading, in a book with no outline, or while the outline
///   loads.
/// - The controller re-decides on every change of the current page, the tab, the outline, and
///   the shown note's editing state, whether or not the panel is on screen (Observation tracking,
///   not view callbacks), so a pin is dropped the moment the reader leaves its range.
///
/// ## Never losing work
/// - **Typing.** A change that only follows the page is deferred while the shown note's text view
///   is editing (`NotePageModel.isEditingText`): the keyboard itself scrolls the PDF. The switch
///   runs as soon as editing ends. Explicit changes (tab, level picker, a heading requested by
///   another feature) switch at once; the editor commits and flushes the old note first.
/// - **Strokes.** The editor (`NotePageEditorView`) keeps a new model pending until a stroke in
///   progress ends, so the stroke lands on the note it was drawn on; then it flushes the old one.
/// - **Models alive.** At most `modelCapacity` models are cached (typically the page note, the
///   section note, and one more), so going back to a tab is instant and keeps its undo stack. An
///   evicted model is flushed; a model an editor still shows is never evicted, so a target never
///   has two live models in one window.
/// - Jumps, tab switches, closing the panel (the editor's dismantle flushes), backgrounding (each
///   model flushes itself) and closing the window (`session.suspend()` flushes every registered
///   surface, the note editor included) all save.
@Observable
@MainActor
final class NotesPanelController {
    /// Models kept alive at once.
    static let modelCapacity = 3

    // MARK: State

    /// The note the editor shows; `nil` on the Section tab when there is no heading.
    private(set) var model: NotePageModel?
    /// What the Section tab shows while `model` is `nil`, as of the last decision.
    enum SectionPlaceholder: Equatable {
        /// The outline is loading, or has loaded and the controller has not caught up with it yet.
        case loading
        /// The outline has loaded and no heading contains the page (or the book has no outline).
        case noHeading
    }
    /// Set only when the controller decides, never ahead of it. The panel reads this rather than
    /// `session.isOutlineLoaded`: the outline lands one turn before the controller re-decides
    /// (`track()` refreshes in a `Task`), and an empty state read straight from the session
    /// flashed "before the first heading" and its accent-filled Add Heading button in that gap.
    private(set) var sectionPlaceholder = SectionPlaceholder.loading
    /// A page-following switch is waiting for the reader to stop typing.
    private(set) var isSwitchDeferred = false
    /// The Section tab's level choice.
    private(set) var selection = NotesSectionSelection()
    /// The base zoom the reader pinched to (`NotesPanelMetrics`), `nil` until they pinch: then
    /// the default follows Dynamic Type. Remembered for the window's lifetime; the panel drops it
    /// when Dynamic Type changes.
    var chosenBaseZoom: CGFloat?
    /// Heading notes re-attached after the outline loaded (diagnostics, tests).
    private(set) var repairedAnchorCount = 0
    /// Whether the anchor repair has run for this window's outline load.
    private(set) var didRepairAnchors = false

    // MARK: Private

    @ObservationIgnored private weak var session: ReaderSession?
    @ObservationIgnored private let makeModel: @MainActor (NoteTarget) -> NotePageModel
    @ObservationIgnored private var cache: [NoteTarget: NotePageModel] = [:]
    @ObservationIgnored private var recency: [NoteTarget] = []
    @ObservationIgnored private var lastTab: ReaderSession.NotesTab

    /// - Parameter makeModel: how a note model is made (tests shorten the autosave delay).
    init(session: ReaderSession, makeModel: (@MainActor (NoteTarget) -> NotePageModel)? = nil) {
        self.session = session
        self.lastTab = session.notesTab
        self.makeModel = makeModel ?? { [weak session] target in
            guard let session else { preconditionFailure("notes panel without a session") }
            return NotePageModel(session: session, target: target)
        }
        // A pending `showNotes(.section, heading:)` request is honoured on the next turn: this
        // initialiser runs inside `ReaderSession.init`, or, in a session made without features,
        // while SwiftUI builds the panel, where the session must not change.
        refresh(explicit: true, honoursRequests: false)
        track()
        Task { @MainActor [weak self] in self?.refresh() }
    }

    // MARK: Reader actions

    /// The tab picker: switch tabs at once (even while typing; the old note is flushed).
    func selectTab(_ tab: ReaderSession.NotesTab) {
        guard let session else { return }
        session.notesTab = tab
        lastTab = tab
        refresh(explicit: true)
    }

    /// The level picker: show this heading's note and keep it while the page stays in its range.
    func chooseLevel(_ heading: OutlineNode) {
        guard let session else { return }
        selection.choose(heading.anchor, atPage: session.currentPageIndex)
        refresh(explicit: true)
    }

    /// Any "open this heading's note": the Section tab on that heading.
    func openSectionNote(for heading: OutlineNode) {
        guard let session else { return }
        selection.choose(heading.anchor, atPage: session.currentPageIndex)
        session.showNotes(.section)
        lastTab = .section
        refresh(explicit: true)
    }

    /// Opens the Section tab on a heading named by anchor. Behaves exactly like choosing that
    /// level in the level picker. Returns `false`, changing nothing, when the outline has not
    /// loaded or no heading matches. Other features use `session.showNotes(.section, heading:)`,
    /// which this controller honours the same way (`takeHeadingRequest`).
    @discardableResult
    func openSectionNote(forHeading anchor: HeadingAnchor) -> Bool {
        guard let session, session.isOutlineLoaded,
              let node = session.outline.node(for: anchor) ?? session.outline.resolve(anchor)?.node else { return false }
        openSectionNote(for: node)
        return true
    }

    // MARK: Deleting (design: "Deleting a note")

    /// Deletes the note a model shows (the header's Delete Note). The model deletes it, so no
    /// pending or late autosave can re-create it and its editor shows the empty placeholder.
    /// Attributed to the session's origin, so other windows update. Returns `false` when the
    /// store failed.
    @discardableResult
    func delete(_ model: NotePageModel) async -> Bool {
        do {
            try await model.deleteNote()
            return true
        } catch {
            return false
        }
    }

    /// Whether a model's note is empty (no text, no ink): Delete Note is disabled then.
    static func isEmpty(_ model: NotePageModel) -> Bool {
        !model.hasInk && model.text.allSatisfy { $0.isWhitespace || $0.isNewline }
    }

    /// Back to following the page on the Section tab.
    func followPage() {
        selection.clear()
        refresh(explicit: true)
    }

    // MARK: Derived

    /// The heading whose note is shown (Section tab), in the current outline.
    var shownHeading: OutlineNode? {
        guard let anchor = model?.target.headingAnchor else { return nil }
        return session?.outline.node(for: anchor)
    }

    /// The page whose note is shown (Page tab).
    var shownPage: Int? { model?.target.pageIndex }

    /// The models alive now (tests).
    var liveTargets: Set<NoteTarget> { Set(cache.keys) }

    /// Saves every live model's pending text and ink and waits for it (before a sleeping reader
    /// lets its session go: a model's autosave does not outlive the model).
    func flushAll() async {
        for model in Array(cache.values) {
            await model.flush()
        }
    }

    // MARK: Deciding

    /// Re-decides which note to show. `explicit`: the reader asked for this change (see
    /// `NotesTargetSwitch`).
    func refresh(explicit: Bool = false, honoursRequests: Bool = true) {
        guard let session else { return }
        repairAnchorsIfNeeded(session)
        let page = session.currentPageIndex
        selection.pageDidChange(to: page, outline: session.outline)
        let honoured = honoursRequests && takeHeadingRequest(session)
        let desired = desiredTarget(session)
        if desired == nil {
            let placeholder: SectionPlaceholder = session.isOutlineLoaded ? .noHeading : .loading
            if sectionPlaceholder != placeholder { sectionPlaceholder = placeholder }
        }
        switch NotesTargetSwitch.decide(displayed: model?.target, desired: desired,
                                        isEditingText: model?.isEditingText ?? false, explicit: explicit || honoured) {
        case .keep:
            if isSwitchDeferred { isSwitchDeferred = false }
        case .deferUntilEditingEnds:
            if !isSwitchDeferred { isSwitchDeferred = true }
        case .switchNow:
            if isSwitchDeferred { isSwitchDeferred = false }
            show(desired)
        }
    }

    /// `session.showNotes(.section, heading:)` (search hits, Notebook rows, Contents): the
    /// requested heading is chosen exactly as if the reader had picked it in the level picker, so
    /// the existing stickiness rule applies (`NotesSectionSelection`), including for a heading
    /// outside the page's heading path or with no page range (its level picker is then its
    /// lineage). The request waits while the outline loads, and is cleared when read; a stale
    /// anchor resolves through `Outline.resolve`, and one that matches nothing is dropped.
    private func takeHeadingRequest(_ session: ReaderSession) -> Bool {
        guard session.requestedSectionHeading != nil, session.isOutlineLoaded,
              let anchor = session.takeRequestedSectionHeading(),
              let node = session.outline.node(for: anchor) ?? session.outline.resolve(anchor)?.node else { return false }
        selection.choose(node.anchor, atPage: session.currentPageIndex)
        if session.notesTab != .section { session.notesTab = .section }
        lastTab = .section
        return true
    }

    private func desiredTarget(_ session: ReaderSession) -> NoteTarget? {
        switch session.notesTab {
        case .page:
            return .page(session.currentPageIndex)
        case .section:
            guard session.isOutlineLoaded else { return nil }
            return selection.heading(forPage: session.currentPageIndex, outline: session.outline).map { .heading($0.anchor) }
        }
    }

    private func show(_ target: NoteTarget?) {
        guard let target else {
            model = nil
            return
        }
        recency.removeAll { $0 == target }
        recency.append(target)
        if let cached = cache[target] {
            model = cached
        } else {
            let made = makeModel(target)
            cache[target] = made
            model = made
        }
        evict()
    }

    private func evict() {
        var index = 0
        while cache.count > Self.modelCapacity, index < recency.count {
            let target = recency[index]
            guard let candidate = cache[target], candidate !== model, candidate.editor == nil else {
                index += 1
                continue
            }
            cache[target] = nil
            recency.remove(at: index)
            Task { await candidate.flush() }
        }
    }

    /// Observes what the decision depends on, panel shown or not.
    private func track() {
        withObservationTracking {
            guard let session else { return }
            _ = session.currentPageIndex
            _ = session.notesTab
            _ = session.isOutlineLoaded
            _ = session.outline
            _ = session.requestedSectionHeading
            _ = model?.isEditingText
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let session = self.session else { return }
                let tabChanged = session.notesTab != self.lastTab
                self.lastTab = session.notesTab
                self.refresh(explicit: tabChanged)
                self.track()
            }
        }
    }

    // MARK: Heading anchors

    /// Once per window, when its outline has loaded: re-attach heading notes whose anchor went
    /// stale (`NotesHeadingAnchorRepair`), before any heading note is opened. Only PDF anchors
    /// can be stale and the PDF outline is read once per window, so one pass is enough; user
    /// heading changes rebuild the outline without changing any PDF anchor.
    private func repairAnchorsIfNeeded(_ session: ReaderSession) {
        // A window whose book was deleted or replaced (a restore) writes nothing more.
        guard !didRepairAnchors, session.isOutlineLoaded, !session.saveToken.isRevoked else { return }
        didRepairAnchors = true
        repairedAnchorCount = NotesHeadingAnchorRepair.apply(store: session.store, bookID: session.book.id,
                                                            outline: session.outline, origin: session.origin)
    }
}
