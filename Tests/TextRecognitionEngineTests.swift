import CoreGraphics
import Foundation
import PDFKit
import ReaderCore
import Testing
import UIKit
@testable import Marginal

/// The recognition queue (S2) on `scanned.pdf`: Vision finds the known phrase with rects in page
/// space, the typed cover is not recognised, a relaunch continues the count, pause reasons hold
/// and release, suspension stops it, and deleting the book cancels it and removes its files.
/// Serialised: the Vision tests are heavy and the worker's document counter is process-wide.
@Suite(.serialized)
@MainActor
struct TextRecognitionEngineTests {
    typealias Support = TextRecognitionTestSupport

    // MARK: Vision

    /// Real Vision, with a reader on page 17 so that page goes first.
    @Test func recognisesTheKnownPhraseOnPage17WithItsRects() async throws {
        let fixture = try Support.scannedFixture()
        defer { fixture.cleanUp() }
        let bookID = fixture.book.id
        let engine = TextRecognitionEngine(store: fixture.store, conditions: FakeRecognitionConditions(),
                                           readerPages: { _ in [Support.phrasePage] }, pauseBetweenPages: .zero,
                                           observesApplicationState: false)
        await engine.start()
        #expect(await engine.accept(bookID: bookID))
        #expect(await Support.waitUntil(timeout: 90) { !engine.recognisedPages.isEmpty })
        await engine.shutDown()

        #expect(engine.recognisedPages.first?.pageIndex == Support.phrasePage, "the reader's page goes first")
        let page = try #require(try await fixture.store.recognisedPage(bookID: bookID, pageIndex: Support.phrasePage))
        let text = page.text as NSString
        let range = text.range(of: Support.phrase)
        #expect(range.location != NSNotFound, "recognised: \(page.text.prefix(200))")
        let rects = page.rects(forUTF16Range: range.location..<NSMaxRange(range))
        #expect(rects.count == 1)
        let rect = try #require(rects.first)
        print("TEXT-RECOGNITION phrase rect \(rect) (findings: \(Support.phraseBox))")
        #expect(abs(rect.minX - Support.phraseBox.minX) <= 3, "\(rect)")
        #expect(abs(rect.minY - Support.phraseBox.minY) <= 3, "\(rect)")
        #expect(abs(rect.width - Support.phraseBox.width) <= 6, "\(rect)")
        #expect(abs(rect.height - Support.phraseBox.height) <= 3, "\(rect)")
        // The phrase is on that page only of the pages read, and the word boxes run left to right.
        let heron = text.range(of: "heron")
        let heronRect = try #require(page.rects(forUTF16Range: heron.location..<NSMaxRange(heron)).first)
        #expect(heronRect.minX > rect.minX && heronRect.maxX < rect.maxX)
        // The stored state counts the cover (text of its own) and the page read.
        let state = await Support.state(fixture.store, bookID)
        #expect(state?.progress?.totalPages == 30)
        #expect((state?.progress?.pagesDone ?? 0) >= 2)
    }

    // MARK: Whole book (fake recogniser)

    @Test func theTypedCoverIsNotRecognisedAndTheBookCompletes() async throws {
        let fixture = try Support.scannedFixture()
        defer { fixture.cleanUp() }
        let bookID = fixture.book.id
        let engine = Support.makeEngine(fixture.store)
        await engine.start()
        #expect(await engine.accept(bookID: bookID))
        #expect(await Support.waitUntil(timeout: 60) { await Support.state(fixture.store, bookID) == .complete })
        await engine.shutDown()

        let indices = await Support.recognisedIndices(fixture.store, bookID)
        #expect(indices == Array(1..<30), "every scanned page, not the cover")
        #expect(!engine.recognisedPages.contains { $0.pageIndex == 0 })
        #expect(engine.recognisedPages.count == 29)
        // Without a reader, in page order.
        #expect(engine.recognisedPages.map(\.pageIndex) == Array(1..<30))
        // The fake's words, in page space.
        let page = try #require(try await fixture.store.recognisedPage(bookID: bookID, pageIndex: 5))
        #expect(page.text == "fake words")
        let box = try #require(page.words.first?.bounds)
        #expect(abs(box.minX - 61.2) < 0.2 && abs(box.minY - 396) < 0.2, "\(box)")
        #expect(TextRecognitionWorker.liveDocuments.withLock { $0 } == 0, "the private document is released")
    }

    @Test func aRelaunchMidwayContinuesTheCount() async throws {
        let fixture = try Support.scannedFixture()
        defer { fixture.cleanUp() }
        let bookID = fixture.book.id
        let slow = FakePageRecognizer(delay: 0.15)
        let first = Support.makeEngine(fixture.store, recognizer: slow)
        await first.start()
        #expect(await first.accept(bookID: bookID))
        #expect(await Support.waitUntil { first.recognisedPages.count >= 5 })
        await first.shutDown()  // as if the app were quit: the page in flight is saved

        let doneBefore = try #require(await Support.state(fixture.store, bookID)?.progress?.pagesDone)
        let readBefore = Set(first.recognisedPages.map(\.pageIndex))
        #expect(doneBefore == readBefore.count + 1, "the pages read and the cover")
        #expect(await Support.recognisedIndices(fixture.store, bookID).count == readBefore.count)

        // "Relaunch": a new engine on the same store resumes from the pages on disk.
        var counts: [Int] = []
        let observation = fixture.store.hub.observe { event in
            guard case .recognitionStateChanged(let changed) = event.change, changed == bookID else { return }
            Task { @MainActor in
                if let done = await Support.state(fixture.store, bookID)?.progress?.pagesDone { counts.append(done) }
            }
        }
        defer { observation.cancel() }
        let second = Support.makeEngine(fixture.store)
        await second.start()
        #expect(await Support.waitUntil(timeout: 60) { await Support.state(fixture.store, bookID) == .complete })
        await second.shutDown()
        #expect(Set(second.recognisedPages.map(\.pageIndex)).isDisjoint(with: readBefore), "nothing is read twice")
        #expect(second.recognisedPages.count == 29 - readBefore.count)
        #expect(!counts.isEmpty)
        #expect(counts.allSatisfy { $0 >= doneBefore }, "the count continues from \(doneBefore): \(counts)")
        #expect(await Support.recognisedIndices(fixture.store, bookID) == Array(1..<30))
    }

    // MARK: Pauses

    @Test func pauseReasonsHoldAndRelease() async throws {
        let fixture = try Support.scannedFixture()
        defer { fixture.cleanUp() }
        let bookID = fixture.book.id
        let conditions = FakeRecognitionConditions()
        let engine = Support.makeEngine(fixture.store, recognizer: FakePageRecognizer(delay: 0.1), conditions: conditions)
        await engine.start()
        #expect(await engine.accept(bookID: bookID))
        #expect(await Support.waitUntil { !engine.recognisedPages.isEmpty })

        func reasons() async -> Set<RecognitionPauseReason>? {
            switch await Support.state(fixture.store, bookID) {
            case .paused(_, let reasons): reasons
            case .inProgress: []
            default: nil
            }
        }
        conditions.isLowPowerModeEnabled = true
        #expect(await Support.waitUntil { await reasons() == [.lowPowerMode] })
        conditions.isUnderThermalPressure = true
        #expect(await Support.waitUntil { await reasons() == [.lowPowerMode, .thermal] })
        #expect(await engine.pause(bookID: bookID))
        #expect(await reasons() == [.lowPowerMode, .thermal, .reader])

        // Nothing is read while paused (the page in flight when it paused may still finish).
        try await Task.sleep(for: .milliseconds(300))
        let pagesWhilePaused = engine.recognisedPages.count
        try await Task.sleep(for: .milliseconds(600))
        #expect(engine.recognisedPages.count == pagesWhilePaused)

        conditions.isLowPowerModeEnabled = false
        #expect(await Support.waitUntil { await reasons() == [.thermal, .reader] })
        #expect(await engine.resume(bookID: bookID))
        #expect(await reasons() == [.thermal])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.recognisedPages.count == pagesWhilePaused, "still paused for heat")
        conditions.isUnderThermalPressure = false
        #expect(await Support.waitUntil { await reasons() == [] })
        #expect(await Support.waitUntil { engine.recognisedPages.count > pagesWhilePaused }, "running again")

        // Accepting in Low Power Mode pauses at once; a reader pause outlives it.
        let other = try SearchTestSupport.makeFixture("scanned.pdf", pages: 30)
        defer { other.cleanUp() }
        await engine.shutDown()
        let lowPower = FakeRecognitionConditions(lowPower: true)
        let second = Support.makeEngine(other.store, conditions: lowPower)
        await second.start()
        #expect(await second.accept(bookID: other.book.id))
        #expect(await Support.state(other.store, other.book.id)?.pauseReasons == [.lowPowerMode])
        #expect(await second.pause(bookID: other.book.id))
        lowPower.isLowPowerModeEnabled = false
        #expect(await Support.waitUntil { await Support.state(other.store, other.book.id)?.pauseReasons == [.reader] })
        try await Task.sleep(for: .milliseconds(300))
        #expect(second.recognisedPages.isEmpty)
        await second.shutDown()
    }

    @Test func suspensionStopsTheQueueAndReturningResumesIt() async throws {
        let fixture = try Support.scannedFixture()
        defer { fixture.cleanUp() }
        let bookID = fixture.book.id
        let engine = Support.makeEngine(fixture.store, recognizer: FakePageRecognizer(delay: 0.1))
        await engine.start()
        #expect(await engine.accept(bookID: bookID))
        #expect(await Support.waitUntil { engine.recognisedPages.count >= 2 })
        engine.setSuspended(true)
        try await Task.sleep(for: .milliseconds(300))  // the page in flight finishes
        let count = engine.recognisedPages.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(engine.recognisedPages.count == count)
        if case .inProgress = await Support.state(fixture.store, bookID) {} else {
            Issue.record("suspension is not a pause: the state stays in progress")
        }
        engine.setSuspended(false)
        #expect(await Support.waitUntil { engine.recognisedPages.count > count })
        await engine.shutDown()
    }

    // MARK: Decisions

    @Test func declineAndAcceptFollowTheStateRules() async throws {
        let fixture = try Support.scannedFixture()
        defer { fixture.cleanUp() }
        let bookID = fixture.book.id
        try await fixture.store.saveRecognitionState(.notDecided, bookID: bookID, origin: nil)
        let engine = Support.makeEngine(fixture.store)
        await engine.start()
        #expect(await engine.decline(bookID: bookID))
        #expect(await Support.state(fixture.store, bookID) == .declined)
        #expect(!(await engine.pause(bookID: bookID)), "nothing to pause")
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.recognisedPages.isEmpty, "declined: nothing is read")
        // Declining is never final.
        #expect(await engine.accept(bookID: bookID))
        #expect(!(await engine.accept(bookID: bookID)), "already accepted")
        #expect(!(await engine.decline(bookID: bookID)), "in progress cannot be declined")
        #expect(await Support.waitUntil(timeout: 60) { await Support.state(fixture.store, bookID) == .complete })
        await engine.shutDown()
    }

    // MARK: Deletion

    @Test func deletingTheBookCancelsItAndRemovesItsFiles() async throws {
        let fixture = try Support.scannedFixture()
        defer { fixture.cleanUp() }
        let bookID = fixture.book.id
        let engine = Support.makeEngine(fixture.store, recognizer: FakePageRecognizer(delay: 0.3))
        await engine.start()
        #expect(await engine.accept(bookID: bookID))
        #expect(await Support.waitUntil { engine.recognisedPages.count >= 1 })
        #expect(await Support.waitUntil { engine.isWorking }, "a page is in flight")

        try await fixture.store.deleteBook(id: bookID, origin: nil)
        let root = fixture.store.rootDirectory
        let bookDirectory = root.appendingPathComponent(BookStorageLayout.bookDirectory(bookID: bookID))
        let pagesBefore = engine.recognisedPages.count
        // Wait well past the page in flight.
        try await Task.sleep(for: .milliseconds(900))
        #expect(engine.recognisedPages.count <= pagesBefore, "no page is saved after the delete")
        #expect(!FileManager.default.fileExists(atPath: bookDirectory.path), "the book's directory is gone")
        #expect(await Support.recognisedIndices(fixture.store, bookID).isEmpty)
        #expect(await Support.state(fixture.store, bookID) == nil)
        #expect(await engine.state(bookID: bookID) == nil)
        await engine.shutDown()
    }

    // MARK: Restores (S4)

    /// A restore replacing the book posts `.bookDeleted` then `.bookSaved` for the same ID and
    /// carries its recognised text across: nothing is removed, and recognition resumes from the
    /// files on disk.
    @Test func aReplaceCancelsWithoutRemovingAndResumesFromTheFiles() async throws {
        let fixture = try Support.scannedFixture()
        defer { fixture.cleanUp() }
        let bookID = fixture.book.id
        let engine = Support.makeEngine(fixture.store, recognizer: FakePageRecognizer(delay: 0.1))
        await engine.start()
        #expect(await engine.accept(bookID: bookID))
        #expect(await Support.waitUntil { engine.recognisedPages.count >= 4 })

        fixture.store.hub.post(.bookDeleted(bookID: bookID), origin: ChangeOrigin(label: "restore"))
        let onDisk = await Support.recognisedIndices(fixture.store, bookID)
        #expect(await engine.state(bookID: bookID) != nil, "the stored state is still there")
        try await Task.sleep(for: .milliseconds(300))
        #expect(await Support.recognisedIndices(fixture.store, bookID).count >= onDisk.count, "nothing was removed")
        let pagesBefore = engine.recognisedPages.count
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.recognisedPages.count == pagesBefore, "cancelled until the book is back")

        fixture.store.hub.post(.bookSaved(bookID: bookID), origin: ChangeOrigin(label: "restore"))
        #expect(await Support.waitUntil(timeout: 60) { await Support.state(fixture.store, bookID) == .complete })
        await engine.shutDown()
        #expect(await Support.recognisedIndices(fixture.store, bookID) == Array(1..<30))
        let pages = engine.recognisedPages.map(\.pageIndex)
        #expect(Set(pages).count == pages.count, "no page read twice: resumed from the files")
    }

    /// While a restore holds the book at `BookWriteGate`, nothing is written into it.
    @Test func writesWaitWhileARestoreHoldsTheBook() async throws {
        let fixture = try Support.scannedFixture()
        defer { fixture.cleanUp() }
        let bookID = fixture.book.id
        let engine = Support.makeEngine(fixture.store, recognizer: FakePageRecognizer(delay: 0.05))
        await engine.start()
        #expect(await engine.accept(bookID: bookID))
        #expect(await Support.waitUntil { engine.recognisedPages.count >= 2 })

        let pause = await BookWriteGate.shared.pause([bookID])
        let held = await Support.recognisedIndices(fixture.store, bookID)
        let stateHeld = await Support.state(fixture.store, bookID)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await Support.recognisedIndices(fixture.store, bookID) == held, "no page written while held")
        #expect(await Support.state(fixture.store, bookID) == stateHeld, "no state written while held")
        BookWriteGate.shared.resume(pause)
        #expect(await Support.waitUntil(timeout: 60) { await Support.state(fixture.store, bookID) == .complete })
        await engine.shutDown()
    }

    /// Pages lost from disk while the queue runs (a merge's set-aside directory) are read again
    /// before the book is marked complete, and the count matches the files.
    @Test func pagesLostFromDiskAreReadAgainBeforeCompleting() async throws {
        let fixture = try Support.scannedFixture()
        defer { fixture.cleanUp() }
        let bookID = fixture.book.id
        let engine = Support.makeEngine(fixture.store, recognizer: FakePageRecognizer(delay: 0.05))
        await engine.start()
        #expect(await engine.accept(bookID: bookID))
        #expect(await Support.waitUntil { engine.recognisedPages.count >= 5 })
        let lost = fixture.store.rootDirectory.appendingPathComponent(
            BookStorageLayout.recognisedPagePath(bookID: bookID, pageIndex: 2))
        try FileManager.default.removeItem(at: lost)

        #expect(await Support.waitUntil(timeout: 60) { await Support.state(fixture.store, bookID) == .complete })
        await engine.shutDown()
        #expect(await Support.recognisedIndices(fixture.store, bookID) == Array(1..<30))
        #expect(engine.recognisedPages.filter { $0.pageIndex == 2 }.count == 2, "page 3 was read again")
    }

    // MARK: Order

    @Test func pagesNearestTheReaderGoFirst() throws {
        let pages = Array(0..<30)
        #expect(TextRecognitionOrder.nextPage(remaining: pages, readerPages: []) == 0)
        #expect(TextRecognitionOrder.nextPage(remaining: pages, readerPages: [16]) == 16)
        #expect(TextRecognitionOrder.nextPage(remaining: pages.filter { $0 != 16 }, readerPages: [16]) == 17)
        #expect(TextRecognitionOrder.nextPage(remaining: pages.filter { $0 != 16 && $0 != 17 }, readerPages: [16]) == 15)
        #expect(TextRecognitionOrder.nextPage(remaining: [2, 3, 27], readerPages: [16, 25]) == 27)
        #expect(TextRecognitionOrder.nextPage(remaining: [2, 3], readerPages: [29]) == 3)
        #expect(TextRecognitionOrder.nextPage(remaining: [], readerPages: [3]) == nil)
        // Spreading out from page 16.
        var left = pages
        var order: [Int] = []
        for _ in 0..<5 {
            let next = try #require(TextRecognitionOrder.nextPage(remaining: left, readerPages: [16]))
            order.append(next)
            left.removeAll { $0 == next }
        }
        #expect(order == [16, 17, 15, 18, 14])
    }
}

/// Rendering and the conversion of image boxes to page space (findings, question 8), on a page
/// with a crop box away from the origin and a `/Rotate`: boxes come back in unrotated page space.
@MainActor
struct TextRecognitionGeometryTests {
    @Test func boxesMapBackToPageSpaceOnCroppedAndRotatedPages() throws {
        // A black bar at a known place in page space (y up): UIKit draws y down.
        let pageSize = CGSize(width: 612, height: 792)
        let bar = CGRect(x: 100, y: 500, width: 200, height: 30)
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize)).pdfData { context in
            context.beginPage()
            UIColor.black.setFill()
            UIRectFill(CGRect(x: bar.minX, y: pageSize.height - bar.maxY, width: bar.width, height: bar.height))
        }
        for (crop, rotation) in [(CGRect(origin: .zero, size: pageSize), 0),
                                 (CGRect(x: 50, y: 60, width: 450, height: 600), 0),
                                 (CGRect(x: 50, y: 60, width: 450, height: 600), 90),
                                 (CGRect(origin: .zero, size: pageSize), 270)] {
            let document = try #require(PDFDocument(data: data))
            let page = try #require(document.page(at: 0))
            page.setBounds(crop, for: .cropBox)
            page.rotation = rotation
            let rendered = try #require(PageImageRenderer.render(page, dpi: 100))
            #expect(rendered.box == crop)
            let found = try #require(Self.darkBounds(rendered.image), "crop \(crop) rotation \(rotation)")
            let mapped = PageImageRenderer.pageRect(fromNormalised: found, box: rendered.box)
            #expect(abs(mapped.minX - bar.minX) < 1.5 && abs(mapped.minY - bar.minY) < 1.5
                    && abs(mapped.width - bar.width) < 2 && abs(mapped.height - bar.height) < 2,
                    "crop \(crop) rotation \(rotation): \(mapped)")
        }
    }

    /// The normalised bounds (origin lower-left) of the dark pixels of a greyscale image.
    static func darkBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Rows in memory run top to bottom.
        var minX = width, maxX = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            for column in 0..<width where pixels[row * width + column] < 128 {
                minX = min(minX, column); maxX = max(maxX, column)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
            }
        }
        guard maxX >= 0 else { return nil }
        let w = Double(width), h = Double(height)
        return CGRect(x: Double(minX) / w, y: 1 - Double(maxRow + 1) / h,
                      width: Double(maxX + 1 - minX) / w, height: Double(maxRow + 1 - minRow) / h)
    }
}
