import Foundation
import ReaderCore

/// `-importFixture`'s importer: test scaffolding over the app's one `ImportService`, which
/// `AppEnvironment` owns and hands in. Every import (launch arguments, Files picker, drops,
/// "Open in") goes through that service, so fixtures exercise the real pipeline (preflight,
/// fingerprint, streamed copy, cover, dedupe, commit, and for other formats the Convert to PDF
/// request).
@MainActor
struct FixtureImporter {
    /// The app's import pipeline (not owned here).
    let service: ImportService

    init(service: ImportService) {
        self.service = service
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
