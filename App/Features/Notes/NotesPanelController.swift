import Foundation
import Observation
import ReaderCore

/// The notes panel's per-window state (WP8): which note the editor shows, the Section tab's
/// level choice, the reader's zoom, and the note models kept alive. One per reader window,
/// stored in the session (`featureState`), so it survives the panel being closed, reopened, or
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
///   runs as soon as editing ends. Explicit changes (tab, level picker, "This page is in") switch
///   at once; the editor commits and flushes the old note first.
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

    /// The controller of a session's window (created on first use).
    static func forSession(_ session: ReaderSession) -> NotesPanelController {
        session.featureState { NotesPanelController(session: session) }
    }

    // MARK: State

    /// The note the editor shows; `nil` on the Section tab when there is no heading.
    private(set) var model: NotePageModel?
    /// A page-following switch is waiting for the reader to stop typing.
    private(set) var isSwitchDeferred = false
    /// The Section tab's level choice.
    private(set) var selection = NotesSectionSelection()
    /// The reader's chosen base zoom (`NotesPanelMetrics`), `nil` until they choose one: then the
    /// default follows Dynamic Type. Remembered for the window's lifetime.
    var chosenBaseZoom: CGFloat?
    /// Bumped per note whenever its ink file changes (any window), for read-only renderings.
    private(set) var inkRevisions: [UUID: Int] = [:]
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
    @ObservationIgnored private var changeToken: StoreChangeObservation?
    @ObservationIgnored private var snapshots: [SnapshotKey: NotePageSnapshot] = [:]

    /// - Parameter makeModel: how a note model is made (tests shorten the autosave delay).
    init(session: ReaderSession, makeModel: (@MainActor (NoteTarget) -> NotePageModel)? = nil) {
        self.session = session
        self.lastTab = session.notesTab
        self.makeModel = makeModel ?? { [weak session] target in
            guard let session else { preconditionFailure("notes panel without a session") }
            return NotePageModel(session: session, target: target)
        }
        changeToken = session.observeBookChanges(includeOwn: true) { [weak self] event in
            if case .noteInkChanged(_, let noteID) = event.change {
                self?.inkRevisions[noteID, default: 0] += 1
            }
        }
        refresh(explicit: true)
        track()
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

    /// "This page is in" (or any "open this heading's note"): the Section tab on that heading.
    func openSectionNote(for heading: OutlineNode) {
        guard let session else { return }
        selection.choose(heading.anchor, atPage: session.currentPageIndex)
        session.showNotes(.section)
        lastTab = .section
        refresh(explicit: true)
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

    // MARK: Read-only renderings

    struct SnapshotKey: Hashable {
        var noteID: UUID
        var modifiedAt: Date
        var inkRevision: Int
    }

    /// A cached layout of a stored note for its list row (built on first display).
    func cachedSnapshot(_ key: SnapshotKey) -> NotePageSnapshot? { snapshots[key] }

    func storeSnapshot(_ snapshot: NotePageSnapshot, for key: SnapshotKey) {
        if snapshots.count >= 200 { snapshots.removeAll(keepingCapacity: true) }
        snapshots[key] = snapshot
    }

    // MARK: Deciding

    /// Re-decides which note to show. `explicit`: the reader asked for this change (see
    /// `NotesTargetSwitch`).
    func refresh(explicit: Bool = false) {
        guard let session else { return }
        repairAnchorsIfNeeded(session)
        let page = session.currentPageIndex
        selection.pageDidChange(to: page, outline: session.outline)
        let desired = desiredTarget(session)
        switch NotesTargetSwitch.decide(displayed: model?.target, desired: desired,
                                        isEditingText: model?.isEditingText ?? false, explicit: explicit) {
        case .keep:
            if isSwitchDeferred { isSwitchDeferred = false }
        case .deferUntilEditingEnds:
            if !isSwitchDeferred { isSwitchDeferred = true }
        case .switchNow:
            if isSwitchDeferred { isSwitchDeferred = false }
            show(desired)
        }
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
        guard !didRepairAnchors, session.isOutlineLoaded else { return }
        didRepairAnchors = true
        repairedAnchorCount = NotesHeadingAnchorRepair.apply(store: session.store, bookID: session.book.id,
                                                            outline: session.outline, origin: session.origin)
    }
}
