import Foundation

extension AppEnvironment {
    /// The shared import pipeline.
    var importService: ImportService { fixtureImporter.service }

    /// The import pipeline, once launch work (the orphan sweep and `-importFixture` imports) has
    /// finished. Every import that starts from a window must go through this: the launch-time
    /// sweep removes `Books/<id>` directories that have no record, and an import committed
    /// while it runs could lose its directory. `ImportService` itself does not wait, because the
    /// launch task imports through it.
    func readyImportService() async -> ImportService {
        _ = await launchPlan()
        return importService
    }
}
