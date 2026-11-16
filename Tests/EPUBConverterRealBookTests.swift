import Foundation
import PDFKit
import ReaderCore
import Testing
import UIKit
@testable import TactileTexts

/// Real EPUBs the owner supplied. They live only on the development Mac (never in the
/// repository), so each test is skipped when its file is absent. The files are only read.
@Suite(.serialized)
struct EPUBConverterRealBookTests {
    static let louisXIV = URL(fileURLWithPath: "/Users/benw/Downloads/pg79999-images-3.epub")
    static let birds = URL(fileURLWithPath: "/Users/benw/Downloads/pg80000-images-3.epub")

    struct Measured {
        var converted: ConvertedDocument
        var document: PDFDocument
        var entries: [RawOutlineEntry]
        var diagnostics: EPUBConversionDiagnostics
        var outlineHits: Int
        var misses: [String]
        var blankPages: [Int]
    }

    private func run(_ url: URL, name: String) async throws -> (Measured, EPUBTestWorkspace) {
        let workspace = try EPUBTestWorkspace(existing: url)
        let diagnostics = EPUBConversionDiagnostics()
        var converter = EPUBConverter()
        converter.diagnostics = diagnostics
        let memory = EPUBTestMemorySampler()
        let watchdog = EPUBTestMainThreadWatchdog()
        let started = CACurrentMediaTime()
        let converted = try await converter.convert(workspace.input()) { fraction in
            memory.setPhase(fraction < 0.88 ? "render" : fraction < 0.904 ? "locate" : "join")
        }
        let elapsed = CACurrentMediaTime() - started
        let stall = watchdog.stop()
        let footprint = memory.stop()
        let document = try #require(PDFDocument(url: converted.pdf))
        let entries = await ReaderDocumentLoader.outlineEntries(at: converted.pdf)

        var hits = 0
        var misses: [String] = []
        for entry in entries {
            guard let page = entry.pageIndex else { misses.append("\(entry.title) (no page)"); continue }
            if EPUBTestPDF.page(document, page, shows: entry.title) {
                hits += 1
            } else {
                misses.append("\(entry.title) → p\(page): '\(EPUBTestPDF.pageText(document, page).prefix(80))'")
            }
        }
        let bytes = (try? converted.pdf.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let printSlice = diagnostics.longestMainThreadSlice
        let reloaded = diagnostics.chapters.filter(\.reloadedAsHTML).map(\.path)
        let failedRequests = diagnostics.requests.filter { $0.outcome == .notFound || $0.outcome == .failed }
        print(String(format: "EPUB real %@: pages=%d chapters=%d time=%.1fs pages/s=%.0f size=%.1f MB footprint before %.1f peak %.1f after %.1f MB "
                     + "longestPrintSlice=%.0f ms watchdogLongest=%.0f ms",
                     name, converted.pageCount, diagnostics.chapters.count, elapsed, Double(converted.pageCount) / elapsed,
                     Double(bytes) / 1_048_576, footprint.start, footprint.peak, footprint.end, printSlice * 1000, stall.longest * 1000))
        print("EPUB real \(name): title=\(converted.title ?? "nil") cover=\(converted.coverImage?.lastPathComponent ?? "nil") "
              + "outline \(hits)/\(entries.count) on a page showing the title; \(diagnostics.outline); links \(diagnostics.links); "
              + "reloadedAsHTML=\(reloaded) failedRequests=\(failedRequests.map(\.path))")
        let imageBytes = (try? ZIPArchive(url: url))?.entries.filter { entry in
            ["jpg", "jpeg", "png", "gif", "webp", "svg"].contains((entry.path as NSString).pathExtension.lowercased())
        }.reduce(UInt64(0)) { $0 + $1.uncompressedSize } ?? 0
        print(String(format: "EPUB real %@: footprint peaks by phase (MB): %@; images in the book %.1f MB",
                     name, memory.phaseSummary, Double(imageBytes) / 1_048_576))
        // Every link annotation covers text; a few samples, for a person to judge the targets.
        let links = EPUBTestPDF.links(document)
        var empty = 0
        for (index, link) in links.enumerated() {
            let covered = EPUBTestPDF.collapsed(document.page(at: link.page)?.selection(for: link.bounds.insetBy(dx: 0.5, dy: 0.5))?.string ?? "")
            if covered.isEmpty { empty += 1 }
            if index % max(1, links.count / 6) == 0 {
                let target = link.destination.map { "p\($0): '\(EPUBTestPDF.pageText(document, $0).prefix(60))'" } ?? link.url?.absoluteString ?? "?"
                print("EPUB real \(name) link sample: p\(link.page) '\(covered.prefix(40))' → \(target)")
            }
        }
        print("EPUB real \(name): \(links.count) link annotations, \(empty) covering no text")
        for reason in diagnostics.links.dropped { print("EPUB real \(name) dropped link: \(reason)") }
        #expect(empty == 0)
        // Blank pages, and which printed part (chapter or segment) each comes from.
        let blank = EPUBTestPDF.blankPages(document)
        var partStart = 0
        var located: [String] = []
        for chapter in diagnostics.chapters {
            for page in blank where page >= partStart && page < partStart + chapter.pageCount {
                located.append("p\(page) = \(chapter.path) part \(chapter.part + 1)/\(chapter.parts) page \(page - partStart + 1)/\(chapter.pageCount)")
            }
            partStart += chapter.pageCount
        }
        print("EPUB real \(name): \(blank.count) blank pages \(located)")
        for miss in misses { print("EPUB real \(name) outline miss: \(miss)") }
        for chapter in diagnostics.chapters {
            print(String(format: "EPUB real %@ chapter %@: %d pages in %.2fs (print main %.0f ms, longest %.0f ms, %d batches)",
                         name, chapter.path, chapter.pageCount, chapter.seconds, chapter.print.mainThreadTime * 1000,
                         chapter.print.longestMainThreadSlice * 1000, chapter.print.batches))
        }
        return (Measured(converted: converted, document: document, entries: entries, diagnostics: diagnostics,
                         outlineHits: hits, misses: misses, blankPages: blank), workspace)
    }

    /// Writes PNGs of a few pages for a person to look at; prints where.
    private func snapshot(_ measured: Measured, name: String, pages: [(String, Int)]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBRealBookShots/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (label, page) in pages where page >= 0 && page < measured.document.pageCount {
            if let png = EPUBTestPDF.png(measured.document, page: page) {
                try? png.write(to: folder.appendingPathComponent("\(label)-p\(page + 1).png"))
            }
        }
        print("EPUB real \(name) snapshots: \(folder.path)")
    }

    /// The first page whose text contains `text`.
    private func page(containing text: String, in document: PDFDocument) -> Int {
        document.findString(text, withOptions: []).first?.pages.first.map { document.index(for: $0) } ?? 0
    }

    @Test(.enabled(if: FileManager.default.isReadableFile(atPath: louisXIV.path)))
    func louisXIVConverts() async throws {
        let (measured, workspace) = try await run(Self.louisXIV, name: "louis-xiv")
        #expect(measured.entries.count == 31)
        #expect(measured.blankPages.isEmpty)
        #expect(measured.outlineHits == 31)
        #expect(measured.diagnostics.links.internalPlaced >= 23)
        #expect(measured.diagnostics.links.externalPlaced == 5)
        #expect(measured.converted.title != nil)
        #expect(measured.converted.coverImage != nil)
        // Accented text is searchable.
        let accented = measured.document.findString("DIEUDONNÉ", withOptions: [.caseInsensitive])
        print("EPUB real louis-xiv: 'DIEUDONNÉ' found \(accented.count) times")
        #expect(!accented.isEmpty)
        #expect(measured.outlineHits >= measured.entries.count * 8 / 10)
        let chapterStart = measured.entries.dropFirst(3).first?.pageIndex ?? 1
        defer { withExtendedLifetime(workspace) {} }
        snapshot(measured, name: "louis-xiv", pages: [("first", 0), ("chapter", chapterStart),
                                                       ("middle", measured.document.pageCount / 2),
                                                       ("last", measured.document.pageCount - 1)])
    }

    @Test(.enabled(if: FileManager.default.isReadableFile(atPath: birds.path)))
    func birdsOfAmericaConverts() async throws {
        let (measured, workspace) = try await run(Self.birds, name: "birds")
        // The workspace (and the PDF in it) lives until the end of the test.
        defer { withExtendedLifetime(workspace) {} }
        #expect(measured.entries.count == 109)
        #expect(measured.blankPages.isEmpty)
        #expect(measured.outlineHits == 109)
        #expect(measured.diagnostics.links.internalPlaced >= 170)
        #expect(measured.diagnostics.links.externalPlaced == 5)
        #expect(measured.converted.coverImage != nil)
        let total = EPUBTestPDF.imageObjectCount(measured.converted.pdf)
        print("EPUB real birds: \(total) image objects in the PDF")
        #expect(total > 0)
        #expect(measured.outlineHits >= measured.entries.count * 8 / 10)
        let chapterStart = measured.entries.dropFirst(5).first?.pageIndex ?? 1
        let plate = page(containing: "Pl. 1.", in: measured.document)
        snapshot(measured, name: "birds", pages: [("first", 0), ("chapter", chapterStart), ("plate", plate),
                                                   ("after-plate", plate + 1), ("middle", measured.document.pageCount / 2),
                                                   ("last", measured.document.pageCount - 1)])
    }
}
