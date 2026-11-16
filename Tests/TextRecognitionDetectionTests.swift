import CoreGraphics
import Foundation
import PDFKit
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// Scan detection at import (S3): the generated fixtures, the image-coverage measurement, the
/// time it adds to importing `large.pdf`, and what an import leaves behind (state and notice).
@Suite(.serialized)
@MainActor
struct TextRecognitionDetectionTests {
    static let fixtures = SearchTestSupport.fixturesDir

    static func document(_ name: String) throws -> PDFDocument {
        try #require(PDFDocument(url: fixtures.appendingPathComponent(name)), "\(name) missing: run scripts/fixtures.sh")
    }

    // MARK: Fixtures

    @Test func scannedPDFIsScanned() throws {
        let document = try Self.document("scanned.pdf")
        let samples = ScanDetector.samples(of: document)
        #expect(samples.count == ScanDetection.defaultSampleCount)
        // The typed cover is a text sample; the rest are pictures covering the page.
        let cover = try #require(samples.first)
        #expect(cover.pageIndex == 0 && ScanDetection.kind(of: cover) == .text, "\(cover)")
        for sample in samples.dropFirst() {
            #expect(sample.textCharacterCount == 0, "\(sample)")
            #expect(sample.imageCoverage > 0.95, "\(sample)")
            #expect(ScanDetection.kind(of: sample) == .scanned, "\(sample)")
        }
        #expect(ScanDetector.isScanned(document))
    }

    @Test(arguments: ["small.pdf", "large.pdf", "no-outline.pdf"])
    func typedPDFsAreNotScanned(_ name: String) throws {
        let document = try Self.document(name)
        let samples = ScanDetector.samples(of: document)
        #expect(!samples.isEmpty)
        #expect(!ScanDetector.isScanned(document), "\(name): \(samples)")
    }

    // MARK: Image coverage

    /// The grid union: overlapping rects count once, rects outside the box are clipped.
    @Test func coverageIsTheUnionClippedToTheBox() {
        let box = CGRect(x: 0, y: 0, width: 640, height: 640)  // 10 pt cells
        #expect(PDFImageCoverage.coverage(of: [], in: box) == 0)
        #expect(PDFImageCoverage.coverage(of: [box], in: box) == 1)
        #expect(PDFImageCoverage.coverage(of: [CGRect(x: 0, y: 0, width: 320, height: 640)], in: box) == 0.5)
        // Two halves overlapping by a quarter: the union is three quarters.
        let left = CGRect(x: 0, y: 0, width: 320, height: 640)
        let middle = CGRect(x: 160, y: 0, width: 320, height: 640)
        #expect(PDFImageCoverage.coverage(of: [left, middle], in: box) == 0.75)
        // Hanging off the page: only the part on it counts.
        #expect(PDFImageCoverage.coverage(of: [CGRect(x: 320, y: -1000, width: 5000, height: 5000)], in: box) == 0.5)
        // A box not at the origin (a crop box).
        let crop = CGRect(x: 100, y: 200, width: 640, height: 640)
        #expect(PDFImageCoverage.coverage(of: [CGRect(x: 100, y: 200, width: 640, height: 320)], in: crop) == 0.5)
    }

    /// Placements read from real content streams: a full-page image, half a page, a rotated
    /// image (its bounding box), two images, vector art only, and an image too small to matter.
    @Test func coverageIsMeasuredFromTheContentStream() throws {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let url = try Self.makePDF(pageSize: page.size, pages: [
            { $0.draw(Self.image, in: page) },
            { $0.draw(Self.image, in: CGRect(x: 0, y: 0, width: 306, height: 792)) },
            { ctx in
                ctx.translateBy(x: 306, y: 396)
                ctx.rotate(by: .pi / 2)
                ctx.draw(Self.image, in: CGRect(x: -198, y: -153, width: 396, height: 306))  // 306 × 396 upright
            },
            { ctx in
                ctx.draw(Self.image, in: CGRect(x: 0, y: 396, width: 612, height: 396))
                ctx.draw(Self.image, in: CGRect(x: 0, y: 0, width: 612, height: 198))
            },
            { ctx in
                ctx.setFillColor(UIColor.gray.cgColor)
                ctx.fill(page.insetBy(dx: 20, dy: 20))
            },
            { $0.draw(Self.image, in: CGRect(x: 50, y: 50, width: 100, height: 100)) },
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(CGPDFDocument(url as CFURL))
        func coverage(_ number: Int) throws -> Double {
            PDFImageCoverage.coverage(of: try #require(document.page(at: number)))
        }
        #expect(abs(try coverage(1) - 1) < 0.001)
        #expect(abs(try coverage(2) - 0.5) < 0.02)
        #expect(abs(try coverage(3) - 0.5 * 396 / 792) < 0.03)  // 306 wide (of 612), 396 tall (of 792)
        #expect(abs(try coverage(4) - 0.75) < 0.02)
        #expect(try coverage(5) == 0, "vector art is not an image")
        #expect(try coverage(6) < 0.05)
        let placements = PDFImageCoverage.placements(on: try #require(document.page(at: 4)))
        #expect(placements.count == 2)
    }

    /// A page with text gets no coverage measured (it cannot change its kind); a page with no
    /// text and a small picture is blank, not scanned.
    @Test func samplesOfMixedPages() throws {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let url = try Self.makePDF(pageSize: page.size, pages: [
            { ctx in
                ctx.draw(Self.image, in: page)
                Self.drawText(String(repeating: "Typed words over a picture. ", count: 6), in: ctx)
            },
            { $0.draw(Self.image, in: CGRect(x: 50, y: 50, width: 200, height: 200)) },
            { _ in },
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let samples = ScanDetector.samples(of: document)
        #expect(samples.count == 3)
        #expect(ScanDetection.kind(of: samples[0]) == .text && samples[0].imageCoverage == 0, "\(samples[0])")
        #expect(ScanDetection.kind(of: samples[1]) == .blank, "\(samples[1])")
        #expect(ScanDetection.kind(of: samples[2]) == .blank, "\(samples[2])")
        #expect(!ScanDetector.isScanned(document))
    }

    // MARK: Time

    /// What detection adds to importing `large.pdf` (1,500 pages of text): sampling 12 pages
    /// of the document `ImportPipeline.check` already opened. Printed for the report.
    @Test func detectionAddsNoNoticeableTimeToLargePDF() throws {
        var times: [Double] = []
        for _ in 0..<5 {
            let document = try Self.document("large.pdf")  // a fresh document: no cached page text
            let start = ContinuousClock.now
            #expect(!ScanDetector.isScanned(document))
            times.append((ContinuousClock.now - start).seconds)
        }
        let scannedDocument = try Self.document("scanned.pdf")
        let start = ContinuousClock.now
        #expect(ScanDetector.isScanned(scannedDocument))
        let scanned = (ContinuousClock.now - start).seconds
        let median = times.sorted()[times.count / 2]
        print("S3-DETECTION large.pdf: median \(Int(median * 1000)) ms, runs \(times.map { Int($0 * 1000) }) ms; scanned.pdf \(Int(scanned * 1000)) ms")
        #expect(median < 0.25, "detection on large.pdf took \(median) s")
    }

    /// The whole stage check of `large.pdf` (open, cover, detection), for comparison.
    @Test func stageCheckOfLargePDFWithDetection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("S3-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = ContinuousClock.now
        let staged = try ImportPipeline.check(pdf: Self.fixtures.appendingPathComponent("large.pdf"), directory: directory,
                                              fileName: "large.pdf", coverImage: nil)
        let elapsed = (ContinuousClock.now - start).seconds
        print("S3-DETECTION stage check of large.pdf with detection: \(Int(elapsed * 1000)) ms")
        #expect(staged.pageCount == 1500 && !staged.isScanned)
    }

    // MARK: Import

    private func makeService(_ converters: ConverterRegistry = .standard) throws -> (LibraryStore, ImportService) {
        let store = try LibraryStore.ephemeral()
        return (store, ImportService(store: store, converters: converters))
    }

    private func state(_ store: LibraryStore, _ id: UUID) async -> RecognitionState? {
        (try? await store.recognitionState(bookID: id)) ?? nil
    }

    @Test func importingAScanGivesNotDecidedAndOneNotice() async throws {
        let (store, service) = try makeService()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let results = await service.importFiles([Self.fixtures.appendingPathComponent("scanned.pdf"),
                                                 Self.fixtures.appendingPathComponent("small.pdf")])
        let scanned = try #require(results[0].book)
        let small = try #require(results[1].book)
        #expect(await state(store, scanned.id) == .notDecided)
        #expect(await state(store, small.id) == nil, "a book with a text layer gets no state")
        // One notice for the batch, naming the scanned book, unaddressed (no window asked).
        #expect(service.scanNotices.notices.count == 1)
        let notice = try #require(service.scanNotices.notices.first)
        #expect(notice.windowKey == nil)
        #expect(notice.books == [ScanNoticeBook(id: scanned.id, title: "scanned", pageCount: 30)])
        // The first window takes it with the conversion requests.
        let window = NSObject()
        service.address([], to: ObjectIdentifier(window))
        #expect(service.scanNotices.notice(for: ObjectIdentifier(window))?.id == notice.id)

        // Importing it again finds the existing book: no second notice.
        let again = await service.importFiles([Self.fixtures.appendingPathComponent("scanned.pdf")])
        guard case .success(.existing)? = again.first?.result else { Issue.record("not existing"); return }
        #expect(service.scanNotices.notices.count == 1)
    }

    @Test func aBatchOfTypedPDFsGetsNoNotice() async throws {
        let (store, service) = try makeService()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let window = NSObject()
        let results = await service.importFiles([Self.fixtures.appendingPathComponent("small.pdf"),
                                                 Self.fixtures.appendingPathComponent("no-outline.pdf")],
                                                requester: ObjectIdentifier(window))
        for result in results {
            let book = try #require(result.book)
            #expect(await state(store, book.id) == nil)
        }
        #expect(service.scanNotices.notices.isEmpty)
    }

    /// A comic is converted from pictures: detected scanned (not decided) but no notice. A
    /// format converted to blank pages (the stub) is not scanned.
    @Test func convertedBooksAreDetectedWithoutANotice() async throws {
        let (store, service) = try makeService()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let window = NSObject()
        let comic = await service.importFiles([Self.fixtures.appendingPathComponent("small.cbz")],
                                              requester: ObjectIdentifier(window), convertWithoutAsking: ConversionOptions())
        let book = try #require(comic.first?.book, "\(String(describing: comic.first?.result))")
        #expect(book.sourceFormat == .comicArchive)
        #expect(await state(store, book.id) == .notDecided)
        #expect(service.scanNotices.notices.isEmpty, "the Convert to PDF sheet already said the pages are pictures")

        var stub = StubDocumentConverter()
        stub.formats = [.markdown]
        let (stubStore, stubService) = try makeService(ConverterRegistry([stub]))
        defer { try? FileManager.default.removeItem(at: stubStore.rootDirectory) }
        let markdown = Self.fixtures.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/f3-notes.md")
        let converted = await stubService.importFiles([markdown], convertWithoutAsking: ConversionOptions())
        let mdBook = try #require(converted.first?.book)
        #expect(await state(stubStore, mdBook.id) == nil)
        #expect(stubService.scanNotices.notices.isEmpty)
    }

    // MARK: Helpers

    /// A mid-grey 64 × 64 picture.
    static let image: CGImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }.cgImage!
    }()

    static func drawText(_ text: String, in context: CGContext) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        context.saveGState()
        context.translateBy(x: 0, y: 792)
        context.scaleBy(x: 1, y: -1)
        (text as NSString).draw(in: CGRect(x: 40, y: 40, width: 532, height: 700),
                                withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
        context.restoreGState()
    }

    /// A PDF with one page per closure, drawn in PDF space (origin lower left).
    static func makePDF(pageSize: CGSize, pages: [(CGContext) -> Void]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("S3-coverage-\(UUID().uuidString).pdf")
        var box = CGRect(origin: .zero, size: pageSize)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for draw in pages {
            context.beginPDFPage(nil)
            context.saveGState()
            draw(context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}

private extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
