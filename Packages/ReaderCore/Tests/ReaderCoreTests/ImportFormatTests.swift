import Foundation
import Testing
@testable import ReaderCore

@Suite("Import formats and limitations")
struct ImportFormatTests {
    @Test func rawValuesAreTheStoredContract() {
        #expect(ImportFormat.allCases.map(\.rawValue) == [
            "pdf", "epub", "comicArchive", "image", "plainText", "markdown", "html", "webArchive",
            "word", "rtf", "pages", "powerPoint", "keynote",
        ])
        let encoded = try! JSONEncoder().encode([ImportFormat.comicArchive])
        #expect(String(decoding: encoded, as: UTF8.self) == "[\"comicArchive\"]")
    }

    @Test func converterFamilies() {
        #expect(ImportFormat.pdf.converterFamily == .none)
        #expect(ImportFormat.comicArchive.converterFamily == .images)
        #expect(ImportFormat.image.converterFamily == .images)
        for format in ImportFormat.allCases where ![.pdf, .comicArchive, .image].contains(format) {
            #expect(format.converterFamily == .web, "\(format)")
        }
        #expect(!ImportFormat.pdf.isConverted && ImportFormat.epub.isConverted)
    }

    @Test func limitationGroupsPartitionTheConvertedFormats() {
        #expect(ImportFormat.pdf.limitationGroup == nil)
        #expect(LimitationGroup.epub.formats == [.epub])
        #expect(LimitationGroup.comicsAndImages.formats == [.comicArchive, .image])
        #expect(LimitationGroup.wordProcessing.formats == [.word, .rtf, .pages])
        #expect(LimitationGroup.textAndWeb.formats == [.plainText, .markdown, .html, .webArchive])
        #expect(LimitationGroup.presentations.formats == [.powerPoint, .keynote])
        let grouped = LimitationGroup.allCases.flatMap(\.formats)
        #expect(Set(grouped) == Set(ImportFormat.allCases.filter(\.isConverted)))
        #expect(grouped.count == Set(grouped).count)
    }

    @Test func onlyReflowableGroupsOfferTextSize() {
        #expect(LimitationGroup.allCases.filter(\.offersTextSizeChoice) == [.epub, .textAndWeb])
    }

    @Test func limitationsAreGroupSpecificThenCommon() {
        let common: [ConversionLimitation] = [.fixedPages, .reconvertingMakesNewBook, .originalKeptUsesStorage]
        #expect(ConversionLimitation.common == common)
        #expect(ConversionLimitation.limitations(for: .epub)
            == [.pageNumbersDiffer, .contentsFromBook, .someLinksMayNotWork, .mediaLeftOut] + common)
        #expect(ConversionLimitation.limitations(for: .comicsAndImages) == [.pagesArePictures] + common)
        #expect(ConversionLimitation.limitations(for: .wordProcessing) == [.layoutMayDiffer, .commentsNotShown] + common)
        #expect(ConversionLimitation.limitations(for: .textAndWeb) == [.appChoosesTypography, .remoteImagesNotLoaded] + common)
        #expect(ConversionLimitation.limitations(for: .presentations)
            == [.oneSlidePerPage, .animationsAndMediaLeftOut, .speakerNotesNotIncluded, .fontsMayDiffer] + common)
        #expect(ImportFormat.pdf.conversionLimitations.isEmpty)
        #expect(ImportFormat.keynote.conversionLimitations == LimitationGroup.presentations.limitations)
        #expect(ImportFormat.rtf.conversionLimitations == ConversionLimitation.limitations(for: .wordProcessing))
        // Every identifier is used by some group.
        let used = Set(LimitationGroup.allCases.flatMap(\.limitations))
        #expect(used == Set(ConversionLimitation.allCases))
    }
}

@Suite("Natural sort")
struct NaturalSortTests {
    @Test func numbersCompareByValue() {
        #expect(NaturalSort.sorted(["page10", "page2", "page1"]) == ["page1", "page2", "page10"])
        #expect(NaturalSort.sorted(["img100.jpg", "img20.jpg", "img3.jpg"]) == ["img3.jpg", "img20.jpg", "img100.jpg"])
        #expect(NaturalSort.areInIncreasingOrder("v1.2", "v1.10"))
    }

    @Test func caseInsensitive() {
        // Case only breaks ties (upper case first, by scalar value).
        #expect(NaturalSort.sorted(["b", "A", "c", "B"]) == ["A", "B", "b", "c"])
        #expect(NaturalSort.sorted(["Zebra", "apple"]) == ["apple", "Zebra"])
        #expect(NaturalSort.sorted(["Page2", "page10", "PAGE1"]) == ["PAGE1", "Page2", "page10"])
    }

    @Test func pathComponentAware() {
        #expect(NaturalSort.sorted(["ch2/p1", "ch1/p10", "ch1/p2", "ch10/p1"]) == ["ch1/p2", "ch1/p10", "ch2/p1", "ch10/p1"])
        // A folder's own pages come before a sibling folder whose name merely extends it.
        #expect(NaturalSort.sorted(["a1/a.jpg", "a/z.jpg"]) == ["a/z.jpg", "a1/a.jpg"])
        #expect(NaturalSort.sorted(["vol 2/001.png", "vol 10/001.png", "vol 2/010.png", "vol 2/002.png"])
            == ["vol 2/001.png", "vol 2/002.png", "vol 2/010.png", "vol 10/001.png"])
        #expect(NaturalSort.areInIncreasingOrder("ch1/p10", "ch2/p1"))
    }

    @Test func tiesAreDeterministic() {
        // Equal by value: fewer leading zeros first, then exact scalars.
        #expect(NaturalSort.sorted(["p01", "p1", "p001"]) == ["p1", "p01", "p001"])
        #expect(NaturalSort.sorted(["p001", "p01", "p1"]) == ["p1", "p01", "p001"])
        #expect(NaturalSort.compare("a", "A") != .orderedSame)
        #expect(NaturalSort.compare("x", "x") == .orderedSame)
        let names = ["b", "B", "a", "A", "a1", "a01", "A1"]
        #expect(NaturalSort.sorted(names) == NaturalSort.sorted(names.reversed()))
    }

    @Test func stableForIdenticalKeys() {
        let items = [(1, "x"), (2, "a"), (3, "x"), (4, "a")]
        #expect(NaturalSort.sorted(items, by: \.1).map(\.0) == [2, 4, 1, 3])
    }

    @Test func numbersBeforeLettersAndHugeRunsDoNotOverflow() {
        #expect(NaturalSort.sorted(["b", "10", "a", "9"]) == ["9", "10", "a", "b"])
        let big = "p" + String(repeating: "9", count: 40)
        let bigger = "p1" + String(repeating: "0", count: 40)
        #expect(NaturalSort.areInIncreasingOrder(big, bigger))
    }

    @Test func precomposedAndDecomposedCompareEqualUpToTie() {
        let composed = "caf\u{E9}2", decomposed = "cafe\u{301}10"
        #expect(NaturalSort.areInIncreasingOrder(composed, decomposed))
    }
}
