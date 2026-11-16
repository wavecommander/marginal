import Foundation
import ReaderCore
import ReaderStore
import Testing
@testable import Marginal

/// What the app does when the library's store could not be opened: it runs on an empty stand-in
/// store, so nothing may treat that store as the reader's library.
@MainActor
struct StoreFailureTests {
    @Test func automaticBackupsAreNeverArmedOnTheStandInStore() {
        let environment = AppEnvironment(store: .inMemory(), launchOptions: LaunchOptions(arguments: ["app"]),
                                         libraryRecovery: LibraryRecovery(error: ReaderStoreError.libraryFromNewerVersion,
                                                                          rootDirectory: FileManager.default.temporaryDirectory))
        #expect(!environment.backupScheduler.isArmed)
    }

    @Test func automaticBackupsAreArmedWhenTheStoreOpened() throws {
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let environment = AppEnvironment(store: store, launchOptions: LaunchOptions(arguments: ["app"]))
        #expect(environment.storeErrorMessage == nil)
        #expect(environment.backupScheduler.isArmed)
    }
}
