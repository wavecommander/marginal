import Foundation
import Testing
@testable import TactileTexts

/// The Include PDFs choice is one stored value shared by every backup (the backup-file switch,
/// each destination's switch and the automatic backup's switch all bind to it).
@MainActor
struct BackupIncludePDFsTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "BackupIncludePDFsTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func isOnUntilTheReaderTurnsItOff() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(BackupAutomaticSettings(defaults: defaults).includesPDFs)
    }

    @Test func oneStoredValueIsSeenByEveryReaderOfTheSettings() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BackupAutomaticSettings(defaults: defaults)
        settings.includesPDFs = false
        #expect(defaults.object(forKey: BackupAutomaticSettings.Key.includesPDFs) as? Bool == false)
        // Another window's screens, and the next launch, read the same value.
        #expect(!BackupAutomaticSettings(defaults: defaults).includesPDFs)
        settings.includesPDFs = true
        #expect(BackupAutomaticSettings(defaults: defaults).includesPDFs)
    }

    @Test func theChoiceIsNotTiedToAutomaticBackupsBeingOn() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BackupAutomaticSettings(defaults: defaults)
        settings.includesPDFs = false
        settings.isEnabled = true
        settings.isEnabled = false
        #expect(!BackupAutomaticSettings(defaults: defaults).includesPDFs)
    }

    @Test func aResetPutsItBackOn() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        BackupAutomaticSettings(defaults: defaults).includesPDFs = false
        BackupAutomaticSettings.reset(in: defaults)
        #expect(BackupAutomaticSettings(defaults: defaults).includesPDFs)
    }

    @Test func noScreenKeepsItsOwnCopyOfTheChoice() throws {
        // The per-screen keys the first version used must not come back: a second stored copy is
        // exactly how two switches end up disagreeing.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Features/Backup/UI", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("@AppStorage(\"backup.file.includePDFs\")"), "\(file.lastPathComponent)")
            #expect(!source.contains(".includePDFs\")"), "\(file.lastPathComponent) stores its own Include PDFs value")
        }
    }
}
