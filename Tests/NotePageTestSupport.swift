import CoreGraphics
import Foundation
import PencilKit
import ReaderCore
import ReaderStore
import UIKit
@testable import Marginal

/// Helpers for the WP13 note-page tests.
@MainActor
enum NotePageTestSupport {
    private static var dateCounter: TimeInterval = 0

    /// A straight stroke from `start` to `end` (note-page coordinates), with a unique creation date.
    static func stroke(from start: CGPoint, to end: CGPoint, ink: PKInk.InkType = .pen, width: CGFloat = 3,
                       color: UIColor = UIColor(red: 0.12, green: 0.31, blue: 0.84, alpha: 1)) -> PKStroke {
        dateCounter += 1
        let count = 16
        let points = (0...count).map { index -> PKStrokePoint in
            let t = CGFloat(index) / CGFloat(count)
            let location = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            return PKStrokePoint(location: location, timeOffset: TimeInterval(index) * 0.01,
                                 size: CGSize(width: width, height: width), opacity: 1, force: 1,
                                 azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 700_000_000 + dateCounter))
        return PKStroke(ink: PKInk(ink, color: color), path: path)
    }

    /// A horizontal stroke across the middle of a band.
    static func stroke(over band: NoteParagraphBand, x: ClosedRange<CGFloat> = 20...120) -> PKStroke {
        let y = band.top + min(band.height, NotePageStyle.lineHeight) / 2
        return stroke(from: CGPoint(x: x.lowerBound, y: y), to: CGPoint(x: x.upperBound, y: y))
    }

    /// An ephemeral store with one book. Remove `store.rootDirectory` when done.
    static func makeStore() throws -> (LibraryStore, Book) {
        let store = try LibraryStore.ephemeral()
        let book = Book(title: "Notes", fingerprint: "note-test-\(UUID().uuidString)", fileName: "notes.pdf",
                        pageCount: 20, fileSize: 1)
        try store.books.save(book)
        return (store, book)
    }

    /// Polls `condition` on the main actor.
    static func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Adds a stroke to a model the way the canvas does: the displayed drawing plus the stroke.
    static func draw(_ stroke: PKStroke, on model: NotePageModel) {
        var drawing = model.displayInk()
        drawing.strokes.append(stroke)
        model.applyUserDrawing(drawing)
    }

    /// The strokes of a model as drawn on its page now.
    static func pageStrokes(_ model: NotePageModel) -> [PKStroke] {
        model.ink.composedDrawing().strokes
    }

    /// Counts content-stream operators (fills, strokes, curves, images, text) on page 1 of a PDF.
    static func pdfOperatorCounts(_ data: Data) -> [String: Int] {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1), let table = CGPDFOperatorTableCreate() else { return [:] }
        let box = PDFOperatorCounter()
        CGPDFOperatorTableSetCallback(table, "f") { _, info in PDFOperatorCounter.bump(info, "f") }
        CGPDFOperatorTableSetCallback(table, "f*") { _, info in PDFOperatorCounter.bump(info, "f*") }
        CGPDFOperatorTableSetCallback(table, "S") { _, info in PDFOperatorCounter.bump(info, "S") }
        CGPDFOperatorTableSetCallback(table, "c") { _, info in PDFOperatorCounter.bump(info, "c") }
        CGPDFOperatorTableSetCallback(table, "Do") { _, info in PDFOperatorCounter.bump(info, "Do") }
        CGPDFOperatorTableSetCallback(table, "BI") { _, info in PDFOperatorCounter.bump(info, "BI") }
        CGPDFOperatorTableSetCallback(table, "Tj") { _, info in PDFOperatorCounter.bump(info, "Tj") }
        CGPDFOperatorTableSetCallback(table, "TJ") { _, info in PDFOperatorCounter.bump(info, "TJ") }
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(box).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return box.counts
    }
}

/// Collects operator counts for `NotePageTestSupport.pdfOperatorCounts`.
final class PDFOperatorCounter: @unchecked Sendable {
    var counts: [String: Int] = [:]

    nonisolated static func bump(_ info: UnsafeMutableRawPointer?, _ name: String) {
        guard let info else { return }
        let counter = Unmanaged<PDFOperatorCounter>.fromOpaque(info).takeUnretainedValue()
        counter.counts[name, default: 0] += 1
    }
}
