import Accelerate
import Compression
import CoreGraphics
import Foundation
import ImageIO

/// Writes a PDF of picture pages straight to a file, one page at a time, keeping nothing of a page
/// once it is written: memory stays flat however many pages there are.
///
/// Why not `CGPDFContext`: measured on the iOS 27 simulator, a `CGPDFContext` keeps every image's
/// compressed data in memory until `closePDF()` (300 pages of ~320 KB JPEGs: +93 MB at the peak),
/// whether the image comes from bytes, a file, a sequential data provider or a page of another
/// PDF. So this writer produces the (simple) PDF structure itself:
/// - an 8-bit RGB or grey JPEG is stored as it is (`/DCTDecode`): no re-encoding, so the page is
///   the size of the JPEG plus a few hundred bytes;
/// - any other picture (PNG, TIFF, HEIC, GIF, WebP, CMYK JPEG…) is decoded by CoreGraphics into an
///   8-bit RGB (or grey) bitmap over white and stored losslessly (`/FlateDecode`);
/// - the colour profile goes in as `/ICCBased`, written once per distinct profile.
///
/// Every page: `/MediaBox` = `/CropBox` = `[0 0 w h]`, no `/Rotate`. EXIF orientation is applied
/// by the page's drawing matrix, so the stored picture data is never touched.
///
/// Not thread-safe: one task owns a writer from `init` to `close()` or `abandon()`.
nonisolated final class ImagesPDFWriter {
    let url: URL
    private var handle: FileHandle?
    private var buffer = Data()
    private var offset: UInt64 = 0
    /// Byte offset of each object, by object number (0 is the free-list head; 1 the catalog,
    /// 2 the page tree).
    private var objectOffsets: [UInt64] = [0, 0, 0]
    private var pageObjects: [Int] = []
    private var profiles: [Data: Int] = [:]
    private var fontObject: Int?

    var pageCount: Int { pageObjects.count }

    /// Creates (or truncates) the PDF file at `url`.
    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ConversionError.failed(reason: "the PDF file could not be created")
        }
        handle = try FileHandle(forWritingTo: url)
        write("%PDF-1.4\n")
        write(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))  // binary marker comment
    }

    deinit { try? handle?.close() }

    // MARK: Pages

    /// Adds one page showing `image` upright and filling the page. `jpeg` is the picture's file
    /// data when it is a JPEG: an 8-bit RGB or grey one is stored without re-encoding. The page has
    /// the shape of the picture as displayed (see `pageSize(forDisplayPixels:)`).
    func addPage(_ image: CGImage, jpeg: Data?, orientation: CGImagePropertyOrientation) throws {
        let pixels = CGSize(width: image.width, height: image.height)
        let display = Self.displaySize(pixels: pixels, orientation: orientation)
        let page = Self.pageSize(forDisplayPixels: display)

        let imageObject = reserve()
        if let jpeg, let colourSpace = passThroughColourSpace(of: image) {
            let space = try colourSpaceReference(colourSpace)
            try writeStream(imageObject, dictionary: "/Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) "
                + "/ColorSpace \(space) /BitsPerComponent 8 /Filter /DCTDecode", data: jpeg)
        } else {
            try writeDecoded(image, as: imageObject)
        }

        let matrix = CGAffineTransform(scaleX: pixels.width, y: pixels.height)
            .concatenating(Self.orientationTransform(orientation, pixels: pixels))
            .concatenating(CGAffineTransform(scaleX: page.width / display.width, y: page.height / display.height))
        let content = "q \(number(matrix.a)) \(number(matrix.b)) \(number(matrix.c)) \(number(matrix.d)) "
            + "\(number(matrix.tx)) \(number(matrix.ty)) cm /Im0 Do Q\n"
        try writePage(size: page, content: content, resources: "/XObject << /Im0 \(imageObject) 0 R >>")
    }

    /// Adds a plain page in place of a picture that could not be read, naming it, so the reader
    /// sees where a page is missing instead of losing it silently.
    func addPlaceholderPage(naming name: String) throws {
        let page = Self.placeholderPageSize
        let font = try helvetica()
        let content = """
            0.93 g 0 0 \(number(page.width)) \(number(page.height)) re f
            0.25 g BT /F1 18 Tf 54 \(number(page.height / 2 + 8)) Td (\(Self.pdfText("This page could not be read."))) Tj ET
            0.45 g BT /F1 12 Tf 54 \(number(page.height / 2 - 16)) Td (\(Self.pdfText(name, maxLength: 80))) Tj ET

            """
        try writePage(size: page, content: content, resources: "/Font << /F1 \(font) 0 R >>")
    }

    /// Writes the page tree, catalogue and cross-reference table, and closes the file.
    func close() throws {
        guard handle != nil else { return }
        let kids = pageObjects.map { "\($0) 0 R" }.joined(separator: " ")
        begin(2)
        write("<< /Type /Pages /Kids [\(kids)] /Count \(pageObjects.count) >>\nendobj\n")
        begin(1)
        write("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        let xref = offset
        var table = "xref\n0 \(objectOffsets.count)\n0000000000 65535 f \n"
        for objectOffset in objectOffsets.dropFirst() {
            table += String(format: "%010llu 00000 n \n", objectOffset)
        }
        table += "trailer\n<< /Size \(objectOffsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        write(table)
        try flush()
        try handle?.close()
        handle = nil
    }

    /// Closes and deletes the file (failure or cancellation), leaving nothing behind.
    func abandon() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Objects

    private func reserve() -> Int {
        objectOffsets.append(0)
        return objectOffsets.count - 1
    }

    private func begin(_ object: Int) {
        objectOffsets[object] = offset
        write("\(object) 0 obj\n")
    }

    private func writePage(size: CGSize, content: String, resources: String) throws {
        let contentObject = reserve()
        try writeStream(contentObject, dictionary: "", data: Data(content.utf8))
        let pageObject = reserve()
        begin(pageObject)
        let box = "[0 0 \(number(size.width)) \(number(size.height))]"
        write("<< /Type /Page /Parent 2 0 R /MediaBox \(box) /CropBox \(box) /Resources << \(resources) >> "
            + "/Contents \(contentObject) 0 R >>\nendobj\n")
        pageObjects.append(pageObject)
        try flushIfLarge()
    }

    private func writeStream(_ object: Int, dictionary: String, data: Data) throws {
        begin(object)
        write("<< \(dictionary) /Length \(data.count) >>\nstream\n")
        try flush()
        try handle?.write(contentsOf: data)
        offset += UInt64(data.count)
        write("\nendstream\nendobj\n")
    }

    private func helvetica() throws -> Int {
        if let fontObject { return fontObject }
        let object = reserve()
        begin(object)
        write("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n")
        fontObject = object
        return object
    }

    // MARK: Colour

    /// The colour space a JPEG can keep its data under, or `nil` when it must be decoded (CMYK,
    /// not 8-bit, or anything unusual).
    private func passThroughColourSpace(of image: CGImage) -> CGColorSpace? {
        guard image.bitsPerComponent == 8, let space = image.colorSpace else { return nil }
        switch space.model {
        case .rgb: return space.numberOfComponents == 3 ? space : nil
        case .monochrome: return space.numberOfComponents == 1 ? space : nil
        default: return nil
        }
    }

    /// `/ICCBased` for a space with a profile (written once per profile), else the device space.
    private func colourSpaceReference(_ space: CGColorSpace) throws -> String {
        let components = space.numberOfComponents
        guard let profile = space.copyICCData() as Data? else { return components == 1 ? "/DeviceGray" : "/DeviceRGB" }
        if let object = profiles[profile] { return "[/ICCBased \(object) 0 R]" }
        let object = reserve()
        try writeStream(object, dictionary: "/N \(components)", data: profile)
        if profiles.count < 16 { profiles[profile] = object }
        return "[/ICCBased \(object) 0 R]"
    }

    /// Draws `image` over white into an 8-bit bitmap (grey for grey pictures, else RGB in the
    /// picture's own RGB profile or sRGB) and writes the rows zlib-compressed.
    private func writeDecoded(_ image: CGImage, as object: Int) throws {
        let width = image.width, height = image.height
        let grey = image.colorSpace?.model == .monochrome
        let space: CGColorSpace
        if grey {
            space = CGColorSpaceCreateDeviceGray()
        } else if let own = image.colorSpace, own.model == .rgb, own.copyICCData() != nil {
            space = own
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                               bitmapInfo: grey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let bitmap, let pixels = bitmap.data else {
            throw ConversionError.failed(reason: "a picture of \(width) × \(height) pixels could not be drawn")
        }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let drawnSpace = bitmap.colorSpace ?? space
        let components = drawnSpace.numberOfComponents
        let stride = bitmap.bitsPerPixel / 8
        let spaceReference = try colourSpaceReference(drawnSpace)

        // The stream's length is only known afterwards: an indirect /Length object follows it.
        let lengthObject = reserve()
        begin(object)
        write("<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace \(spaceReference) "
            + "/BitsPerComponent 8 /Filter /FlateDecode /Length \(lengthObject) 0 R >>\nstream\n")
        try flush()
        let start = offset
        let deflater = try ImagesDeflater(handle: handle)
        let rowBytes = bitmap.bytesPerRow
        var row = [UInt8](repeating: 0, count: width * components)
        let source = pixels.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let line = source + y * rowBytes  // row 0 of a bitmap context is the top row
            if stride == components {
                try deflater.append(UnsafeRawBufferPointer(start: line, count: width * components))
                continue
            }
            row.withUnsafeMutableBufferPointer { out in
                if stride == 4, components == 3 {
                    var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: line), height: 1,
                                             width: vImagePixelCount(width), rowBytes: width * 4)
                    var to = vImage_Buffer(data: out.baseAddress, height: 1, width: vImagePixelCount(width), rowBytes: width * 3)
                    vImageConvert_RGBA8888toRGB888(&from, &to, vImage_Flags(kvImageNoFlags))
                } else {
                    for x in 0..<width {
                        for c in 0..<components { out[components * x + c] = line[stride * x + c] }
                    }
                }
            }
            try row.withUnsafeBytes { try deflater.append($0) }
        }
        try deflater.finish()
        offset += deflater.written
        let length = offset - start
        write("\nendstream\nendobj\n")
        begin(lengthObject)
        write("\(length)\nendobj\n")
    }

    // MARK: Output

    private func write(_ string: String) { write(Data(string.utf8)) }

    private func write(_ data: Data) {
        buffer.append(data)
        offset += UInt64(data.count)
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle?.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private func flushIfLarge() throws {
        if buffer.count >= 64 * 1024 { try flush() }
    }

    private func number(_ value: CGFloat) -> String {
        let rounded = (value * 10_000).rounded() / 10_000
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var text = String(format: "%.4f", Double(rounded))
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    /// `text` as a PDF literal string body in WinAnsi (Latin-1 range kept, anything else `?`),
    /// shortened in the middle to `maxLength` characters.
    static func pdfText(_ text: String, maxLength: Int = 200) -> String {
        var scalars = Array(text.unicodeScalars)
        if scalars.count > maxLength {
            let half = (maxLength - 3) / 2
            scalars = Array(scalars.prefix(half)) + Array("...".unicodeScalars) + Array(scalars.suffix(half))
        }
        var result = ""
        for scalar in scalars {
            switch scalar {
            case "(", ")", "\\": result += "\\" + String(scalar)
            case " "..."~": result.unicodeScalars.append(scalar)
            case "\u{A0}"..."\u{FF}": result += String(format: "\\%03o", scalar.value)
            default: result += "?"
            }
        }
        return result
    }

    // MARK: Geometry

    /// Every page has the area of a US Letter page (612 × 792 pt) and the shape of its picture,
    /// whatever the picture's resolution, so pen widths, zoom and note placement feel the same as
    /// on an ordinary PDF and the same within a book scanned at mixed resolutions. The longer side
    /// is capped at PDF's 14,400 pt limit (very tall strips) and neither side is under 3 pt.
    static let pageArea: CGFloat = 612 * 792
    static let maxPageSide: CGFloat = 14_400
    static let minPageSide: CGFloat = 3
    static let placeholderPageSize = CGSize(width: 612, height: 792)

    static func pageSize(forDisplayPixels pixels: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return placeholderPageSize }
        var scale = (pageArea / (pixels.width * pixels.height)).squareRoot()
        let longest = max(pixels.width, pixels.height) * scale
        if longest > maxPageSide { scale *= maxPageSide / longest }
        return CGSize(width: min(maxPageSide, max(minPageSide, pixels.width * scale)),
                      height: min(maxPageSide, max(minPageSide, pixels.height * scale)))
    }

    /// The picture's size as displayed: width and height swap for the four orientations that turn
    /// it a quarter.
    static func displaySize(pixels: CGSize, orientation: CGImagePropertyOrientation) -> CGSize {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: CGSize(width: pixels.height, height: pixels.width)
        default: pixels
        }
    }

    /// Maps the stored picture, drawn in `(0, 0, width, height)` of a y-up space (its first row at
    /// the top, as both CoreGraphics and PDF draw images), onto its upright display rect
    /// `(0, 0, displayWidth, displayHeight)`. EXIF values: up 1, upMirrored 2, down 3,
    /// downMirrored 4, leftMirrored 5, right 6, rightMirrored 7, left 8.
    static func orientationTransform(_ orientation: CGImagePropertyOrientation, pixels: CGSize) -> CGAffineTransform {
        let w = pixels.width, h = pixels.height
        switch orientation {
        case .up: return .identity
        case .upMirrored: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        @unknown default: return .identity
        }
    }
}

/// zlib (RFC 1950) compression straight to a file handle: the Compression framework's raw
/// DEFLATE between a zlib header and an Adler-32 trailer, as PDF's `/FlateDecode` expects.
nonisolated final class ImagesDeflater {
    private let handle: FileHandle?
    private let stream: UnsafeMutablePointer<compression_stream>
    private let output: UnsafeMutablePointer<UInt8>
    private let outputSize = 256 * 1024
    private var adlerA: UInt32 = 1
    private var adlerB: UInt32 = 0
    private(set) var written: UInt64 = 0

    init(handle: FileHandle?) throws {
        self.handle = handle
        stream = .allocate(capacity: 1)
        output = .allocate(capacity: outputSize)
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            output.deallocate()
            throw ConversionError.failed(reason: "the compressor could not start")
        }
        try emit(Data([0x78, 0x9C]))
    }

    func append(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), !bytes.isEmpty else { return }
        updateAdler(base, count: bytes.count)
        stream.pointee.src_ptr = base
        stream.pointee.src_size = bytes.count
        while stream.pointee.src_size > 0 {
            try process(flags: 0)
        }
    }

    func finish() throws {
        stream.pointee.src_size = 0
        while try process(flags: Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue)) != COMPRESSION_STATUS_END {}
        let adler = (adlerB << 16) | adlerA
        try emit(Data([UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]))
    }

    @discardableResult
    private func process(flags: Int32) throws -> compression_status {
        stream.pointee.dst_ptr = output
        stream.pointee.dst_size = outputSize
        let status = compression_stream_process(stream, flags)
        guard status != COMPRESSION_STATUS_ERROR else { throw ConversionError.failed(reason: "a picture could not be compressed") }
        let produced = outputSize - stream.pointee.dst_size
        if produced > 0 { try emit(Data(bytes: output, count: produced)) }
        return status
    }

    private func emit(_ data: Data) throws {
        try handle?.write(contentsOf: data)
        written += UInt64(data.count)
    }

    private func updateAdler(_ bytes: UnsafePointer<UInt8>, count: Int) {
        var a = adlerA, b = adlerB
        var index = 0
        while index < count {
            let end = min(count, index + 5552)  // the most bytes before the sums can overflow
            while index < end {
                a &+= UInt32(bytes[index])
                b &+= a
                index += 1
            }
            a %= 65_521
            b %= 65_521
        }
        adlerA = a
        adlerB = b
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        output.deallocate()
    }
}
