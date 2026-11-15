import Testing
@testable import ReaderBackup

struct BackupFormatTests {
    @Test func constantsMatchTheAppConfiguration() {
        // project.yml declares the same identifier and extension for the exported type.
        #expect(BackupFormat.typeIdentifier == "software.tactile.marginal.backup")
        #expect(BackupFormat.fileExtension == "ttbackup")
        #expect(BackupFormat.currentVersion == 1)
    }
}
