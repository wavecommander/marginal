import Foundation
import CoreGraphics
import Testing
@testable import ReaderCore

// MARK: - Detection

@Suite("Scan detection")
struct ScanDetectionTests {
    static func text(_ page: Int, characters: Int = 2_300) -> ScanPageSample {
        ScanPageSample(pageIndex: page, textCharacterCount: characters, imageCoverage: 0)
    }
    static func scan(_ page: Int, coverage: Double = 1) -> ScanPageSample {
        ScanPageSample(pageIndex: page, textCharacterCount: 0, imageCoverage: coverage)
    }
    static func blank(_ page: Int) -> ScanPageSample {
        ScanPageSample(pageIndex: page, textCharacterCount: 0, imageCoverage: 0)
    }

    @Test func classifiesPages() {
        #expect(ScanDetection.kind(of: Self.text(0)) == .text)
        #expect(ScanDetection.kind(of: Self.scan(0)) == .scanned)
        #expect(ScanDetection.kind(of: Self.blank(0)) == .blank)
        // A stray page number on a scan is not a text layer.
        #expect(ScanDetection.kind(of: ScanPageSample(pageIndex: 0, textCharacterCount: 3, imageCoverage: 0.98)) == .scanned)
        // A scan that already has an OCR text layer has text of its own.
        #expect(ScanDetection.kind(of: ScanPageSample(pageIndex: 0, textCharacterCount: 1_900, imageCoverage: 1)) == .text)
        // A small picture on an otherwise empty page is neutral.
        #expect(ScanDetection.kind(of: Self.scan(0, coverage: 0.3)) == .blank)
        #expect(ScanDetection.kind(of: Self.scan(0, coverage: 0.6)) == .scanned)
        #expect(ScanDetection.kind(of: Self.scan(0, coverage: 7)) == .scanned)
        #expect(ScanDetection.kind(of: Self.scan(0, coverage: .nan)) == .blank)
        #expect(ScanDetection.kind(of: Self.text(0, characters: ScanDetection.textCharacterThreshold - 1)) == .blank)
        #expect(ScanDetection.kind(of: Self.text(0, characters: ScanDetection.textCharacterThreshold)) == .text)
    }

    @Test func allTextBookIsNotScanned() {
        #expect(!ScanDetection.isScanned((0..<12).map { Self.text($0) }))
    }

    @Test func aFewBlankOrPictureOnlyPagesDoNotMakeABookScanned() {
        var samples = (0..<12).map { Self.text($0) }
        samples[0] = Self.scan(0)        // a picture cover
        samples[4] = Self.scan(4)        // a full-page plate
        samples[7] = Self.blank(7)       // a blank verso
        samples[11] = Self.blank(11)
        #expect(!ScanDetection.isScanned(samples))
        // Even a picture-heavy typed book is not scanned while most pages have text.
        samples[2] = Self.scan(2)
        samples[9] = Self.scan(9)
        #expect(!ScanDetection.isScanned(samples))
    }

    @Test func aScanWithATypedCoverIsScanned() {
        var samples = (0..<12).map { Self.scan($0) }
        samples[0] = Self.text(0, characters: 120)
        #expect(ScanDetection.isScanned(samples))
        // A couple of typed pages and blank pages too (a library's front sheet, blank versos).
        samples[1] = Self.text(1)
        samples[5] = Self.blank(5)
        samples[6] = Self.blank(6)
        #expect(ScanDetection.isScanned(samples))
    }

    @Test func halfTypedHalfScannedIsNotScanned() {
        let samples = (0..<12).map { $0.isMultiple(of: 2) ? Self.text($0) : Self.scan($0) }
        #expect(!ScanDetection.isScanned(samples))
    }

    @Test func emptyOneAndAllBlankBooks() {
        #expect(!ScanDetection.isScanned([]))
        #expect(ScanDetection.isScanned([Self.scan(0)]))
        #expect(!ScanDetection.isScanned([Self.text(0)]))
        #expect(!ScanDetection.isScanned([Self.blank(0)]))
        #expect(!ScanDetection.isScanned((0..<12).map(Self.blank)))
    }

    /// The `scanned.pdf` fixture: a typed cover, then 29 scanned pages.
    @Test func theScannedFixtureIsScanned() {
        let pages = ScanDetection.samplePageIndices(pageCount: 30)
        let samples = pages.map { $0 == 0 ? Self.text(0, characters: 70) : Self.scan($0) }
        #expect(pages.first == 0)
        #expect(ScanDetection.isScanned(samples))
    }

    @Test func samplePageIndices() {
        #expect(ScanDetection.samplePageIndices(pageCount: 0).isEmpty)
        #expect(ScanDetection.samplePageIndices(pageCount: -3).isEmpty)
        #expect(ScanDetection.samplePageIndices(pageCount: 1) == [0])
        #expect(ScanDetection.samplePageIndices(pageCount: 5) == [0, 1, 2, 3, 4])
        #expect(ScanDetection.samplePageIndices(pageCount: 12) == Array(0..<12))
        #expect(ScanDetection.samplePageIndices(pageCount: 100, maximum: 0).isEmpty)
        #expect(ScanDetection.samplePageIndices(pageCount: 100, maximum: 1) == [50])
        #expect(ScanDetection.samplePageIndices(pageCount: 100, maximum: 2) == [0, 99])
        for count in [13, 30, 31, 100, 1_500, 100_000] {
            let pages = ScanDetection.samplePageIndices(pageCount: count)
            #expect(pages.count == ScanDetection.defaultSampleCount, "\(count)")
            #expect(pages == pages.sorted() && Set(pages).count == pages.count, "\(count): ascending and distinct")
            #expect(pages.first == 0 && pages.last == count - 1, "\(count): spread from first to last")
            let gaps = zip(pages.dropFirst(), pages).map { $0 - $1 }
            #expect(gaps.max()! - gaps.min()! <= 1, "\(count): evenly spread, gaps \(gaps)")
        }
    }
}

// MARK: - Recognition state

@Suite("Recognition state")
struct RecognitionStateTests {
    static func progress(_ done: Int, _ total: Int = 30) -> RecognitionProgress {
        RecognitionProgress(pagesDone: done, totalPages: total)
    }

    @Test func offerDeclinedAndAcceptedLater() {
        let start = RecognitionState.notDecided
        #expect(start.isAwaitingDecision)
        #expect(start.declining() == .declined)
        #expect(RecognitionState.declined.declining() == .declined)
        #expect(start.accepting(totalPages: 30) == .inProgress(Self.progress(0)))
        // Declining is never final.
        #expect(RecognitionState.declined.accepting(totalPages: 30) == .inProgress(Self.progress(0)))
        #expect(RecognitionState.declined.accepting(totalPages: 30, pagesDone: 7) == .inProgress(Self.progress(7)))
        // Nothing left to do: complete at once.
        #expect(start.accepting(totalPages: 0) == .complete)
        #expect(start.accepting(totalPages: 30, pagesDone: 30) == .complete)
        #expect(start.accepting(totalPages: 30, pagesDone: 99) == .complete)
        // Not offered once accepted.
        for state in [RecognitionState.inProgress(Self.progress(1)), .paused(Self.progress(1), reasons: [.reader]), .complete] {
            #expect(state.declining() == nil, "\(state)")
            #expect(state.accepting(totalPages: 30) == nil, "\(state)")
            #expect(!state.isAwaitingDecision)
        }
    }

    @Test func pagesFinishUntilComplete() {
        var state = RecognitionState.notDecided.accepting(totalPages: 3)!
        state = state.finishingPage()!
        #expect(state == .inProgress(Self.progress(1, 3)))
        #expect(state.progress?.fractionDone == 1.0 / 3)
        state = state.finishingPage()!.finishingPage()!
        #expect(state == .complete)
        #expect(state.progress == nil)
        #expect(state.finishingPage() == nil)
        #expect(RecognitionState.notDecided.finishingPage() == nil)
        #expect(RecognitionState.declined.finishingPage() == nil)
        // The page in flight when a pause came is still counted, and can complete the book.
        let paused = RecognitionState.paused(Self.progress(1, 3), reasons: [.reader])
        #expect(paused.finishingPage() == .paused(Self.progress(2, 3), reasons: [.reader]))
        #expect(paused.finishingPage()!.finishingPage() == .complete)
    }

    @Test func pauseAndResumeForEachReason() {
        let running = RecognitionState.inProgress(Self.progress(4))
        for reason in RecognitionPauseReason.allCases {
            let paused = running.pausing(reason)
            #expect(paused == .paused(Self.progress(4), reasons: [reason]))
            #expect(paused?.pauseReasons == [reason])
            #expect(paused?.progress == Self.progress(4))
            #expect(paused?.resuming(reason) == running)
            // A reason that does not hold changes nothing.
            let other = RecognitionPauseReason.allCases.first { $0 != reason }!
            #expect(paused?.resuming(other) == paused)
        }
        #expect(running.resuming(.reader) == running)
    }

    @Test func overlappingPausesResumeOnlyWhenNoReasonIsLeft() {
        let running = RecognitionState.inProgress(Self.progress(10))
        let thermal = running.pausing(.thermal)!
        let both = thermal.pausing(.reader)!
        #expect(both.pauseReasons == [.thermal, .reader])
        #expect(both.pausing(.reader) == both)
        // The device cools down, but the reader paused too: still paused.
        let readerOnly = both.resuming(.thermal)!
        #expect(readerOnly == .paused(Self.progress(10), reasons: [.reader]))
        // Low Power Mode comes on, the reader resumes: still paused for Low Power Mode.
        let lowPower = readerOnly.pausing(.lowPowerMode)!.resuming(.reader)!
        #expect(lowPower == .paused(Self.progress(10), reasons: [.lowPowerMode]))
        #expect(lowPower.resuming(.lowPowerMode) == running)
    }

    @Test func pauseAndResumeDoNotApplyBeforeAcceptingOrAfterCompleting() {
        for state in [RecognitionState.notDecided, .declined, .complete] {
            #expect(state.pausing(.reader) == nil, "\(state)")
            #expect(state.resuming(.reader) == nil, "\(state)")
            #expect(state.finishing() == nil, "\(state)")
            #expect(state.pauseReasons.isEmpty)
        }
    }

    @Test func finishing() {
        #expect(RecognitionState.inProgress(Self.progress(28)).finishing() == .complete)
        #expect(RecognitionState.paused(Self.progress(28), reasons: [.thermal]).finishing() == .complete)
    }

    @Test func progressIsClamped() {
        #expect(RecognitionProgress(pagesDone: -2, totalPages: 5) == Self.progress(0, 5))
        #expect(RecognitionProgress(pagesDone: 9, totalPages: 5) == Self.progress(5, 5))
        #expect(RecognitionProgress(pagesDone: 0, totalPages: -1) == Self.progress(0, 0))
        #expect(RecognitionProgress(pagesDone: 0, totalPages: 0).fractionDone == 1)
    }

    @Test func codingRoundTripsAndIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let states: [RecognitionState] = [
            .notDecided, .declined, .inProgress(Self.progress(3)), .paused(Self.progress(4), reasons: [.thermal, .reader, .lowPowerMode]),
            .complete,
        ]
        for state in states {
            let data = try encoder.encode(state)
            #expect(try JSONDecoder().decode(RecognitionState.self, from: data) == state)
        }
        let paused = String(decoding: try encoder.encode(states[3]), as: UTF8.self)
        #expect(paused == #"{"pagesDone":4,"pausedFor":["lowPowerMode","reader","thermal"],"state":"paused","totalPages":30}"#)
        #expect(String(decoding: try encoder.encode(RecognitionState.notDecided), as: UTF8.self) == #"{"state":"notDecided"}"#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RecognitionState.self, from: Data(#"{"state":"paused","pagesDone":1,"totalPages":2,"pausedFor":[]}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RecognitionState.self, from: Data(#"{"state":"sideways"}"#.utf8))
        }
    }
}

// MARK: - Recognised page

@Suite("Recognised page")
struct RecognisedPageTests {
    static func token(_ text: String, _ x: Double, _ y: Double, _ width: Double, height: Double = 12) -> RecognisedPage.Token {
        RecognisedPage.Token(text: text, bounds: CGRect(x: x, y: y, width: width, height: height))
    }

    /// Two lines on page 17 of `scanned.pdf`, as Vision boxes them.
    static let page = RecognisedPage(pageIndex: 16, lines: [
        [token("The", 71.4, 692.6, 22.04), token("quiet", 97, 692.6, 28), token("heron", 114.3, 693.1, 28),
         token("measures", 146, 693, 46), token("tidewater.", 196, 692.98, 37)],
        [token("Independent", 72, 669, 60, height: 13), token("factorization", 136, 669, 64, height: 13)],
    ])

    @Test func textAndWords() {
        let page = Self.page
        #expect(page.text == "The quiet heron measures tidewater.\nIndependent factorization")
        #expect(page.words.count == 7)
        let ns = page.text as NSString
        #expect(page.words.map { ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
                == ["The", "quiet", "heron", "measures", "tidewater.", "Independent", "factorization"])
        #expect(page.words.map(\.line) == [0, 0, 0, 0, 0, 1, 1])
        // Boxes are kept to a tenth of a point.
        #expect(page.words[0].bounds == CGRect(x: 71.4, y: 692.6, width: 22, height: 12))
        #expect(page.words[4].bounds == CGRect(x: 196, y: 693, width: 37, height: 12))
    }

    @Test func tokensAreCleanedUp() {
        let page = RecognisedPage(pageIndex: 0, lines: [
            [Self.token("", 0, 0, 1), Self.token("two words", 10, 10, 50)],
            [],
            [Self.token("  ", 0, 0, 1)],
            [Self.token("naïve 数学 😀", 0, 50, 40)],
        ])
        #expect(page.text == "two words\nnaïve 数学 😀")
        #expect(page.words.map(\.line) == [0, 0, 1, 1, 1])
        #expect(page.words[0].bounds == page.words[1].bounds)
        // UTF-16 offsets: the emoji is two units.
        #expect(page.words.last?.range == 19..<21)
        let empty = RecognisedPage(pageIndex: 3, lines: [])
        #expect(empty.text.isEmpty && empty.words.isEmpty)
    }

    @Test func textAndBoxesMustAgree() {
        let boxes = [CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 2, y: 0, width: 1, height: 1)]
        #expect(RecognisedPage(pageIndex: 0, text: "a b", wordBoxes: boxes) != nil)
        #expect(RecognisedPage(pageIndex: 0, text: "a b c", wordBoxes: boxes) == nil)
        #expect(RecognisedPage(pageIndex: 0, text: "  a\r\n\r\nb ", wordBoxes: boxes)?.words.map(\.line) == [0, 2])
        #expect(RecognisedPage(pageIndex: 0, text: "a\u{2028}b", wordBoxes: boxes)?.words.map(\.line) == [0, 1])
    }

    @Test func rectsForARangeMergePerLine() {
        let page = Self.page
        let ns = page.text as NSString
        func rects(_ phrase: String) -> [CGRect] {
            let r = ns.range(of: phrase)
            return page.rects(forUTF16Range: r.location..<(r.location + r.length))
        }
        // One word.
        #expect(rects("heron") == [CGRect(x: 114.3, y: 693.1, width: 28, height: 12)])
        // Part of a word marks the whole word.
        #expect(rects("ero") == [CGRect(x: 114.3, y: 693.1, width: 28, height: 12)])
        // The known phrase: one rect for its line, the union of its words.
        let line = rects("The quiet heron measures tidewater.")
        #expect(line.count == 1)
        #expect(line[0].minX == 71.4 && line[0].maxX == 233)
        #expect(abs(line[0].minY - 692.6) < 1e-9 && abs(line[0].maxY - 705.1) < 1e-9)
        // Across a line break: one rect per line, in order.
        let two = rects("tidewater.\nIndependent")
        #expect(two == [CGRect(x: 196, y: 693, width: 37, height: 12), CGRect(x: 72, y: 669, width: 60, height: 13)])
        // A range covering only spaces or nothing touches no word.
        let space = ns.range(of: " ")
        #expect(page.rects(forUTF16Range: space.location..<(space.location + 1)).isEmpty)
        #expect(page.rects(forUTF16Range: 4..<4).isEmpty)
        #expect(page.rects(forUTF16Range: 500..<600).isEmpty)
        #expect(page.rects(forUTF16Range: 0..<ns.length).count == 2)
    }

    @Test func codingRoundTrips() throws {
        let data = try JSONEncoder().encode(Self.page)
        let decoded = try JSONDecoder().decode(RecognisedPage.self, from: data)
        #expect(decoded == Self.page)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["format"] as? Int == 1)
        // Tenths of a point, each box as the difference from the previous one.
        #expect((object["boxes"] as? [Int])?.prefix(8) == [714, 6926, 220, 120, 256, 0, 60, 0])
        // Wrong format, boxes not in fours, or boxes that do not match the words: refused.
        for json in [#"{"format":2,"pageIndex":0,"text":"a","boxes":[0,0,1,1]}"#,
                     #"{"format":1,"pageIndex":0,"text":"a","boxes":[0,0,1]}"#,
                     #"{"format":1,"pageIndex":0,"text":"a b","boxes":[0,0,1,1]}"#] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(RecognisedPage.self, from: Data(json.utf8)) }
        }
    }

    /// A 1,500-page book of dense printed pages stays around a dozen megabytes, not tens.
    @Test func sizeIsCompact() throws {
        var generator = SeededGenerator(state: 7)
        let vocabulary = ["the", "eigenvalue", "of", "a", "linear", "operator", "is", "characteristic", "polynomial", "and",
                          "factorization", "vector", "space", "independent", "measures", "tidewater"]
        var lines: [[RecognisedPage.Token]] = []
        for row in 0..<40 {
            var x = 72.0
            var line: [RecognisedPage.Token] = []
            for _ in 0..<10 {
                let word = vocabulary[Int(generator.next() % UInt64(vocabulary.count))]
                let width = Double(word.count) * 5.37 + 0.123
                line.append(RecognisedPage.Token(text: word, bounds: CGRect(x: x, y: 720 - 16.25 * Double(row), width: width, height: 12.4)))
                x += width + 3.1
            }
            lines.append(line)
        }
        let page = RecognisedPage(pageIndex: 1_499, lines: lines)
        #expect(page.words.count == 400)
        let bytes = try JSONEncoder().encode(page).count
        #expect(bytes < 9_000, "a 400-word page took \(bytes) bytes")
        #expect(bytes * 1_500 < 13_500_000, "a 1,500-page book would take \(bytes * 1_500) bytes")
    }
}

// MARK: - Store

@Suite("Recognised-text store")
struct RecognisedTextStoreTests {
    @Test func inMemoryConformance() throws {
        try RepositoryConformance.verifyRecognisedTextStore(InMemoryRecognisedTextStore())
    }

    @Test func layout() {
        let id = UUID(uuidString: "6A1C0000-0000-4000-8000-000000000001")!
        #expect(BookStorageLayout.recognisedTextDirectory(bookID: id) == "Books/6A1C0000-0000-4000-8000-000000000001/text")
        #expect(BookStorageLayout.recognisedPagePath(bookID: id, pageIndex: 16) == "Books/6A1C0000-0000-4000-8000-000000000001/text/16.json")
        #expect(BookStorageLayout.recognitionStatePath(bookID: id) == "Books/6A1C0000-0000-4000-8000-000000000001/recognition.json")
        #expect(BookStorageLayout.pageIndex(fromRecognisedPageFileName: "16.json") == 16)
        for name in ["16.drawing", ".json", "x.json", "16.json.tmp", "-1.json", "1 6.json"] {
            #expect(BookStorageLayout.pageIndex(fromRecognisedPageFileName: name) == nil, "\(name)")
        }
        #expect(BookStorageLayout.pageIndex(fromPageInkFileName: "311.drawing") == 311)
    }

    @MainActor
    @Test func libraryStorePostsChangesAndRemovesWithTheBook() async throws {
        let store = LibraryStore.inMemory()
        let book = Book(title: "Scan", fingerprint: "fp-scan", fileName: "scan.pdf", pageCount: 30, fileSize: 1)
        try store.books.save(book)
        let origin = ChangeOrigin(label: "queue")
        var events: [StoreChangeEvent] = []
        let token = store.hub.observe { events.append($0) }
        defer { token.cancel() }

        let page = RecognisedPage(pageIndex: 16, lines: [[RecognisedPage.Token(text: "heron", bounds: CGRect(x: 114, y: 693, width: 28, height: 12))]])
        try await store.saveRecognisedPage(page, bookID: book.id, origin: origin)
        try await store.saveRecognitionState(.inProgress(RecognitionProgress(pagesDone: 1, totalPages: 30)), bookID: book.id, origin: origin)
        #expect(try await store.recognisedPage(bookID: book.id, pageIndex: 16) == page)
        #expect(try await store.recognisedPageIndices(bookID: book.id) == [16])
        #expect(try await store.recognitionState(bookID: book.id)?.progress?.pagesDone == 1)
        try await store.removeRecognisedText(bookID: book.id, origin: nil)
        try await store.saveRecognitionState(nil, bookID: book.id, origin: nil)
        #expect(events.map(\.change) == [.recognisedTextChanged(bookID: book.id, pageIndex: 16), .recognitionStateChanged(bookID: book.id),
                                         .recognisedTextChanged(bookID: book.id, pageIndex: nil), .recognitionStateChanged(bookID: book.id)])
        #expect(events.first?.isFrom(origin) == true)
        #expect(events.allSatisfy { !$0.change.affectsBackup && $0.change.bookID == book.id })
        #expect(events.map(\.change.pageIndex) == [16, nil, nil, nil])
        #expect(StoreChange.highlightsChanged(bookID: book.id, pageIndex: 1).affectsBackup)

        try await store.saveRecognisedPage(page, bookID: book.id, origin: nil)
        try await store.saveRecognitionState(.declined, bookID: book.id, origin: nil)
        try await store.deleteBook(id: book.id, origin: nil)
        #expect(try store.recognisedText.recognisedPageIndices(bookID: book.id).isEmpty)
        #expect(try store.recognisedText.recognitionState(bookID: book.id) == nil)
    }
}

// MARK: - Highlights on scanned pages

@Suite("Scanned-page highlights")
struct ScannedHighlightTests {
    static let outline = Outline(pdfEntries: [e("Chapter", 1, 0)], pageCount: 30)
    static func highlight(_ n: Int, page: Int = 16, text: String, source: HighlightTextSource?, y: Double = 693) -> Highlight {
        Highlight(id: uuid(n), bookID: bookA, pageIndex: page, rects: [CGRect(x: 72, y: y, width: 159, height: 12)],
                  color: .green, text: text, createdAt: fixedDate, textSource: source)
    }

    @Test func presentation() {
        #expect(Self.highlight(1, text: " The quiet\nheron ", source: nil).presentation == .text("The quiet heron"))
        #expect(Self.highlight(1, text: "typed", source: .textLayer).presentation == .text("typed"))
        #expect(Self.highlight(1, text: " The quiet\nheron ", source: .liveText).presentation == .crop(caption: "The quiet heron"))
        #expect(Self.highlight(1, text: " \n ", source: .liveText).presentation == .crop(caption: nil))
        #expect(HighlightPresentation.crop(caption: nil).caption == nil)
        #expect(Self.highlight(1, text: "x", source: .liveText).isOnScannedPage)
        #expect(!Self.highlight(1, text: "x", source: .textLayer).isOnScannedPage)
        #expect(!Self.highlight(1, text: "x", source: nil).isOnScannedPage)
    }

    @Test func countsAndBadgesLikeAnyHighlight() {
        let notebook = NotebookBuilder.build(outline: Self.outline, notes: [],
                                             highlights: [Self.highlight(1, text: "", source: .liveText),
                                                          Self.highlight(2, page: 3, text: "typed", source: nil)])
        #expect(notebook.totalCounts.highlights == 2)
        #expect(notebook.hasBadge(Self.outline.roots[0].anchor))
        #expect(notebook.sections[0].pages.flatMap(\.highlights).map(\.textSource) == [nil, .liveText])
    }

    @Test func markdownShowsACropWithACaption() {
        let highlights = [Self.highlight(1, text: "The quiet heron measures tidewater.", source: .liveText, y: 693),
                          Self.highlight(2, text: "", source: .liveText, y: 600),
                          Self.highlight(3, text: "A typed line", source: nil, y: 500)]
        let notebook = NotebookBuilder.build(outline: Self.outline, notes: [], highlights: highlights)

        // Text-only Markdown: the caption, or the placeholder, and the page number.
        let textOnly = MarkdownExporter.export(notebook, bookTitle: "Scanned")
        #expect(textOnly == """
        # Scanned

        ## Chapter

        **Page 17**

        > The quiet heron measures tidewater. (p. 17)

        > _Highlight on a scanned page_ (p. 17)

        > A typed line (p. 17)

        """)

        // With images (the ZIP): the hook is called once per scanned-page highlight, in order.
        var asked: [UUID] = []
        let zipped = MarkdownExporter.export(notebook, bookTitle: "Scanned", highlightImagePath: { highlight in
            asked.append(highlight.id)
            return "highlights/highlight \(asked.count).png"
        })
        #expect(asked == [uuid(1), uuid(2)])
        #expect(zipped == """
        # Scanned

        ## Chapter

        **Page 17**

        ![Highlight on page 17](<highlights/highlight 1.png>)

        > The quiet heron measures tidewater. (p. 17)

        ![Highlight on page 17](<highlights/highlight 2.png>)

        > _Highlight on a scanned page_ (p. 17)

        > A typed line (p. 17)

        """)
    }

    @Test func codingIsOptional() throws {
        let typed = Self.highlight(1, text: "typed", source: nil)
        let json = String(decoding: try JSONEncoder().encode(typed), as: UTF8.self)
        #expect(!json.contains("textSource"), "an unset source is not written")
        // A highlight written before the field existed still decodes, with no source.
        var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(object["textSource"] == nil)
        object["color"] = "pink"
        let old = try JSONDecoder().decode(Highlight.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.textSource == nil && old.color == .pink)
        let scanned = Self.highlight(2, text: "", source: .liveText)
        let data = try JSONEncoder().encode(scanned)
        #expect(String(decoding: data, as: UTF8.self).contains(#""textSource":"liveText""#))
        #expect(try JSONDecoder().decode(Highlight.self, from: data) == scanned)
    }
}
