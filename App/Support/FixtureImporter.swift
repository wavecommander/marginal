import Foundation
import ReaderCore

/// `-importFixture`'s importer. Since WP3 it is a thin wrapper: every import (launch arguments,
/// Files picker, drops, "Open in") goes through the one `ImportService` it owns, so fixtures
/// exercise the real pipeline (preflight, fingerprint, streamed copy, cover, dedupe, commit, and
/// for other formats the Convert to PDF request).
///
/// The type name is kept for `AppEnvironment`; `service` is how the Library and the
/// incoming-document handler reach the shared `ImportService`.
@MainActor
struct FixtureImporter {
    let store: LibraryStore
    /// The app's one import pipeline.
    let service: ImportService

    init(store: LibraryStore, converters: ConverterRegistry = .standard) {
        self.store = store
        self.service = ImportService(store: store, converters: converters)
    }

    /// The converters for these launch options: `standard`, or with `-stubConverters` (DEBUG)
    /// the stub for every converted format.
    static func converters(for options: LaunchOptions) -> ConverterRegistry {
        #if DEBUG
        if options.stubConverters {
            return .withStubConverters(pageDelay: .milliseconds(options.stubConverterPageDelay ?? 0))
        }
        #endif
        return .standard
    }

    /// Imports (or finds) the file at `source`; it is copied, never moved or modified. A file
    /// that needs converting is converted at once with `confirmConversions` (Medium text size);
    /// otherwise it waits in an unaddressed conversion request (`ImportResult.conversionRequestID`)
    /// for the first window to show.
    func importFixture(at source: URL, confirmConversions: Bool) async -> ImportResult {
        await service.importFiles([source], convertWithoutAsking: confirmConversions ? ConversionOptions() : nil)[0]
    }
}
