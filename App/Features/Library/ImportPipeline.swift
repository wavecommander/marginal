import CoreGraphics
import Foundation
import PDFKit
import UIKit

/// The file work of an import. Everything here is `nonisolated` and the entry points are
/// `@concurrent`, so it runs on the cooperative pool, never on the main actor, and never holds a
/// whole file in memory (the copy streams 4 MiB at a time).
nonisolated enum ImportPipeline {
    /// What `probe` learns about a source file without copying it.
    struct Probe: Sendable, Equatable {
        var size: Int64
        var fingerprint: String
    }

    /// What `stage` produced inside the staging directory.
    struct Staged: Sendable, Equatable {
        var pageCount: Int
        var fileSize: Int64
        var hasCover: Bool
    }

    static let copyChunkSize = 4 * 1024 * 1024
    static let coverFileName = "cover.jpg"
    /// Longest side of the stored cover, in pixels.
    static let coverMaxPixels: CGFloat = 520

    // MARK: Probe

    /// Reads the size, checks the `%PDF-` header and computes the fingerprint (2 MiB of reads).
    @concurrent
    static func probe(_ source: URL, fileName: String) async throws -> Probe {
        try Task.checkCancellation()
        do {
            let values = try source.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard values.isDirectory != true else { throw ImportError.notAPDF(fileName: fileName) }
            let size = Int64(values.fileSize ?? 0)
            guard size > 0, try hasPDFHeader(source) else { throw ImportError.notAPDF(fileName: fileName) }
            return Probe(size: size, fingerprint: try BookFingerprint.fingerprint(ofFileAt: source))
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.unreadable(fileName: fileName, reason: error.localizedDescription)
        }
    }

    /// `%PDF-` within the first 1 KiB (the PDF specification allows leading junk).
    static func hasPDFHeader(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 1024) ?? Data()
        return head.range(of: Data("%PDF-".utf8)) != nil
    }

    // MARK: Stage

    /// Copies (or, with `consume`, moves) `source` into `directory/fileName`, opens it to check it
    /// is a usable PDF, and renders the cover next to it. `progress` receives the fraction
    /// `0...1` of the copy; it is called off the main actor. On any error the caller removes
    /// `directory`.
    @concurrent
    static func stage(source: URL, directory: URL, fileName: String, consume: Bool, size: Int64,
                      progress: @Sendable (Double) -> Void) async throws -> Staged {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ImportError.storage(fileName: fileName, reason: error.localizedDescription)
        }
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        if consume, (try? fileManager.moveItem(at: source, to: destination)) != nil {
            progress(1)
        } else {
            do {
                try copyStreaming(from: source, to: destination, totalSize: size, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NSError where isOutOfSpace(error) {
                throw ImportError.storage(fileName: fileName, reason: error.localizedDescription)
            } catch {
                throw ImportError.unreadable(fileName: fileName, reason: error.localizedDescription)
            }
        }
        try Task.checkCancellation()

        guard let document = PDFDocument(url: destination) else { throw ImportError.notAPDF(fileName: fileName) }
        if document.isLocked { throw ImportError.locked(fileName: fileName) }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw ImportError.noPages(fileName: fileName) }
        try Task.checkCancellation()

        let hasCover = renderCover(of: destination, to: directory.appendingPathComponent(coverFileName))
        let copiedSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? size
        return Staged(pageCount: pageCount, fileSize: copiedSize, hasCover: hasCover)
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
    static func adoptDroppedFile(_ temporary: URL, suggestedName: String?, into directory: URL) throws -> URL {
        let fileManager = FileManager.default
        var name = sanitizedFileName(suggestedName ?? temporary.lastPathComponent)
        if (name as NSString).pathExtension.isEmpty { name += ".pdf" }
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
