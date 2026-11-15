import CoreGraphics
import Darwin
import Foundation
import ImageIO
import ReaderCore
import UniformTypeIdentifiers
@testable import Marginal

/// Writes a ZIP archive of stored (uncompressed) entries straight to a file, for building comic
/// archive fixtures. `method` and `flags` are written as given, so entries can claim an unsupported
/// compression method or encryption.
nonisolated final class ImagesZIPWriter {
    private let handle: FileHandle
    private var central = Data()
    private var count = 0
    private var offset: UInt64 = 0

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }

    /// `crc` overrides the checksum (a damaged entry).
    func add(_ path: String, _ data: Data, method: UInt16 = 0, flags: UInt16 = 0, crc: UInt32? = nil) throws {
        let name = Data(path.utf8)
        let crc = crc ?? CRC32.checksum(data)
        var local = Data()
        local.le32(0x0403_4B50); local.le16(20); local.le16(flags); local.le16(method)
        local.le16(0); local.le16(0x21)  // time, date (1 January 1980)
        local.le32(crc); local.le32(UInt32(data.count)); local.le32(UInt32(data.count))
        local.le16(UInt16(name.count)); local.le16(0)
        local.append(name)
        try handle.write(contentsOf: local)
        try handle.write(contentsOf: data)

        let isDirectory = path.hasSuffix("/")
        central.le32(0x0201_4B50); central.le16(20); central.le16(20); central.le16(flags); central.le16(method)
        central.le16(0); central.le16(0x21)
        central.le32(crc); central.le32(UInt32(data.count)); central.le32(UInt32(data.count))
        central.le16(UInt16(name.count)); central.le16(0); central.le16(0)  // name, extra, comment lengths
        central.le16(0); central.le16(0); central.le32(isDirectory ? 0x10 : 0)  // disk, internal, external
        central.le32(UInt32(offset))
        central.append(name)
        offset += UInt64(local.count + data.count)
        count += 1
    }

    func addDirectory(_ path: String) throws { try add(path.hasSuffix("/") ? path : path + "/", Data()) }

    func finish() throws {
        var end = Data()
        end.le32(0x0605_4B50); end.le16(0); end.le16(0)
        end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(central.count)); end.le32(UInt32(offset)); end.le16(0)
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end)
        try handle.close()
    }

    /// Writes an archive of `entries` (path, bytes) in the order given.
    static func write(_ entries: [(String, Data)], to url: URL) throws {
        let writer = try ImagesZIPWriter(url: url)
        for (path, data) in entries {
            if path.hasSuffix("/") { try writer.addDirectory(path) } else { try writer.add(path, data) }
        }
        try writer.finish()
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}

/// Builds picture fixtures with CoreGraphics and ImageIO.
nonisolated enum ImagesFixtures {
    struct RGB: Equatable, CustomStringConvertible {
        var r: UInt8, g: UInt8, b: UInt8
        static let red = RGB(r: 230, g: 20, b: 20)
        static let green = RGB(r: 20, g: 200, b: 40)
        static let blue = RGB(r: 20, g: 40, b: 230)
        static let yellow = RGB(r: 240, g: 220, b: 20)
        var description: String { "(\(r), \(g), \(b))" }

        func distance(to other: RGB) -> Int {
            abs(Int(r) - Int(other.r)) + abs(Int(g) - Int(other.g)) + abs(Int(b) - Int(other.b))
        }
    }

    static func bitmap(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// A picture filled with `color`.
    static func solid(width: Int, height: Int, color: RGB) -> CGImage {
        let context = bitmap(width: width, height: height)
        context.setFillColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Four solid quadrants as stored (top-left, top-right, bottom-left, bottom-right).
    static func quadrants(width: Int, height: Int, _ colors: [RGB]) -> CGImage {
        let context = bitmap(width: width, height: height)
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        // y-up context: the top row of the image is at y = height.
        let rects = [CGRect(x: 0, y: h, width: w, height: h), CGRect(x: w, y: h, width: w, height: h),
                     CGRect(x: 0, y: 0, width: w, height: h), CGRect(x: w, y: 0, width: w, height: h)]
        for (rect, color) in zip(rects, colors) {
            context.setFillColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
            context.fill(rect)
        }
        return context.makeImage()!
    }

    /// A grey picture (one channel, no alpha).
    static func grey(width: Int, height: Int, level: UInt8) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: CGFloat(level) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A CMYK picture filled with the given ink amounts.
    static func cmyk(width: Int, height: Int, c: CGFloat, m: CGFloat, y: CGFloat, k: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceCMYK(), components: [c, m, y, k, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Transparent on the left half, `color` on the right half.
    static func halfTransparent(width: Int, height: Int, color: RGB) -> CGImage {
        let context = bitmap(width: width, height: height)
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()!
    }

    /// Random pixels: compresses badly, so a JPEG of it is large (like a real scanned page).
    static func noise(width: Int, height: Int, seed: UInt64) -> CGImage {
        let context = bitmap(width: width, height: height)
        let bytes = context.data!.assumingMemoryBound(to: UInt64.self)
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        for index in 0..<(context.bytesPerRow * height / 8) {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            bytes[index] = state | 0xFF00_0000_FF00_0000  // opaque alpha in both pixels
        }
        return context.makeImage()!
    }

    /// Encodes `images` as one file of `type` (several frames for TIFF/GIF). `nil` when ImageIO
    /// has no encoder for the type.
    static func encode(_ images: [CGImage], as type: UTType, quality: Double = 0.85,
                       orientation: CGImagePropertyOrientation? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil) else {
            return nil
        }
        for image in images {
            var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            if let orientation { properties[kCGImagePropertyOrientation] = orientation.rawValue }
            if type == .gif {
                properties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: 0.1]
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.85, orientation: CGImagePropertyOrientation? = nil) -> Data {
        encode([image], as: .jpeg, quality: quality, orientation: orientation)!
    }

    static func png(_ image: CGImage) -> Data { encode([image], as: .png)! }

    /// A 1 × 1 lossless WebP (ImageIO decodes WebP but cannot write it).
    static let webP = Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!
}

/// Reads back a converted PDF.
nonisolated enum ImagesPDFInspector {
    /// Page `index` (0-based) rendered into a bitmap `width` pixels wide; the colour at the given
    /// fractions of the page's width and height, measured from the top-left corner.
    static func colours(in pdf: URL, page index: Int, at points: [CGPoint], width: Int = 120) -> [ImagesFixtures.RGB] {
        guard let document = CGPDFDocument(pdf as CFURL), let page = document.page(at: index + 1) else { return [] }
        let box = page.getBoxRect(.cropBox)
        let height = max(1, Int((CGFloat(width) * box.height / box.width).rounded()))
        let context = ImagesFixtures.bitmap(width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                     rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return points.map { point in
            let x = min(width - 1, Int(point.x * CGFloat(width)))
            let y = min(height - 1, Int(point.y * CGFloat(height)))  // row 0 of the bitmap is the top
            let offset = y * context.bytesPerRow + x * 4
            return ImagesFixtures.RGB(r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2])
        }
    }

    /// Colour of the quadrant centres: top-left, top-right, bottom-left, bottom-right.
    static func quadrantColours(in pdf: URL, page: Int) -> [ImagesFixtures.RGB] {
        colours(in: pdf, page: page, at: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
                                          CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.75, y: 0.75)])
    }

    /// Problems with the file's cross-reference table: every in-use entry must point at its
    /// `n 0 obj`. (PDFKit repairs a broken table silently, so opening the file does not prove it.)
    static func crossReferenceProblems(in pdf: URL) -> [String] {
        guard let data = try? Data(contentsOf: pdf) else { return ["unreadable"] }
        let bytes = [UInt8](data)
        func text(at offset: Int, count: Int) -> String {
            guard offset >= 0, offset < bytes.count else { return "" }
            return String(decoding: bytes[offset..<min(bytes.count, offset + count)], as: UTF8.self)
        }
        let tail = text(at: max(0, bytes.count - 64), count: 64)
        guard let marker = tail.range(of: "startxref\n") else { return ["no startxref"] }
        let number = tail[marker.upperBound...].prefix { $0.isNumber }
        guard let xref = Int(number), text(at: xref, count: 5) == "xref\n" else { return ["startxref does not point at xref"] }
        let header = text(at: xref + 5, count: 40).split(separator: "\n").first.map(String.init) ?? ""
        let parts = header.split(separator: " ")
        guard parts.count == 2, parts[0] == "0", let count = Int(parts[1]) else { return ["bad subsection header \(header)"] }
        var problems: [String] = []
        let first = xref + 5 + header.utf8.count + 1
        for object in 0..<count {
            let entry = text(at: first + 20 * object, count: 20)
            guard entry.count == 20 else { problems.append("entry \(object) short"); continue }
            if object == 0 { if entry != "0000000000 65535 f \n" { problems.append("bad free entry") }; continue }
            guard entry.hasSuffix(" 00000 n \n"), let offset = Int(entry.prefix(10)) else {
                problems.append("entry \(object): \(entry)")
                continue
            }
            if !text(at: offset, count: 20).hasPrefix("\(object) 0 obj") { problems.append("object \(object) not at \(offset)") }
        }
        if !text(at: first + 20 * count, count: 7).hasPrefix("trailer") { problems.append("no trailer after the table") }
        return problems
    }

    /// The nearest of `palette` to `colour`.
    static func nearest(_ colour: ImagesFixtures.RGB, in palette: [ImagesFixtures.RGB]) -> ImagesFixtures.RGB {
        palette.min { $0.distance(to: colour) < $1.distance(to: colour) }!
    }
}

/// The process's physical memory footprint in bytes (what Xcode's memory gauge shows).
nonisolated func imagesFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

/// Collects progress fractions from any thread.
nonisolated final class ImagesFractions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}

/// Keeps the highest value it is given, from any thread.
nonisolated final class ImagesPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64 = 0
    private var samples: [Double] = []
    func record(_ value: UInt64, fraction: Double) {
        lock.withLock {
            stored = max(stored, value)
            samples.append(fraction)
        }
    }
    var value: UInt64 { lock.withLock { stored } }
    var fractions: [Double] { lock.withLock { samples } }
}
