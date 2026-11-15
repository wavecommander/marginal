import ReaderBackup
import ReaderCore
import SwiftUI

/// The restore sheet for one backup: opening it, the per-book preview, progress and the
/// summary. Presented by the Backup screen (from a file or a destination's backup), by a window
/// receiving a `.ttbackup` ("Open in"), and by the empty Library's "Restore from Backup…".
struct RestoreFlowView: View {
    let request: RestoreRequest

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: RestoreFlowModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    RestoreFlowContent(model: model, close: { dismiss() })
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(model?.isRestoring == true)
        .onAppear {
            guard model == nil else { return }
            let model = RestoreFlowModel(request: request, service: environment.backupService, store: environment.store)
            self.model = model
            model.start()
        }
        .onDisappear { model?.dismissed() }
        .onChange(of: model?.shouldClose == true) { _, close in if close { dismiss() } }
        .accessibilityIdentifier(AccessibilityID.Restore.sheet)
    }
}

private struct RestoreFlowContent: View {
    @Bindable var model: RestoreFlowModel
    let close: () -> Void

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        content
            .navigationTitle(title)
            .toolbar { toolbar }
            .alert(model.confirmation?.title ?? "", isPresented: confirmationBinding, presenting: model.confirmation) { confirmation in
                Button(confirmation.confirmTitle, role: .destructive) { model.restore() }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message)
            }
    }

    private var title: String {
        switch model.stage {
        case .opening: "Opening Backup"
        case .preview: "Restore"
        case .restoring: "Restoring"
        case .finished: "Restore Finished"
        case .failed(let failure): failure.title
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .opening:
            OpeningView(job: environment.backupService.job)
        case .preview:
            if let plan = model.plan, let session = model.session {
                RestorePreviewForm(model: model, plan: plan, manifest: session.manifest)
            }
        case .restoring:
            Form {
                if let job = environment.backupService.job {
                    Section { BackupJobProgressView(job: job) }
                }
                Section("Restoring") {
                    ForEach(model.selectedItems) { Text($0.entry.book.title) }
                }
            }
        case .finished(let summary):
            RestoreSummaryForm(summary: summary)
        case .failed(let failure):
            FailedView(failure: failure)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch model.stage {
        case .opening:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.cancelOpening() }
                    .accessibilityIdentifier(AccessibilityID.Restore.cancel)
            }
        case .preview:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: close)
                    .accessibilityIdentifier(AccessibilityID.Restore.cancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(RestorePreviewLogic.restoreButtonTitle(count: model.selection.count)) { model.requestRestore() }
                    .disabled(model.selection.isEmpty || environment.backupService.isBusy)
                    .accessibilityIdentifier(AccessibilityID.Restore.confirm)
            }
        case .restoring:
            ToolbarItem(placement: .cancellationAction) { EmptyView() }
        case .finished, .failed:
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: close)
                    .accessibilityIdentifier(AccessibilityID.Restore.done)
            }
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } })
    }
}

// MARK: - Opening and failure

private struct OpeningView: View {
    let job: BackupJob?

    var body: some View {
        Form {
            Section {
                if let job, job.kind == .openBackup {
                    BackupJobProgressView(job: job)
                } else {
                    HStack(spacing: Space.m) {
                        ProgressView()
                        Text("Opening the backup…")
                    }
                }
            } footer: {
                Text("Nothing changes in your Library until you choose what to restore.")
            }
        }
        .accessibilityIdentifier(AccessibilityID.Restore.opening)
    }
}

private struct FailedView: View {
    let failure: BackupFailure

    @Environment(AppEnvironment.self) private var environment
    @Environment(WindowContext.self) private var window: WindowContext?
    @State private var signInFailure: BackupFailure?

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(failure.message)
                .accessibilityIdentifier(AccessibilityID.Restore.error)
        } actions: {
            if failure.offersSignIn, environment.googleDriveAccount.state != .notSetUp {
                Button("Sign In…") { signIn() }
                    .buttonStyle(.bordered)
                    .disabled(environment.googleDriveAccount.isSigningIn)
            }
        }
        .alert(signInFailure?.title ?? "", isPresented: Binding(get: { signInFailure != nil }, set: { if !$0 { signInFailure = nil } }),
               presenting: signInFailure) { _ in Button("OK", role: .cancel) {} } message: { Text($0.message) }
    }

    private func signIn() {
        guard let anchor = window?.presentationAnchor else { return }
        Task {
            do { try await environment.googleDriveAccount.signIn(anchor: anchor) } catch {
                signInFailure = BackupFailure.from(error, title: "Couldn’t Sign In")
            }
        }
    }
}

// MARK: - Preview

private struct RestorePreviewForm: View {
    @Bindable var model: RestoreFlowModel
    let plan: RestorePlan
    let manifest: BackupManifest

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(RestorePreviewLogic.headerLine(createdAt: manifest.createdAt, deviceName: manifest.deviceName))
                        .font(.headline)
                    Text(model.sourceLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(BackupUIText.count(plan.items.count, "book", "books") + " in this backup")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.Restore.header)
            }

            Section {
                if plan.items.isEmpty {
                    Text("This backup has no books.").foregroundStyle(.secondary)
                }
                ForEach(plan.items) { item in
                    RestoreItemRow(item: item, isSelected: model.selection.contains(item.id),
                                   restorePDFs: model.offersRestorePDFs ? model.restorePDFs : true) {
                        model.toggle(item.id)
                    }
                }
            } header: {
                Text("Books")
            } footer: {
                Text("New books are ticked. A book already in your Library is left as it is unless you tick it.")
            }

            if model.offersRestorePDFs {
                Section {
                    Toggle("Restore PDFs", isOn: $model.restorePDFs)
                        .accessibilityIdentifier(AccessibilityID.Restore.restorePDFs)
                } footer: {
                    Text("Off: a book whose PDF is already on this iPad keeps it; the others come back without their PDF, to be linked later with Locate PDF….")
                }
            }
        }
    }
}

/// One book of the preview: checkbox, title, New / Already in Library, where the PDF comes from
/// and, for a book already here, both sides and the replace warning.
private struct RestoreItemRow: View {
    let item: RestorePlan.Item
    let isSelected: Bool
    let restorePDFs: Bool
    let toggle: () -> Void

    @Environment(\.accentTheme) private var accentTheme
    /// The checkbox column; the details below line up with the title at every text size.
    @ScaledMetric(relativeTo: .title3) private var checkboxWidth: CGFloat = 24

    private var title: String { item.entry.book.title }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AnyShapeStyle(accentTheme.accent) : AnyShapeStyle(.secondary))
                        .frame(width: checkboxWidth)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(title)
                            .font(Typeface.heading)
                            .foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.leading)
                        Text(RestorePreviewLogic.statusText(item.status))
                            .font(Typeface.meta)
                            .foregroundStyle(item.status == .new ? AnyShapeStyle(accentTheme.accent) : AnyShapeStyle(Palette.inkSecondary))
                            .accessibilityIdentifier(AccessibilityID.Restore.status(title))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(RestorePreviewLogic.statusText(item.status))")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? [.isToggle, .isSelected] : .isToggle)
            .accessibilityHint("Double-tap to \(isSelected ? "leave this book out" : "restore this book").")
            .accessibilityIdentifier(AccessibilityID.Restore.book(title))

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(RestorePreviewLogic.pdfText(item, restorePDFs: restorePDFs))
                    .accessibilityIdentifier(AccessibilityID.Restore.pdfSource(title))
                if item.status == .inLibrary {
                    Text(RestorePreviewLogic.sideText(RestorePreviewLogic.backupSideLabel, counts: item.entry.counts,
                                                      modified: item.entry.lastModifiedAt))
                    ForEach(item.localMatches, id: \.book.id) { local in
                        Text(RestorePreviewLogic.sideText(RestorePreviewLogic.localSideLabel, counts: local.counts,
                                                          modified: local.lastModifiedAt))
                    }
                    Label(RestorePreviewLogic.replaceWarning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.margin)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(AccessibilityID.Restore.replaceWarning(title))
                } else {
                    Text(RestorePreviewLogic.countsText(item.entry.counts))
                }
            }
            .font(Typeface.caption)
            .foregroundStyle(Palette.inkSecondary)
            .padding(.leading, checkboxWidth + Space.m)
        }
        .padding(.vertical, Space.xs)
    }
}

// MARK: - Summary

private struct RestoreSummaryForm: View {
    let summary: RestoreSummary

    @Environment(AppEnvironment.self) private var environment
    @State private var locateTarget: Book?
    @State private var linked: Set<UUID> = []

    var body: some View {
        Form {
            Section {
                Text(RestorePreviewLogic.summaryHeadline(summary))
                    .font(Typeface.title)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(AccessibilityID.Restore.summary)
                if let dropped = RestorePreviewLogic.droppedNotesLine(summary.droppedEmptyNotes) {
                    Text(dropped).font(Typeface.caption).foregroundStyle(.secondary)
                }
            }

            let needing = summary.needingPDF.filter { !linked.contains($0.id) }
            if !needing.isEmpty {
                Section {
                    ForEach(needing) { book in
                        HStack {
                            Text(book.title)
                            Spacer(minLength: Space.s)
                            Button(MissingPDFText.locateTitle) { locate(book.id) }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier(AccessibilityID.Restore.locate(book.title))
                        }
                    }
                } header: {
                    Text("Need Their PDF")
                } footer: {
                    Text(RestorePreviewLogic.needsPDFExplanation)
                }
            }

            let restored = summary.restored.filter { $0.hasPDF || linked.contains($0.id) }
            if !restored.isEmpty {
                Section("Restored") {
                    ForEach(restored) { book in
                        Label(book.title, systemImage: "checkmark.circle")
                    }
                }
            }

            if !summary.failures.isEmpty {
                Section("Not Restored") {
                    ForEach(summary.failures) { failure in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(failure.title).font(.headline)
                            Text(failure.message).font(Typeface.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .locatePDF(for: $locateTarget) { book in linked.insert(book.id) }
    }

    private func locate(_ id: UUID) {
        locateTarget = try? environment.store.books.book(id: id)
    }
}
