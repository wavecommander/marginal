import Darwin
import Foundation
import PDFKit
import ReaderCore
import ReaderStore
import Testing
@testable import TactileTexts

/// Every search test lives under this suite. It is serialised because the engine's resource
/// counters (`SearchDiagnostics`) are process-wide: a test that asserts "no worker and no document
/// left" must not see another test's search.
@Suite(.serialized)
@MainActor
struct SearchTests {}

/// Fixtures and waits shared by the search suites (`scripts/test.sh` generates the PDFs first).
@MainActor
enum SearchTestSupport {
    struct Fixture {
        let store: LibraryStore
        let book: Book
        let url: URL

        @MainActor func cleanUp() {
            try? FileManager.default.removeItem(at: store.rootDirectory)
        }
    }

    static let fixturesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/out")

    /// An ephemeral store holding one book: a copy of a generated fixture.
    static func makeFixture(_ name: String, pages: Int) throws -> Fixture {
        let store = try LibraryStore.ephemeral()
        let book = Book(title: name, fingerprint: "test-\(UUID().uuidString)", fileName: name, pageCount: pages,
                        fileSize: 1)
        try store.books.save(book)
        let url = store.documentURL(for: book)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixturesDir.appendingPathComponent(name), to: url)
        return Fixture(store: store, book: book, url: url)
    }

    /// A session without the PDF view's feature controllers (no on-screen view is needed).
    static func makeSession(_ fixture: Fixture) -> ReaderSession {
        var configuration = ReaderSession.Configuration()
        configuration.installsFeatures = false
        configuration.notebookRebuildDelay = .milliseconds(10)
        return ReaderSession(book: fixture.book, store: fixture.store, configuration: configuration)
    }

    /// Opens the session's document and waits for its outline.
    static func openAndWaitForOutline(_ session: ReaderSession) async -> Bool {
        session.open()
        return await waitUntil { session.isOutlineLoaded }
    }

    /// A model that searches as soon as the query is set.
    static func makeModel(_ session: ReaderSession, hitCap: Int = PDFTextSearch.defaultHitCap,
                          pageDelay: Duration = .zero) -> SearchModel {
        let model = SearchModel(session: session, hitCap: hitCap, pageDelay: pageDelay)
        model.debounce = .zero
        return model
    }

    /// Polls `condition` every 10 ms until it holds or `timeout` seconds pass.
    static func waitUntil(timeout: Double = 30, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Waits until the engine has no live worker and no open document.
    static func waitUntilEngineIdle(timeout: Double = 3) async -> Bool {
        await waitUntil(timeout: timeout) {
            let snapshot = SearchDiagnostics.snapshot
            return snapshot.liveWorkers == 0 && snapshot.liveDocuments == 0
        }
    }

    /// Process memory charged to the app (what jetsam counts), in MB.
    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// The machine's 1-minute load average (recorded beside timings).
    nonisolated static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : -1
    }
}
