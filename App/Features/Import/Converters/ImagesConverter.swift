import CoreGraphics
import Foundation
import ImageIO
import ReaderCore
import UniformTypeIdentifiers

/// Converts comic archives (CBZ, or a ZIP of pictures) and picture files to a PDF of one picture per
/// page. See docs/FORMAT_IMPORT_PLAN.md ▸ "Images converter".
///
/// - **Which entries are pages.** Every file entry of the archive whose name has a picture extension
///   and that the format detector does not ignore (`__MACOSX/`, names starting with a dot in any
///   folder, `.xml`/`.txt`/`.nfo`/`.sfv`, `Thumbs.db`, `desktop.ini`), in natural order of the full
///   path (`page2` before `page10`, folder by folder). Other entries are left out.
/// - **Frames.** A TIFF gives one page per frame (multi-page scans). Any other picture gives its
///   primary image only: an animated GIF, PNG or WebP shows its first frame.
/// - **Page size.** The page has the picture's shape as displayed (EXIF orientation applied) and the
///   area of a US Letter page; see `ImagesPDFWriter.pageSize(forDisplayPixels:)`. The picture is
///   stored at full resolution, never downsampled; an 8-bit RGB or grey JPEG is copied in without
///   re-encoding. Crop box = media box at (0, 0), rotation 0, so ink coordinates are stable.
/// - **Pictures that cannot be read** (not decodable by ImageIO, an archive entry whose data fails
///   its CRC or size check, a compression method the ZIP reader lacks, an unsafe entry name, over
///   `Limits`): the conversion fails, naming the picture, when it is the first page or when more
///   than one picture in twenty fails. Otherwise the page is kept as a plain placeholder page
///   naming the picture, so no page is lost silently and the page numbers still match the archive.
///   A JPEG that was already cut short when archived is not caught: ImageIO decodes what is there
///   (the rest grey), as other viewers do, and it stays a picture page.
/// - **Encrypted entries** (a password-protected ZIP): `ConversionError.protected`.
/// - No title, no cover image (the flow renders page one), no outline.
///
/// Memory: one entry's bytes and one decoded picture at a time, released after each page (an
/// autorelease pool per entry), and a PDF writer that keeps nothing of a written page (see
/// `ImagesPDFWriter` for why it is not `CGPDFContext`). Runs on the cooperative pool, never on
/// the main actor.
nonisolated struct ImagesConverter: DocumentConverter {
    struct Limits: Sendable, Equatable {
        /// Largest archive entry read into memory.
        var maxEntryBytes: UInt64 = 256 << 20
        /// Largest picture, in pixels (width × height). Decoding one this size takes ~400 MB.
        var maxPixels: Int = 100_000_000
    }

    var version: Int { 1 }
    var formats: Set<ImportFormat> { [.comicArchive, .image] }
    var limits = Limits()

    func convert(_ input: ConversionInput, progress: @escaping @Sendable (Double) -> Void) async throws -> ConvertedDocument {
        try await Self.run(input, limits: limits, progress: progress)
    }

    @concurrent
    static func run(_ input: ConversionInput, limits: Limits,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> ConvertedDocument {
        try Task.checkCancellation()
        let pageCount: Int
        do {
            switch input.format {
            case .comicArchive: pageCount = try convertArchive(input, limits: limits, progress: progress)
            case .image: pageCount = try convertPictureFile(input, limits: limits, progress: progress)
            default: throw ConversionError.unsupported(reason: "not a comic archive or a picture")
            }
        } catch let error as ConversionError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            throw ConversionError.failed(reason: "the PDF could not be written: \(error.localizedDescription)")
        }
        progress(1)
        return ConvertedDocument(pdf: input.outputURL, pageCount: pageCount, title: nil, coverImage: nil)
    }

    // MARK: Archive

    /// File extensions taken as pictures inside an archive (the detector's list).
    static let pictureExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "webp", "tif", "tiff", "heic", "heif", "bmp", "avif",
    ]
    private static let ignoredExtensions: Set<String> = ["xml", "txt", "nfo", "sfv"]
    private static let ignoredNames: Set<String> = ["thumbs.db", "desktop.ini"]

    /// The same rule as `ImportFormatDetector.isIgnoredComicEntry` (internal to ReaderCore).
    static func isIgnored(_ path: String) -> Bool {
        if path.hasPrefix("__MACOSX/") { return true }
        let components = path.split(separator: "/")
        if components.contains(where: { $0.hasPrefix(".") }) { return true }
        guard let name = components.last?.lowercased() else { return true }
        return ignoredNames.contains(name) || ignoredExtensions.contains(fileExtension(name))
    }

    static func fileExtension(_ path: String) -> String {
        guard let name = path.split(separator: "/").last, let dot = name.lastIndex(of: "."),
              dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// The archive's page entries in reading order.
    static func pageEntries(_ entries: [ZIPEntry]) -> [ZIPEntry] {
        let pictures = entries.filter {
            !$0.isDirectory && !isIgnored($0.path) && pictureExtensions.contains(fileExtension($0.path))
        }
        return NaturalSort.sorted(pictures, by: \.path)
    }

    private static func convertArchive(_ input: ConversionInput, limits: Limits,
                                       progress: @Sendable (Double) -> Void) throws -> Int {
        let archive: ZIPArchive
        do {
            archive = try ZIPArchive(url: input.original)
        } catch {
            throw ConversionError.failed(reason: "the archive could not be opened: \(describe(error))")
        }
        let entries = pageEntries(archive.entries)
        guard !entries.isEmpty else { throw ConversionError.failed(reason: "the archive contains no pictures") }
        if entries.contains(where: \.isEncrypted) { throw ConversionError.protected }
        try Task.checkCancellation()

        let writer = try ImagesPDFWriter(url: input.outputURL)
        do {
            var budget = ImagesFailureBudget(units: entries.count)
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                try autoreleasepool {
                    let data: Data
                    do {
                        data = try archive.data(for: entry, maxSize: limits.maxEntryBytes)
                    } catch {
                        try budget.record(entry.path, reason: describe(error), writer: writer)
                        return
                    }
                    try appendPictures(from: data, name: entry.path, limits: limits, writer: writer, budget: &budget)
                }
                progress(Double(index + 1) / Double(entries.count))
            }
            try writer.close()
            return writer.pageCount
        } catch {
            writer.abandon()
            throw error
        }
    }

    // MARK: Single picture file

    private static func convertPictureFile(_ input: ConversionInput, limits: Limits,
                                           progress: @Sendable (Double) -> Void) throws -> Int {
        // Mapped, not read: a large multi-page TIFF does not count against memory.
        let data: Data
        do {
            data = try Data(contentsOf: input.original, options: .alwaysMapped)
        } catch {
            throw ConversionError.failed(reason: "the picture could not be opened: \(error.localizedDescription)")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions), !frameIndices(of: source).isEmpty else {
            throw ConversionError.failed(reason: "the file is not a picture that can be read")
        }
        let frames = frameIndices(of: source)
        try Task.checkCancellation()

        let writer = try ImagesPDFWriter(url: input.outputURL)
        do {
            var budget = ImagesFailureBudget(units: frames.count)
            let jpeg = jpegData(data, source: source, frames: frames)
            for (position, frame) in frames.enumerated() {
                try Task.checkCancellation()
                let name = frames.count > 1 ? "\(input.fileName), page \(position + 1)" : input.fileName
                try autoreleasepool {
                    if let failure = try appendFrame(frame, of: source, jpeg: jpeg, limits: limits, writer: writer) {
                        try budget.record(name, reason: failure, writer: writer)
                    }
                }
                progress(Double(position + 1) / Double(frames.count))
            }
            try writer.close()
            return writer.pageCount
        } catch {
            writer.abandon()
            throw error
        }
    }

    // MARK: Pictures

    private static var sourceOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }
    /// A tiny thumbnail made from the full image data: proves the picture decodes, cheaply
    /// (JPEG decodes at 1/8 scale), without keeping a full decoded copy.
    private static var checkOptions: CFDictionary {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 16,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
    }

    /// The frames that become pages: every frame of a TIFF, the primary image of anything else.
    static func frameIndices(of source: CGImageSource) -> [Int] {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return [] }
        if let type = CGImageSourceGetType(source), type as String == UTType.tiff.identifier {
            return Array(0..<count)
        }
        return [min(CGImageSourceGetPrimaryImageIndex(source), count - 1)]
    }

    /// The file's bytes when it is a single JPEG, so they can be stored without re-encoding.
    private static func jpegData(_ data: Data, source: CGImageSource, frames: [Int]) -> Data? {
        guard frames.count == 1, let type = CGImageSourceGetType(source), type as String == UTType.jpeg.identifier else {
            return nil
        }
        return data
    }

    /// Adds a page for each frame of the picture in `data` (a placeholder for a frame that fails).
    private static func appendPictures(from data: Data, name: String, limits: Limits, writer: ImagesPDFWriter,
                                       budget: inout ImagesFailureBudget) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            try budget.record(name, reason: "it is not a picture", writer: writer)
            return
        }
        let frames = frameIndices(of: source)
        guard !frames.isEmpty else {
            try budget.record(name, reason: "it is not a picture that can be decoded", writer: writer)
            return
        }
        let jpeg = jpegData(data, source: source, frames: frames)
        for (position, frame) in frames.enumerated() {
            if let failure = try appendFrame(frame, of: source, jpeg: jpeg, limits: limits, writer: writer) {
                try budget.record(frames.count > 1 ? "\(name), page \(position + 1)" : name, reason: failure, writer: writer)
            }
        }
    }

    /// Writes one frame as a page. Returns why it could not, or `nil` when the page was added.
    /// Throws only when the PDF itself cannot be written.
    private static func appendFrame(_ index: Int, of source: CGImageSource, jpeg: Data?, limits: Limits,
                                    writer: ImagesPDFWriter) throws -> String? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            return "it is not a picture that can be decoded"
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= limits.maxPixels else { return "it is too large (\(width) × \(height) pixels)" }
        guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
              CGImageSourceCreateThumbnailAtIndex(source, index, checkOptions) != nil,
              let image = CGImageSourceCreateImageAtIndex(source, index, sourceOptions) else {
            return "its data is damaged or incomplete"
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        try writer.addPage(image, jpeg: jpeg, orientation: orientation)
        return nil
    }

    static func describe(_ error: any Error) -> String {
        guard let error = error as? ZIPError else { return error.localizedDescription }
        switch error {
        case .entryTooLarge(_, let size, _):
            return "it is too large (\(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)))"
        case .unsupportedCompressionMethod(_, let method): return "it is compressed with a method the app can't read (\(method))"
        case .unsafeEntryName: return "its name is not allowed in an archive"
        case .encryptedEntry: return "it is encrypted"
        case .notAZIPArchive: return "it is not a ZIP archive"
        case .readFailed(let reason): return reason
        case .tooManyEntries, .centralDirectoryTooLarge, .totalUncompressedSizeTooLarge: return "it is too large"
        default: return "its data is damaged"
        }
    }
}

/// How many pictures may fail before the whole conversion fails: none on the first page, and at
/// most one in twenty overall. Each failure within the budget becomes a placeholder page.
nonisolated struct ImagesFailureBudget {
    let units: Int
    private(set) var failures = 0
    private(set) var firstFailure: String?

    init(units: Int) { self.units = units }

    /// One picture in twenty may fail (none in a book of fewer than twenty).
    var allowed: Int { units / 20 }

    mutating func record(_ name: String, reason: String, writer: ImagesPDFWriter) throws {
        if writer.pageCount == 0 {
            throw ConversionError.failed(reason: "the first picture, “\(name)”, could not be read: \(reason)")
        }
        failures += 1
        if firstFailure == nil { firstFailure = name }
        if failures > allowed {
            throw ConversionError.failed(reason: "\(failures) pictures could not be read, the first being “\(firstFailure ?? name)”")
        }
        try writer.addPlaceholderPage(naming: name)
    }
}
