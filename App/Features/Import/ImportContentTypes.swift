import Foundation
import UniformTypeIdentifiers

/// The content types the Files picker and drops accept, for every format in
/// docs/FORMAT_IMPORT_PLAN.md's table plus the formats the app names when it turns them down
/// (Kindle, DjVu, CBR, spreadsheets). What a file really is is decided afterwards by
/// `ImportFormatDetector`; these only decide what can be chosen or dropped.
///
/// Types without a system declaration are declared in `project.yml`
/// (`UTImportedTypeDeclarations`); the same list is in `CFBundleDocumentTypes` for "Open in",
/// minus the unsupported formats.
nonisolated enum ImportContentTypes {
    // Declared by the app (imported type declarations in project.yml).
    static let comicArchive = UTType(importedAs: "software.tactile.marginal.cbz", conformingTo: .zip)
    static let kindleBook = UTType(importedAs: "software.tactile.marginal.kindle-book", conformingTo: .data)
    static let djvu = UTType(importedAs: "software.tactile.marginal.djvu", conformingTo: .data)
    static let comicRar = UTType(importedAs: "software.tactile.marginal.cbr", conformingTo: .archive)
    // System types the app also declares, in case a device lacks them (no Pages or Keynote).
    static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    static let pagesPackage = UTType(importedAs: "com.apple.iwork.pages.pages", conformingTo: .package)
    static let keynotePackage = UTType(importedAs: "com.apple.iwork.keynote.key", conformingTo: .package)

    /// System types looked up by identifier.
    private static let systemTypes: [UTType] = [
        "public.xhtml",
        "org.openxmlformats.wordprocessingml.document",
        "com.microsoft.word.doc",
        "com.apple.iwork.pages.sffpages",
        "org.openxmlformats.presentationml.presentation",
        "com.microsoft.powerpoint.ppt",
        "com.apple.iwork.keynote.sffkey",
    ].compactMap { UTType($0) }

    /// Formats the app imports (as they are, or by converting).
    static let importable: [UTType] = [
        .pdf, .epub, comicArchive, .zip, .image, .plainText, markdown, .html, .webArchive, .rtf,
        pagesPackage, keynotePackage,
    ] + systemTypes

    /// Formats the app recognises and turns down by name.
    static let namedUnsupported: [UTType] = [kindleBook, djvu, comicRar, .spreadsheet]

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
