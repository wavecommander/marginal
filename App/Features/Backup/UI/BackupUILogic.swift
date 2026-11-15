import Foundation
import ReaderBackup
import ReaderCore

// The Backup screens' plain decisions and strings: no views and no store access, so they are
// unit-tested directly (`Tests/BackupUILogicTests.swift`), like `LibraryLogic`.

// MARK: - Shared text

/// Sizes, dates, lists and the result lines of a backup.
nonisolated enum BackupUIText {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "14 Nov 2026 at 10:02" (the reader's locale).
    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "1 note", "3 notes".
    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted(.number)) \(value == 1 ? singular : plural)"
    }

    /// "“A”", "“A” and “B”", "“A”, “B” and “C”" (the reader's locale joins them).
    static func quotedList(_ titles: [String]) -> String {
        titles.map { "“\($0)”" }.formatted(.list(type: .and))
    }

    /// "Notes and ink only: 14 MB · With PDFs: 3.2 GB".
    static func estimateLine(_ estimate: BackupSizeEstimate) -> String {
        "Notes and ink only: \(bytes(estimate.notesAndInk)) · With PDFs: \(bytes(estimate.withPDFs))"
    }

    /// Books a backup left out (no PDF and no recorded hash), or `nil` when none were.
    static func skippedLine(_ titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        let list = quotedList(titles)
        return titles.count == 1
            ? "\(list) was left out: its PDF is missing, so the backup can’t record which PDF the book needs."
            : "\(list) were left out: their PDFs are missing, so the backup can’t record which PDFs the books need."
    }

    /// After a backup file was saved where the reader chose.
    static func fileBackupSaved(bookCount: Int, byteSize: Int64) -> String {
        "Saved a backup of \(count(bookCount, "book", "books")) (\(bytes(byteSize)))."
    }

    /// After a backup to a destination.
    static func destinationBackupDone(_ result: DestinationBackupResult, destinationName: String) -> String {
        var line = "Backed up \(count(result.bookCount, "book", "books")) to \(destinationName)."
        if result.uploadedPDFs > 0 { line += " \(count(result.uploadedPDFs, "PDF", "PDFs")) uploaded." }
        return line
    }

    /// "Last backup: 14 Nov 2026 at 10:02", or "No backups yet".
    static func lastBackupLine(_ date: Date?, dateText: (Date) -> String = BackupUIText.date) -> String {
        guard let date else { return "No backups yet" }
        return "Last backup: \(dateText(date))"
    }

    /// The secondary line of a destination row: "Checking…" until its availability is known, the
    /// reason it can't be used, or when it was last backed up to.
    static func destinationStatus(availability: BackupDestinationAvailability?, lastSuccess: Date?,
                                  dateText: (Date) -> String = BackupUIText.date) -> String {
        switch availability {
        case nil: "Checking…"
        case .unavailable(let reason): reason
        case .available: lastBackupLine(lastSuccess, dateText: dateText)
        }
    }

    /// A snapshot row: its date as the title, "device · size" below.
    static func snapshotTitle(_ snapshot: BackupSnapshotInfo, dateText: (Date) -> String = BackupUIText.date) -> String {
        dateText(snapshot.createdAt)
    }

    static func snapshotDetail(_ snapshot: BackupSnapshotInfo) -> String {
        [snapshot.deviceName.isEmpty ? nil : snapshot.deviceName, bytes(snapshot.byteSize)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The footnote under the Backup screen.
    static let footnote = "Tactile Texts doesn’t encrypt backups: anyone who can open a backup file can read the notes in it. A backup without PDFs is much smaller; after restoring it, link each book to its PDF with Locate PDF…."
}

// MARK: - Errors

/// An error ready to show: title, the error's own message, and whether to offer "Sign In".
nonisolated struct BackupFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    var title: String
    var message: String
    /// A Google sign-in would fix it (`CloudBackupError.needsSignIn`).
    var offersSignIn: Bool

    static func == (lhs: BackupFailure, rhs: BackupFailure) -> Bool {
        lhs.title == rhs.title && lhs.message == rhs.message && lhs.offersSignIn == rhs.offersSignIn
    }

    /// `nil` for a cancellation (quiet); otherwise the error's own `localizedDescription`.
    static func from(_ error: any Error, title: String) -> BackupFailure? {
        if isCancellation(error) { return nil }
        let signIn = (error as? CloudBackupError)?.needsSignIn ?? false
        return BackupFailure(title: title, message: error.localizedDescription, offersSignIn: signIn)
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let importError = error as? ImportError, importError == .cancelled { return true }
        if let cocoa = error as? CocoaError, cocoa.code == .userCancelled { return true }
        return false
    }
}

// MARK: - Destinations

/// Which kind of destination an entry is, from its ID: decides its icon and the controls only
/// it needs.
nonisolated enum BackupDestinationKind: Equatable, Sendable {
    /// The folder the reader picks in Files (`folder`).
    case pickedFolder
    case iCloud
    case googleDrive
    case s3
    /// Anything else (the test-only `-backupFolder` destination).
    case other

    init(id: String) {
        switch id {
        case PickedFolderBackupDestination.destinationID: self = .pickedFolder
        case ICloudBackupDestination.destinationID: self = .iCloud
        case GoogleDriveBackupDestination.destinationID: self = .googleDrive
        case S3BackupDestination.destinationID: self = .s3
        default: self = .other
        }
    }

    var systemImage: String {
        switch self {
        case .pickedFolder, .other: "folder"
        case .iCloud: "icloud"
        case .googleDrive: "cloud"
        case .s3: "server.rack"
        }
    }

    /// "Choose Folder…", the folder's name and "Stop Using This Folder".
    var showsFolderControls: Bool { self == .pickedFolder }
    /// The Google account's state with Sign In / Sign Out.
    var showsGoogleAccount: Bool { self == .googleDrive }
}

/// What the Google Drive destination shows for the account.
nonisolated struct GoogleAccountPresentation: Equatable, Sendable {
    var status: String
    var showsSignIn: Bool
    var showsSignOut: Bool

    static func make(_ state: GoogleDriveAccount.State) -> GoogleAccountPresentation {
        switch state {
        case .notSetUp:
            GoogleAccountPresentation(status: "Google Drive isn’t set up in this build of Tactile Texts.",
                                      showsSignIn: false, showsSignOut: false)
        case .signedOut:
            GoogleAccountPresentation(status: "Not signed in.", showsSignIn: true, showsSignOut: false)
        case .signedIn:
            GoogleAccountPresentation(status: "Signed in to Google Drive.", showsSignIn: false, showsSignOut: true)
        case .needsSignInAgain:
            GoogleAccountPresentation(status: "Google Drive needs you to sign in again.", showsSignIn: true, showsSignOut: true)
        }
    }

    /// What the app can see in the reader's Drive.
    static let scopeSentence = "Tactile Texts can see only the files it creates in your Google Drive (the “Tactile Texts Backups” folder), nothing else."
}

// MARK: - Automatic backup

nonisolated enum AutomaticBackupLogic {
    struct Choice: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
    }

    /// The destinations automatic backups may go to: those available now, in list order.
    static func choices(_ entries: [Choice], availability: [String: BackupDestinationAvailability]) -> [Choice] {
        entries.filter { availability[$0.id]?.isAvailable == true }
    }

    /// The destination to select when the switch is turned on: the current one if it can be
    /// chosen, else the first available, else `nil`.
    static func destination(current: String?, choices: [Choice]) -> String? {
        if let current, choices.contains(where: { $0.id == current }) { return current }
        return choices.first?.id
    }

    /// The status line under the automatic-backup controls.
    static func statusLine(isEnabled: Bool, destinationName: String?, availability: BackupDestinationAvailability?,
                           lastSuccess: Date?, lastFailureMessage: String?,
                           dateText: (Date) -> String = BackupUIText.date) -> String {
        guard isEnabled else { return "Automatic backups are off." }
        guard let destinationName else { return "Choose where automatic backups go." }
        if case .unavailable(let reason) = availability {
            return "Automatic backups to \(destinationName) are waiting: \(reason)"
        }
        if let lastFailureMessage {
            return "The last automatic backup didn’t finish: \(lastFailureMessage)"
        }
        if let lastSuccess { return "Last successful backup: \(dateText(lastSuccess))." }
        return "No backup to \(destinationName) yet."
    }

    static let footer = "Once a day, when something has changed, Tactile Texts backs up to the chosen destination while it is open or in the background."
}

// MARK: - Restore preview: choices

/// What a preview row's menu offers for a book already in the Library. Leave as Is is the same
/// as unticking the book.
nonisolated enum RestoreRowChoice: String, CaseIterable, Identifiable, Sendable {
    case merge
    case replace
    case leave

    var id: String { rawValue }

    /// The menu item's title.
    var title: String {
        switch self {
        case .merge: "Merge"
        case .replace: "Replace with Backup"
        case .leave: "Leave as Is"
        }
    }

    /// The SF Symbol beside the title in the menu.
    var systemImage: String {
        switch self {
        case .merge: "arrow.triangle.merge"
        case .replace: "arrow.2.squarepath"
        case .leave: "minus.circle"
        }
    }

    /// The menu for `item`: everything, except Merge for a converted book whose PDF here is not
    /// the backup's (`RestorePlan.Item.hasDifferentConversion`).
    static func choices(for item: RestorePlan.Item) -> [RestoreRowChoice] {
        item.hasDifferentConversion ? [.replace, .leave] : allCases
    }

    /// What the restore does for this choice; `nil` for Leave as Is (the book is not passed).
    var action: RestoreAction? {
        switch self {
        case .merge: .merge
        case .replace: .replace
        case .leave: nil
        }
    }
}

/// The reader's choices in the restore preview: which books are ticked and, for each book
/// already in the Library, whether it is merged or replaced. The tick and the menu are two views
/// of the same state: unticking a book is Leave as Is, and ticking it again brings back the
/// choice it had (Merge unless the reader picked Replace).
nonisolated struct RestoreChoices: Equatable, Sendable {
    /// Ticked books.
    private(set) var selection: Set<UUID> = []
    /// Merge or Replace, for every book already in the Library (kept while it is unticked).
    private(set) var existingActions: [UUID: RestoreAction] = [:]
    /// The books already in the Library, as of the last plan.
    private(set) var existing: Set<UUID> = []
    /// Books that cannot be merged (`RestorePlan.Item.hasDifferentConversion`), as of the last plan.
    private(set) var unmergeable: Set<UUID> = []

    init() {}

    /// The choices when the preview opens: `RestorePlan.Item.isSelectedByDefault` and
    /// `defaultAction` (every book ticked; a book already in the Library set to Merge).
    init(plan: RestorePlan) {
        selection = Set(plan.items.filter(\.isSelectedByDefault).map(\.id))
        reconcile(with: plan)
    }

    func isSelected(_ id: UUID) -> Bool { selection.contains(id) }

    /// The menu's current choice for a book already in the Library; `nil` for a new book, which
    /// has no menu.
    func choice(for item: RestorePlan.Item) -> RestoreRowChoice? {
        guard existing.contains(item.id) else { return nil }
        guard selection.contains(item.id) else { return .leave }
        return existingActions[item.id] == .replace ? .replace : .merge
    }

    /// What restoring a ticked book does; `nil` when it is not ticked.
    func action(for item: RestorePlan.Item) -> RestoreAction? {
        guard selection.contains(item.id) else { return nil }
        guard existing.contains(item.id) else { return .restore }
        return existingActions[item.id] ?? item.defaultAction
    }

    /// The tick.
    mutating func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// The menu of a book already in the Library.
    mutating func choose(_ choice: RestoreRowChoice, for id: UUID) {
        guard existing.contains(id) else { return }
        if choice == .merge, unmergeable.contains(id) { return }
        if let action = choice.action {
            existingActions[id] = action
            selection.insert(id)
        } else {
            selection.remove(id)
        }
    }

    /// The actions to pass to `BackupService.restore(_:from:restorePDFs:)`: one per ticked book,
    /// in no particular order. Books left as they are, or unticked, are not listed.
    func actions(in plan: RestorePlan) -> [UUID: RestoreAction] {
        var result: [UUID: RestoreAction] = [:]
        for item in plan.items {
            if let action = action(for: item) { result[item.id] = action }
        }
        return result
    }

    /// The ticked items, in plan order.
    func selectedItems(in plan: RestorePlan) -> [RestorePlan.Item] {
        plan.items.filter { selection.contains($0.id) }
    }

    /// Whether any ticked book is set to Merge (the preview then shows the deletions footnote).
    func anyMerge(in plan: RestorePlan) -> Bool {
        plan.items.contains { action(for: $0) == .merge }
    }

    /// After the plan was rebuilt (the Library changed under the preview): books that are no
    /// longer in the backup are dropped, a book that is now in the Library starts at its default
    /// (Merge), and a book that left the Library loses its Merge or Replace.
    mutating func reconcile(with plan: RestorePlan) {
        let ids = Set(plan.items.map(\.id))
        selection.formIntersection(ids)
        existing = Set(plan.items.filter { $0.status == .inLibrary }.map(\.id))
        unmergeable = Set(plan.items.filter { $0.status == .inLibrary && $0.hasDifferentConversion }.map(\.id))
        existingActions = existingActions.filter { existing.contains($0.key) }
        for item in plan.items where item.status == .inLibrary {
            if existingActions[item.id] == nil || unmergeable.contains(item.id) {
                existingActions[item.id] = item.defaultAction == .replace ? .replace : .merge
            }
        }
    }
}

// MARK: - Restore preview

nonisolated enum RestorePreviewLogic {
    static func statusText(_ status: RestorePlan.Status) -> String {
        switch status {
        case .new: "New"
        case .inLibrary: "Already in Library"
        }
    }

    /// "2 notes, 1 highlight, 0 bookmarks, 3 pages of ink" (plus headings when there are any).
    static func countsText(_ counts: BackupManifest.RecordCounts) -> String {
        var parts = [BackupUIText.count(counts.notes, "note", "notes"),
                     BackupUIText.count(counts.highlights, "highlight", "highlights"),
                     BackupUIText.count(counts.bookmarks, "bookmark", "bookmarks")]
        if counts.userHeadings > 0 { parts.append(BackupUIText.count(counts.userHeadings, "heading", "headings")) }
        parts.append(BackupUIText.count(counts.inkedPages, "page of ink", "pages of ink"))
        return parts.joined(separator: ", ")
    }

    /// One side of an existing book's comparison: "In this backup: … Changed 12 Nov 2026 at 9:30."
    static func sideText(_ label: String, counts: BackupManifest.RecordCounts, modified: Date,
                         dateText: (Date) -> String = BackupUIText.date) -> String {
        "\(label): \(countsText(counts)). Changed \(dateText(modified))."
    }

    static let backupSideLabel = "In this backup"
    static let localSideLabel = "On this iPad"

    /// Said on a book already in the Library that is set to Replace with Backup.
    static let replaceWarning = "Restoring replaces this book’s notes, highlights, bookmarks and ink on this iPad with the backup’s."

    /// Said on a book already in the Library that is set to Leave as Is.
    static let leaveText = "Left as it is: nothing from this backup is added to this book."

    /// Why a converted book whose PDF here is not the backup's cannot be merged
    /// (`RestorePlan.Item.hasDifferentConversion`).
    static let differentConversionReason = "This book was converted to a PDF separately on this iPad, so its pages may not match the backup’s and their notes can’t be merged."

    /// Said on such a book while it is left as it is (its default).
    static let differentConversionLeaveText = "\(differentConversionReason) Left as it is."

    /// Said on such a book set to Replace with Backup.
    static let differentConversionReplaceWarning = "\(differentConversionReason) \(replaceWarning)"

    /// Said on a book set to Merge while its merge preview is being worked out.
    static let mergeLoadingText = "Working out what a merge adds…"

    /// Said on a book set to Merge when its merge preview could not be worked out (the backup's
    /// records for it could not be read; restoring it reports why).
    static let mergeFallbackText = "Adds what this backup has that this iPad doesn’t. Nothing on this iPad is removed."

    /// The note shown while any ticked book is set to Merge.
    static let mergeFootnote = "In a merge, anything deleted on this iPad after this backup was made comes back: notes, highlights, bookmarks, headings, ink and paragraphs that the backup still has."

    /// The footer under the books.
    static func booksFooter(hasExistingBooks: Bool) -> String {
        hasExistingBooks
            ? "Every book is ticked. A book already in your Library is merged: it keeps everything on this iPad and gains what the backup has. Its menu can replace it with the backup’s copy instead, or leave it as it is."
            : "Every book is ticked. Untick a book to leave it out."
    }

    /// Where the book's PDF will come from, as the reader sees it, for what restoring it does
    /// (`nil`: left as it is, so nothing is said). A merge keeps this iPad's PDF, and takes the
    /// backup's only when this iPad has none.
    static func pdfText(_ item: RestorePlan.Item, action: RestoreAction?, restorePDFs: Bool) -> String? {
        guard let action else { return nil }
        if action == .merge, item.status == .inLibrary {
            let target = BackupService.mergeTargetID(for: item)
            if item.localMatches.first(where: { $0.book.id == target })?.hasPDF == true { return "PDF: already on this iPad" }
            switch item.pdfSource {
            case .embedded where restorePDFs: return "PDF: included in the backup"
            case .destination where restorePDFs: return "PDF: stored with the backups"
            default: return "PDF: not included. Link it later with Locate PDF…"
            }
        }
        return pdfText(item, restorePDFs: restorePDFs)
    }

    /// Where a restored (or replaced) book's PDF will come from.
    static func pdfText(_ item: RestorePlan.Item, restorePDFs: Bool) -> String {
        let localHasPDF = item.localMatches.contains(where: \.hasPDF)
        switch item.pdfSource {
        case .embedded where restorePDFs: return "PDF: included in the backup"
        case .destination where restorePDFs: return "PDF: stored with the backups"
        case .localBook: return "PDF: already on this iPad"
        case .embedded, .destination, .missing:
            return localHasPDF ? "PDF: already on this iPad" : "PDF: not included. Link it later with Locate PDF…"
        }
    }

    /// Whether to offer "Restore PDFs": the backup or its destination holds any of its PDFs.
    static func offersRestorePDFs(_ plan: RestorePlan) -> Bool {
        plan.items.contains { item in
            switch item.pdfSource {
            case .embedded, .destination: true
            case .localBook, .missing: false
            }
        }
    }

    // MARK: Rows

    /// What a row says under its title and PDF line about what will happen to the book.
    enum RowNote: Equatable, Sendable {
        /// A new book: the backup's counts.
        case counts(String)
        /// Merge: what it adds and combines (`isLoading` while the preview is worked out).
        case merge(String, isLoading: Bool)
        /// Replace with Backup: the warning.
        case replaceWarning(String)
        /// Leave as Is.
        case leave(String)
        /// A new book left out: nothing to add.
        case none
    }

    /// The controls and texts of one preview row.
    struct Row: Equatable, Sendable {
        /// The Merge / Replace with Backup / Leave as Is menu (books already in the Library).
        var menuChoice: RestoreRowChoice?
        /// Where the PDF comes from; `nil` when the book is left out.
        var pdfLine: String?
        /// "In this backup: …" and "On this iPad: …", for a book already in the Library.
        var sideLines: [String]
        var note: RowNote

        var showsMenu: Bool { menuChoice != nil }
    }

    /// - Parameters:
    ///   - preview: the merge preview for this book, when it has been worked out.
    ///   - previewsLoaded: `true` once the merge previews have been worked out (a missing
    ///     preview then means it couldn't be).
    static func row(_ item: RestorePlan.Item, choices: RestoreChoices, restorePDFs: Bool,
                    preview: BookMergePreview?, previewsLoaded: Bool,
                    dateText: (Date) -> String = BackupUIText.date) -> Row {
        let action = choices.action(for: item)
        let pdf = pdfText(item, action: action, restorePDFs: restorePDFs)
        guard item.status == .inLibrary else {
            return Row(menuChoice: nil, pdfLine: pdf, sideLines: [],
                       note: action == nil ? .none : .counts(countsText(item.entry.counts)))
        }
        var sides = [sideText(backupSideLabel, counts: item.entry.counts, modified: item.entry.lastModifiedAt, dateText: dateText)]
        sides += item.localMatches.map { sideText(localSideLabel, counts: $0.counts, modified: $0.lastModifiedAt, dateText: dateText) }
        let choice = choices.choice(for: item) ?? .leave
        let note: RowNote
        switch choice {
        case .merge:
            if let preview {
                note = .merge(MergeText.previewText(preview), isLoading: false)
            } else {
                note = .merge(previewsLoaded ? mergeFallbackText : mergeLoadingText, isLoading: !previewsLoaded)
            }
        case .replace: note = .replaceWarning(item.hasDifferentConversion ? differentConversionReplaceWarning : replaceWarning)
        case .leave: note = .leave(item.hasDifferentConversion ? differentConversionLeaveText : leaveText)
        }
        return Row(menuChoice: choice, pdfLine: pdf, sideLines: sides, note: note)
    }

    /// The tick's VoiceOver value.
    static func tickValue(isSelected: Bool) -> String { isSelected ? "Selected" : "Not selected" }

    /// The tick's VoiceOver hint.
    static func tickHint(isSelected: Bool, isExisting: Bool, canMerge: Bool = true) -> String {
        switch (isSelected, isExisting) {
        case (true, _): "Double-tap to leave this book out."
        case (false, false): "Double-tap to restore this book."
        case (false, true): canMerge ? "Double-tap to merge this book." : "Double-tap to replace this book with the backup’s."
        }
    }

    /// The menu's VoiceOver label (its value is the current choice's title).
    static func menuAccessibilityLabel(title: String) -> String { "What to do with “\(title)”" }

    // MARK: Restore button and confirmation

    /// "Restore 1 Book", "Merge 2 Books" (when every ticked book is merged); "Restore" with
    /// nothing ticked.
    static func restoreButtonTitle(actions: [RestoreAction]) -> String {
        let verb = !actions.isEmpty && actions.allSatisfy { $0 == .merge } ? "Merge" : "Restore"
        switch actions.count {
        case 0: return "Restore"
        case 1: return "\(verb) 1 Book"
        default: return "\(verb) \(actions.count.formatted(.number)) Books"
        }
    }

    /// "Restore 1 Book", "Restore 3 Books"; "Restore" with nothing ticked.
    static func restoreButtonTitle(count: Int) -> String {
        restoreButtonTitle(actions: Array(repeating: .restore, count: count))
    }

    struct Confirmation: Equatable, Sendable {
        var title: String
        var message: String
        var confirmTitle: String
    }

    /// The confirmation needed before restoring: `nil` unless a ticked book already in the
    /// Library is set to Replace with Backup; then it names those books.
    /// - Parameter selected: the ticked books with what restoring each does, in plan order.
    static func confirmation(selected: [(item: RestorePlan.Item, action: RestoreAction)]) -> Confirmation? {
        let replacing = selected.filter { $0.item.status == .inLibrary && $0.action == .replace }.map(\.item)
        guard !replacing.isEmpty else { return nil }
        let titles = BackupUIText.quotedList(replacing.map(\.entry.book.title))
        let title = replacing.count == 1 ? "Replace “\(replacing[0].entry.book.title)”?"
            : "Replace \(replacing.count.formatted(.number)) Books?"
        let message = "Restoring replaces the notes, highlights, bookmarks and ink of \(titles) on this iPad with the backup’s. What is there now is lost, unless you undo this restore from the Backup screen."
        return Confirmation(title: title, message: message, confirmTitle: restoreButtonTitle(actions: selected.map(\.action)))
    }

    /// "Made 14 Nov 2026 at 10:02 on Ben’s iPad".
    static func headerLine(createdAt: Date, deviceName: String, dateText: (Date) -> String = BackupUIText.date) -> String {
        deviceName.isEmpty ? "Made \(dateText(createdAt))" : "Made \(dateText(createdAt)) on \(deviceName)"
    }

    /// "Merge" or "Replace with Backup" beside a title in the Restoring list; `nil` for a new book.
    static func restoringActionText(_ item: RestorePlan.Item, action: RestoreAction) -> String? {
        guard item.status == .inLibrary else { return nil }
        return action == .replace ? RestoreRowChoice.replace.title : RestoreRowChoice.merge.title
    }

    // MARK: Summary

    /// "3 books restored, 1 needs its PDF"; "1 book merged, 2 books restored".
    static func summaryHeadline(_ summary: RestoreSummary) -> String {
        guard !summary.restored.isEmpty else {
            return summary.failures.isEmpty ? "Nothing was restored" : "No books could be restored"
        }
        let mergedIDs = Set(summary.merged.map(\.id))
        let mergedCount = summary.restored.filter { mergedIDs.contains($0.id) }.count
        let restoredCount = summary.restored.count - mergedCount
        var parts: [String] = []
        if mergedCount > 0 { parts.append("\(BackupUIText.count(mergedCount, "book", "books")) merged") }
        if restoredCount > 0 { parts.append("\(BackupUIText.count(restoredCount, "book", "books")) restored") }
        var line = parts.joined(separator: ", ")
        let needing = summary.needingPDF.count
        if needing > 0 {
            line += needing == 1 ? ", 1 needs its PDF" : ", \(needing.formatted(.number)) need their PDFs"
        }
        if !summary.failures.isEmpty {
            line += ", \(BackupUIText.count(summary.failures.count, "book", "books")) not restored"
        }
        return line
    }

    static func droppedNotesLine(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? "1 note was left out because it was empty."
            : "\(count.formatted(.number)) notes were left out because they were empty."
    }

    /// Under the summary's headline when the restore kept a safety copy.
    static let undoHint = "To put things back as they were, use Undo Last Restore on the Backup screen."

    /// The books the summary lists under Restored: committed, not merged, and with their PDF (or
    /// linked since).
    static func plainlyRestored(_ summary: RestoreSummary, linked: Set<UUID>) -> [RestoreSummary.RestoredBook] {
        let merged = Set(summary.merged.map(\.id))
        return summary.restored.filter { !merged.contains($0.id) && ($0.hasPDF || linked.contains($0.id)) }
    }

    static let needsPDFExplanation = "These books are back with their notes, highlights and ink, but not their PDFs. Choose each book’s original PDF to read it; you can also do this later from the book in the Library."
}

// MARK: - Merge sentences

/// What a merge adds and combines, in plain sentences with correct singular and plural, for the
/// restore preview (future: "Adds …") and the summary (past: "Added …").
nonisolated enum MergeText {
    /// The counts one sentence pair is made from.
    struct Counts: Equatable, Sendable {
        var notesAdded = 0
        var highlightsAdded = 0
        var bookmarksAdded = 0
        var headingsAdded = 0
        var inkPagesAdded = 0
        var inkNotesAdded = 0
        var notesCombined = 0
        var inkPagesCombined = 0
        var inkNotesCombined = 0
        /// Ink combined on pages and notes together, when the two can't be told apart (part of the
        /// combined ink already held everything; see `summaryCounts`).
        var inkPagesAndNotesCombined = 0

        var isEmpty: Bool {
            notesAdded + highlightsAdded + bookmarksAdded + headingsAdded + inkPagesAdded + inkNotesAdded
                + notesCombined + inkPagesCombined + inkNotesCombined + inkPagesAndNotesCombined == 0
        }
    }

    enum Tense: Sendable {
        /// The preview: "Adds", "Combines".
        case future
        /// The summary: "Added", "Combined".
        case past
    }

    /// "Adds 3 notes, 12 highlights and 2 bookmarks. Combines 2 notes and the ink on 4 pages.";
    /// an empty string when there is nothing to say.
    static func sentences(_ counts: Counts, tense: Tense) -> String {
        var added: [String] = []
        if counts.notesAdded > 0 { added.append(BackupUIText.count(counts.notesAdded, "note", "notes")) }
        if counts.highlightsAdded > 0 { added.append(BackupUIText.count(counts.highlightsAdded, "highlight", "highlights")) }
        if counts.bookmarksAdded > 0 { added.append(BackupUIText.count(counts.bookmarksAdded, "bookmark", "bookmarks")) }
        if counts.headingsAdded > 0 { added.append(BackupUIText.count(counts.headingsAdded, "heading", "headings")) }
        if counts.inkPagesAdded > 0 { added.append("ink on \(BackupUIText.count(counts.inkPagesAdded, "page", "pages"))") }
        if counts.inkNotesAdded > 0 { added.append("handwriting in \(BackupUIText.count(counts.inkNotesAdded, "note", "notes"))") }

        var combined: [String] = []
        if counts.notesCombined > 0 { combined.append(BackupUIText.count(counts.notesCombined, "note", "notes")) }
        if counts.inkPagesCombined > 0 {
            combined.append("the ink on \(BackupUIText.count(counts.inkPagesCombined, "page", "pages"))")
        }
        if counts.inkNotesCombined > 0 {
            combined.append("the handwriting in \(BackupUIText.count(counts.inkNotesCombined, "note", "notes"))")
        }
        if counts.inkPagesAndNotesCombined > 0 {
            combined.append("the ink on \(counts.inkPagesAndNotesCombined.formatted(.number)) pages and notes")
        }

        var result: [String] = []
        if !added.isEmpty { result.append("\(tense == .future ? "Adds" : "Added") \(list(added)).") }
        if !combined.isEmpty { result.append("\(tense == .future ? "Combines" : "Combined") \(list(combined)).") }
        return result.joined(separator: " ")
    }

    /// The preview's counts.
    static func counts(_ report: BookMergeReport, ink: MergeInkCounts) -> Counts {
        Counts(notesAdded: report.notesAdded, highlightsAdded: report.highlightsAdded, bookmarksAdded: report.bookmarksAdded,
               headingsAdded: report.headingsAdded, inkPagesAdded: ink.pagesAdded, inkNotesAdded: ink.notesAdded,
               notesCombined: report.notesCombined, inkPagesCombined: ink.pagesCombined, inkNotesCombined: ink.notesCombined)
    }

    static let nothingToAdd = "This iPad already has everything in this backup."
    static let nothingRemoved = "Nothing on this iPad is removed."

    /// What the preview says on a book set to Merge.
    static func previewText(_ preview: BookMergePreview) -> String {
        let counts = counts(preview.report, ink: preview.ink)
        guard !preview.addsNothing, !counts.isEmpty else { return nothingToAdd }
        return "\(sentences(counts, tense: .future)) \(nothingRemoved)"
    }

    // MARK: Summary

    /// What a merge did, leaving out the combined ink that already held every stroke of the
    /// backup's (`combinedInkAlreadyPresent`). When that ink can't be placed on pages or notes
    /// (both had combined ink), the rest is counted together as "pages and notes".
    static func summaryCounts(_ book: RestoreSummary.MergedBook) -> Counts {
        var counts = counts(book.report, ink: book.ink)
        let already = max(0, book.combinedInkAlreadyPresent)
        guard already > 0 else { return counts }
        if counts.inkNotesCombined == 0 {
            counts.inkPagesCombined = max(0, counts.inkPagesCombined - already)
        } else if counts.inkPagesCombined == 0 {
            counts.inkNotesCombined = max(0, counts.inkNotesCombined - already)
        } else {
            counts.inkPagesAndNotesCombined = max(0, counts.inkPagesCombined + counts.inkNotesCombined - already)
            counts.inkPagesCombined = 0
            counts.inkNotesCombined = 0
        }
        return counts
    }

    static let nothingNew = "Nothing new: this iPad already had everything in the backup."

    /// The lines under a merged book's title in the summary.
    static func summaryLines(_ book: RestoreSummary.MergedBook) -> [String] {
        let counts = summaryCounts(book)
        var lines = [counts.isEmpty ? nothingNew : sentences(counts, tense: .past)]
        if let unreadable = unreadableLine(book.unreadableInk) { lines.append(unreadable) }
        if book.tookPDFFromBackup { lines.append("Its PDF came from the backup.") }
        return lines
    }

    /// "The ink on page 3 and in 1 note couldn’t be read, so it was kept as it was and not
    /// combined."; `nil` when all ink was read. Pages are numbered from 1.
    static func unreadableLine(_ ink: [UnreadableInk]) -> String? {
        var pages = Set<Int>()
        var notes = Set<UUID>()
        for item in ink {
            switch item.location {
            case .page(let index): pages.insert(index)
            case .note(let id): notes.insert(id)
            }
        }
        guard !pages.isEmpty || !notes.isEmpty else { return nil }
        var parts: [String] = []
        if !pages.isEmpty {
            let numbers = pages.sorted().map { ($0 + 1).formatted(.number) }
            parts.append((pages.count == 1 ? "on page " : "on pages ") + list(numbers))
        }
        if !notes.isEmpty { parts.append("in \(BackupUIText.count(notes.count, "note", "notes"))") }
        return "The ink \(parts.joined(separator: " and ")) couldn’t be read, so it was kept as it was and not combined."
    }

    /// "a", "a and b", "a, b and c" (no serial comma, matching the owner's examples).
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

// MARK: - Undo Last Restore

nonisolated enum UndoRestoreLogic {
    static let rowTitle = "Undo Last Restore"

    /// "The restore on 14 Nov 2026 at 10:02 changed 1 book and added 2 books."
    static func rowDetail(_ record: RestoreSafetyRecord, dateText: (Date) -> String = BackupUIText.date) -> String {
        let changed = record.changedBooks.count
        let added = record.added.count
        var parts: [String] = []
        if changed > 0 { parts.append("changed \(BackupUIText.count(changed, "book", "books"))") }
        if added > 0 { parts.append("added \(BackupUIText.count(added, "book", "books"))") }
        let what = parts.isEmpty ? "changed nothing" : parts.joined(separator: " and ")
        return "The restore on \(dateText(record.createdAt)) \(what)."
    }

    /// The row's VoiceOver label.
    static func rowAccessibilityLabel(_ record: RestoreSafetyRecord, dateText: (Date) -> String = BackupUIText.date) -> String {
        "\(rowTitle). \(rowDetail(record, dateText: dateText))"
    }

    /// The confirmation before undoing: names the books, says that work done on the changed books
    /// since the restore is lost and that the books it added are removed.
    static func confirmation(_ record: RestoreSafetyRecord,
                             dateText: (Date) -> String = BackupUIText.date) -> RestorePreviewLogic.Confirmation {
        let changed = record.changedBooks.map(\.title)
        let added = record.added.map(\.title)
        let when = dateText(record.createdAt)
        var sentences: [String] = []
        if !changed.isEmpty {
            let list = BackupUIText.quotedList(changed)
            sentences.append(changed.count == 1
                ? "\(list) will go back to how it was before the restore on \(when). Anything done in it since then will be lost."
                : "\(list) will go back to how they were before the restore on \(when). Anything done in them since then will be lost.")
        }
        if !added.isEmpty {
            let list = BackupUIText.quotedList(added)
            sentences.append(added.count == 1
                ? "\(list), which the restore added, will be removed from the Library with its notes, highlights and ink."
                : "\(list), which the restore added, will be removed from the Library with their notes, highlights and ink.")
        }
        return RestorePreviewLogic.Confirmation(title: "Undo the Last Restore?", message: sentences.joined(separator: " "),
                                                confirmTitle: "Undo Restore")
    }

    /// After an undo: "1 book put back as it was, 2 books removed." plus each failure's message.
    static func resultLine(_ summary: RestoreSummary) -> String {
        var parts: [String] = []
        if !summary.restored.isEmpty {
            parts.append("\(BackupUIText.count(summary.restored.count, "book", "books")) put back as \(summary.restored.count == 1 ? "it was" : "they were")")
        }
        if !summary.removed.isEmpty {
            parts.append("\(BackupUIText.count(summary.removed.count, "book", "books")) removed")
        }
        var line = parts.isEmpty ? "Nothing was undone." : "Restore undone: \(parts.joined(separator: ", "))."
        if !summary.failures.isEmpty {
            line += " " + summary.failures.map(\.message).joined(separator: " ")
            line += " Undo Last Restore again to finish."
        }
        return line
    }
}

// MARK: - Books without their PDF

nonisolated enum MissingPDFText {
    static let badge = "PDF missing"
    static let locateTitle = "Locate PDF…"

    /// The Library cell's VoiceOver label with the missing state appended.
    static func cellAccessibilityLabel(_ base: String, isMissing: Bool) -> String {
        isMissing ? "\(base), \(badge)" : base
    }

    static func promptTitle(_ title: String) -> String { "“\(title)” Needs Its PDF" }

    static let promptMessage = "This book’s PDF isn’t on this iPad. Choose the original PDF to read it again; its notes, highlights and ink are kept, and the Notebook works without it."

    static let readerMessage = "The PDF for this book isn’t on this iPad. Choose the original PDF to read it; your notes, highlights and ink are safe, and the Notebook works without it."

    /// The file a converted book was made from, as the reader knows it.
    static func originalDescription(_ book: Book) -> String {
        book.originalFileName.map { "the file it was made from (“\($0)”)" } ?? "the file it was made from"
    }

    /// What choosing a converted book's original does, and the one thing that can differ.
    static func reconversionNote(_ book: Book) -> String {
        "Choose \(originalDescription(book)) and it is converted to a PDF again. If iPadOS has been updated since the book was made, some pages can come out differently."
    }

    /// The Library's prompt for a book without its PDF (a converted book is rebuilt from the
    /// file it was made from, not linked to a PDF).
    static func promptMessage(for book: Book) -> String {
        guard book.isConverted else { return promptMessage }
        return "This book’s PDF isn’t on this iPad. \(reconversionNote(book)) Its notes, highlights and ink are kept, and the Notebook works without it."
    }

    /// The reader's "Cannot Open Book" message for a book without its PDF.
    static func readerMessage(for book: Book) -> String {
        guard book.isConverted else { return readerMessage }
        return "The PDF for this book isn’t on this iPad. \(reconversionNote(book)) Your notes, highlights and ink are safe, and the Notebook works without it."
    }
}
