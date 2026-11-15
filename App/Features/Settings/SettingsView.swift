import SwiftUI

/// The in-app Settings sheet (iPadOS has no system Settings entry for Marginal, and there is no
/// `Settings.bundle`, so this is the one place for preferences). Opened from the Library's gear
/// button and from "Settings…" (⌘,) in any window (`WindowContext.showSettings()`).
///
/// Importing: the Supported Formats screen (`SupportedFormatsView`).
///
/// Appearance: the accent preset. Picking a swatch writes `AccentChoice.storageKey`; every
/// window's `AccentRoot` reads the same key, so all windows, this sheet and its preview change
/// at once.
///
/// Backup & Restore is a page of its own (`BackupScreen`); "Back Up & Restore…" in the menu bar
/// opens the sheet straight on it (`WindowContext.showBackupSettings()`).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WindowContext.self) private var window: WindowContext?
    /// Opens the Quick Guide in the window that presented Settings (`nil` in previews).
    var openQuickGuide: (() -> Void)?
    @AppStorage(AccentChoice.storageKey) private var storedAccent = AccentChoice.default.rawValue
    @State private var path: [SettingsPage]

    init(initialPage: SettingsPage? = nil, openQuickGuide: (() -> Void)? = nil) {
        _path = State(initialValue: initialPage.map { [$0] } ?? [])
        self.openQuickGuide = openQuickGuide
    }

    private var selection: AccentChoice { AccentChoice(storedValue: storedAccent) }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    AccentSwatchGrid(selection: selection) { storedAccent = $0.rawValue }
                        .padding(.vertical, Space.s)
                    AccentPreview()
                        .padding(.vertical, Space.s)
                    Button("Reset to \(AccentChoice.default.displayName)") {
                        storedAccent = AccentChoice.default.rawValue
                    }
                    .disabled(selection == .default)
                    .accessibilityIdentifier(AccessibilityID.Settings.reset)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("The accent colours buttons, selection and reading progress in every window. Highlights and notes keep their own colours.")
                }
                Section {
                    NavigationLink {
                        SupportedFormatsView()
                    } label: {
                        Label {
                            Text("Supported Formats", comment: "Settings: row that opens the list of file formats the app can import.")
                        } icon: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.SupportedFormats.settingsRow)
                } header: {
                    Text("Importing", comment: "Settings: header of the section about importing books and documents.")
                } footer: {
                    Text("What Tactile Texts can import, and what changes when a file is converted to PDF.",
                         comment: "Settings: line under the Supported Formats row.")
                }
                Section {
                    NavigationLink(value: SettingsPage.backup) {
                        Label("Backup & Restore", systemImage: "externaldrive")
                    }
                    .accessibilityIdentifier(AccessibilityID.Backup.settingsRow)
                } footer: {
                    Text("Back up your notes, highlights and ink to a file, a folder or a cloud service, and restore them on this or another iPad.")
                }
                Section {
                    Button("Open the Quick Guide") {
                        dismiss()
                        openQuickGuide?()
                    }
                    .accessibilityIdentifier(AccessibilityID.Onboarding.settingsOpenGuide)
                } header: {
                    Text("Help")
                } footer: {
                    Text("The Quick Guide is a six-page book that shows how notes, highlights and Markup work. If you deleted it, this brings it back.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.Settings.done)
                }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .backup: BackupScreen()
                }
            }
        }
        .environment(\.closeSettings, CloseSettingsAction { dismiss() })
        .onChange(of: window?.settingsPageRequestCount) { _, _ in
            if let page = window?.settingsPage, path != [page] { path = [page] }
        }
        .accessibilityIdentifier(AccessibilityID.Settings.sheet)
    }
}

/// A grid of the accent presets; the selected one carries a check.
private struct AccentSwatchGrid: View {
    let selection: AccentChoice
    let select: (AccentChoice) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: Space.m)], spacing: Space.m) {
            ForEach(AccentChoice.allCases) { choice in
                AccentSwatch(choice: choice, isSelected: choice == selection) { select(choice) }
            }
        }
    }
}

private struct AccentSwatch: View {
    let choice: AccentChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let theme = choice.theme
        Button(action: action) {
            VStack(spacing: Space.xs) {
                ZStack {
                    Circle().fill(theme.accent)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.bold))
                            .foregroundStyle(theme.onAccent)
                    }
                }
                .frame(width: Size.touch, height: Size.touch)
                .overlay {
                    Circle()
                        .strokeBorder(isSelected ? theme.accent : Color.clear, lineWidth: 2)
                        .padding(-4)
                }
                Text(choice.displayName)
                    .font(Typeface.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(choice.displayName)
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(AccessibilityID.Settings.accent(choice.rawValue))
    }
}

/// A live sample of the accent in the current environment: primary and tonal buttons, a
/// selected row and a progress bar. Used by Settings and the design-system gallery.
struct AccentPreview: View {
    @Environment(\.accentTheme) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Button("Resume") {}.buttonStyle(.marginalPrimary)
                Button("Open Notebook") {}.buttonStyle(.marginalTonal)
            }
            HStack {
                Image(systemName: "note.text")
                Text("5.2 The Characteristic Equation")
                Spacer(minLength: 0)
            }
            .font(Typeface.body)
            .foregroundStyle(accent.accent)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(accent.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            ReadingProgress(fraction: 0.42)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the \(accent.choice.displayName) accent")
        .accessibilityIdentifier(AccessibilityID.Settings.preview)
    }
}

#Preview { SettingsView() }
