import CoreGraphics
import Foundation
import PDFKit
import ReaderCore

/// Scan detection at the end of an import (S3; design, "Scanned books" ▸ "Detection").
///
/// Reads a few pages spread through the book (`ScanDetection.samplePageIndices`) from a
/// `PDFDocument` the caller opened on the **file** (the import's own staged document, never an
/// on-screen one, which gains Live Text the file does not have), builds a `ScanPageSample` per
/// page and applies `ScanDetection.isScanned`. `nonisolated` and synchronous: the import calls
/// it from `ImportPipeline.check`, which runs on the cooperative pool.
///
/// **Cost.** A sampled page's text is read once (`PageTextPolicy`, the rule recognition and
/// search use). Image coverage is measured only for a page with next to no text, since a page
/// with text is a *text* sample whatever its images (`ScanDetection.kind(of:)`), so a typed book
/// such as `large.pdf` never scans a content stream. A page with no text is cheap to scan: a
/// scanned page's content stream is a handful of operators.
nonisolated enum ScanDetector {
    /// The samples of `document` (at most `maximum` pages).
    static func samples(of document: PDFDocument,
                        maximum: Int = ScanDetection.defaultSampleCount) -> [ScanPageSample] {
        ScanDetection.samplePageIndices(pageCount: document.pageCount, maximum: maximum).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            return autoreleasepool { sample(of: page, pageIndex: index) }
        }
    }

    /// One page's sample: its characters of its own (0 when `PageTextPolicy` says it has no
    /// text of its own, such as a page of only whitespace), and, when that is below
    /// `ScanDetection.textCharacterThreshold`, how much of it images cover. A page with text
    /// gets coverage 0: it is not measured because it cannot change the page's kind.
    static func sample(of page: PDFPage, pageIndex: Int) -> ScanPageSample {
        let characters = PageTextPolicy.hasOwnText(page) ? page.numberOfCharacters : 0
        guard characters < ScanDetection.textCharacterThreshold, let cgPage = page.pageRef else {
            return ScanPageSample(pageIndex: pageIndex, textCharacterCount: characters, imageCoverage: 0)
        }
        return ScanPageSample(pageIndex: pageIndex, textCharacterCount: characters,
                              imageCoverage: PDFImageCoverage.coverage(of: cgPage))
    }

    /// Whether the book in `document` is scanned.
    static func isScanned(_ document: PDFDocument) -> Bool {
        ScanDetection.isScanned(samples(of: document))
    }
}

/// How much of a PDF page its images cover (`ScanPageSample.imageCoverage`), measured from the
/// page's content stream with `CGPDFScanner`, without rendering anything.
///
/// **How.** The scanner walks the page's operators keeping the current transformation matrix
/// (`q`, `Q`, `cm`). Each image painted (`Do` on an image XObject, or an inline image) fills the
/// unit square under the current matrix, so its placement is that square's bounding box in page
/// space. Form XObjects are followed (with their `/Matrix`) a few levels deep, since some scans
/// wrap the page image in one. The placements are clipped to the crop box and their union is
/// measured on a `gridSize` × `gridSize` grid laid over it (a cell counts when its centre is
/// inside a placement), so overlapping images are not counted twice; the error is at most a
/// cell's width along each edge (about 1.5% of the page at 64).
///
/// Clipping paths and soft masks are ignored (an image clipped to a small area still counts its
/// full placement), as are images drawn by patterns and annotations. A rotated placement counts
/// its bounding box. These only matter for pages that are not scans.
nonisolated enum PDFImageCoverage {
    /// Cells per side of the grid the union is measured on.
    static let gridSize = 64
    /// Image placements read from one page at most; a page with more stops being scanned (its
    /// coverage is measured from those read so far).
    static let maximumPlacements = 512
    /// How deep form XObjects are followed.
    static let maximumFormDepth = 4

    /// The share of `page`'s crop box covered by images, `0...1`.
    static func coverage(of page: CGPDFPage) -> Double {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return 0 }
        return coverage(of: placements(on: page), in: box)
    }

    /// The bounding boxes, in page space, of the images painted on `page` (unclipped).
    static func placements(on page: CGPDFPage) -> [CGRect] {
        let scan = ImageScan()
        let stream = CGPDFContentStreamCreateWithPage(page)
        scan.run(stream)
        CGPDFContentStreamRelease(stream)
        return scan.placements
    }

    /// The share of `box` covered by the union of `rects`, on the grid.
    static func coverage(of rects: [CGRect], in box: CGRect) -> Double {
        let clipped = rects.map { $0.standardized.intersection(box) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !clipped.isEmpty, box.width > 0, box.height > 0 else { return 0 }
        let n = gridSize
        let cellWidth = box.width / CGFloat(n), cellHeight = box.height / CGFloat(n)
        var covered = [Bool](repeating: false, count: n * n)
        var count = 0
        for rect in clipped {
            // Cells whose centre lies inside `rect`: centre of column i is minX + (i + 0.5) * w.
            let firstColumn = max(0, Int(((rect.minX - box.minX) / cellWidth - 0.5).rounded(.up)))
            let lastColumn = min(n - 1, Int(((rect.maxX - box.minX) / cellWidth - 0.5).rounded(.down)))
            let firstRow = max(0, Int(((rect.minY - box.minY) / cellHeight - 0.5).rounded(.up)))
            let lastRow = min(n - 1, Int(((rect.maxY - box.minY) / cellHeight - 0.5).rounded(.down)))
            guard firstColumn <= lastColumn, firstRow <= lastRow else { continue }
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn where !covered[row * n + column] {
                    covered[row * n + column] = true
                    count += 1
                }
            }
        }
        return Double(count) / Double(n * n)
    }
}

/// The scanner's state: the matrix stack and the placements found. A class so the C callbacks
/// can reach it through the scanner's `info` pointer.
private nonisolated final class ImageScan {
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var placements: [CGRect] = []
    /// The content stream being scanned (for resource lookups) and how deep in forms it is.
    var streams: [CGPDFContentStreamRef] = []
    var isFull: Bool { placements.count >= PDFImageCoverage.maximumPlacements }

    /// The operator table, made per scan (cheap) rather than shared between threads.
    private let table: CGPDFOperatorTableRef? = ImageScan.makeTable()

    deinit {
        if let table { CGPDFOperatorTableRelease(table) }
    }

    private static func makeTable() -> CGPDFOperatorTableRef? {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let scan = ImageScan.from(info) else { return }
            scan.stack.append(scan.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let scan = ImageScan.from(info) else { return }
            if let top = scan.stack.popLast() { scan.ctm = top }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let scan = ImageScan.from(info) else { return }
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in stride(from: 5, through: 0, by: -1) {
                guard CGPDFScannerPopNumber(scanner, &values[index]) else { return }
            }
            let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3],
                                           tx: values[4], ty: values[5])
            // PDF: CTM' = M × CTM (M applies first).
            scan.ctm = matrix.concatenating(scan.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let scan = ImageScan.from(info) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            scan.paintXObject(named: name, scanner: scanner)
        }
        // An inline image (BI … ID … EI). Quartz reports it once; both names are registered so
        // either form is seen (a placement counted twice does not change the union).
        CGPDFOperatorTableSetCallback(table, "BI") { _, info in ImageScan.from(info)?.paintImage() }
        CGPDFOperatorTableSetCallback(table, "EI") { _, info in ImageScan.from(info)?.paintImage() }
        return table
    }

    static func from(_ info: UnsafeMutableRawPointer?) -> ImageScan? {
        info.map { Unmanaged<ImageScan>.fromOpaque($0).takeUnretainedValue() }
    }

    func run(_ stream: CGPDFContentStreamRef) {
        guard let table, streams.count <= PDFImageCoverage.maximumFormDepth, !isFull else { return }
        streams.append(stream)
        defer { streams.removeLast() }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    func paintImage() {
        guard !isFull else { return }
        placements.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm))
    }

    func paintXObject(named name: UnsafePointer<CChar>, scanner: CGPDFScannerRef) {
        guard let stream = streams.last,
              let object = CGPDFContentStreamGetResource(stream, "XObject", name) else { return }
        var xObject: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &xObject), let xObject,
              let dictionary = CGPDFStreamGetDictionary(xObject) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
        switch String(cString: subtype) {
        case "Image":
            paintImage()
        case "Form":
            var resources: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            // A form runs inside its own q … Q: whatever it leaves on the stack is dropped.
            let saved = (ctm, stack)
            ctm = Self.formMatrix(dictionary).concatenating(ctm)
            let form = CGPDFContentStreamCreateWithStream(xObject, resources ?? dictionary, stream)
            run(form)
            CGPDFContentStreamRelease(form)
            (ctm, stack) = saved
        default:
            break
        }
    }

    /// A form XObject's `/Matrix` (identity when absent or malformed).
    static func formMatrix(_ dictionary: CGPDFDictionaryRef) -> CGAffineTransform {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 else {
            return .identity
        }
        var values = [CGPDFReal](repeating: 0, count: 6)
        for index in 0..<6 {
            guard CGPDFArrayGetNumber(array, index, &values[index]) else { return .identity }
        }
        return CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
    }
}
