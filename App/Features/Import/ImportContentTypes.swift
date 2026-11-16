import Foundation
import ReaderCore
import UniformTypeIdentifiers

/// The content types the Files picker and drops accept: every importable format, plus the kinds
/// the app names when it turns them down (Kindle, DjVu, CBR, spreadsheets). Both lists come from
/// the one list of formats (`ImportFormat.typeIdentifiers`, `UnsupportedImportFormat` in
/// ReaderCore). What a file really is is decided afterwards by `ImportFormatDetector`; these only
/// decide what can be chosen or dropped.
///
/// Types without a system declaration are declared in `project.yml`
/// (`UTImportedTypeDeclarations`), and the importable ones are its `CFBundleDocumentTypes` for
/// "Open in"; `ImportFormatCatalogTests` fails when `Info.plist` and the list disagree.
nonisolated enum ImportContentTypes {
    /// The type an identifier of the list names: the declared one, or, on a device that has no
    /// declaration for it, a placeholder of that name.
    private static func type(_ identifier: String) -> UTType {
        UTType(identifier) ?? UTType(importedAs: identifier)
    }

    /// Formats the app imports (as they are, or by converting).
    static let importable: [UTType] = ImportFormatCatalog.importableTypeIdentifiers.map(type)

    /// Formats the app recognises and turns down by name.
    static let namedUnsupported: [UTType] = ImportFormatCatalog.namedUnsupportedTypeIdentifiers.map(type)

    /// What the Files picker offers and a drop accepts.
    static let acceptable: [UTType] = importable + namedUnsupported

    /// The type identifier to load a dropped item as: the first one it offers that conforms to
    /// an acceptable type, or `nil` when it offers none.
    static func loadableTypeIdentifier(among registered: [String]) -> String? {
        registered.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return acceptable.contains { type.conforms(to: $0) }
        }
    }
}

/// A drop on the Library: every item is adopted (moved out of the system's temporary file into
/// the drop landing area) and the whole drop is imported as one batch, so one Convert to PDF
/// sheet covers it.
nonisolated enum DropImport {
    /// The providers that carry something the app can take.
    static func acceptedProviders(_ providers: [NSItemProvider]) -> [NSItemProvider] {
        providers.filter { ImportContentTypes.loadableTypeIdentifier(among: $0.registeredTypeIdentifiers) != nil }
    }

    /// Adopts each provider's file into `directory` (in `drop-…` folders), in provider order.
    /// Items that cannot be loaded are skipped. The file work happens on the item provider's own
    /// callback queue, never on the caller's actor.
    static func adopt(_ providers: [NSItemProvider], into directory: URL) async -> [URL] {
        var adopted: [URL] = []
        for provider in providers {
            if let url = await adoptOne(provider, into: directory) { adopted.append(url) }
        }
        return adopted
    }

    private static func adoptOne(_ provider: NSItemProvider, into directory: URL) async -> URL? {
        guard let type = ImportContentTypes.loadableTypeIdentifier(among: provider.registeredTypeIdentifiers) else {
            return nil
        }
        let name = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                // The system deletes `url` when this returns: take it now.
                let adopted = url.flatMap {
                    try? ImportPipeline.adoptDroppedFile($0, suggestedName: name, typeIdentifier: type, into: directory)
                }
                continuation.resume(returning: adopted)
            }
        }
    }
}
