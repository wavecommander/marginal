import ReaderBackup
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The recovery key, to write down or save: its 14 groups in a monospaced, selectable block,
/// Copy, Share or Save…, and "I’ve Saved It", which records that the reader saved it. As a
/// prompt (`isPrompt`), it follows the first backup, which made the key.
struct CloudRecoveryKeyScreen: View {
    let account: CloudBackupAccount
    let isPrompt: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var key: BackupRecoveryKey?
    @State private var loadError: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(isPrompt ? CloudBackupRecoveryKeyText.promptIntro : CloudBackupRecoveryKeyText.explanation)
                }
                if let key {
                    keySection(key)
                    actionsSection(key)
                } else if let loadError {
                    Section {
                        Text(loadError).foregroundStyle(.secondary)
                    }
                } else {
                    Section { ProgressView() }
                }
            }
            .navigationTitle(isPrompt ? "Save Your Recovery Key" : "Recovery Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isPrompt && !account.recoveryKeySaved ? "Not Now" : "Close") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.CloudBackup.keyClose)
                }
            }
            .accessibilityIdentifier(AccessibilityID.CloudBackup.keyScreen)
        }
        .task {
            do {
                key = try await account.recoveryKey()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func keySection(_ key: BackupRecoveryKey) -> some View {
        let groups = CloudBackupRecoveryKeyText.groups(key.formatted)
        return Section {
            ViewThatFits(in: .horizontal) {
                keyText(groups, perLine: 7)
                keyText(groups, perLine: 4)
                keyText(groups, perLine: 2)
                keyText(groups, perLine: 1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.s)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recovery key")
            .accessibilityValue(Text(CloudBackupRecoveryKeyText.spoken(groups)).speechSpellsOutCharacters())
            .accessibilityIdentifier(AccessibilityID.CloudBackup.keyText)
        } footer: {
            Text("\(BackupRecoveryKey.characterCount) characters in \(groups.count) groups. Upper or lower case, spaces and dashes don’t matter when you type it.")
        }
    }

    private func keyText(_ groups: [String], perLine: Int) -> some View {
        Text(CloudBackupRecoveryKeyText.lines(groups, perLine: perLine))
            .font(.system(.title3, design: .monospaced, weight: .medium))
            .multilineTextAlignment(.center)
            .lineSpacing(Space.xs)
            .fixedSize()
            .textSelection(.enabled)
    }

    private func actionsSection(_ key: BackupRecoveryKey) -> some View {
        Section {
            Button {
                UIPasteboard.general.string = key.formatted
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityIdentifier(AccessibilityID.CloudBackup.keyCopy)
            ShareLink(item: CloudRecoveryKeyDocument(text: CloudBackupRecoveryKeyText.document(key.formatted)),
                      preview: SharePreview("Tactile Texts Cloud Recovery Key")) {
                Label("Share or Save…", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier(AccessibilityID.CloudBackup.keyShare)
            if account.recoveryKeySaved {
                Label("You’ve saved this recovery key.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    account.markRecoveryKeySaved()
                    dismiss()
                } label: {
                    Label("I’ve Saved It", systemImage: "checkmark.circle")
                        .font(Typeface.control)
                }
                .accessibilityIdentifier(AccessibilityID.CloudBackup.keySaved)
            }
        } footer: {
            Text(DeviceKind.current.pick(
                iPad: "Save it somewhere other than this iPad, for example in a password manager or on paper.",
                iPhone: "Save it somewhere other than this iPhone, for example in a password manager or on paper."))
        }
    }
}

/// The recovery key as a small text file for the share sheet (Save to Files, a password
/// manager, AirDrop, Print).
struct CloudRecoveryKeyDocument: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { Data($0.text.utf8) }
            .suggestedFileName("Tactile Texts Cloud Recovery Key.txt")
    }
}

/// Enter Recovery Key, for backups this iPad can't read without it. Forgiving input (case,
/// spaces and dashes don't matter); every refusal says what was wrong. When this iPad has no key
/// at all, it says first that the key may still be on its way through iCloud Keychain and offers
/// Try Again. "I’ve Lost My Recovery Key" deletes everything, the only way to start over.
struct CloudEnterRecoveryKeyScreen: View {
    let model: CloudBackupScreenModel

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?
    /// The key the error is about (`CloudBackupRecoveryKeyText.normalized`): the error stays
    /// until the key itself changes, not when the field merely reports the same text again.
    @State private var errorKey: String?
    @State private var isChecking = false
    @State private var isStartOverPresented = false
    @FocusState private var fieldFocused: Bool

    private var account: CloudBackupAccount { model.account }

    private var stillNeedsKey: Bool {
        if case .needsRecoveryKey = account.status { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                if account.status == .needsRecoveryKey(.noKeyOnThisDevice) {
                    Section {
                        Label {
                            Text(CloudBackupRecoveryKeyText.arrivingNote)
                        } icon: {
                            Image(systemName: "key.icloud").foregroundStyle(.tint)
                        }
                        Button("Try Again") { Task { await model.refresh() } }
                            .disabled(account.isRefreshing || isChecking)
                            .accessibilityIdentifier(AccessibilityID.CloudBackup.enterTryAgain)
                    }
                }
                Section {
                    TextField("Recovery key", text: $text, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .lineLimit(2...6)
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit(submit)
                        .accessibilityIdentifier(AccessibilityID.CloudBackup.enterField)
                    Text(CloudBackupRecoveryKeyText.progress(text))
                        .font(Typeface.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.CloudBackup.enterProgress)
                    if let errorMessage {
                        Label {
                            Text(errorMessage)
                        } icon: {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.red)
                        }
                        .font(Typeface.caption)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(AccessibilityID.CloudBackup.enterError)
                    }
                    Button(action: submit) {
                        HStack(spacing: Space.s) {
                            Text("Use This Recovery Key")
                            if isChecking { ProgressView() }
                        }
                    }
                    .disabled(CloudBackupRecoveryKeyText.typedCount(text) == 0 || isChecking || model.isDeleting)
                    .accessibilityIdentifier(AccessibilityID.CloudBackup.enterSubmit)
                } header: {
                    Text("Recovery Key")
                } footer: {
                    Text(CloudBackupRecoveryKeyText.enterIntro)
                }
                Section {
                    if model.isDeleting {
                        HStack(spacing: Space.s) {
                            ProgressView()
                            Text("Deleting your cloud backups…").foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        Button("I’ve Lost My Recovery Key: Start Over…", role: .destructive) { isStartOverPresented = true }
                            .disabled(isChecking)
                            .accessibilityIdentifier(AccessibilityID.CloudBackup.enterStartOver)
                    }
                } footer: {
                    Text("Starting over deletes every backup kept in \(CloudServiceError.serviceName). Nobody can open them without the recovery key.")
                }
            }
            .navigationTitle("Enter Recovery Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.CloudBackup.enterCancel)
                }
            }
            .accessibilityIdentifier(AccessibilityID.CloudBackup.enterScreen)
            .onChange(of: text) { _, new in
                if CloudBackupRecoveryKeyText.normalized(new) != errorKey { errorMessage = nil }
            }
            .onChange(of: stillNeedsKey) { _, needs in
                // The key arrived through iCloud Keychain, or was entered here.
                if !needs { dismiss() }
            }
            .alert(CloudBackupRecoveryKeyText.startOverTitle, isPresented: $isStartOverPresented) {
                Button("Delete Everything and Start Over", role: .destructive) {
                    Task {
                        if await model.deleteEverything() { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(CloudBackupRecoveryKeyText.startOverMessage)
            }
        }
        .interactiveDismissDisabled(isChecking || model.isDeleting)
    }

    private func submit() {
        guard CloudBackupRecoveryKeyText.typedCount(text) > 0, !isChecking else { return }
        let typed = text
        errorMessage = nil
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                try await account.adoptRecoveryKey(typed)
                await model.destination.refresh()
                dismiss()
            } catch is CancellationError {
                // Stopped: nothing to say.
            } catch {
                errorKey = CloudBackupRecoveryKeyText.normalized(typed)
                errorMessage = CloudBackupRecoveryKeyText.entryError(error, typed: typed)
                fieldFocused = true
            }
        }
    }
}
