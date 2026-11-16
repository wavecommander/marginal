import Foundation
import PDFKit
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// WP7 against a real reader session and `PDFView` (the generated `small.pdf`): selection to
/// highlights, the overlap rule, hit-testing and taps, applying and removing per displayed
/// page, re-applying after the document view is rebuilt, the PDF never written, change events
/// and two windows, drawing registration on rotated and cropped pages.
@Suite(.serialized)
@MainActor
struct HighlightsControllerTests {
    typealias Support = HighlightsTestSupport

    // MARK: Making highlights

    @Test func singleLineSelectionMakesOneHighlight() async throws {
        let (store, book) = try Support.makeSmallStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let host = try await Support.host(book, store, pageIndex: 2)
        defer { Task { await host.close() } }
        let controller = Support.controller(host)

        let selection = try Support.select(Support.phrase, onPage: 2, in: host)
        #expect(selection.parts.count == 1)
        let made = controller.highlight(selection, color: .yellow)
        #expect(made.count == 1)
        let stored = try store.highlights.highlights(bookID: book.id)
        #expect(stored.count == 1)
        let highlight = try #require(stored.first)
        #expect(highlight.pageIndex == 2)
        #expect(highlight.color == .yellow)
        #expect(highlight.text == Support.phrase)
        #expect(highlight.rects.count == 1)
        #expect(highlight.rects == selection.parts[0].lineRects)
        // The selection is cleared and the highlight is shown at once.
        #expect(host.pdfView.currentSelection == nil || host.pdfView.currentSelection?.string?.isEmpty != false)
        let annotations = controller.appliedAnnotations(onPage: 2)
        #expect(annotations.map(\.highlightID) == [highlight.id])
        #expect(annotations.first?.page === host.session.pdf.page(at: 2))
        #expect(controller.displayedHighlights[2]?.map(\.id) == [highlight.id])
    }

    @Test func multiLineSelectionStoresOneRectPerLineAndNormalisedText() async throws {
        let (store, book) = try Support.makeSmallStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let host = try await Support.host(book, store, pageIndex: 2)
        defer { Task { await host.close() } }
        let controller = Support.controller(host)

        // From the phrase line through the start of the paragraph below (three lines).
        let page = try #require(host.session.pdf.page(at: 2))
        let text = (page.string ?? "") as NSString
        let start = text.range(of: "quick amber").location
        let end = text.range(of: "Verify").location
        let selection = try Support.select(fromPage: 2, character: start, toPage: 2, character: end + 5, in: host)
        #expect(selection.parts.count == 1)
        controller.highlight(selection, color: .blue)
        let highlight = try #require(try store.highlights.highlights(bookID: book.id).first)
        #expect(highlight.rects.count >= 3, "\(highlight.rects)")
        #expect(highlight.rects.count == selection.parts[0].lineRects.count)
        #expect(highlight.text.hasPrefix("quick amber fox annotates margins. Inverse then"))
        #expect(highlight.text.hasSuffix("Verify"))
        #expect(!highlight.text.contains("\n") && !highlight.text.contains("  "))
    }

    @Test func selectionAcrossAPageBoundaryMakesOneHighlightPerPage() async throws {
        let (store, book) = try Support.makeSmallStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let host = try await Support.host(book, store, pageIndex: 2)
        defer { Task { await host.close() } }
        let controller = Support.controller(host)

        let page1 = try #require(host.session.pdf.page(at: 1))
        let length1 = (page1.string ?? "").utf16.count
        let selection = try Support.select(fromPage: 1, character: max(length1 - 40, 0), toPage: 2, character: 30, in: host)
        #expect(selection.parts.map(\.pageIndex) == [1, 2])
        let made = controller.highlight(selection, color: .green)
        #expect(made.map(\.pageIndex) == [1, 2])
        let stored = try store.highlights.highlights(bookID: book.id)
        #expect(stored.map(\.pageIndex) == [1, 2])
        #expect(stored.allSatisfy { $0.color == .green && !$0.text.isEmpty && !$0.rects.isEmpty })
    }

    // MARK: Overlap rule

    @Test func overlappingSelectionsMergeRecolourAndNeverDuplicate() async throws {
        let (store, book) = try Support.makeSmallStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let host = try await Support.host(book, store, pageIndex: 2)
        defer { Task { await host.close() } }
        let controller = Support.controller(host)

        let original = try #require(controller.highlight(try Support.select(Support.phrase, onPage: 2, in: host),
                                                         color: .yellow).first)
        let revisions = host.session.revisions.highlights

        // Inside, same colour: nothing changes, nothing is saved.
        controller.highlight(try Support.select("amber fox", onPage: 2, in: host), color: .yellow)
        #expect(try store.highlights.highlights(bookID: book.id) == [original])
        #expect(host.session.revisions.highlights == revisions, "a no-op must not post a change")

        // Inside, another colour: the whole highlight is recoloured (same id, rects, text).
        controller.highlight(try Support.select("amber fox", onPage: 2, in: host), color: .pink)
        var stored = try store.highlights.highlights(bookID: book.id)
        #expect(stored.count == 1)
        #expect(stored.first?.id == original.id)
        #expect(stored.first?.color == .pink)
        #expect(stored.first?.text == original.text)
        #expect(stored.first?.rects == original.rects)

        // Partly overlapping and extending to the left: one merged highlight, new colour, oldest id.
        controller.highlight(try Support.select("Remember that the quick", onPage: 2, in: host), color: .green)
        stored = try store.highlights.highlights(bookID: book.id)
        #expect(stored.count == 1)
        #expect(stored.first?.id == original.id)
        #expect(stored.first?.color == .green)
        #expect(stored.first?.text == "Remember that " + Support.phrase)
        #expect(stored.first?.rects.count == 1)

        // A separate highlight elsewhere, then a selection joining both.
        let other = try #require(controller.highlight(try Support.select("Inverse then hence", onPage: 2, in: host),
                                                      color: .blue).first)
        #expect(try store.highlights.highlights(bookID: book.id).count == 2)
        let page = try #require(host.session.pdf.page(at: 2))
        let text = (page.string ?? "") as NSString
        let from = text.range(of: "margins").location
        let to = text.range(of: "then hence").location
        controller.highlight(try Support.select(fromPage: 2, character: from, toPage: 2, character: to + 3, in: host),
                             color: .yellow)
        stored = try store.highlights.highlights(bookID: book.id)
        #expect(stored.count == 1, "\(stored.map(\.text))")
        #expect(stored.first?.id == original.id, "the oldest absorbed highlight's id is kept")
        #expect(stored.first?.text == "Remember that the quick amber fox annotates margins. Inverse then hence")
        #expect(stored.first?.rects.count == 2)
        #expect(try store.highlights.highlight(id: other.id) == nil)
        // The page shows exactly the stored highlight.
        await PageInkTestSupport.pause(0.1)
        #expect(controller.appliedAnnotations(onPage: 2).map(\.highlightID) == [original.id])
        #expect(Support.highlightAnnotations(page).count == 1)
    }

    @Test func adjacentHighlightsStaySeparate() async throws {
        let (store, book) = try Support.makeSmallStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let host = try await Support.host(book, store, pageIndex: 2)
        defer { Task { await host.close() } }
        let controller = Support.controller(host)
        controller.highlight(try Support.select("the quick", onPage: 2, in: host), color: .yellow)
        controller.highlight(try Support.select("amber fox", onPage: 2, in: host), color: .yellow)
        #expect(try store.highlights.highlights(bookID: book.id).map(\.text) == ["the quick", "amber fox"])
    }

    // MARK: Taps and menus

    @Test func tapsHitStoredRectsAndOtherwiseAreNotConsumed() async throws {
        let (store, book) = try Support.makeSmallStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let host = try await Support.host(book, store, pageIndex: 2)
        defer { Task { await host.close() } }
        let controller = Support.controller(host)
        let highlight = try #require(controller.highlight(try Support.select(Support.phrase, onPage: 2, in: host),
                                                          color: .yellow).first)
        let page = try #require(host.session.pdf.page(at: 2))
        let rect = highlight.rects[0]

        func tap(_ point: CGPoint) -> Bool {
            controller.handleTap(ReaderPageTap(pageIndex: 2, page: page, pointInPage: point,
                                               pointInView: host.pdfView.convert(point, from: page), view: host.pdfView))
        }
        #expect(controller.highlight(atPageIndex: 2, point: CGPoint(x: rect.midX, y: rect.midY))?.id == highlight.id)
        #expect(controller.highlight(atPageIndex: 2, point: CGPoint(x: rect.maxX + 3, y: rect.midY))?.id == highlight.id)
        #expect(controller.highlight(atPageIndex: 2, point: CGPoint(x: rect.maxX + 20, y: rect.midY)) == nil)
        #expect(!tap(CGPoint(x: rect.midX, y: rect.minY - 30)), "a tap off the highlight is not consumed")
        #expect(controller.menuHighlightID == nil)

        let modeBefore = host.session.mode
        #expect(tap(CGPoint(x: rect.midX, y: rect.midY)), "a tap on the highlight is consumed")
        #expect(controller.menuHighlightID == highlight.id, "the menu is for the tapped highlight")
        #expect(host.session.mode == modeBefore)

        // Markup mode: display-only, the tap belongs to the ink canvas.
        host.session.setMode(.markup)
        #expect(!tap(CGPoint(x: rect.midX, y: rect.midY)))
        #expect(controller.appliedAnnotations(onPage: 2).count == 1, "still shown in markup mode")
        #expect(!controller.isInteractive)
        host.session.setMode(.reading)
    }

    @Test func recolourCopyAndDelete() async throws {
        let (store, book) = try Support.makeSmallStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let host = try await Support.host(book, store, pageIndex: 2)
        defer { Task { await host.close() } }
        let controller = Support.controller(host)
        let highlight = try #require(controller.highlight(try Support.select(Support.phrase, onPage: 2, in: host),
                                                          color: .yellow).first)
        controller.recolor(highlightID: highlight.id, to: .blue)
        #expect(try store.highlights.highlight(id: highlight.id)?.color == .blue)
        #expect(controller.appliedAnnotations(onPage: 2).first?.highlightColor == .blue)

        controller.copyText(highlightID: highlight.id)
        #expect(UIPasteboard.general.string == Support.phrase)

        controller.delete(highlightID: highlight.id)
        #expect(try store.highlights.highlights(bookID: book.id).isEmpty)
        #expect(controller.appliedAnnotations(onPage: 2).isEmpty)
        #expect(Support.highlightAnnotations(host.session.pdf.page(at: 2)).isEmpty)
    }

    @Test func revealAPIJumpsToTheHighlightAndRecordsHistory() async throws {
        let (store, book) = try Support.makeSmallStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let highlight = Highlight(bookID: book.id, pageIndex: 9, rects: [CGRect(x: 72, y: 600, width: 100, height: 12)],
                                  color: .green, text: "x")
        try store.highlights.save(highlight)
        let host = try await Support.host(book, store, pageIndex: 0)
        defer { Task { await host.close() } }
        _ = await PageInkTestSupport.waitUntil { host.session.isOutlineLoaded }
        #expect(host.session.jump(toHighlightID: highlight.id))
        #expect(host.session.currentPageIndex == 9)
        #expect(host.session.canGoBack)
        #expect(!host.session.jump(toHighlightID: UUID()))
        #expect(await PageInkTestSupport.waitUntil { Support.controller(host).appliedPageIndices.contains(9) })
    }

    // MARK: Display lifecycle

    @Test func highlightsFollowTheDisplayedPages() async throws {
        let (store, book) = try Support.makeSmallStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        for pageIndex in [2, 9] {
            try store.highlights.save(Highlight(bookID: book.id, pageIndex: pageIndex,
                                                rects: [CGRect(x: 72, y: 600, width: 100, height: 12)],
                                                color: .yellow, text: "p\(pageIndex)"))
        }
        let host = try await Support.host(book, store, pageIndex: 2)
        defer { Task { await host.close() } }
        let controller = Support.controller(host)
        #expect(await PageInkTestSupport.waitUntil { controller.appliedPageIndices == [2] })
        #expect(Support.highlightAnnotations(host.session.pdf.page(at: 9)).isEmpty, "nothing on pages off screen")
        #expect(controller.targetPages.allSatisfy { abs($0 - 2) <= 2 }, "\(controller.targetPages)")

        host.session.moveWithoutRecordingHistory(toPage: 9)
        #expect(await PageInkTestSupport.waitUntil { controller.appliedPageIndices == [9] }, "\(controller.appliedPageIndices)")
        #expect(Support.highlightAnnotations(host.session.pdf.page(at: 2)).isEmpty, "removed when the page left")
        #expect(Support.highlightAnnotations(host.session.pdf.page(at: 9)).count == 1)
        #expect(controller.displayedHighlights.keys.sorted() == [9])
    }

    @Test func highlightsAreReappliedAfterTheDocumentViewIsRebuilt() async throws {
        let (store, book) = try Support.makeSmallStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        try store.highlights.save(Highlight(bookID: book.id, pageIndex: 2, rects: [CGRect(x: 72, y: 600, width: 100, height: 12)],
                                            color: .pink, text: "x"))
        let host = try await Support.host(book, store, pageIndex: 2)
        defer { Task { await host.close() } }
        let controller = Support.controller(host)
        #expect(await PageInkTestSupport.waitUntil { controller.appliedPageIndices == [2] })

        // Same document re-assigned (what the shell does when the overlay provider changes).
        let document = try #require(host.pdfView.document)
        host.pdfView.document = nil
        host.pdfView.document = document
        host.pdfView.go(to: try #require(document.page(at: 2)))
        await PageInkTestSupport.pause(0.5)
        #expect(Support.highlightAnnotations(document.page(at: 2)).count == 1)

        // A new document object for the same file: its pages get the highlight once shown.
        let replacement = try #require(PDFDocument(url: host.session.documentURL))
        host.pdfView.document = replacement
        host.pdfView.go(to: try #require(replacement.page(at: 2)))
        #expect(await PageInkTestSupport.waitUntil {
            Support.highlightAnnotations(replacement.page(at: 2)).count == 1
        }, "not re-applied on the replacement document")
        #expect(Support.highlightAnnotations(document.page(at: 2)).isEmpty, "the old document's page was cleaned up")
    }

    // MARK: The PDF is never modified

    @Test func thePDFIsNeverWritten() async throws {
        let (store, book) = try Support.makeSmallStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let url = store.documentURL(for: book)
        let before = try Support.hash(url)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let host = try await Support.host(book, store, pageIndex: 2)
        defer { Task { await host.close() } }
        let controller = Support.controller(host)
        let ownAnnotationsBefore = (0..<12).map { host.session.pdf.annotations(onPageAt: $0).count }

        let highlight = try #require(controller.highlight(try Support.select(Support.phrase, onPage: 2, in: host),
                                                          color: .yellow).first)
        controller.recolor(highlightID: highlight.id, to: .green)
        controller.highlight(try Support.select("Inverse then", onPage: 2, in: host), color: .blue)
        await host.session.suspend()
        await PageInkTestSupport.pause(0.3)

        // The file on disk: same bytes, same modification date, no highlight annotations.
        #expect(try Support.hash(url) == before)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) == modified)
        let reopened = try #require(PDFDocument(url: url))
        #expect((0..<reopened.pageCount).allSatisfy { Support.highlightAnnotations(reopened.page(at: $0)).isEmpty })

        // Once the page leaves the screen, the on-screen document holds none of them either, so
        // even serialising it (which the app never does) carries no highlight.
        host.session.moveWithoutRecordingHistory(toPage: 9)
        #expect(await PageInkTestSupport.waitUntil { !controller.appliedPageIndices.contains(2) })
        let document = try #require(host.pdfView.document)
        #expect((0..<12).map { document.page(at: $0)?.annotations.count ?? 0 } == ownAnnotationsBefore)
        let data = try #require(document.dataRepresentation())
        let serialised = try #require(PDFDocument(data: data))
        #expect((0..<serialised.pageCount).allSatisfy { Support.highlightAnnotations(serialised.page(at: $0)).isEmpty })
        // The stored records are the only persistent form.
        #expect(try store.highlights.highlights(bookID: book.id).count == 2)
    }

    // MARK: Change events and windows

    @Test func ownChangesMoveRevisionsAndOtherWindowsFollow() async throws {
        let (store, book) = try Support.makeSmallStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let hostA = try await Support.host(book, store, pageIndex: 2)
        defer { Task { await hostA.close() } }
        let hostB = try await Support.host(book, store, pageIndex: 2, size: CGSize(width: 700, height: 900))
        defer { Task { await hostB.close() } }
        let controllerA = Support.controller(hostA), controllerB = Support.controller(hostB)
        let revisionsA = hostA.session.revisions.highlights
        let externalB = hostB.session.externalRevisions.highlights

        let highlight = try #require(controllerA.highlight(try Support.select(Support.phrase, onPage: 2, in: hostA),
                                                           color: .yellow).first)
        #expect(hostA.session.revisions.highlights > revisionsA, "own change moves revisions.highlights")
        #expect(hostB.session.externalRevisions.highlights > externalB)
        #expect(controllerB.appliedAnnotations(onPage: 2).map(\.highlightID) == [highlight.id], "window B shows it")
        // The Notebook (badges, lists) rebuilds from the store.
        #expect(await PageInkTestSupport.waitUntil { hostA.session.notebook?.totalCounts.highlights == 1 })

        // B recolours; A follows. B deletes; A follows.
        controllerB.recolor(highlightID: highlight.id, to: .pink)
        #expect(controllerA.appliedAnnotations(onPage: 2).first?.highlightColor == .pink)
        controllerB.delete(highlightID: highlight.id)
        #expect(controllerA.appliedAnnotations(onPage: 2).isEmpty)
        #expect(Support.highlightAnnotations(hostA.session.pdf.page(at: 2)).isEmpty)
    }

    // MARK: Accessibility

    @Test func accessibilityElementsSurfaceBesideThePDFView() async throws {
        let (store, book) = try Support.makeSmallStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let host = try await Support.host(book, store, pageIndex: 2)
        defer { Task { await host.close() } }
        let controller = Support.controller(host)
        controller.highlight(try Support.select(Support.phrase, onPage: 2, in: host), color: .green)

        // A sibling of the PDF view in its host (the PDF view's own children are only pages).
        let container = try #require(host.hostView.subviews.first { $0.accessibilityIdentifier == HighlightAccessibilityID.container })
        #expect(!container.isUserInteractionEnabled)
        #expect(container.frame == host.pdfView.frame)
        let elements = try #require(container.accessibilityElements as? [UIAccessibilityElement])
        #expect(elements.count == 1)
        let element = try #require(elements.first)
        #expect(element.accessibilityIdentifier == "reader.highlight.3.0")
        #expect(element.accessibilityLabel == "Green highlight, page 3")
        #expect(element.accessibilityValue == Support.phrase)
        #expect(element.accessibilityTraits.contains(.button))
        #expect(element.accessibilityCustomActions?.map(\.name) == ["Make Yellow", "Make Blue", "Make Pink",
                                                                    "Copy Text", "Delete Highlight"])
        #expect(element.accessibilityFrame.width > 0)

        // Markup mode: still read, no actions (display-only).
        host.session.setMode(.markup)
        let inMarkup = try #require((container.accessibilityElements as? [UIAccessibilityElement])?.first)
        #expect(inMarkup.accessibilityValue == Support.phrase)
        #expect(inMarkup.accessibilityCustomActions?.isEmpty != false)
        #expect(!inMarkup.accessibilityActivate())
        host.session.setMode(.reading)
    }

    // MARK: Drawing registration

    /// On screen, at two zooms and after a window resize: pages upright, rotated 90/180/270 and
    /// cropped, each with a highlight over "marker text". The tint lies on the word wherever
    /// PDFKit draws it (`pdfView.convert(rect, from: page)`), nowhere beside it, and the glyphs
    /// under it stay dark (multiply).
    ///
    /// (Off screen, `PDFPage.draw(with:to:)` calls an annotation's `draw(with:in:)` *without* the
    /// page rotation on this SDK, so thumbnails of rotated pages would misplace a custom-drawn
    /// annotation. Nothing renders the on-screen document off screen: thumbnails and exports use
    /// their own `PDFDocument`, which never carries these annotations.)
    @Test func drawingRegistersOnScreenOnRotatedAndCroppedPages() async throws {
        let pdf = try PageInkTestSupport.makePDF(
            sizes: Array(repeating: CGSize(width: 612, height: 792), count: 5),
            rotations: [0, 90, 180, 270, 90],
            cropInsets: [nil, nil, nil, nil, UIEdgeInsets(top: 20, left: 25, bottom: 100, right: 60)])
        defer { try? FileManager.default.removeItem(at: pdf) }
        let (store, book) = try PageInkTestSupport.makeStore(pdf: pdf, pageCount: 5)
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let host = try await Support.host(book, store, pageIndex: 0, size: CGSize(width: 900, height: 1100))
        defer { Task { await host.close() } }
        let document = try #require(host.pdfView.document)
        var rects: [Int: CGRect] = [:]
        for pageIndex in 0..<5 {
            let page = try #require(document.page(at: pageIndex))
            let string = (page.string ?? "") as NSString
            let selection = try #require(page.selection(for: string.range(of: "marker text")))
            let lineRects = selection.selectionsByLine().map { $0.bounds(for: page) }
            rects[pageIndex] = lineRects.first
            try host.session.perform {
                try $0.highlights.save(Highlight(bookID: book.id, pageIndex: pageIndex, rects: lineRects, color: .yellow,
                                                 text: "marker text"))
            }
        }
        for size in [CGSize(width: 900, height: 1100), CGSize(width: 640, height: 900)] {
            host.resize(to: size)
            for scale in [1.0, 2.5] as [CGFloat] {
                // The reader's own zoom, as a zoom command reports it. A scale change the
                // controller was not told about counts as PDFKit refitting, and it puts the
                // reading anchor back over the first `go(to:on:)` below (TSOFT-223).
                host.session.pdf.readerDidZoom()
                host.pdfView.autoScales = false
                host.pdfView.scaleFactor = scale
                for pageIndex in 0..<5 {
                    let page = try #require(document.page(at: pageIndex))
                    let rect = try #require(rects[pageIndex])
                    host.pdfView.go(to: rect.insetBy(dx: -30, dy: -30), on: page)
                    let applied = await PageInkTestSupport.waitUntil {
                        Support.controller(host).appliedAnnotations(onPage: pageIndex).count == 1
                    }
                    #expect(applied, "page \(pageIndex) not applied")
                    await PageInkTestSupport.pause(1.0)
                    let frame = host.pdfView.convert(rect, from: page)
                    let snapshot = Support.snapshot(host.pdfView)
                    var tinted = 0, dark = 0, samples = 0
                    for fx in stride(from: 0.05, through: 0.95, by: 0.05) {
                        for fy in [0.3, 0.5, 0.7] {
                            let p = snapshot.pixel(CGPoint(x: frame.minX + frame.width * fx, y: frame.minY + frame.height * fy))
                            samples += 1
                            if Support.isTinted(p) { tinted += 1 }
                            if p.r < 110 && p.g < 110 && p.b < 110 { dark += 1 }
                        }
                    }
                    let label = "page \(pageIndex) rot \(page.rotation) scale \(scale) size \(size) frame \(frame)"
                    #expect(tinted > samples / 4, "\(label): \(tinted)/\(samples) tinted")
                    #expect(dark > 0, "\(label): glyphs under the highlight stay dark")
                    let clear = max(frame.width, frame.height) * 0.5 + 12
                    for point in [CGPoint(x: frame.midX, y: frame.minY - clear), CGPoint(x: frame.midX, y: frame.maxY + clear),
                                  CGPoint(x: frame.minX - clear, y: frame.midY), CGPoint(x: frame.maxX + clear, y: frame.midY)]
                    where host.pdfView.bounds.insetBy(dx: 2, dy: 2).contains(point) {
                        #expect(!Support.isTinted(snapshot.pixel(point)), "\(label): tint outside the highlight at \(point)")
                    }
                }
            }
        }
    }
}
