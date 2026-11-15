import Testing
@testable import GoogleDriveKit

struct GoogleDriveScopeTests {
    @Test func asksOnlyForPerFileAccess() {
        #expect(GoogleDriveScope.driveFile == "https://www.googleapis.com/auth/drive.file")
    }
}
