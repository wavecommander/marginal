import ReaderCore
import Testing
@testable import Marginal

/// Settings ▸ Supported Formats (F7): which groups and formats it lists, from the converters the
/// app has, and that every kind of file it can't import has words.
@MainActor
struct SupportedFormatsTests {
    @Test func listsOnlyGroupsWithAConverterAndOnlyThoseFormats() {
        let catalog = SupportedFormatsCatalog(convertible: [.epub, .comicArchive, .image])
        #expect(catalog.groups.map(\.group) == [.epub, .comicsAndImages])
        #expect(catalog.groups.first { $0.group == .comicsAndImages }?.formats == [.comicArchive, .image])

        // One format of a group is enough for the group to appear, and only it is named.
        let partial = SupportedFormatsCatalog(convertible: [.markdown, .powerPoint])
        #expect(partial.groups.map(\.group) == [.textAndWeb, .presentations])
        #expect(partial.groups.map(\.formats) == [[.markdown], [.powerPoint]])

        #expect(SupportedFormatsCatalog(convertible: []).groups.isEmpty)
    }

    @Test func everyConvertedFormatAppearsOnceWhenAllHaveConverters() {
        let all = Set(ImportFormat.allCases.filter(\.isConverted))
        let catalog = SupportedFormatsCatalog(convertible: all)
        #expect(catalog.groups.map(\.group) == LimitationGroup.allCases)
        let listed = catalog.groups.flatMap(\.formats)
        #expect(listed.count == all.count)
        #expect(Set(listed) == all)
        // A PDF is never "converted", even if a registry somehow named it.
        #expect(!SupportedFormatsCatalog(convertible: [.pdf]).groups.contains { $0.formats.contains(.pdf) })
    }

    /// The screen follows `ConverterRegistry.standard`: a converter registered there (F6's, at
    /// merge) shows up without touching the screen.
    @Test func standardCatalogMatchesTheStandardRegistry() {
        let convertible = ConverterRegistry.standard.convertibleFormats
        let catalog = SupportedFormatsCatalog.standard
        #expect(Set(catalog.groups.flatMap(\.formats)) == convertible)
        #expect(catalog.groups.contains { $0.group == .epub })
        #expect(catalog.groups.contains { $0.group == .comicsAndImages })
    }

    @Test func notSupportedListsEveryUnsupportedKindWithWords() {
        #expect(Set(SupportedFormatsCatalog.notSupported) == Set(UnsupportedImportFormat.allCases))
        #expect(SupportedFormatsCatalog.notSupported.count == UnsupportedImportFormat.allCases.count)
        for kind in UnsupportedImportFormat.allCases {
            #expect(!kind.name.isEmpty)
            #expect(!kind.reason.isEmpty)
        }
    }

    @Test func everyFormatHasANameAndEveryLimitationHasWords() {
        for format in ImportFormat.allCases {
            #expect(!format.displayName.isEmpty)
            #expect(!format.fileExtensions.isEmpty)
        }
        #expect(Set(ImportFormat.allCases.map(\.displayName)).count == ImportFormat.allCases.count)
        for limitation in ConversionLimitation.allCases {
            #expect(!limitation.text.isEmpty)
        }
        for group in LimitationGroup.allCases {
            #expect(!group.sheetTitle.isEmpty)
        }
    }
}
