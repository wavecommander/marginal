import Foundation
import Observation
import PencilKit
import ReaderCore
import UIKit

/// What an editor showing a `NotePageModel` provides to it (implemented by `NotePageEditorView`).
@MainActor
protocol NotePageEditing: AnyObject {
    /// The band layout of `text` as the editor lays it out on screen, or `nil` if the editor is
    /// not showing exactly that text. The model falls back to `NotePageLayoutEngine`.
    func liveBandLayout(for text: String) -> NoteBandLayout?
    /// The model replaced its text (load, or a change from another window). Show `model.text`.
    func noteModelDidReplaceText(_ model: NotePageModel)
    /// The model's ink changed other than through the canvas (load, relocation after a text
    /// change, undo/redo, another window). Show `model.displayInk()` once no stroke is in
    /// progress.
    func noteModelDidChangeInk(_ model: NotePageModel)
    /// Hand the model any input the editor has not reported yet (canvas strokes, text), before
    /// the model reconciles with the store.
    func commitPendingInput(to model: NotePageModel)
    /// `true` while the text view holds uncommitted marked text (an input method composing).
    var isComposingText: Bool { get }
}

/// The note for one `(bookID, target)`: loads it, takes edits from an editor, autosaves text and
/// ink together, flushes on demand, and reconciles with changes made in other windows.
///
/// ## Lifecycle (WP8)
/// 1. `let model = NotePageModel(session: session, target: .page(i))` (or the store initialiser).
/// 2. `await model.load()` — or just show it in a `NotePageView`, which loads it.
/// 3. Show it: `NotePageView(model: model, session: session, zoom: $zoom)`.
/// 4. To switch targets (the reader scrolled), make a new model and give it to the view. The view
///    finishes a stroke in progress on the *old* model first, then switches, and flushes the old
///    model (`flush()`); keep no other reference to the old model.
/// 5. Before dropping a model you created yourself without showing it, `await model.flush()`.
///
/// ## Saving
/// - Edits are saved `autosaveDelay` after the last change (text or a finished stroke), and at
///   once by `flush()` (the editor's `MarkupSurface.flushPendingMarkup`, which the session calls
///   on leaving markup mode, backgrounding, window close and memory warnings; the model also flushes itself
///   when the app enters the background).
/// - A save writes the record first (`notes.save`, attributed to `origin`), then the ink file
///   (`saveNoteInk`) when the note has ink, or deletes the ink file when the last stroke went.
///   The band layout is written both in `Note.bandLayout` and inside the ink data (see
///   `NoteInkArchive`), from the same snapshot.
/// - An empty note (blank text, no ink) is never stored: saving it deletes the record and ink
///   (`LibraryStore.deleteNote`). A note with only ink is kept.
///
/// ## Other windows (reconcile rule)
/// The model observes `noteSaved` / `noteRemoved` for its target and `noteInkChanged` for its
/// note from other origins.
/// - Nothing pending here, no stroke in progress, no text being composed: reload text and ink.
/// - Otherwise the change is applied when the stroke ends / the composition commits, and every
///   save first re-reads the store and merges:
///   - **Text: last writer wins.** Unsaved local text wins and overwrites the other window's text
///     on the next save; otherwise the other window's text is adopted.
///   - **Ink: three-way merge, never silently dropping a stroke** (`NoteInk.merge`): strokes added
///     in either window are kept; an erase in one window removes a stroke only if the other window
///     left it unchanged.
///   Applying another window's change clears this note's undo stack.
@Observable
@MainActor
final class NotePageModel {
    /// Persistence state, for the panel's "Saved" label.
    enum SaveState: Equatable, Sendable {
        /// Loading from the store; the editor is read-only.
        case loading
        /// Nothing stored and nothing to store (an empty placeholder).
        case empty
        /// Changed since the last save; a save is scheduled.
        case edited
        /// A save is running.
        case saving
        /// Everything is stored.
        case saved
        /// The last load or save failed (message for diagnostics); edits are kept and retried on
        /// the next change or flush.
        case failed(String)
    }

    // MARK: Identity

    let bookID: UUID
    let target: NoteTarget
    /// The origin attached to every write (the reader window's `session.origin`).
    let origin: ChangeOrigin?
    /// Revoked when the model (or the reader session that made it) sees `.bookDeleted` for its
    /// book: from then on no save, autosave, flush or delete of this model touches the store, so
    /// a closing window can never write over a book restored under the same ID.
    let saveToken: BookSaveToken
    /// Undo stack of this note's ink. Returned as the note surface's
    /// `markupUndoManager` (typing undo stays the text view's own).
    @ObservationIgnored let undoManager: UndoManager

    // MARK: State

    /// The note's typed text (plain).
    private(set) var text = ""
    /// Number of strokes in the note's ink.
    private(set) var strokeCount = 0
    /// `true` when the note has at least one stroke.
    var hasInk: Bool { strokeCount > 0 }
    /// The stored note's ID, or the ID reserved for its first save; `nil` while nothing is stored.
    private(set) var noteID: UUID?
    /// Whether a record exists in the store (as of the last load or save).
    private(set) var isStored = false
    /// `true` once loaded; until then the editor is read-only.
    private(set) var isLoaded = false
    /// Persistence state.
    private(set) var saveState: SaveState = .loading
    /// Bumped on every change of text or ink (for views that render the note).
    private(set) var revision = 0
    /// `true` while an editor's text view is editing this note (has keyboard focus). Hosts
    /// should not switch the editor to another target while this is true (the reader would be
    /// typing into a note that changes under them); switch when it turns `false`.
    private(set) var isEditingText = false

    /// Short status text for the panel: "Saved", "Saving…", "Edited", "Not saved", or "".
    var statusText: String {
        switch saveState {
        case .loading, .empty: ""
        case .edited: "Edited"
        case .saving: "Saving…"
        case .saved: "Saved"
        case .failed: "Not saved"
        }
    }

    /// The current note value as it would be stored (for read-only rendering of the open note).
    var currentNote: Note {
        Note(id: noteID ?? UUID(), bookID: bookID, target: target, text: text, hasInk: hasInk,
             bandLayout: hasInk ? ink.layout : nil, createdAt: createdAt ?? Date())
    }

    // MARK: Private

    /// The store the model reads and writes (`OpenEditorRegistry` flushes per store).
    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored private let autosaveDelay: Duration
    @ObservationIgnored weak var editor: (any NotePageEditing)?
    /// The ink, anchored to the band layout of `text`.
    @ObservationIgnored private(set) var ink: NoteInk
    /// What the canvas was last given (see `NoteInk.applyCanvasDrawing`).
    @ObservationIgnored private var displayBaseline = CanvasBaseline()
    @ObservationIgnored private var createdAt: Date?

    // The store state last synchronised with (loaded, saved or merged).
    @ObservationIgnored private var baseText = ""
    @ObservationIgnored private var baseInk: NoteInk?
    @ObservationIgnored private var baseInkData: Data?
    @ObservationIgnored private var baseRecordID: UUID?

    @ObservationIgnored private var inkGeneration = 0
    @ObservationIgnored private var baseInkGeneration = 0
    /// Ink data in the store this app version cannot read: never overwritten or deleted.
    @ObservationIgnored private(set) var hasUnreadableInk = false

    @ObservationIgnored private var strokeInProgress = false
    @ObservationIgnored private var remoteChangePending = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var pendingOperations = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var observation: StoreChangeObservation?
    @ObservationIgnored nonisolated(unsafe) private var backgroundObserver: (any NSObjectProtocol)?

    // MARK: Init

    /// A model writing through `store` with `origin`.
    /// - Parameters:
    ///   - observeChanges: how to subscribe to other windows' changes; defaults to the store's hub
    ///     filtered to this book and to origins other than `origin`.
    ///   - parentSaveToken: the reader session's token (the model then also stops saving when
    ///     the session saw its book deleted, even before it was created).
    init(store: LibraryStore, bookID: UUID, target: NoteTarget, origin: ChangeOrigin?,
         autosaveDelay: Duration = .milliseconds(800),
         observeChanges: ((@escaping @MainActor (StoreChangeEvent) -> Void) -> StoreChangeObservation)? = nil,
         parentSaveToken: BookSaveToken? = nil) {
        self.store = store
        self.bookID = bookID
        self.target = target
        self.origin = origin
        self.saveToken = BookSaveToken(bookID: bookID, parent: parentSaveToken)
        self.autosaveDelay = autosaveDelay
        self.undoManager = UndoManager()
        self.ink = NoteInk(layout: NotePageLayoutEngine.shared.bandLayout(for: ""))
        let handler: @MainActor (StoreChangeEvent) -> Void = { [weak self] event in self?.handle(event) }
        if let observeChanges {
            observation = observeChanges(handler)
        } else {
            observation = store.hub.observe { event in
                guard event.change.bookID == bookID else { return }
                if let origin, event.isFrom(origin) { return }
                handler(event)
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.flush() }
            }
        }
        OpenEditorRegistry.shared.register(self)
    }

    /// A model for the note of `target` in the session's book, writing with the session's origin
    /// and observing changes through the session.
    convenience init(session: ReaderSession, target: NoteTarget, autosaveDelay: Duration = .milliseconds(800)) {
        self.init(store: session.store, bookID: session.book.id, target: target, origin: session.origin,
                  autosaveDelay: autosaveDelay,
                  observeChanges: { [weak session] handler in
                      session?.observeBookChanges(handler) ?? StoreChangeObservation.inactive
                  },
                  parentSaveToken: session.saveToken)
    }

    deinit {
        // The hub observation ends with its token; the debounce task holds `self` weakly.
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    // MARK: Loading

    /// Loads the note and its ink (idempotent; concurrent callers share one load).
    func load() async {
        if let loadTask { return await loadTask.value }
        let task = Task { await self.performLoad() }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        await enqueue {
            do {
                let (record, data) = try await self.readStore()
                self.reconcile(record: record, inkData: data, initial: true)
                self.isLoaded = true
                self.refreshSaveState()
                self.editor?.noteModelDidReplaceText(self)
            } catch {
                self.isLoaded = true
                self.saveState = .failed(String(describing: error))
            }
        }
    }

    // MARK: Editor input

    /// The drawing the canvas should show, in note-page coordinates. Resets the baseline that
    /// recognises unchanged strokes when the canvas reports a change.
    func displayInk() -> PKDrawing {
        let (drawing, baseline) = ink.composedForDisplay()
        displayBaseline = baseline
        return drawing
    }

    /// The canvas reported a user change (stroke, lasso move, erase). Registers undo.
    func applyUserDrawing(_ drawing: PKDrawing) {
        let before = ink
        guard ink.applyCanvasDrawing(drawing, baseline: &displayBaseline) else { return }
        registerInkUndo(restoring: before, actionName: "Drawing")
        inkDidChange()
    }

    /// The text view's text changed (typing, paste, dictation, Scribble, text undo/redo).
    func userDidEditText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        relayoutInk()
        revision += 1
        scheduleSave()
    }

    /// A stroke began on the canvas: remote changes wait until it ends.
    func strokeDidBegin() {
        strokeInProgress = true
    }

    /// The stroke ended; applies a deferred remote change and schedules a save.
    func strokeDidEnd() {
        strokeInProgress = false
        if remoteChangePending { scheduleSave(after: .milliseconds(50)) }
    }

    /// The editor's text view began (`true`) or ended (`false`) editing this note.
    func setEditingText(_ editing: Bool) {
        if isEditingText != editing { isEditingText = editing }
    }

    /// The editor finished composing text (marked text committed or ended editing).
    func textEditingDidSettle() {
        if remoteChangePending { scheduleSave(after: .milliseconds(50)) }
    }

    // MARK: Saving

    /// Saves anything pending now and waits for it (and for any save already running). Safe to
    /// call repeatedly and when nothing is pending.
    func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        editor?.commitPendingInput(to: self)
        await enqueue { await self.performSave() }
    }

    /// Deletes the note (design: "Deleting a note"): cancels any pending autosave, then, after any
    /// load or save already queued, deletes the stored record and its ink file
    /// (`LibraryStore.deleteNote`, attributed to `origin`) and resets this model to the empty
    /// placeholder of the same target, discarding unsaved text and strokes. The editor showing it
    /// is told to show the empty page and stays ready for a new note. A note never saved is simply
    /// cleared. Added by WP8.
    /// - Throws: the store's error; the model then keeps its content and shows "Not saved".
    func deleteNote() async throws {
        debounceTask?.cancel()
        debounceTask = nil
        var failure: (any Error)?
        await enqueue {
            guard !self.saveToken.isRevoked else { return }
            do {
                let ran: Bool? = try await BookWriteGate.shared.performSave(bookID: self.bookID, token: self.saveToken) {
                    if let record = try self.store.notes.note(bookID: self.bookID, target: self.target) {
                        try await self.store.deleteNote(id: record.id, origin: self.origin)
                    }
                    return true
                }
                if ran == nil { return }
            } catch {
                failure = error
                self.saveState = .failed(String(describing: error))
                return
            }
            self.debounceTask?.cancel()
            self.debounceTask = nil
            let empty = NoteInk(layout: self.layout(for: ""))
            self.text = ""
            self.ink = empty
            self.strokeCount = 0
            self.noteID = nil
            self.createdAt = nil
            self.isStored = false
            self.hasUnreadableInk = false
            self.remoteChangePending = false
            self.baseText = ""
            self.baseInk = empty
            self.baseInkData = nil
            self.baseRecordID = nil
            self.inkGeneration += 1
            self.baseInkGeneration = self.inkGeneration
            self.undoManager.removeAllActions()
            self.revision += 1
            self.saveState = .empty
            self.editor?.noteModelDidReplaceText(self)
            self.editor?.noteModelDidChangeInk(self)
        }
        if let failure { throw failure }
    }

    /// `true` while text or ink differ from what was last stored.
    var hasUnsavedChanges: Bool {
        text != baseText || inkGeneration != baseInkGeneration
    }

    private func scheduleSave(after delay: Duration? = nil) {
        guard !saveToken.isRevoked else { return }
        if isLoaded { saveState = hasUnsavedChanges ? .edited : saveState }
        debounceTask?.cancel()
        let delay = delay ?? autosaveDelay
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.editor?.commitPendingInput(to: self)
            await self.enqueue { await self.performSave() }
        }
    }

    /// Runs `operation` after every earlier queued operation (loads, saves, reloads never overlap).
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = saveChain
        pendingOperations += 1
        let task = Task { @MainActor in
            await previous?.value
            await operation()
            self.pendingOperations -= 1
        }
        saveChain = task
        await task.value
    }

    private func readStore() async throws -> (Note?, Data?) {
        let record = try store.notes.note(bookID: bookID, target: target)
        var data: Data?
        if let record {
            data = try await store.noteInk(bookID: bookID, noteID: record.id)
        }
        return (record, data)
    }

    /// One save, through `BookWriteGate` (a restore's commit never overlaps it); nothing once
    /// the save token is revoked.
    private func performSave() async {
        guard isLoaded, !saveToken.isRevoked else { return }
        _ = await BookWriteGate.shared.performSave(bookID: bookID, token: saveToken) {
            await self.performSaveNow()
        }
    }

    private func performSaveNow() async {
        do {
            // Pick up changes another window stored since the last sync, whether or not an event
            // announced them; this is also where deferred remote changes are applied. Never while
            // a stroke or a text composition is in progress: then only an unchanged store is
            // written over, and the merge waits for the stroke or composition to end.
            let (record, data) = try await readStore()
            if record?.id != baseRecordID || (record?.text ?? "") != baseText || data != baseInkData {
                if strokeInProgress || editor?.isComposingText == true {
                    remoteChangePending = true
                    scheduleSave()
                    return
                }
                reconcile(record: record, inkData: data, initial: false)
            }
            remoteChangePending = false
            guard hasUnsavedChanges || inkFileNeedsRewrite(record: record) else {
                refreshSaveState()
                return
            }
            saveState = .saving
            try await write(existing: record)
            refreshSaveState()
        } catch {
            saveState = .failed(String(describing: error))
        }
    }

    /// The stored ink must be rewritten when the text moved its bands, so the stored layout and
    /// the record's `bandLayout` describe the current text.
    private func inkFileNeedsRewrite(record: Note?) -> Bool {
        guard hasInk, !hasUnreadableInk else { return false }
        return baseInk?.layout != ink.layout || record?.bandLayout != ink.layout
    }

    private func write(existing record: Note?) async throws {
        guard !saveToken.isRevoked else { return }
        let snapshotText = text
        let snapshotInk = ink
        let snapshotGeneration = inkGeneration
        let now = Date()
        let inkPresent = !snapshotInk.isEmpty || hasUnreadableInk
        let id = record?.id ?? noteID ?? UUID()
        let note = Note(id: id, bookID: bookID, target: target, text: snapshotText, hasInk: inkPresent,
                        bandLayout: hasUnreadableInk ? record?.bandLayout : (snapshotInk.isEmpty ? nil : snapshotInk.layout),
                        createdAt: record?.createdAt ?? createdAt ?? now, modifiedAt: now)
        if note.isEmpty {
            if let record {
                try await store.deleteNote(id: record.id, origin: origin)
            }
            noteID = nil
            createdAt = nil
            isStored = false
            baseRecordID = nil
            baseInkData = nil
        } else {
            noteID = id
            createdAt = note.createdAt
            try store.perform(as: origin) { _ = try store.notes.save(note) }
            isStored = true
            baseRecordID = id
            if hasUnreadableInk {
                // Leave the file alone.
            } else if snapshotInk.isEmpty {
                if record?.hasInk == true || baseInkData != nil {
                    try await store.deleteNoteInk(bookID: bookID, noteID: id, origin: origin)
                }
                baseInkData = nil
            } else {
                let data = try NoteInkArchive.encode(snapshotInk)
                try await store.saveNoteInk(data, bookID: bookID, noteID: id, origin: origin)
                baseInkData = data
            }
        }
        baseText = snapshotText
        baseInk = snapshotInk
        baseInkGeneration = snapshotGeneration
    }

    private func refreshSaveState() {
        if hasUnsavedChanges {
            saveState = .edited
            if debounceTask == nil { scheduleSave() }
        } else {
            saveState = isStored ? .saved : .empty
        }
    }

    // MARK: Reconcile

    /// Adopts the stored state, merging unsaved local edits (see the type's reconcile rule).
    private func reconcile(record: Note?, inkData: Data?, initial: Bool) {
        editor?.commitPendingInput(to: self)
        let localTextDirty = !initial && text != baseText
        let localInkDirty = !initial && inkGeneration != baseInkGeneration

        let remoteText = record?.text ?? ""
        var remoteInk: NoteInk?
        hasUnreadableInk = false
        if let inkData {
            let fallback = record?.bandLayout ?? layout(for: remoteText)
            do {
                remoteInk = try NoteInkArchive.decode(inkData, fallbackLayout: fallback)
            } catch {
                hasUnreadableInk = true
            }
        }

        // Text: last writer wins (unsaved local text wins).
        let finalText = localTextDirty ? text : remoteText
        if finalText != text {
            text = finalText
            editor?.noteModelDidReplaceText(self)
        }
        let currentLayout = layout(for: finalText)
        ink.relayout(to: currentLayout)

        // Ink.
        let remote = (remoteInk ?? NoteInk(layout: currentLayout)).relaid(to: currentLayout)
        let localInkBefore = ink
        if localInkDirty {
            ink = NoteInk.merge(local: ink, remote: remote, base: baseInk)
        } else {
            ink = remote
        }
        if !initial && !ink.isEquivalent(to: localInkBefore) {
            undoManager.removeAllActions()
        }
        strokeCount = ink.strokes.count
        editor?.noteModelDidChangeInk(self)

        if let record {
            noteID = record.id
            createdAt = record.createdAt
            isStored = true
        } else {
            isStored = false
            if !localTextDirty && !localInkDirty { noteID = nil; createdAt = nil }
        }
        baseRecordID = record?.id
        baseText = remoteText
        baseInk = remote
        baseInkData = inkData
        inkGeneration += 1
        baseInkGeneration = ink.isEquivalent(to: remote) ? inkGeneration : inkGeneration - 1
        revision += 1
        if !initial && hasUnsavedChanges { scheduleSave() }
    }

    private func handle(_ event: StoreChangeEvent) {
        switch event.change {
        case .noteSaved(_, let changedTarget, _), .noteRemoved(_, let changedTarget, _):
            guard changedTarget == target else { return }
        case .noteInkChanged(_, let changedNoteID):
            guard changedNoteID == noteID || changedNoteID == baseRecordID else { return }
        case .bookDeleted:
            saveToken.revoke()
            debounceTask?.cancel()
            return
        default:
            return
        }
        remoteChangePending = true
        guard isLoaded else { return }
        if strokeInProgress || editor?.isComposingText == true { return }
        // Coalesce the burst of events one save posts (record, then ink).
        scheduleSave(after: .milliseconds(30))
    }

    // MARK: Ink helpers

    private func layout(for text: String) -> NoteBandLayout {
        editor?.liveBandLayout(for: text) ?? NotePageLayoutEngine.shared.bandLayout(for: text)
    }

    /// Re-anchors the ink to the layout of the current text (after a text change).
    func relayoutInk() {
        let newLayout = layout(for: text)
        if ink.relayout(to: newLayout) {
            editor?.noteModelDidChangeInk(self)
        }
    }

    private func inkDidChange() {
        inkGeneration += 1
        strokeCount = ink.strokes.count
        revision += 1
        scheduleSave()
    }

    private func registerInkUndo(restoring snapshot: NoteInk, actionName: String) {
        undoManager.registerUndo(withTarget: self) { model in
            let current = model.ink
            model.ink = snapshot.relaid(to: model.layout(for: model.text))
            model.registerInkUndo(restoring: current, actionName: actionName)
            model.inkDidChange()
            model.editor?.noteModelDidChangeInk(model)
        }
        undoManager.setActionName(actionName)
    }
}

extension StoreChangeObservation {
    /// An observation that never delivers (used when a session has gone away).
    static var inactive: StoreChangeObservation {
        let observation = StoreChangeHub().observe { _ in }
        observation.cancel()
        return observation
    }
}
