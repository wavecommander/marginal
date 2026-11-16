import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import ReaderBackup
import ReaderCore
import UIKit
import UniformTypeIdentifiers

/// The file work of an import. Everything here is `nonisolated` and the entry points are
/// `@concurrent`, so it runs on the cooperative pool, never on the main actor, and never holds a
/// whole file in memory (the copy streams 4 MiB at a time).
nonisolated enum ImportPipeline {
    /// What `preflight` learns about a source file without copying it.
    struct Probe: Sendable, Equatable {
        /// Bytes; for a package directory, the total of its files.
        var size: Int64
        var fingerprint: String
    }

    /// The cheap check every file gets before anything is copied or the sheet is shown: the
    /// format (`ImportFormatDetector`, the single source of truth for "is this a PDF"), the size
    /// and, for a file the app can import, its fingerprint.
    struct Preflight: Sendable, Equatable {
        var detection: ImportDetection
        /// `nil` unless `detection` is `.supported`.
        var probe: Probe?
    }

    /// What `stage` produced inside the staging directory.
    struct Staged: Sendable, Equatable {
        var pageCount: Int
        var fileSize: Int64
        var hasCover: Bool
        /// Scan detection found the book scanned (S3: `ScanDetector`, sampled from this staged
        /// file's own document).
        var isScanned = false
    }

    static let copyChunkSize = 4 * 1024 * 1024
    static let coverFileName = "cover.jpg"
    /// The text size and converter of a converted book, beside its PDF (`ConversionRecord`).
    static let conversionRecordFileName = "conversion.json"
    /// Longest side of the stored cover, in pixels.
    static let coverMaxPixels: CGFloat = 520

    // MARK: Preflight

    /// Detects the format, and for an importable file reads its size and fingerprint (at most
    /// 2 MiB of reads per file; a package directory reads that much per file inside it).
    @concurrent
    static func preflight(_ source: URL, fileName: String) async throws -> Preflight {
        try Task.checkCancellation()
        do {
            let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            let size = try itemSize(at: source)
            guard size > 0 || isDirectory else { return Preflight(detection: .unknown, probe: nil) }
            let detection = try ImportFormatDetector.detect(fileAt: source)
            guard case .supported = detection else { return Preflight(detection: detection, probe: nil) }
            let fingerprint = isDirectory ? try BookFingerprint.fingerprint(ofPackageAt: source)
                                          : try BookFingerprint.fingerprint(ofFileAt: source)
            return Preflight(detection: detection, probe: Probe(size: size, fingerprint: fingerprint))
        } catch {
            throw ImportError.unreadable(fileName: fileName, reason: error.localizedDescription)
        }
    }

    /// Size in bytes of a file, or the total of the regular files inside a directory.
    static func itemSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values.isDirectory == true else { return Int64(values.fileSize ?? 0) }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        for case let file as URL in enumerator {
            let fileValues = try file.resourceValues(forKeys: Set(keys))
            if fileValues.isRegularFile == true { total += Int64(fileValues.fileSize ?? 0) }
        }
        return total
    }

    // MARK: Stage

    /// Copies (or, with `consume`, moves) `source` into `directory/fileName`, opens it to check it
    /// is a usable PDF, and renders the cover next to it. `progress` receives the fraction
    /// `0...1` of the copy; it is called off the main actor. On any error the caller removes
    /// `directory`.
    @concurrent
    static func stage(source: URL, directory: URL, fileName: String, consume: Bool, size: Int64,
                      progress: @Sendable (Double) -> Void) async throws -> Staged {
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        try place(source: source, at: destination, directory: directory, fileName: fileName, consume: consume,
                  size: size, progress: progress)
        try Task.checkCancellation()
        return try check(pdf: destination, directory: directory, fileName: fileName, coverImage: nil)
    }

    /// Copies (or, with `consume`, moves) `source` to `destination` inside `directory`, creating
    /// the directory. A package directory is copied whole (no progress until it is done).
    static func place(source: URL, at destination: URL, directory: URL, fileName: String, consume: Bool,
                      size: Int64, progress: @Sendable (Double) -> Void) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ImportError.storage(fileName: fileName, reason: error.localizedDescription)
        }
        if consume, (try? fileManager.moveItem(at: source, to: destination)) != nil {
            progress(1)
            return
        }
        do {
            if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try fileManager.copyItem(at: source, to: destination)
                progress(1)
            } else {
                try copyStreaming(from: source, to: destination, totalSize: size, progress: progress)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NSError where isOutOfSpace(error) {
            throw ImportError.storage(fileName: fileName, reason: error.localizedDescription)
        } catch {
            throw ImportError.unreadable(fileName: fileName, reason: error.localizedDescription)
        }
    }

    /// The stage checks, for an imported PDF and a converted one alike: it opens, is not locked
    /// and has pages; then the cover (`coverImage` scaled down when given, else page one) is
    /// written to `cover.jpg` in `directory`, and scan detection samples the same document.
    static func check(pdf destination: URL, directory: URL, fileName: String, coverImage: URL?) throws -> Staged {
        guard let document = PDFDocument(url: destination) else { throw ImportError.notAPDF(fileName: fileName) }
        if document.isLocked { throw ImportError.locked(fileName: fileName) }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw ImportError.noPages(fileName: fileName) }
        try Task.checkCancellation()

        let coverURL = directory.appendingPathComponent(coverFileName)
        let hasCover = coverImage.map { renderCover(ofImage: $0, to: coverURL) } == true
            || renderCover(of: destination, to: coverURL)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        try Task.checkCancellation()
        let isScanned = ScanDetector.isScanned(document)
        return Staged(pageCount: pageCount, fileSize: size, hasCover: hasCover, isScanned: isScanned)
    }

    // MARK: Convert

    /// Copies (or, with `consume`, moves) a converted book's original to `destination`
    /// (`original.<ext>` in the staging directory) before the converter runs.
    @concurrent
    static func placeOriginal(source: URL, at destination: URL, directory: URL, fileName: String, consume: Bool,
                              size: Int64, progress: @Sendable (Double) -> Void) async throws {
        try place(source: source, at: destination, directory: directory, fileName: fileName, consume: consume,
                  size: size, progress: progress)
    }

    /// After a re-conversion in `staging`: moves the PDF named `documentFileName` into the book's
    /// `directory` (created if missing), and the kept original, `cover.jpg` and
    /// `conversion.json` too where the book has none.
    @concurrent
    static func restore(from staging: URL, into directory: URL, documentFileName: String, fileName: String) async throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: staging.appendingPathComponent(documentFileName),
                                     to: directory.appendingPathComponent(documentFileName))
            let kept = (try? fileManager.contentsOfDirectory(atPath: staging.path)) ?? []
            for name in kept where name.hasPrefix("original") || name == coverFileName || name == conversionRecordFileName {
                let target = directory.appendingPathComponent(name)
                if !fileManager.fileExists(atPath: target.path) {
                    try? fileManager.moveItem(at: staging.appendingPathComponent(name), to: target)
                }
            }
        } catch {
            throw ImportError.storage(fileName: fileName, reason: error.localizedDescription)
        }
    }

    /// Runs `converter` off the main actor (a converter's `convert` is `nonisolated`, so without
    /// this hop it would run on the caller's actor). A `ConversionError` becomes an `ImportError`.
    @concurrent
    static func convert(with converter: any DocumentConverter, input: ConversionInput,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> ConvertedDocument {
        do {
            return try await converter.convert(input, progress: progress)
        } catch let error as ConversionError {
            throw ImportError.from(error, fileName: input.fileName)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.conversionFailed(fileName: input.fileName, reason: error.localizedDescription)
        }
    }

    /// The stage checks on a converter's output. A PDF that does not open or is locked is the
    /// converter's failure, not the reader's file's.
    @concurrent
    static func checkConverted(_ converted: ConvertedDocument, directory: URL, fileName: String) async throws -> Staged {
        do {
            // Only an image inside the staging directory is used (the contract); it is removed
            // once `cover.jpg` is made from it, so the book's directory holds no stray files.
            let inside = directory.standardizedFileURL.path + "/"
            let cover = converted.coverImage.flatMap { $0.standardizedFileURL.path.hasPrefix(inside) ? $0 : nil }
            let staged = try check(pdf: converted.pdf, directory: directory, fileName: fileName, coverImage: cover)
            if let cover, cover.lastPathComponent != coverFileName, cover.standardizedFileURL != converted.pdf.standardizedFileURL {
                try? FileManager.default.removeItem(at: cover)
            }
            return staged
        } catch ImportError.notAPDF {
            throw ImportError.conversionFailed(fileName: fileName, reason: "the converted PDF could not be opened")
        } catch ImportError.locked {
            throw ImportError.conversionFailed(fileName: fileName, reason: "the converted PDF is locked")
        }
    }

    /// Writes `record` as `conversion.json` in `directory`.
    @concurrent
    static func writeConversionRecord(_ record: ConversionRecord, in directory: URL, fileName: String) async throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: directory.appendingPathComponent(conversionRecordFileName), options: .atomic)
        } catch {
            throw ImportError.storage(fileName: fileName, reason: error.localizedDescription)
        }
    }

    /// The `conversion.json` in `directory`, or `nil` when it is missing or unreadable.
    @concurrent
    static func readConversionRecord(in directory: URL) async -> ConversionRecord? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(conversionRecordFileName)) else { return nil }
        return try? JSONDecoder().decode(ConversionRecord.self, from: data)
    }

    /// Size in bytes of `url` (file or package), `0` when it cannot be read.
    @concurrent
    static func size(of url: URL) async -> Int64 {
        (try? itemSize(at: url)) ?? 0
    }

    /// Moves `staged` to `destination`, replacing nothing (fails if it exists).
    @concurrent
    static func move(_ staged: URL, to destination: URL, fileName: String) async throws {
        do {
            try FileManager.default.moveItem(at: staged, to: destination)
        } catch {
            throw ImportError.storage(fileName: fileName, reason: error.localizedDescription)
        }
    }

    /// Whether a file or directory exists at `url`, checked off the main actor.
    @concurrent
    static func exists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func isOutOfSpace(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
    }

    /// Chunked file copy with progress and cooperative cancellation. Removes a partial
    /// destination before rethrowing.
    static func copyStreaming(from source: URL, to destination: URL, totalSize: Int64,
                              progress: @Sendable (Double) -> Void) throws {
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var copied: Int64 = 0
            var lastReported = -1.0
            while true {
                try Task.checkCancellation()
                let chunk: Data? = try autoreleasepool { try input.read(upToCount: copyChunkSize) }
                guard let chunk, !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                if totalSize > 0 {
                    let fraction = min(1, Double(copied) / Double(totalSize))
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress(fraction)
                    }
                }
            }
            progress(1)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    // MARK: Cover

    /// Renders page one into `destination` as a JPEG whose longest side is `coverMaxPixels`.
    /// Uses CoreGraphics (thread-safe) rather than PDFKit. Returns `false` if it could not.
    static func renderCover(of pdf: URL, to destination: URL) -> Bool {
        guard let data = coverJPEG(of: pdf) else { return false }
        return (try? data.write(to: destination, options: .atomic)) != nil
    }

    /// Scales the image at `image` down to `coverMaxPixels` on its longest side and writes it to
    /// `destination` as a JPEG (ImageIO: thread-safe, decodes only the thumbnail). Returns
    /// `false` if it could not.
    static func renderCover(ofImage image: URL, to destination: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil) else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: coverMaxPixels,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: thumbnail.width, height: thumbnail.height)
        let flattened = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: thumbnail).draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = flattened.jpegData(compressionQuality: 0.82) else { return false }
        return (try? data.write(to: destination, options: .atomic)) != nil
    }

    static func coverJPEG(of pdf: URL, maxPixels: CGFloat = coverMaxPixels) -> Data? {
        guard let document = CGPDFDocument(pdf as CFURL) else { return nil }
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") { return nil }
        guard document.numberOfPages > 0, let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let rotated = page.rotationAngle % 180 != 0
        let natural = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = maxPixels / max(natural.width, natural.height)
        let target = CGSize(width: max(1, (natural.width * scale).rounded()),
                            height: max(1, (natural.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            let cg = context.cgContext
            cg.translateBy(x: 0, y: target.height)
            cg.scaleBy(x: 1, y: -1)
            cg.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: target),
                                                    rotate: 0, preserveAspectRatio: true))
            cg.drawPDFPage(page)
        }
        return image.jpegData(compressionQuality: 0.82)
    }

    // MARK: Housekeeping

    /// Removes `url` if it exists (best effort), off the main actor.
    @concurrent
    static func remove(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes the entries of `directory` last modified before `cutoff` (stale staging
    /// directories from a previous run). Best effort.
    @concurrent
    static func removeStale(in directory: URL, before cutoff: Date) async {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let url = directory.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < cutoff { try? fileManager.removeItem(at: url) }
        }
    }

    /// Moves a file handed over by a drop (a temporary file the system deletes when the callback
    /// returns) into `directory`, so it can be imported afterwards. Runs on the system's
    /// callback queue. Returns the new URL.
    ///
    /// A name without an extension gets the temporary file's extension, else the preferred one
    /// of `typeIdentifier` (the type the drop was loaded as), since format detection falls back
    /// on the extension for some formats (Word 97, iWork, text).
    static func adoptDroppedFile(_ temporary: URL, suggestedName: String?, typeIdentifier: String? = nil,
                                 into directory: URL) throws -> URL {
        let fileManager = FileManager.default
        var name = sanitizedFileName(suggestedName ?? temporary.lastPathComponent)
        if (name as NSString).pathExtension.isEmpty {
            let ext = temporary.pathExtension.isEmpty
                ? (typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension } ?? "")
                : temporary.pathExtension
            if !ext.isEmpty { name += ".\(ext)" }
        }
        let folder = directory.appendingPathComponent("drop-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try fileManager.copyItem(at: temporary, to: destination)
        }
        return destination
    }

    /// Whether `name` is one the app itself uses at the top of a book's directory: the cover,
    /// the conversion record, the hash sidecar, a kept original, the ink folders, and
    /// `records.json` (which a backup reserves). Compared without regard to case, because the
    /// simulator's file system ignores it.
    static func isReservedFileName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let reserved = [coverFileName, conversionRecordFileName, BookStorageLayout.contentHashFileName,
                        BackupArchiveLayout.recordsFileName, "ink", "notes"]
        return reserved.contains(lowered) || BookStorageLayout.isOriginalFileName(lowered)
    }

    /// The name a book's PDF is stored under in its directory: `sanitizedFileName`, and never a
    /// name the app uses there itself. A PDF that arrives as `cover.jpg` would otherwise be
    /// overwritten by its own cover, and one called `original.pdf` taken for a kept original; such
    /// a name gets `-book` before its extension (`original-book.pdf`). The book's title still
    /// comes from the name the file arrived with.
    static func documentFileName(_ name: String) -> String {
        let cleaned = sanitizedFileName(name)
        guard isReservedFileName(cleaned) else { return cleaned }
        let ext = (cleaned as NSString).pathExtension
        let stem = (cleaned as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem)-book" : "\(stem)-book.\(ext)"
    }

    /// A file name safe to use inside a book directory: no separators, not empty, not hidden,
    /// at most 120 characters (the extension is kept).
    static func sanitizedFileName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "Document.pdf" }
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            let stem = String((cleaned as NSString).deletingPathExtension.prefix(100))
            cleaned = ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        return cleaned
    }
}
