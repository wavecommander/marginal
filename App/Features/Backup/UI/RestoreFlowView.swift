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
                    ForEach(model.selectedWithActions, id: \.item.id) { entry in
                        if let action = RestorePreviewLogic.restoringActionText(entry.item, action: entry.action) {
                            LabeledContent(entry.item.entry.book.title, value: action)
                        } else {
                            Text(entry.item.entry.book.title)
                        }
                    }
                }
            }
        case .finished(let summary):
            RestoreSummaryForm(summary: summary, canBeUndone: model.restoreCanBeUndone)
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
                Button(model.restoreButtonTitle) { model.requestRestore() }
                    .disabled(model.actions.isEmpty || environment.backupService.isBusy)
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

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(failure.message)
                .accessibilityIdentifier(AccessibilityID.Restore.error)
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
                    RestoreItemRow(item: item, isSelected: model.choices.isSelected(item.id),
                                   row: RestorePreviewLogic.row(item, choices: model.choices,
                                                                restorePDFs: model.offersRestorePDFs ? model.restorePDFs : true,
                                                                preview: model.mergePreviews[item.id],
                                                                previewsLoaded: model.mergePreviewsLoaded),
                                   toggle: { model.toggle(item.id) },
                                   choose: { model.choose($0, for: item.id) })
                }
            } header: {
                Text("Books")
            } footer: {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(RestorePreviewLogic.booksFooter(hasExistingBooks: plan.items.contains { $0.status == .inLibrary }))
                    if model.anyMerge {
                        Label(RestorePreviewLogic.mergeFootnote, systemImage: "arrow.uturn.backward.circle")
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier(AccessibilityID.Restore.mergeFootnote)
                    }
                }
            }

            if model.offersRestorePDFs {
                // Each book's row says where its PDF comes from, so the switch needs no footer.
                Section {
                    Toggle("Restore PDFs", isOn: $model.restorePDFs)
                        .accessibilityIdentifier(AccessibilityID.Restore.restorePDFs)
                }
            }
        }
    }
}

/// One book of the preview: checkbox, title, New / Already in Library, where the PDF comes from
/// and, for a book already here, the Merge / Replace with Backup / Leave as Is menu, both sides
/// and what the choice does.
private struct RestoreItemRow: View {
    let item: RestorePlan.Item
    let isSelected: Bool
    let row: RestorePreviewLogic.Row
    let toggle: () -> Void
    let choose: (RestoreRowChoice) -> Void

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
            .accessibilityValue(RestorePreviewLogic.tickValue(isSelected: isSelected))
            .accessibilityAddTraits(isSelected ? [.isToggle, .isSelected] : .isToggle)
            .accessibilityHint(RestorePreviewLogic.tickHint(isSelected: isSelected, isExisting: item.status == .inLibrary,
                                                                 canMerge: !item.hasDifferentConversion))
            .accessibilityIdentifier(AccessibilityID.Restore.book(title))

            VStack(alignment: .leading, spacing: Space.xs) {
                // A book already here: the choice and what it does come first.
                if let choice = row.menuChoice {
                    actionMenu(choice)
                    note
                }
                if let pdf = row.pdfLine {
                    Text(pdf)
                        .accessibilityIdentifier(AccessibilityID.Restore.pdfSource(title))
                }
                ForEach(Array(row.sideLines.enumerated()), id: \.offset) { Text($0.element) }
                if row.menuChoice == nil { note }
            }
            .font(Typeface.caption)
            .foregroundStyle(Palette.inkSecondary)
            .padding(.leading, checkboxWidth + Space.m)
        }
        .padding(.vertical, Space.xs)
        // The separator starts under the title, whatever the first label in the row is.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + checkboxWidth + Space.m }
    }

    /// The standard menu: the current choice with up-and-down chevrons; the three choices, the
    /// current one checked.
    private func actionMenu(_ choice: RestoreRowChoice) -> some View {
        Menu {
            Picker(selection: Binding(get: { choice }, set: { choose($0) })) {
                ForEach(RestoreRowChoice.choices(for: item)) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            } label: {
                Text(RestorePreviewLogic.menuAccessibilityLabel(title: title))
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            // The current choice in the accent with the system's up-and-down chevrons, lined up
            // with the lines below it (a menu-style picker would add its own inset).
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(choice.title)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .font(Typeface.control)
            .foregroundStyle(accentTheme.accent)
            .frame(minHeight: Size.touch)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityLabel(RestorePreviewLogic.menuAccessibilityLabel(title: title))
        .accessibilityValue(choice.title)
        .accessibilityIdentifier(AccessibilityID.Restore.action(title))
    }

    @ViewBuilder
    private var note: some View {
        switch row.note {
        case .none:
            EmptyView()
        case .counts(let text):
            Text(text)
        case .merge(let text, let isLoading):
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                if isLoading { ProgressView().controlSize(.small) }
                Text(text).foregroundStyle(Palette.ink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Restore.mergeText(title))
        case .replaceWarning(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.margin)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.Restore.replaceWarning(title))
        case .leave(let text):
            Text(text)
                .accessibilityIdentifier(AccessibilityID.Restore.leaveText(title))
        }
    }
}

// MARK: - Summary

private struct RestoreSummaryForm: View {
    let summary: RestoreSummary
    /// The restore kept a safety copy: say that Undo Last Restore can put things back.
    let canBeUndone: Bool

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
                if canBeUndone {
                    Text(RestorePreviewLogic.undoHint)
                        .font(Typeface.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.Restore.undoHint)
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

            if !summary.merged.isEmpty {
                Section("Merged") {
                    ForEach(summary.merged) { book in
                        Label {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(book.title).font(.headline)
                                ForEach(Array(MergeText.summaryLines(book).enumerated()), id: \.offset) { line in
                                    Text(line.element)
                                        .font(Typeface.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "arrow.triangle.merge")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(AccessibilityID.Restore.merged(book.title))
                    }
                }
            }

            let restored = RestorePreviewLogic.plainlyRestored(summary, linked: linked)
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
