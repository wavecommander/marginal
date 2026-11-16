import Foundation
import PDFKit
import ReaderCore
import Testing
import UIKit
@testable import TactileTexts

/// The PowerPoint / Keynote converter, called directly on the committed decks
/// (Tests/Fixtures/f6-slides.pptx, 5 slides; f6-deck-40.pptx, 40 slides).
@Suite(.serialized)
struct SlidesConverterTests {
    private func convert(_ workspace: F6Workspace, textSize: ConversionTextSize = .medium,
                         diagnostics: WebConversionDiagnostics? = nil) async throws -> ConvertedDocument {
        var converter = SlidesConverter()
        converter.diagnostics = diagnostics
        converter.trace = F6Check.trace("Slides")
        return try await converter.convert(workspace.input(textSize: textSize)) { _ in }
    }

    @Test func eachSlideIsOnePageAtTheSlidesAspectRatio() async throws {
        let workspace = try F6Workspace(copying: F6Fixtures.fixture("f6-slides.pptx"), format: .powerPoint)
        let diagnostics = WebConversionDiagnostics()
        let started = CACurrentMediaTime()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        print(String(format: "pptx: %d pages in %.2fs (load %.2fs), page %@, notes %@", converted.pageCount,
                     CACurrentMediaTime() - started, diagnostics.loadSeconds, String(describing: diagnostics.pageSize),
                     diagnostics.notes.description))
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(converted.pageCount == 5)
        #expect(document.pageCount == 5)
        #expect(EPUBTestPDF.blankPages(document) == [])
        for index in 0..<document.pageCount {
            let size = try #require(document.page(at: index)?.bounds(for: .mediaBox).size)
            #expect(abs(size.width / size.height - 16.0 / 9.0) < 0.01, "page \(index): \(size)")
            #expect(size == CGSize(width: 960, height: 540))
        }
        // Each slide's own text is on its own page (nothing split, nothing moved).
        for slide in 1...5 {
            let page = EPUBTestPDF.pageText(document, slide - 1)
            if slide < 5 {
                #expect(page.contains("F6TITLE-\(slide)"), "page \(slide): \(page)")
                #expect(page.contains("F6BODY-\(slide)"), "page \(slide): \(page)")
            } else {
                #expect(page.contains("F6CLOSING-5"), "page 5: \(page)")
            }
            #expect(document.findString("F6BODY-\(slide)", withOptions: []).count == (slide < 5 ? 1 : 0))
        }
        // Nothing clipped: the last body line of every slide is drawn inside its page.
        for slide in 1...4 {
            let hit = try #require(document.findString("Second point of slide \(slide)", withOptions: []).first)
            let page = try #require(hit.pages.first)
            #expect(document.index(for: page) == slide - 1)
            #expect(page.bounds(for: .mediaBox).contains(hit.bounds(for: page)))
        }
        // The picture on slide 3.
        #expect(EPUBTestPDF.imageObjectCount(converted.pdf) >= 1)
        // One outline entry per slide: its first line of text.
        let entries = await F6Check.outline(converted.pdf)
        #expect(entries.map(\.title) == ["Slide 1 Title F6TITLE-1", "Slide 2 Title F6TITLE-2", "Slide 3 Title F6TITLE-3",
                                         "Slide 4 Title F6TITLE-4", "Closing words F6CLOSING-5"])
        #expect(entries.map(\.page) == [0, 1, 2, 3, 4])
        #expect(converted.title == "F6 Deck Title")
        #expect(workspace.contents == ["Document.pdf", "original.pptx"])
        F6Check.savePages(document, name: "pptx", pages: Array(0..<5))
    }

    @Test func textSizeDoesNotChangeSlides() async throws {
        var counts: [Int] = []
        for size in [ConversionTextSize.small, .large] {
            let workspace = try F6Workspace(copying: F6Fixtures.fixture("f6-slides.pptx"), format: .powerPoint)
            counts.append(try await convert(workspace, textSize: size).pageCount)
        }
        #expect(counts == [5, 5])
    }

    @Test func aLongDeckKeepsTheMainThreadResponsive() async throws {
        let warmUp = try F6Workspace(copying: F6Fixtures.fixture("f6-slides.pptx"), format: .powerPoint)
        _ = try await convert(warmUp)

        let workspace = try F6Workspace(copying: F6Fixtures.fixture("f6-deck-40.pptx"), format: .powerPoint)
        let diagnostics = WebConversionDiagnostics()
        let memory = EPUBTestMemorySampler()
        let watchdog = EPUBTestMainThreadWatchdog()
        let started = CACurrentMediaTime()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        let elapsed = CACurrentMediaTime() - started
        let stall = watchdog.stop()
        let footprint = memory.stop()
        print(String(format: "40-slide deck: pages=%d parts=%d total=%.2fs load=%.2fs longestPrintSlice=%.0f ms watchdogLongest=%.0f ms "
                     + "footprint before %.1f peak %.1f after %.1f MB notes %@",
                     converted.pageCount, diagnostics.parts.count, elapsed, diagnostics.loadSeconds,
                     diagnostics.longestMainThreadSlice * 1000, stall.longest * 1000, footprint.start, footprint.peak, footprint.end,
                     diagnostics.notes.description))
        #expect(converted.pageCount == 40)
        #expect(diagnostics.parts.count > 1)
        #expect(diagnostics.longestMainThreadSlice < 0.2)
        #expect(stall.longest < 0.3)
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(EPUBTestPDF.blankPages(document) == [])
        for slide in [1, 16, 17, 33, 39] {
            #expect(EPUBTestPDF.pageText(document, slide - 1).contains("F6TITLE-\(slide)"), "slide \(slide)")
        }
        let entries = await F6Check.outline(converted.pdf)
        #expect(entries.count == 40)
        #expect(entries.map(\.page) == (0..<40).map { $0 })
    }

    @Test func damagedDecksFailWithAReason() async throws {
        let sample = try Data(contentsOf: F6Fixtures.fixture("f6-slides.pptx"))
        let cases: [(String, Data, String)] = [
            ("empty", Data(), "empty"),
            ("junk", Data("PK\u{3}\u{4} not a presentation".utf8), "could not be opened as a PowerPoint presentation"),
            ("truncated", sample.prefix(sample.count / 3), "could not be opened as a PowerPoint presentation"),
        ]
        for (name, data, phrase) in cases {
            let workspace = try F6Workspace(data: data, extension: "pptx", format: .powerPoint)
            do {
                let converted = try await convert(workspace)
                Issue.record("\(name) converted to \(converted.pageCount) pages")
            } catch let ConversionError.failed(reason) {
                print("Slides failure \(name): \(reason)")
                #expect(reason.contains(phrase), "\(name): \(reason)")
            }
            #expect(workspace.contents == ["original.pptx"], "\(name) left \(workspace.contents)")
        }
    }

    @Test func cancellingLeavesNothingBehind() async throws {
        let workspace = try F6Workspace(copying: F6Fixtures.fixture("f6-deck-40.pptx"), format: .powerPoint)
        let input = workspace.input()
        let holder = EPUBTestTaskHolder()
        var converter = SlidesConverter()
        converter.trace = { line in if line.hasPrefix("printed") { holder.cancelOnce() } }
        let task = Task { () throws -> ConvertedDocument in try await converter.convert(input) { _ in } }
        holder.set(task)
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(workspace.contents == ["original.pptx"])
    }

    // MARK: Formats this Mac cannot make

    @Test(arguments: [("f6-sample.ppt", ImportFormat.powerPoint), ("f6-sample.key", .keynote)])
    func aRealDeck(name: String, format: ImportFormat) async throws {
        guard let url = F6Fixtures.downloaded(name) else {
            print("\(name): not in /Users/benw/Downloads; UNTESTED")
            return
        }
        let workspace = try F6Workspace(copying: url, format: format)
        let diagnostics = WebConversionDiagnostics()
        let converted = try await convert(workspace, diagnostics: diagnostics)
        let document = try #require(PDFDocument(url: converted.pdf))
        let entries = await F6Check.outline(converted.pdf)
        print("\(name): \(converted.pageCount) pages, page \(String(describing: diagnostics.pageSize)), outline \(entries.map(\.title)), notes \(diagnostics.notes)")
        #expect(converted.pageCount > 0)
        #expect(EPUBTestPDF.blankPages(document) == [])
        #expect(entries.count == converted.pageCount)
        F6Check.savePages(document, name: (name as NSString).pathExtension, pages: [0, 1, 2])
    }
}
