import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import ReaderCore
import Testing
import UniformTypeIdentifiers
@testable import TactileTexts

/// The images converter (comic archives and picture files to PDF), on the simulator. Serialized
/// so the memory measurement is not disturbed by the other tests of the suite.
@Suite(.serialized)
struct ImagesConverterTests {
    typealias RGB = ImagesFixtures.RGB

    private struct Scratch {
        let directory: URL
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func input(_ original: URL, format: ImportFormat) -> ConversionInput {
            ConversionInput(original: original, format: format, fileName: original.lastPathComponent,
                            directory: directory.appendingPathComponent("staging", isDirectory: true),
                            outputFileName: "Book.pdf", options: ConversionOptions())
        }
    }

    private func makeScratch() throws -> Scratch {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImagesConverterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("staging"), withIntermediateDirectories: true)
        return Scratch(directory: directory)
    }

    private func cleanup(_ scratch: Scratch) { try? FileManager.default.removeItem(at: scratch.directory) }

    private func stagingContents(_ input: ConversionInput) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: input.directory.path)) ?? []
    }

    private func archive(_ entries: [(String, Data)], in scratch: Scratch, name: String = "Comic.cbz") throws -> URL {
        let url = scratch.url(name)
        try ImagesZIPWriter.write(entries, to: url)
        return url
    }

    private func convert(_ input: ConversionInput, progress: @escaping @Sendable (Double) -> Void = { _ in })
        async throws -> ConvertedDocument {
        try await ImagesConverter().convert(input, progress: progress)
    }

    /// Asserts that every page has crop box = media box at the origin, rotation 0 and the area
    /// of a US Letter page (within rounding), so ink coordinates are stable.
    private func expectStableBoxes(_ document: PDFDocument, sourceLocation: SourceLocation = #_sourceLocation) {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let crop = page.bounds(for: .cropBox), media = page.bounds(for: .mediaBox)
            #expect(crop == media, "page \(index)", sourceLocation: sourceLocation)
            #expect(crop.origin == .zero, "page \(index)", sourceLocation: sourceLocation)
            #expect(page.rotation == 0, "page \(index)", sourceLocation: sourceLocation)
            #expect(abs(crop.width * crop.height - 612 * 792) < 612 * 792 * 0.001, "page \(index): \(crop.size)",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: Contract

    @Test func declaresItsFormatsAndVersion() {
        let converter = ImagesConverter()
        #expect(converter.formats == [.comicArchive, .image])
        #expect(converter.version == 1)
        let registry = ConverterRegistry([converter])
        #expect(registry.converter(for: .comicArchive) != nil)
        #expect(registry.converter(for: .image) != nil)
        #expect(registry.converter(for: .epub) == nil)
    }

    @Test func pageSizeRule() {
        // Letter area, the picture's shape.
        let portrait = ImagesPDFWriter.pageSize(forDisplayPixels: CGSize(width: 1988, height: 3056))
        #expect(abs(portrait.width * portrait.height - 612 * 792) < 1)
        #expect(abs(portrait.width / portrait.height - 1988.0 / 3056.0) < 0.0001)
        // Resolution does not matter.
        let small = ImagesPDFWriter.pageSize(forDisplayPixels: CGSize(width: 100, height: 200))
        let large = ImagesPDFWriter.pageSize(forDisplayPixels: CGSize(width: 1000, height: 2000))
        #expect(abs(small.width - large.width) < 0.001 && abs(small.height - large.height) < 0.001)
        // A very tall strip is capped at 14,400 pt; an absurd one keeps 3 pt minimum.
        let strip = ImagesPDFWriter.pageSize(forDisplayPixels: CGSize(width: 800, height: 400_000))
        #expect(abs(strip.height - 14_400) < 0.001)
        #expect(abs(strip.width - 28.8) < 0.001)
        let thread = ImagesPDFWriter.pageSize(forDisplayPixels: CGSize(width: 1, height: 1_000_000))
        #expect(thread == CGSize(width: 3, height: 14_400))
    }

    // MARK: Archives

    @Test func pagesFollowNaturalOrderAcrossFolders() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        // Reading order; each page's width tells it apart.
        let ordered = ["ch1/page1.png", "ch1/page2.png", "ch1/Page3.png", "ch1/page10.png",
                       "ch2/page1.png", "ch2/page02.png", "ch10/page1.png", "extra.png"]
        var entries = ordered.enumerated().map { index, path in
            (path, ImagesFixtures.png(ImagesFixtures.solid(width: 100 + 20 * index, height: 300, color: .blue)))
        }
        entries.append(("ch1/", Data()))
        let shuffled = [entries[6], entries[3], entries[8], entries[0], entries[7], entries[4], entries[1], entries[5], entries[2]]
        let input = scratch.input(try archive(shuffled, in: scratch), format: .comicArchive)
        let original = try Data(contentsOf: input.original)
        let fractions = ImagesFractions()

        let converted = try await convert(input) { fractions.append($0) }

        #expect(converted.pdf == input.outputURL)
        #expect(converted.pageCount == ordered.count)
        #expect(converted.title == nil)
        #expect(converted.coverImage == nil)
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.pageCount == ordered.count)
        let aspects = (0..<document.pageCount).map { index -> Double in
            let size = document.page(at: index)!.bounds(for: .cropBox).size
            return Double(size.width / size.height)
        }
        let expected = ordered.indices.map { Double(100 + 20 * $0) / 300 }
        for (actual, wanted) in zip(aspects, expected) { #expect(abs(actual - wanted) < 0.001) }
        expectStableBoxes(document)
        #expect(document.outlineRoot == nil)
        #expect(fractions.values == fractions.values.sorted())
        #expect(fractions.values.last == 1)
        #expect(try Data(contentsOf: input.original) == original)
        #expect(stagingContents(input) == ["Book.pdf"])
    }

    @Test func ignoredEntriesAreLeftOut() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let page = { (color: RGB) in ImagesFixtures.jpeg(ImagesFixtures.solid(width: 60, height: 90, color: color)) }
        let garbage = Data("not a picture at all".utf8)
        let entries: [(String, Data)] = [
            ("Comic/", Data()),
            ("Comic/001.jpg", page(.red)),
            ("__MACOSX/Comic/._001.jpg", garbage),
            ("Comic/.DS_Store", garbage),
            ("Comic/.hidden/005.jpg", garbage),
            ("Comic/._002.jpg", garbage),
            ("Comic/002.jpg", page(.green)),
            ("ComicInfo.xml", Data("<ComicInfo/>".utf8)),
            ("Comic/notes.txt", garbage),
            ("scan.nfo", garbage),
            ("check.SFV", garbage),
            ("Comic/Thumbs.db", garbage),
            ("desktop.ini", garbage),
            ("Comic/003.jpg", page(.blue)),
        ]
        let input = scratch.input(try archive(entries, in: scratch), format: .comicArchive)
        let converted = try await convert(input)
        #expect(converted.pageCount == 3)
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.pageCount == 3)
        let palette: [RGB] = [.red, .green, .blue, .yellow]
        let centres = (0..<3).map {
            ImagesPDFInspector.nearest(ImagesPDFInspector.colours(in: converted.pdf, page: $0, at: [CGPoint(x: 0.5, y: 0.5)])[0], in: palette)
        }
        #expect(centres == [.red, .green, .blue])
    }

    /// The "Done when" measurement: 300 distinct JPEG pages of about 320 KB. Memory stays flat
    /// (holding every page's bytes would add ~97 MB; holding decoded pages, ~540 MB) and the PDF
    /// is about the size of the JPEGs, because their data is copied in without re-encoding.
    /// Every page is different: CoreGraphics stores identical pictures once, which would hide
    /// both effects.
    @Test func threeHundredPagesConvertWithFlatMemoryAndJPEGPassthrough() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let pageCount = 300
        let url = scratch.url("Long.cbz")
        var jpegBytes = 0
        do {
            let writer = try ImagesZIPWriter(url: url)
            for index in 0..<pageCount {
                try autoreleasepool {
                    let data = ImagesFixtures.jpeg(ImagesFixtures.noise(width: 560, height: 800, seed: UInt64(index + 1)), quality: 0.6)
                    jpegBytes += data.count
                    try writer.add(String(format: "pages/%03d.jpg", index + 1), data)
                }
            }
            try writer.finish()
        }
        let input = scratch.input(url, format: .comicArchive)
        let peak = ImagesPeak()
        let before = imagesFootprint()
        let clock = ContinuousClock()
        let start = clock.now

        let converted = try await convert(input) { peak.record(imagesFootprint(), fraction: $0) }

        let elapsed = clock.now - start
        let after = imagesFootprint()
        let pdfBytes = try #require(try input.outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let mb = { (bytes: UInt64) in Double(bytes) / 1_048_576 }
        let growth = peak.value > before ? peak.value - before : 0
        print("""
            ImagesConverter 300 pages: \(elapsed); JPEG total \(String(format: "%.1f", Double(jpegBytes) / 1_048_576)) MB, \
            PDF \(String(format: "%.1f", Double(pdfBytes) / 1_048_576)) MB, ratio \(String(format: "%.4f", Double(pdfBytes) / Double(jpegBytes))); \
            footprint before \(String(format: "%.1f", mb(before))) MB, peak \(String(format: "%.1f", mb(peak.value))) MB, \
            after \(String(format: "%.1f", mb(after))) MB, peak growth \(String(format: "%.1f", mb(growth))) MB
            """)

        #expect(converted.pageCount == pageCount)
        #expect(peak.fractions.count >= pageCount)
        // Flat: well under the ~150 MB that keeping each page's bytes would take.
        #expect(mb(growth) < 40)
        // Pass-through: no re-encoding, so the PDF is the JPEGs plus a little structure per page.
        #expect(Double(pdfBytes) >= Double(jpegBytes) * 0.98)
        #expect(Double(pdfBytes) <= Double(jpegBytes) * 1.02 + Double(pageCount) * 1024)
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.pageCount == pageCount)
        expectStableBoxes(document)
        #expect(ImagesPDFInspector.crossReferenceProblems(in: converted.pdf) == [])
    }

    /// Pages that must be decoded (PNG) are released one by one too: 80 pages of 800 × 1100 px
    /// would hold ~280 MB decoded, or ~200 MB of PNG data, if kept.
    @Test func decodedPagesAlsoKeepMemoryFlat() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let url = scratch.url("Pngs.cbz")
        var pngBytes = 0
        do {
            let writer = try ImagesZIPWriter(url: url)
            for index in 0..<80 {
                try autoreleasepool {
                    let data = ImagesFixtures.png(ImagesFixtures.noise(width: 800, height: 1100, seed: UInt64(1000 + index)))
                    pngBytes += data.count
                    try writer.add(String(format: "%02d.png", index + 1), data)
                }
            }
            try writer.finish()
        }
        let input = scratch.input(url, format: .comicArchive)
        let peak = ImagesPeak()
        let before = imagesFootprint()
        let clock = ContinuousClock()
        let start = clock.now
        let converted = try await convert(input) { peak.record(imagesFootprint(), fraction: $0) }
        let elapsed = clock.now - start
        let growth = Double(peak.value > before ? peak.value - before : 0) / 1_048_576
        let pdfBytes = try #require(try converted.pdf.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        print("ImagesConverter 80 PNG pages: \(elapsed); PNG total \(String(format: "%.1f", Double(pngBytes) / 1_048_576)) MB, "
            + "PDF \(String(format: "%.1f", Double(pdfBytes) / 1_048_576)) MB; peak growth \(String(format: "%.1f", growth)) MB")
        #expect(converted.pageCount == 80)
        #expect(growth < 40)
        #expect(PDFDocument(url: converted.pdf)?.pageCount == 80)
    }

    @Test func singleJPEGIsPassedThroughByteForByte() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let jpeg = ImagesFixtures.jpeg(ImagesFixtures.noise(width: 1200, height: 1700, seed: 42), quality: 0.8)
        let url = scratch.url("Scan.jpg")
        try jpeg.write(to: url)
        let input = scratch.input(url, format: .image)
        let converted = try await convert(input)
        let pdf = try Data(contentsOf: converted.pdf)
        print("ImagesConverter single JPEG: \(jpeg.count) bytes → PDF \(pdf.count) bytes")
        #expect(converted.pageCount == 1)
        #expect(pdf.count >= jpeg.count)
        #expect(pdf.count <= jpeg.count + 4096)
        // The JPEG's entropy-coded data appears in the PDF unchanged.
        #expect(pdf.range(of: jpeg.subdata(in: (jpeg.count / 2)..<(jpeg.count / 2 + 4096))) != nil)
    }

    // MARK: Picture files

    @Test func multiPageTIFFGivesOnePagePerFrame() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let frames = [ImagesFixtures.solid(width: 100, height: 200, color: .red),
                      ImagesFixtures.solid(width: 300, height: 100, color: .green),
                      ImagesFixtures.solid(width: 150, height: 150, color: .blue)]
        let url = scratch.url("Scan.tiff")
        try #require(ImagesFixtures.encode(frames, as: .tiff)).write(to: url)
        let converted = try await convert(scratch.input(url, format: .image))
        #expect(converted.pageCount == 3)
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.pageCount == 3)
        let aspects = (0..<3).map { document.page(at: $0)!.bounds(for: .cropBox).size }.map { Double($0.width / $0.height) }
        #expect(abs(aspects[0] - 0.5) < 0.001 && abs(aspects[1] - 3) < 0.001 && abs(aspects[2] - 1) < 0.001)
        expectStableBoxes(document)
        let palette: [RGB] = [.red, .green, .blue]
        let centres = (0..<3).map {
            ImagesPDFInspector.nearest(ImagesPDFInspector.colours(in: converted.pdf, page: $0, at: [CGPoint(x: 0.5, y: 0.5)])[0], in: palette)
        }
        #expect(centres == [.red, .green, .blue])
    }

    @Test(arguments: ["png", "jpg", "heic", "gif", "webp", "bmp"])
    func singlePictureGivesOnePage(_ ext: String) async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let image = ImagesFixtures.solid(width: 120, height: 180, color: .green)
        let data: Data
        switch ext {
        case "webp": data = ImagesFixtures.webP
        default:
            let type = try #require(UTType(filenameExtension: ext))
            data = try #require(ImagesFixtures.encode([image], as: type), "ImageIO cannot write .\(ext) here")
        }
        let url = scratch.url("Picture.\(ext)")
        try data.write(to: url)
        let converted = try await convert(scratch.input(url, format: .image))
        #expect(converted.pageCount == 1)
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.pageCount == 1)
        expectStableBoxes(document)
        if ext != "webp" {
            let size = document.page(at: 0)!.bounds(for: .cropBox).size
            #expect(abs(size.width / size.height - 120.0 / 180.0) < 0.001)
            let centre = ImagesPDFInspector.colours(in: converted.pdf, page: 0, at: [CGPoint(x: 0.5, y: 0.5)])[0]
            #expect(centre.distance(to: .green) < 40, "centre \(centre)")
        }
    }

    @Test func animatedGIFGivesItsFirstFrame() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let frames = [RGB.red, .green, .blue].map { ImagesFixtures.solid(width: 80, height: 80, color: $0) }
        let url = scratch.url("Animation.gif")
        try #require(ImagesFixtures.encode(frames, as: .gif)).write(to: url)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        let converted = try await convert(scratch.input(url, format: .image))
        #expect(converted.pageCount == 1)
        let centre = ImagesPDFInspector.colours(in: converted.pdf, page: 0, at: [CGPoint(x: 0.5, y: 0.5)])[0]
        #expect(ImagesPDFInspector.nearest(centre, in: [.red, .green, .blue]) == .red)
    }

    /// Grey and CMYK pictures and transparency: a grey JPEG keeps its data, a CMYK JPEG and the
    /// others are decoded (grey stays one channel), transparency is laid over white.
    @Test func colourModelsAndTransparencyComeOutRight() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let greyJPEG = ImagesFixtures.jpeg(ImagesFixtures.grey(width: 200, height: 300, level: 128), quality: 0.9)
        let cmykJPEG = try #require(ImagesFixtures.encode([ImagesFixtures.cmyk(width: 200, height: 300, c: 0, m: 1, y: 1, k: 0)], as: .jpeg))
        let entries: [(String, Data)] = [
            ("1.jpg", greyJPEG),
            ("2.png", ImagesFixtures.png(ImagesFixtures.grey(width: 200, height: 300, level: 60))),
            ("3.jpg", cmykJPEG),
            ("4.png", ImagesFixtures.png(ImagesFixtures.halfTransparent(width: 200, height: 300, color: .blue))),
        ]
        let converted = try await convert(scratch.input(try archive(entries, in: scratch), format: .comicArchive))
        #expect(converted.pageCount == 4)
        #expect(ImagesPDFInspector.crossReferenceProblems(in: converted.pdf) == [])
        let pdf = try Data(contentsOf: converted.pdf)
        #expect(pdf.range(of: greyJPEG.subdata(in: (greyJPEG.count / 2)..<(greyJPEG.count / 2 + 256))) != nil)
        let centre = [CGPoint(x: 0.5, y: 0.5)]
        let grey1 = ImagesPDFInspector.colours(in: converted.pdf, page: 0, at: centre)[0]
        #expect(abs(Int(grey1.r) - 128) < 12 && grey1.r == grey1.g && grey1.g == grey1.b, "\(grey1)")
        let grey2 = ImagesPDFInspector.colours(in: converted.pdf, page: 1, at: centre)[0]
        #expect(abs(Int(grey2.r) - 60) < 12 && grey2.r == grey2.g && grey2.g == grey2.b, "\(grey2)")
        let cmyk = ImagesPDFInspector.colours(in: converted.pdf, page: 2, at: centre)[0]
        #expect(cmyk.r > 180 && cmyk.g < 90 && cmyk.b < 90, "\(cmyk)")
        let halves = ImagesPDFInspector.colours(in: converted.pdf, page: 3, at: [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.5)])
        #expect(halves[0].distance(to: RGB(r: 255, g: 255, b: 255)) < 12, "\(halves[0])")
        #expect(halves[1].distance(to: .blue) < 40, "\(halves[1])")
    }

    /// Every EXIF orientation comes out upright: the page's quadrants match ImageIO's own upright
    /// rendering of the same file, and quarter-turned pictures get a turned page.
    @Test func exifOrientationsComeOutUpright() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let palette: [RGB] = [.red, .green, .blue, .yellow]
        let stored = ImagesFixtures.quadrants(width: 240, height: 160, palette)
        let all: [CGImagePropertyOrientation] = [.up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left]
        var entries: [(String, Data)] = []
        var expected: [[RGB]] = []
        for (index, orientation) in all.enumerated() {
            let jpeg = ImagesFixtures.jpeg(stored, quality: 0.95, orientation: orientation)
            entries.append(("o\(index + 1).jpg", jpeg))
            // ImageIO's upright rendering of the same file.
            let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
            let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 240,
            ] as CFDictionary)!
            let context = ImagesFixtures.bitmap(width: upright.width, height: upright.height)
            context.draw(upright, in: CGRect(x: 0, y: 0, width: upright.width, height: upright.height))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            expected.append([(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { fx, fy in
                let x = Int(fx * Double(upright.width)), y = Int(fy * Double(upright.height))
                let o = y * context.bytesPerRow + x * 4
                return ImagesPDFInspector.nearest(RGB(r: bytes[o], g: bytes[o + 1], b: bytes[o + 2]), in: palette)
            })
        }
        let converted = try await convert(scratch.input(try archive(entries, in: scratch), format: .comicArchive))
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.pageCount == all.count)
        for (index, orientation) in all.enumerated() {
            let actual = ImagesPDFInspector.quadrantColours(in: converted.pdf, page: index).map {
                ImagesPDFInspector.nearest($0, in: palette)
            }
            #expect(actual == expected[index], "orientation \(orientation.rawValue)")
            let size = document.page(at: index)!.bounds(for: .cropBox).size
            #expect((size.width < size.height) == (orientation.rawValue >= 5), "orientation \(orientation.rawValue): \(size)")
        }
        // Spot check against the definition: orientation 6 (rotate 90° clockwise to view) puts the
        // stored left column at the top, so red/blue on top, green/yellow below.
        #expect(ImagesPDFInspector.quadrantColours(in: converted.pdf, page: 5).map { ImagesPDFInspector.nearest($0, in: palette) }
            == [.blue, .red, .yellow, .green])
        expectStableBoxes(document)
    }

    // MARK: Failures

    /// 60 pages, three unreadable in different ways (allowed: 60 / 20 = 3): each becomes a
    /// placeholder page naming the picture, and every other page keeps its place. A JPEG cut short
    /// inside an intact archive is not detected: ImageIO decodes what is there (the rest grey), as
    /// other viewers show it, so it stays a picture page.
    @Test func unreadablePicturesBecomePlaceholderPages() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let good = ImagesFixtures.jpeg(ImagesFixtures.solid(width: 90, height: 120, color: .red))
        let truncated = ImagesFixtures.jpeg(ImagesFixtures.noise(width: 300, height: 400, seed: 7)).prefix(3000)
        let url = scratch.url("Damaged.cbz")
        let writer = try ImagesZIPWriter(url: url)
        for index in 1...60 {
            let name = String(format: "p%02d.jpg", index)
            switch index {
            case 7: try writer.add(name, Data(repeating: 0xAB, count: 5000))  // not a picture
            case 20: try writer.add(name, good, crc: 0xDEAD_BEEF)  // damaged in the archive
            case 30: try writer.add(name, Data(truncated))
            case 41: try writer.add(name, good, method: 12)  // bzip2: not supported by the ZIP reader
            default: try writer.add(name, good)
            }
        }
        try writer.finish()
        let converted = try await convert(scratch.input(url, format: .comicArchive))
        #expect(converted.pageCount == 60)
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.pageCount == 60)
        for index in 1...60 {
            let text = document.page(at: index - 1)?.string ?? ""
            let isPlaceholder = [7, 20, 41].contains(index)
            #expect(text.contains("could not be read") == isPlaceholder, "page \(index): \(text)")
            if isPlaceholder { #expect(text.contains(String(format: "p%02d.jpg", index)), "page \(index): \(text)") }
        }
        let truncatedSize = document.page(at: 29)!.bounds(for: .cropBox).size
        #expect(abs(truncatedSize.width / truncatedSize.height - 0.75) < 0.001)
        expectStableBoxes(document)
        #expect(ImagesPDFInspector.crossReferenceProblems(in: converted.pdf) == [])
    }

    @Test func oversizePicturesBecomePlaceholderPages() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let small = ImagesFixtures.jpeg(ImagesFixtures.solid(width: 60, height: 90, color: .red))
        let heavy = ImagesFixtures.jpeg(ImagesFixtures.noise(width: 400, height: 400, seed: 3))  // many bytes
        let wide = ImagesFixtures.png(ImagesFixtures.solid(width: 1500, height: 1000, color: .blue))  // many pixels
        let maxEntryBytes = max(small.count, wide.count)
        try #require(heavy.count > maxEntryBytes)
        let entries = (1...40).map { index -> (String, Data) in
            (String(format: "%02d.jpg", index), index == 10 ? heavy : index == 20 ? wide : small)
        }
        let input = scratch.input(try archive(entries, in: scratch), format: .comicArchive)
        let converter = ImagesConverter(limits: .init(maxEntryBytes: UInt64(maxEntryBytes), maxPixels: 1_000_000))
        let converted = try await converter.convert(input) { _ in }
        let document = try #require(PDFDocument(url: converted.pdf))
        #expect(document.pageCount == 40)
        #expect(document.page(at: 9)?.string?.contains("10.jpg") == true)
        #expect(document.page(at: 19)?.string?.contains("20.jpg") == true)
        #expect(document.page(at: 0)?.string?.isEmpty != false)
    }

    @Test func unreadableFirstPageFailsAndLeavesNothing() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let good = ImagesFixtures.jpeg(ImagesFixtures.solid(width: 90, height: 120, color: .red))
        let entries = [("01.jpg", Data("broken".utf8))] + (2...40).map { (String(format: "%02d.jpg", $0), good) }
        let input = scratch.input(try archive(entries, in: scratch), format: .comicArchive)
        await #expect(throws: ConversionError.failed(reason: "the first picture, “01.jpg”, could not be read: it is not a picture that can be decoded")) {
            _ = try await convert(input)
        }
        #expect(stagingContents(input).isEmpty)
    }

    @Test func tooManyUnreadablePicturesFailAndLeaveNothing() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let good = ImagesFixtures.jpeg(ImagesFixtures.solid(width: 90, height: 120, color: .red))
        // 20 pages allow one failure; the second fails the conversion.
        let entries = (1...20).map { index in
            (String(format: "%02d.jpg", index), [5, 12].contains(index) ? Data("broken".utf8) : good)
        }
        let input = scratch.input(try archive(entries, in: scratch), format: .comicArchive)
        await #expect(throws: ConversionError.failed(reason: "2 pictures could not be read, the first being “05.jpg”")) {
            _ = try await convert(input)
        }
        #expect(stagingContents(input).isEmpty)
    }

    @Test func archiveWithoutPicturesFails() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let empty = scratch.input(try archive([], in: scratch, name: "Empty.cbz"), format: .comicArchive)
        await #expect(throws: ConversionError.failed(reason: "the archive contains no pictures")) { _ = try await convert(empty) }
        #expect(stagingContents(empty).isEmpty)
        let litter = scratch.input(try archive([("__MACOSX/._a.jpg", Data("x".utf8)), ("ComicInfo.xml", Data("<a/>".utf8)),
                                                ("folder/", Data())], in: scratch, name: "Litter.cbz"), format: .comicArchive)
        await #expect(throws: ConversionError.failed(reason: "the archive contains no pictures")) { _ = try await convert(litter) }
        #expect(stagingContents(litter).isEmpty)
        let notZIP = scratch.url("Fake.cbz")
        try Data("not a zip".utf8).write(to: notZIP)
        await #expect(throws: ConversionError.failed(reason: "the archive could not be opened: it is not a ZIP archive")) {
            _ = try await convert(scratch.input(notZIP, format: .comicArchive))
        }
    }

    @Test func unreadablePictureFileFails() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let url = scratch.url("Broken.png")
        try Data("definitely not a png".utf8).write(to: url)
        let input = scratch.input(url, format: .image)
        await #expect(throws: ConversionError.self) { _ = try await convert(input) }
        #expect(stagingContents(input).isEmpty)
    }

    @Test func encryptedArchiveIsProtected() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let good = ImagesFixtures.jpeg(ImagesFixtures.solid(width: 90, height: 120, color: .red))
        let url = scratch.url("Locked.cbz")
        let writer = try ImagesZIPWriter(url: url)
        try writer.add("01.jpg", good)
        try writer.add("02.jpg", good, flags: 0x0001)
        try writer.finish()
        let input = scratch.input(url, format: .comicArchive)
        await #expect(throws: ConversionError.protected) { _ = try await convert(input) }
        #expect(stagingContents(input).isEmpty)
    }

    @Test func cancellingMidwayThrowsAndLeavesNothing() async throws {
        let scratch = try makeScratch(); defer { cleanup(scratch) }
        let pages = (1...60).map { index in
            (String(format: "%02d.jpg", index), ImagesFixtures.jpeg(ImagesFixtures.noise(width: 200, height: 300, seed: UInt64(index))))
        }
        let input = scratch.input(try archive(pages, in: scratch), format: .comicArchive)
        let fractions = ImagesFractions()
        let task = Task {
            try await ImagesConverter().convert(input) { fraction in
                fractions.append(fraction)
                // Cancel the converting task itself once a quarter is done.
                if fraction >= 0.25 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(fractions.values.last.map { $0 >= 0.25 && $0 < 0.3 } == true, "\(fractions.values)")
        #expect(stagingContents(input).isEmpty)
    }
}
