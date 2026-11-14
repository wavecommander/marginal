import Foundation
import ReaderCore

/// `-importFixture`'s importer. Since WP3 it is a thin wrapper: every import (launch arguments,
/// Files picker, drops, "Open in") goes through the one `ImportService` it owns, so fixtures
/// exercise the real pipeline (probe, fingerprint, streamed copy, cover, dedupe, commit).
///
/// The type name and signatures are kept for `AppEnvironment`; `service` is how the Library and
/// the incoming-PDF handler reach the shared `ImportService`.
@MainActor
struct FixtureImporter {
    let store: LibraryStore
    /// The app's one import pipeline.
    let service: ImportService

    init(store: LibraryStore) {
        self.store = store
        self.service = ImportService(store: store)
    }

    /// Imports (or finds) the PDF at `source`. The source is copied, never moved or modified.
    func importPDF(at source: URL) async throws -> Book {
        try await service.importPDF(at: source).book
    }
}
