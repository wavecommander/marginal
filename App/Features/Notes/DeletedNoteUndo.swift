import Foundation
import Observation
import ReaderCore
import SwiftUI

/// Everything needed to restore a deleted note (its record and encoded ink, if any).
struct DeletedNoteSnapshot: Equatable, Sendable {
    let note: Note
    let inkData: Data?
}

/// Restores a deleted note record and its ink file to `LibraryStore`.
@MainActor
enum NoteRestore {
    /// Writes `snapshot` back to `store` inside `BookWriteGate` and `NoteSaveQueue`, replacing
    /// any note that now occupies the same target. Returns the saved record, or `nil` when the
    /// book is gone, the snapshot is empty, or `saveToken` is revoked.
    @discardableResult
    static func restore(_ snapshot: DeletedNoteSnapshot, to store: LibraryStore,
                        origin: ChangeOrigin?, saveToken: BookSaveToken? = nil) async throws -> Note? {
        guard !snapshot.note.isEmpty else { return nil }
        let bookID = snapshot.note.bookID
        let target = snapshot.note.target
        let gated: Result<Note?, any Error>? = await BookWriteGate.shared.performSave(bookID: bookID, token: saveToken) {
            await NoteSaveQueue.shared.run(bookID: bookID, target: target) {
                do {
                    return .success(try await write(snapshot, to: store, origin: origin))
                } catch {
                    return .failure(error)
                }
            }
        }
        guard let gated else { return nil }
        return try gated.get()
    }

    private static func write(_ snapshot: DeletedNoteSnapshot, to store: LibraryStore,
                              origin: ChangeOrigin?) async throws -> Note? {
        guard try store.books.book(id: snapshot.note.bookID) != nil else { return nil }
        if let existing = try store.notes.note(bookID: snapshot.note.bookID, target: snapshot.note.target),
           existing.id != snapshot.note.id {
            try await store.deleteNote(id: existing.id, origin: origin)
        }
        let hasInk = snapshot.inkData != nil
        let restored = Note(
            id: snapshot.note.id,
            bookID: snapshot.note.bookID,
            target: snapshot.note.target,
            text: snapshot.note.text,
            hasInk: hasInk,
            bandLayout: hasInk ? snapshot.note.bandLayout : nil,
            createdAt: snapshot.note.createdAt,
            modifiedAt: Date()
        )
        let saved = try store.perform(as: origin) { try store.notes.save(restored) }
        if let inkData = snapshot.inkData {
            try await store.saveNoteInk(inkData, bookID: restored.bookID, noteID: restored.id, origin: origin)
        }
        return saved ?? restored
    }
}

/// Holds the most recently deleted note so the Undo pill can restore it, and hides the pill after
/// `timeout` unless assistive technology is keeping it on screen.
@Observable
@MainActor
final class DeletedNoteUndoController {
    static let defaultTimeout: Duration = .seconds(8)

    private(set) var pending: DeletedNoteSnapshot?
    private(set) var isRestoring = false

    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var restoreHandler: ((DeletedNoteSnapshot) async -> Bool)?

    init(timeout: Duration = defaultTimeout) {
        self.timeout = timeout
    }

    /// Shows the Undo pill for `snapshot` and runs `restore` when the user taps Undo.
    func offer(_ snapshot: DeletedNoteSnapshot, keepVisible: Bool = false,
               restore: @escaping @MainActor (DeletedNoteSnapshot) async -> Bool) {
        dismissTask?.cancel()
        dismissTask = nil
        pending = snapshot
        restoreHandler = restore
        scheduleDismissIfNeeded(keepVisible: keepVisible)
    }

    /// Pauses or resumes the auto-dismiss timer (e.g. while VoiceOver or Switch Control is on).
    func setKeepVisible(_ keepVisible: Bool) {
        guard pending != nil else { return }
        scheduleDismissIfNeeded(keepVisible: keepVisible)
    }

    /// Hides the Undo pill and drops the pending snapshot.
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        pending = nil
        restoreHandler = nil
    }

    /// Runs the restore handler for the pending snapshot and dismisses the pill.
    @discardableResult
    func undo() async -> Bool {
        guard let snapshot = pending, let restoreHandler, !isRestoring else { return false }
        isRestoring = true
        dismissTask?.cancel()
        dismissTask = nil
        pending = nil
        self.restoreHandler = nil
        defer { isRestoring = false }
        return await restoreHandler(snapshot)
    }

    private func scheduleDismissIfNeeded(keepVisible: Bool) {
        if keepVisible {
            dismissTask?.cancel()
            dismissTask = nil
            return
        }
        guard dismissTask == nil else { return }
        dismissTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.dismiss()
        }
    }
}

/// Compact floating pill shown after deleting a note, letting the user undo the delete.
struct DeletedNoteUndoPill: View {
    let controller: DeletedNoteUndoController
    @Environment(\.accentTheme) private var accentTheme
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverOn
    @Environment(\.accessibilitySwitchControlEnabled) private var isSwitchControlOn

    private var keepVisible: Bool { isVoiceOverOn || isSwitchControlOn }

    var body: some View {
        Group {
            if controller.pending != nil {
                Button {
                    Task { await controller.undo() }
                } label: {
                    HStack(spacing: Space.s) {
                        Text("Note deleted")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accentTheme.accent)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(minHeight: Size.touch)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.hairline))
                    .elevation(.floating)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Note deleted, Undo")
                .accessibilityHint("Restores the deleted note")
                .accessibilityAction(named: "Dismiss") { controller.dismiss() }
                .accessibilityIdentifier(NotesPanelAccessibilityID.undoDelete)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onChange(of: keepVisible, initial: true) { _, keep in
                    controller.setKeepVisible(keep)
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: controller.pending != nil)
    }
}
