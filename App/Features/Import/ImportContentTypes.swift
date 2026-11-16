import Foundation
import os
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
///
/// **Other apps' types.** A type the app declares itself (Kindle, DjVu, CBR, CBZ…) has no system
/// declaration, so any other installed app may declare the same extensions under a name of its
/// own, and the system may then call a `.mobi` file by that name instead of ours. The picker
/// would grey the file out. So `acceptable` also takes whatever types the system currently maps
/// to the extensions of `ImportFormatCatalog.declaredTypes`, read again every few seconds (an
/// app can be installed while this one runs). "Open in" cannot be widened this way: its types
/// are fixed in `Info.plist`.
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

    /// What the Files picker offers and a drop accepts: the two lists, then the types other
    /// apps have given the extensions of the app's own declared types.
    static var acceptable: [UTType] {
        othersTypes.withLock { cache in
            let now = Date()
            if let cached = cache, now.timeIntervalSince(cached.read) < othersTypesLifetime { return cached.types }
            let types = acceptable { UTType.types(tag: $0, tagClass: .filenameExtension, conformingTo: nil) }
            cache = (types, now)
            return types
        }
    }

    /// `acceptable`, with the system's answer to "which types have this extension" passed in.
    /// A type is added when it is declared (not a placeholder the system made up for an unknown
    /// extension) and nothing in the lists already takes it.
    static func acceptable(typesForExtension: (String) -> [UTType]) -> [UTType] {
        var types = importable + namedUnsupported
        for fileExtension in ImportFormatCatalog.declaredTypes.flatMap(\.fileExtensions) {
            for type in typesForExtension(fileExtension)
            where !type.isDynamic && !types.contains(where: { type.conforms(to: $0) }) {
                types.append(type)
            }
        }
        return types
    }

    /// How long one reading of other apps' types is used for.
    private static let othersTypesLifetime: TimeInterval = 5
    private static let othersTypes = OSAllocatedUnfairLock<(types: [UTType], read: Date)?>(initialState: nil)

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
