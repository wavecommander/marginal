import Darwin
import Foundation
import PDFKit
import PencilKit
import Testing
import UIKit
@testable import Marginal

/// Scrolling 200 pages of `large.pdf` in markup mode, in a real PDF view: the number of live
/// page canvases stays small (none is kept for pages that left the screen) and the process
/// footprint stays within a generous bound. Pages with ink are loaded and released on the way.
/// Canvases are counted for this test's book only (`liveCount(bookID:)`): other suites run in
/// the same process at the same time and open readers of their own, so the process-wide count
/// would measure them too. The footprint bound is process-wide and deliberately generous.
@MainActor
struct PageInkMemoryTests {
    /// Physical footprint of the process in bytes (what Xcode's memory gauge shows).
    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    @Test func scrollingTwoHundredPagesKeepsFewCanvasesAndBoundedMemory() async throws {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("large.pdf"), pageCount: 1500)
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        // Ink on every tenth page of the range, so loads and releases of real drawings happen.
        let heavy = PKDrawing(strokes: (0..<60).map { index in
            PageInkTestSupport.stroke(from: CGPoint(x: 40, y: 40 + CGFloat(index) * 10), to: CGPoint(x: 500, y: 44 + CGFloat(index) * 10))
        })
        let data = heavy.dataRepresentation()
        for page in stride(from: 100, to: 300, by: 10) {
            try await store.savePageInk(data, bookID: book.id, pageIndex: page, origin: nil)
        }
        let host = PageInkTestSupport.Host(book: book, store: store, size: CGSize(width: 820, height: 1180)) {
            $0.initialPageIndex = 99
            $0.startInMarkup = true
        }
        #expect(await PageInkTestSupport.waitUntil(timeout: 20) { host.session.loadState == .ready })
        await PageInkTestSupport.pause(1)
        let scrollView = try #require(host.pdfView.documentView?.superview as? UIScrollView)
        let canvasesAtStart = PageInkCanvasView.liveCount(bookID: book.id)
        let startFootprint = footprint()
        var maxCanvases = 0
        var maxProcessCanvases = 0
        var maxFootprint = startFootprint
        var pagesWithInkSeen = Set<Int>()
        // Scroll continuously, a third of a screen at a time, through 200 pages.
        func pageOnScreen() -> Int {
            host.pdfView.layoutIfNeeded()
            let centre = CGPoint(x: host.pdfView.bounds.midX, y: host.pdfView.bounds.midY)
            return host.pdfView.page(for: centre, nearest: true).map { host.pdfView.document?.index(for: $0) ?? 0 } ?? 0
        }
        let startPage = pageOnScreen()
        var steps = 0
        while pageOnScreen() < startPage + 200 && steps < 3000 {
            var offset = scrollView.contentOffset
            offset.y += scrollView.bounds.height / 3
            scrollView.setContentOffset(offset, animated: false)
            steps += 1
            if steps % 3 == 0 { await PageInkTestSupport.pause(0.02) }
            maxCanvases = max(maxCanvases, PageInkCanvasView.liveCount(bookID: book.id))
            maxProcessCanvases = max(maxProcessCanvases, PageInkCanvasView.liveCount)
            maxFootprint = max(maxFootprint, footprint())
            for (page, surface) in host.provider?.liveSurfaces ?? [:] where surface.strokeCount > 0 {
                pagesWithInkSeen.insert(page)
            }
        }
        await PageInkTestSupport.pause(1)
        let scrolledPages = pageOnScreen() - startPage
        let endCanvases = PageInkCanvasView.liveCount(bookID: book.id)
        let growthMB = Double(maxFootprint - min(startFootprint, maxFootprint)) / 1_048_576
        print("PageInk memory: scrolled \(scrolledPages) pages in \(steps) steps; live canvases start \(canvasesAtStart), max \(maxCanvases), end \(endCanvases) (process-wide max \(maxProcessCanvases)); footprint start \(startFootprint / 1_048_576) MB, max \(maxFootprint / 1_048_576) MB (growth \(String(format: "%.1f", growthMB)) MB); pages with ink loaded on the way: \(pagesWithInkSeen.count)")
        #expect(scrolledPages >= 200)
        #expect(maxCanvases <= 8, "only pages near the screen have a canvas")
        #expect(endCanvases <= 6)
        #expect(pagesWithInkSeen.count >= 15, "inked pages were loaded while passing")
        #expect(growthMB < 250, "generous bound on footprint growth")
        // Every surface the provider still knows is on screen.
        #expect((host.provider?.liveSurfaces.count ?? 0) <= 6)
        await host.close()
    }
}
