import Foundation
import ReaderCore
import ReaderStore
import Testing
@testable import TactileTexts

/// The scanned-book notice (S3): the estimate's wording, the notice's content for one book and
/// for several, the queue (addressing, the check before showing, waiting for the answer) and the
/// state after each choice.
@Suite(.serialized)
@MainActor
struct TextRecognitionNoticeTests {
    typealias Support = TextRecognitionTestSupport

    // MARK: Estimate

    @Test func theEstimateIsRoundedTheWayPeopleSayIt() {
        func sentence(_ pages: Int) -> String { RecognitionEstimate.sentence(pageCount: pages) }
        #expect(RecognitionEstimate.secondsPerPage == 1.4)
        #expect(sentence(0) == "Estimated time: less than a minute.")
        #expect(sentence(30) == "Estimated time: less than a minute.")       // 42 s
        #expect(sentence(43) == "Estimated time: about a minute.")           // 60 s
        #expect(sentence(100) == "Estimated time: about 2 minutes.")         // 140 s
        #expect(sentence(300) == "Estimated time: about 7 minutes.")         // 7 min
        #expect(sentence(420) == "Estimated time: about 10 minutes.")        // 9.8 min
        #expect(sentence(1000) == "Estimated time: about 25 minutes.")       // 23.3 min
        #expect(sentence(1500) == "Estimated time: about 35 minutes.")       // 35 min
        #expect(sentence(2400) == "Estimated time: about 55 minutes.")       // 56 min
        #expect(sentence(2500) == "Estimated time: about an hour.")          // 58.3 min
        #expect(sentence(3500) == "Estimated time: about an hour.")          // 81.7 min
        #expect(sentence(4000) == "Estimated time: about 2 hours.")          // 93.3 min
        #expect(sentence(10000) == "Estimated time: about 4 hours.")         // 3.9 h
        #expect(RecognitionEstimate.rounded(pageCount: -5) == .lessThanAMinute)
    }

    // MARK: Content

    @Test func theNoticeForOneBookNamesIt() {
        let books = [ScanNoticeBook(id: UUID(), title: "Lecture Notes", pageCount: 1500)]
        #expect(ScanNoticeText.title(for: books) == "“Lecture Notes” Looks Scanned")
        #expect(ScanNoticeText.message(for: books) == "Its pages are pictures of text, so it can't be searched as it is. "
            + "Making it searchable means reading every page on this iPad, which takes time and battery. "
            + "Estimated time: about 35 minutes. You can also do this later from Search.")
        #expect(ScanNoticeText.makeSearchable == "Make Searchable")
        #expect(ScanNoticeText.notNow == "Not Now")
    }

    @Test func theNoticeForSeveralBooksCountsThemAndAddsTheirPages() {
        let books = [ScanNoticeBook(id: UUID(), title: "A", pageCount: 30),
                     ScanNoticeBook(id: UUID(), title: "B", pageCount: 400),
                     ScanNoticeBook(id: UUID(), title: "C", pageCount: 2100)]
        #expect(ScanNoticeText.title(for: books) == "3 Books Look Scanned")
        #expect(ScanNoticeText.message(for: books) == "Their pages are pictures of text, so they can't be searched as they are. "
            + "Making them searchable means reading every page on this iPad, which takes time and battery. "
            + "Estimated time: about an hour. You can also do this later from Search.")  // 2,530 pages: 59 min
    }

    // MARK: Queue

    @Test func noticesAreAddressedAndFoundPerWindowAndBook() {
        let queue = ScanNoticeQueue()
        let first = NSObject(), second = NSObject()
        let book = ScanNoticeBook(id: UUID(), title: "x", pageCount: 3)
        #expect(queue.post([], windowKey: nil) == nil, "no books, no notice")
        let unaddressed = queue.post([book], windowKey: nil)
        let addressed = queue.post([ScanNoticeBook(id: UUID(), title: "y", pageCount: 3)], windowKey: ObjectIdentifier(second))
        #expect(queue.notice(for: ObjectIdentifier(first)) == nil)
        #expect(queue.notice(for: ObjectIdentifier(second))?.id == addressed)
        #expect(queue.notice(about: book.id)?.id == unaddressed)
        queue.addressUnaddressed(to: ObjectIdentifier(first))
        #expect(queue.notice(for: ObjectIdentifier(first))?.id == unaddressed)
        #expect(queue.notice(for: ObjectIdentifier(second))?.id == addressed, "an addressed notice keeps its window")
    }

    /// Before showing, books decided meanwhile or deleted drop out; a notice left empty goes.
    @Test func theCheckDropsBooksNoLongerNotDecided() async throws {
        let fixture = try Support.scannedFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let other = Book(title: "Other", fingerprint: "test-\(UUID())", fileName: "o.pdf", pageCount: 10, fileSize: 1)
        try store.books.save(other)
        try await store.saveRecognitionState(.notDecided, bookID: fixture.book.id, origin: nil)
        try await store.saveRecognitionState(.inProgress(RecognitionProgress(pagesDone: 0, totalPages: 10)), bookID: other.id, origin: nil)
        let queue = ScanNoticeQueue()
        let gone = UUID()
        let id = try #require(queue.post([ScanNoticeBook(id: fixture.book.id, title: "old title", pageCount: 30),
                                          ScanNoticeBook(id: other.id, title: "Other", pageCount: 10),
                                          ScanNoticeBook(id: gone, title: "Deleted", pageCount: 5)], windowKey: nil))
        #expect(queue.notices.first?.isChecked == false)
        await queue.check(id, store: store)
        let notice = try #require(queue.notices.first)
        #expect(notice.isChecked)
        #expect(notice.books == [ScanNoticeBook(id: fixture.book.id, title: "scanned.pdf", pageCount: 30)])
        #expect(notice.title == "“scanned.pdf” Looks Scanned")

        try await store.saveRecognitionState(.declined, bookID: fixture.book.id, origin: nil)
        let waiting = Task { await queue.waitUntilAnswered(id) }
        await queue.check(id, store: store)
        #expect(queue.notices.isEmpty)
        await waiting.value  // the dropped notice releases its waiters
    }

    /// A notice whose window closed is dropped unanswered: whoever waits for the answer ("Open
    /// in") goes on, and the notice is not left for a window that is gone.
    @Test func droppingANoticeReleasesItsWaiters() async throws {
        let queue = ScanNoticeQueue()
        let id = try #require(queue.post([ScanNoticeBook(id: UUID(), title: "Scan", pageCount: 30)], windowKey: nil))
        let waiting = Task { await queue.waitUntilAnswered(id) }
        await Task.yield()
        queue.drop(id)
        #expect(queue.notices.isEmpty)
        await waiting.value
        queue.drop(id)  // dropping it again does nothing
        await queue.waitUntilAnswered(id)  // nothing queued: returns at once
    }

    @Test func makeSearchableAcceptsEveryBookAndNotNowDeclines() async throws {
        let fixture = try Support.scannedFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let second = Book(title: "Second", fingerprint: "test-\(UUID())", fileName: "s.pdf", pageCount: 12, fileSize: 1)
        try store.books.save(second)
        for id in [fixture.book.id, second.id] { try await store.saveRecognitionState(.notDecided, bookID: id, origin: nil) }
        // The engine is not started: accepted books wait in progress, nothing is recognised.
        let engine = Support.makeEngine(store)
        let queue = ScanNoticeQueue()
        let books = [ScanNoticeBook(id: fixture.book.id, title: "a", pageCount: 30),
                     ScanNoticeBook(id: second.id, title: "b", pageCount: 12)]

        let accepted = try #require(queue.post(books, windowKey: nil))
        let waiter = Task { await queue.waitUntilAnswered(accepted) }
        let work = queue.answer(accepted, makeSearchable: true, recognition: engine)
        #expect(queue.notices.isEmpty, "the notice leaves the queue at once, so its alert does not come back")
        await work?.value
        await waiter.value
        #expect(await Support.state(store, fixture.book.id) == .inProgress(RecognitionProgress(pagesDone: 0, totalPages: 30)))
        #expect(await Support.state(store, second.id) == .inProgress(RecognitionProgress(pagesDone: 0, totalPages: 12)))
        #expect(await Support.recognisedIndices(store, fixture.book.id).isEmpty, "nothing is recognised by the answer itself")
        #expect(queue.answer(accepted, makeSearchable: false, recognition: engine) == nil, "answered once")

        let third = Book(title: "Third", fingerprint: "test-\(UUID())", fileName: "t.pdf", pageCount: 8, fileSize: 1)
        try store.books.save(third)
        try await store.saveRecognitionState(.notDecided, bookID: third.id, origin: nil)
        let declined = try #require(queue.post([ScanNoticeBook(id: third.id, title: "c", pageCount: 8)], windowKey: nil))
        await queue.answer(declined, makeSearchable: false, recognition: engine)?.value
        #expect(await Support.state(store, third.id) == .declined)
        #expect(queue.notices.isEmpty)
        await engine.shutDown()
    }
}

/// The search panel's status model (S3) for every recognition state.
@MainActor
struct TextRecognitionStatusTests {
    private func progress(_ done: Int, _ total: Int) -> RecognitionProgress {
        RecognitionProgress(pagesDone: done, totalPages: total)
    }

    @Test func noStatusForATextBookOrACompleteOne() {
        #expect(RecognitionStatus.make(state: nil, pageCount: 30) == nil)
        #expect(RecognitionStatus.make(state: .complete, pageCount: 30) == nil)
    }

    @Test(arguments: [RecognitionState.notDecided, .declined])
    func notDecidedAndDeclinedMakeTheOffer(_ state: RecognitionState) throws {
        let status = try #require(RecognitionStatus.make(state: state, pageCount: 1500))
        #expect(status.kind == .offer)
        #expect(status.title == "This book looks scanned")
        #expect(status.detail == "Its pages are pictures of text, so search can't find words in them yet. "
            + "Making it searchable means reading every page on this iPad, which takes time and battery. "
            + "Estimated time: about 35 minutes. Your notes and highlights are searched as usual.")
        #expect(status.actions == [.makeSearchable, .notNow])
        #expect(status.progress == nil && status.note == nil)
    }

    @Test func inProgressShowsPagesDoneAndPause() throws {
        let status = try #require(RecognitionStatus.make(state: .inProgress(progress(12, 30)), pageCount: 30))
        #expect(status.kind == .inProgress)
        #expect(status.title == "Making this book searchable…")
        #expect(status.detail == "12 of 30 pages")
        #expect(status.progress == progress(12, 30))
        #expect(status.actions == [.pause])
        #expect(status.note == nil)
        let single = try #require(RecognitionStatus.make(state: .inProgress(progress(0, 1)), pageCount: 1))
        #expect(single.detail == "0 of 1 page")
    }

    @Test func pausedByTheReaderOffersResume() throws {
        let status = try #require(RecognitionStatus.make(state: .paused(progress(5, 30), reasons: [.reader]), pageCount: 30))
        #expect(status.kind == .paused)
        #expect(status.title == "Making this book searchable is paused")
        #expect(status.detail == "5 of 30 pages")
        #expect(status.actions == [.resume])
        #expect(status.note == nil)
    }

    @Test func pausedByTheSystemSaysWhyAndThatItResumesByItself() throws {
        func status(_ reasons: Set<RecognitionPauseReason>) throws -> RecognitionStatus {
            try #require(RecognitionStatus.make(state: .paused(progress(5, 30), reasons: reasons), pageCount: 30))
        }
        let lowPower = try status([.lowPowerMode])
        #expect(lowPower.actions.isEmpty, "Resume would do nothing")
        #expect(lowPower.note == "Paused while Low Power Mode is on. It resumes by itself when Low Power Mode is off.")
        #expect(try status([.thermal]).note == "Paused while the iPad is hot. It resumes by itself when the iPad has cooled down.")
        #expect(try status([.lowPowerMode, .thermal]).note
            == "Paused while Low Power Mode is on and the iPad is hot. It resumes by itself once both have cleared.")
        let both = try status([.reader, .lowPowerMode])
        #expect(both.actions == [.resume])
        #expect(both.note == "Low Power Mode is on, so after you resume it waits until Low Power Mode is off.")
        #expect(try status([.reader, .thermal]).note == "The iPad is hot, so after you resume it waits until the iPad has cooled down.")
        #expect(try status([.reader, .thermal, .lowPowerMode]).note
            == "Low Power Mode is on and the iPad is hot, so after you resume it waits until both have cleared.")
    }

    @Test func thePartialLine() {
        #expect(RecognitionStatus.partialResultsLine == "Page results include only the pages made searchable so far.")
    }
}
