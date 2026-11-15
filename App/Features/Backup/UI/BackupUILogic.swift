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
    /// Tactile Texts Cloud, the paid backup service.
    case tactileCloud
    /// Anything else (the test-only `-backupFolder` destination).
    case other

    init(id: String) {
        switch id {
        case PickedFolderBackupDestination.destinationID: self = .pickedFolder
        case ICloudBackupDestination.destinationID: self = .iCloud
        case GoogleDriveBackupDestination.destinationID: self = .googleDrive
        case S3BackupDestination.destinationID: self = .s3
        case TactileCloudBackupDestination.destinationID: self = .tactileCloud
        default: self = .other
        }
    }

    var systemImage: String {
        switch self {
        case .pickedFolder, .other: "folder"
        case .iCloud: "icloud"
        case .googleDrive: "cloud"
        case .s3: "server.rack"
        case .tactileCloud: "lock.icloud"
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

// MARK: - Restore preview

nonisolated enum RestorePreviewLogic {
    /// The books ticked when the preview opens (`RestorePlan.Item.isSelectedByDefault`).
    static func initialSelection(_ plan: RestorePlan) -> Set<UUID> {
        Set(plan.items.filter(\.isSelectedByDefault).map(\.id))
    }

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

    /// Said on every book already in the Library.
    static let replaceWarning = "Restoring replaces this book’s notes, highlights, bookmarks and ink on this iPad with the backup’s."

    /// Where the book's PDF will come from, as the reader sees it.
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

    /// "Restore 1 Book", "Restore 3 Books"; "Restore" with nothing ticked.
    static func restoreButtonTitle(count: Int) -> String {
        switch count {
        case 0: "Restore"
        case 1: "Restore 1 Book"
        default: "Restore \(count.formatted(.number)) Books"
        }
    }

    struct Confirmation: Equatable, Sendable {
        var title: String
        var message: String
        var confirmTitle: String
    }

    /// The confirmation needed before restoring `selected`: `nil` unless a ticked book replaces
    /// one in the Library; then it names those books.
    static func confirmation(selected: [RestorePlan.Item]) -> Confirmation? {
        let replacing = selected.filter { $0.status == .inLibrary }
        guard !replacing.isEmpty else { return nil }
        let titles = BackupUIText.quotedList(replacing.map(\.entry.book.title))
        let title = replacing.count == 1 ? "Replace “\(replacing[0].entry.book.title)”?"
            : "Replace \(replacing.count.formatted(.number)) Books?"
        let message = "Restoring replaces the notes, highlights, bookmarks and ink of \(titles) on this iPad with the backup’s. What is there now can’t be recovered afterwards."
        return Confirmation(title: title, message: message, confirmTitle: restoreButtonTitle(count: selected.count))
    }

    /// "Made 14 Nov 2026 at 10:02 on Ben’s iPad".
    static func headerLine(createdAt: Date, deviceName: String, dateText: (Date) -> String = BackupUIText.date) -> String {
        deviceName.isEmpty ? "Made \(dateText(createdAt))" : "Made \(dateText(createdAt)) on \(deviceName)"
    }

    /// "3 books restored, 1 needs its PDF".
    static func summaryHeadline(_ summary: RestoreSummary) -> String {
        guard !summary.restored.isEmpty else {
            return summary.failures.isEmpty ? "Nothing was restored" : "No books could be restored"
        }
        var line = "\(BackupUIText.count(summary.restored.count, "book", "books")) restored"
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

    static let needsPDFExplanation = "These books are back with their notes, highlights and ink, but not their PDFs. Choose each book’s original PDF to read it; you can also do this later from the book in the Library."
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
}
