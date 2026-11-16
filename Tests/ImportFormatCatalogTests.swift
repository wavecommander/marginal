import Foundation
import ReaderCore
import Testing
import UniformTypeIdentifiers
@testable import Marginal

/// The app's `Info.plist` and its picker against the one list of importable formats
/// (`ImportFormat` in ReaderCore). `Info.plist` is written by XcodeGen from `project.yml` and
/// cannot be derived from Swift, so these fail when the two disagree.
struct ImportFormatCatalogTests {
    private static let backupType = "software.tactile.marginal.backup"

    private var openInTypes: [String] {
        let documentTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        return documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
    }

    /// Identifier → file name extensions of the app's imported type declarations.
    private var importedDeclarations: [String: [String]] {
        let declarations = Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]] ?? []
        var result: [String: [String]] = [:]
        for declaration in declarations {
            guard let identifier = declaration["UTTypeIdentifier"] as? String else { continue }
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            result[identifier] = tags?["public.filename-extension"] as? [String] ?? []
        }
        return result
    }

    @Test func openInDeclaresExactlyTheImportableFormats() {
        let declared = openInTypes
        #expect(declared.count == Set(declared).count, "a type is declared twice: \(declared)")
        #expect(Set(declared).subtracting([Self.backupType]) == Set(ImportFormatCatalog.importableTypeIdentifiers))
        #expect(declared.contains(Self.backupType))
    }

    @Test func thePickerAndDropsAcceptExactlyTheList() {
        #expect(ImportContentTypes.importable.map(\.identifier) == ImportFormatCatalog.importableTypeIdentifiers)
        #expect(ImportContentTypes.namedUnsupported.map(\.identifier) == ImportFormatCatalog.namedUnsupportedTypeIdentifiers)
        #expect(ImportContentTypes.acceptable.count == Set(ImportContentTypes.acceptable).count)
    }

    @Test func theTypeDeclarationsMatchTheList() {
        let declarations = importedDeclarations
        #expect(Set(declarations.keys) == Set(ImportFormatCatalog.declaredTypes.map(\.identifier)))
        for declared in ImportFormatCatalog.declaredTypes {
            #expect(declarations[declared.identifier].map(Set.init) == Set(declared.fileExtensions), "\(declared.identifier)")
        }
        // Every type of the app's own that the list uses has a declaration.
        let own = (ImportFormatCatalog.importableTypeIdentifiers + ImportFormatCatalog.namedUnsupportedTypeIdentifiers)
            .filter { $0.hasPrefix("software.tactile.marginal.") }
        #expect(Set(own).isSubset(of: Set(declarations.keys)))
    }

    /// Every extension Settings ▸ Supported Formats lists (and the unlisted spellings) names a
    /// type that "Open in", the Files picker and drops take for its format.
    @Test func everyExtensionOfAFormatCanBeChosenAndOpened() {
        // The system's Markdown type claims only .md and .markdown, and a type the system
        // declares cannot be given more extensions by an app: these two can only be dropped or
        // opened from an app that passes them on by name.
        let withoutAType: Set<String> = ["mdown", "mkd"]
        for format in ImportFormat.allCases {
            let accepted = format.typeIdentifiers.compactMap { UTType($0) }
            #expect(accepted.count == format.typeIdentifiers.count, "\(format): an identifier names no type on this system")
            for ext in format.allFileExtensions where !withoutAType.contains(ext) {
                let type = UTType(filenameExtension: ext)
                #expect(type.map { type in accepted.contains { type.conforms(to: $0) } } == true,
                        "\(format) .\(ext) is \(type?.identifier ?? "no type")")
            }
        }
    }

    /// Every extension of a kind the app turns down by name can be chosen, so the app can say why.
    @Test func everyExtensionOfANamedUnsupportedKindCanBeChosen() {
        // `.rar` is the system's RAR type, which the picker does not offer (CBR comics are the
        // case the app names).
        let notOffered: Set<String> = ["rar"]
        for kind in UnsupportedImportFormat.allCases {
            for ext in kind.fileExtensions where !notOffered.contains(ext) {
                let type = UTType(filenameExtension: ext)
                #expect(type.map { type in ImportContentTypes.acceptable.contains { type.conforms(to: $0) } } == true,
                        "\(kind) .\(ext) is \(type?.identifier ?? "no type")")
            }
        }
    }

    /// Another app may declare an extension of one of the app's own types under its own name,
    /// and the system may then call the file by that name: the picker and drops take that type
    /// too. A placeholder type (an extension nothing declares) is not added, and neither is a
    /// type the lists already take.
    @Test func typesOtherAppsGiveADeclaredExtensionAreAccepted() throws {
        let rival = UTType(importedAs: "com.example.rival.mobi-book")
        let placeholder = try #require(UTType(filenameExtension: "nothing-declares-this"))
        #expect(placeholder.isDynamic)
        var asked: [String] = []
        let accepted = ImportContentTypes.acceptable { ext in
            asked.append(ext)
            switch ext {
            case "mobi": return [rival, placeholder]
            case "cbz": return [.zip]  // already taken through the comic archive's zip type
            default: return []
            }
        }
        #expect(accepted.contains(rival))
        #expect(!accepted.contains(placeholder))
        #expect(accepted.count == ImportContentTypes.importable.count + ImportContentTypes.namedUnsupported.count + 1)
        #expect(Array(accepted.prefix(ImportContentTypes.importable.count)) == ImportContentTypes.importable)
        // Only the extensions of the app's own declared types are asked about.
        #expect(Set(asked) == Set(ImportFormatCatalog.declaredTypes.flatMap(\.fileExtensions)))
        #expect(!asked.contains("rar"))
    }

    @Test func officeFilesGoToWebKitWithTheMIMETypeOfTheirForm() {
        let word = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        let slides = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        func mime(_ ext: String, _ format: ImportFormat) -> String { QuickLookWorkarounds.mimeType(forFileExtension: ext, format: format) }
        for ext in ["docx", "docm", "dotx", "DOCX"] { #expect(mime(ext, .word) == word, "\(ext)") }
        for ext in ["doc", "dot"] { #expect(mime(ext, .word) == "application/msword", "\(ext)") }
        for ext in ["pptx", "pptm", "ppsx"] { #expect(mime(ext, .powerPoint) == slides, "\(ext)") }
        for ext in ["ppt", "pps", "pot"] { #expect(mime(ext, .powerPoint) == "application/vnd.ms-powerpoint", "\(ext)") }
        #expect(mime("pages", .pages) == "application/x-iwork-pages-sffpages")
        #expect(mime("key", .keynote) == "application/x-iwork-keynote-sffkey")
        #expect(mime("rtf", .rtf) == "application/rtf")
        // A name that says nothing: the detected format decides.
        #expect(mime("", .word) == word)
        #expect(mime("bin", .powerPoint) == slides)
        #expect(mime("", .pages) == "application/x-iwork-pages-sffpages")
        #expect(mime("", .keynote) == "application/x-iwork-keynote-sffkey")
        #expect(mime("", .rtf) == "application/octet-stream")
        #expect(mime("", .epub) == "application/octet-stream")
        // The name wins over the detected format.
        #expect(mime("doc", .powerPoint) == "application/msword")
    }
}
