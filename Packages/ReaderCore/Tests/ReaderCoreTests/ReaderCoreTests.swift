import Testing
@testable import ReaderCore

@Test func packageBuilds() {
    #expect(ReaderCore.schemaVersion == 1)
}
