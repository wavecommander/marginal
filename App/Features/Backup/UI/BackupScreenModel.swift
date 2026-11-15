import Foundation
import Observation
import ReaderBackup
import SwiftUI

/// Closes the Settings sheet from any page pushed in it (the Backup screens' Done).
struct CloseSettingsAction: Sendable {
    let run: @MainActor @Sendable () -> Void
    @MainActor func callAsFunction() { run() }
}

extension EnvironmentValues {
    @Entry var closeSettings: CloseSettingsAction? = nil
}

/// The Backup screen's state: size estimates, each destination's availability, the backup file
/// waiting for the reader to choose where it goes, and the error to show.
@Observable
@MainActor
final class BackupScreenModel {
    private(set) var estimate: BackupSizeEstimate?
    private(set) var availability: [String: BackupDestinationAvailability] = [:]
    /// Bumped when something not observable changed (a destination's live name, a last-success
    /// date in `UserDefaults`), so rows re-read it.
    private(set) var revision = 0
    var failure: BackupFailure?
    /// The finished backup file the file mover is presenting.
    private(set) var pendingFile: BackupFileResult?
    var isMoverPresented = false
    private(set) var fileStatus: String?
    /// The restore Undo Last Restore would undo, `nil` when there is none.
    private(set) var lastRestore: RestoreSafetyRecord?
    /// The confirmation waiting for an answer before an undo.
    var undoConfirmation: RestorePreviewLogic.Confirmation?
    /// What the last undo did.
    private(set) var undoResult: String?

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored private var availabilityTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var service: BackupService { environment.backupService }
    var entries: [BackupDestinationRegistry.Entry] { environment.backupDestinations.entries }

    /// The destination's live name (the picked folder's name changes; the registry entry's does not).
    func name(of entry: BackupDestinationRegistry.Entry) -> String {
        _ = revision
        return entry.destination.displayName
    }

    func lastSuccess(_ id: String) -> Date? {
        _ = revision
        return service.lastSuccessfulBackup(destinationID: id)
    }

    // MARK: Refreshing

    func refresh() async {
        revision += 1
        refreshLastRestore()
        async let sizes: Void = refreshEstimate()
        async let destinations: Void = refreshAvailability()
        _ = await (sizes, destinations)
    }

    func refreshEstimate() async {
        estimate = try? await service.estimateSizes()
    }

    func refreshAvailability() async {
        let destinations = entries.map { ($0.id, $0.destination) }
        let results = await withTaskGroup(of: (String, BackupDestinationAvailability).self) { group in
            for (id, destination) in destinations {
                group.addTask { (id, await destination.availability()) }
            }
            var results: [String: BackupDestinationAvailability] = [:]
            for await (id, value) in group { results[id] = value }
            return results
        }
        availability = results
        revision += 1
    }

    /// A destination's screen reports what it learned, so this list agrees without re-checking.
    func update(_ id: String, availability value: BackupDestinationAvailability) {
        if availability[id] != value { availability[id] = value }
        revision += 1
    }

    // MARK: Undo Last Restore

    /// Re-reads which restore can be undone (after a restore or an undo, in any window).
    func refreshLastRestore() {
        let record = service.latestRestoreSafetyRecord()
        if lastRestore != record { lastRestore = record }
    }

    /// Undo Last Restore asks first, naming the books.
    func requestUndo() {
        refreshLastRestore()
        guard let lastRestore, !service.isBusy else { return }
        undoConfirmation = UndoRestoreLogic.confirmation(lastRestore)
    }

    func undoLastRestore() {
        undoConfirmation = nil
        guard !service.isBusy else {
            failure = BackupFailure.from(BackupServiceError.busy, title: "Couldn’t Undo the Restore")
            return
        }
        undoResult = nil
        Task {
            do {
                let summary = try await service.undoLastRestore()
                undoResult = UndoRestoreLogic.resultLine(summary)
            } catch {
                failure = BackupFailure.from(error, title: "Couldn’t Undo the Restore")
            }
            refreshLastRestore()
        }
    }

    // MARK: Back up to a file

    func saveBackupFile(includePDFs: Bool) {
        guard !service.isBusy else {
            failure = BackupFailure.from(BackupServiceError.busy, title: "Couldn’t Make the Backup")
            return
        }
        fileStatus = nil
        Task {
            do {
                let result = try await service.backUpToFile(includePDFs: includePDFs)
                pendingFile = result
                isMoverPresented = true
            } catch {
                failure = BackupFailure.from(error, title: "Couldn’t Make the Backup")
            }
        }
    }

    func moverCompleted(_ result: Result<URL, any Error>) {
        guard let file = pendingFile else { return }
        pendingFile = nil
        service.discardTemporaryFile(file.url)
        switch result {
        case .success:
            fileStatus = [BackupUIText.fileBackupSaved(bookCount: file.bookCount, byteSize: file.byteSize),
                          BackupUIText.skippedLine(file.skippedBookTitles)].compactMap { $0 }.joined(separator: " ")
        case .failure(let error):
            failure = BackupFailure.from(error, title: "Couldn’t Save the Backup File")
        }
    }

    func moverCancelled() {
        guard let file = pendingFile else { return }
        pendingFile = nil
        service.discardTemporaryFile(file.url)
        fileStatus = "The backup file wasn’t saved."
    }
}
