import SwiftUI

/// What a running backup or restore says about itself.
enum BackupJobText {
    /// "Backing Up", "Backing Up to iCloud", "Opening Backup", "Restoring".
    static func title(_ kind: BackupJob.Kind) -> String {
        switch kind {
        case .backUpToFile: "Making Backup File"
        case .backUpToDestination(let name): "Backing Up to \(name)"
        case .openBackup: "Opening Backup"
        case .restore: "Restoring"
        }
    }

    static func phase(_ phase: BackupJob.Phase) -> String {
        switch phase {
        case .preparing: "Preparing…"
        case .savingOpenBooks: "Saving open books…"
        case .checkingSpace: "Checking free space…"
        case .hashingPDFs: "Checking PDFs…"
        case .writingBackup: "Writing backup…"
        case .uploadingPDFs: "Uploading PDFs…"
        case .uploadingBackup: "Uploading backup…"
        case .removingOldBackups: "Removing old backups…"
        case .downloading: "Downloading backup…"
        case .reading: "Reading backup…"
        case .extracting: "Checking books…"
        case .committing: "Putting books into the Library…"
        case .cleaningUp: "Finishing…"
        }
    }

    /// Whether Cancel still means anything: not once a restore is swapping books in (the engine
    /// finishes that step), and not once a backup has been stored (only clean-up is left).
    static func canCancel(kind: BackupJob.Kind, phase: BackupJob.Phase) -> Bool {
        switch phase {
        case .committing, .cleaningUp: false
        case .removingOldBackups: false
        default: true
        }
    }

    /// The status line: phase and percentage, or why Cancel is gone.
    static func status(kind: BackupJob.Kind, phase: BackupJob.Phase, fraction: Double) -> String {
        let percent = "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
        if !canCancel(kind: kind, phase: phase), case .restore = kind {
            return "\(Self.phase(phase)) \(percent). This can’t be cancelled now."
        }
        return "\(Self.phase(phase)) \(percent)"
    }
}

/// The running backup or restore: title, phase and percentage, a progress bar and Cancel. Used in
/// place on the Backup screens and the restore sheet; `compact` is the Library's row.
struct BackupJobProgressView: View {
    let job: BackupJob
    var compact = false

    var body: some View {
        let canCancel = BackupJobText.canCancel(kind: job.kind, phase: job.phase)
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs + 2) {
                Text(BackupJobText.title(job.kind))
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(2)
                Text(BackupJobText.status(kind: job.kind, phase: job.phase, fraction: job.fraction))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.Backup.progressStatus)
                ProgressView(value: job.fraction)
                    .accessibilityLabel(BackupJobText.title(job.kind))
                    .accessibilityValue("\(Int((job.fraction * 100).rounded())) percent")
            }
            if compact {
                Button(role: .cancel) {
                    job.cancel()
                } label: {
                    Label("Cancel \(BackupJobText.title(job.kind))", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(minWidth: Size.touch, minHeight: Size.touch)
                }
                .buttonStyle(.borderless)
                .disabled(!canCancel || job.isCancelled)
                .accessibilityIdentifier(AccessibilityID.Backup.progressCancel)
            } else {
                Button("Cancel", role: .cancel) { job.cancel() }
                    .buttonStyle(.bordered)
                    .disabled(!canCancel || job.isCancelled)
                    .accessibilityIdentifier(AccessibilityID.Backup.progressCancel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Backup.progress)
    }
}

/// The Library's row for the app's running backup or restore (beside import rows).
struct LibraryBackupProgressRow: View {
    let job: BackupJob

    var body: some View {
        BackupJobProgressView(job: job, compact: true)
            .padding(Space.m)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier(AccessibilityID.Library.backupProgress)
    }
}
