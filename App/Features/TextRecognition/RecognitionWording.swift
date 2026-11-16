import Foundation
import ReaderCore

// The words the scanned-book notice (at import) and the search status use (S3; design,
// "Scanned books" ▸ "The notice" and "The choice can be revisited from search"). Kept here, as
// plain values, so unit tests check the content without a UI.

/// How long making a book searchable takes, from its page count alone.
nonisolated enum RecognitionEstimate {
    /// Seconds to make one page searchable.
    ///
    /// **A simulator figure: re-measure on an iPad and replace it.** Vision's accurate request
    /// took about 1.2 s a page in the iOS 27 simulator on an M1 Max host
    /// (`docs/SCANNED_BOOKS_FINDINGS.md`, question 9), and the queue adds a render and a 0.1 s
    /// pause per page (`TextRecognitionEngine.pauseBetweenPages`); S2 measured 1.2 to 1.4 s a
    /// page end to end. The upper end is used so the notice does not promise too little. An
    /// iPad's Neural Engine may be faster or slower (`docs/DEVICE_CHECKLIST.md`, "Scanned books").
    static let secondsPerPage: Double = 1.4

    /// The rounded duration the words give.
    enum Rounded: Hashable, Sendable {
        case lessThanAMinute
        case aboutAMinute
        /// About this many minutes (2 to 9, then multiples of 5 up to 55).
        case minutes(Int)
        case aboutAnHour
        /// About this many hours (2 or more).
        case hours(Int)
    }

    /// Seconds to make a book of `pageCount` pages searchable.
    static func seconds(pageCount: Int) -> Double {
        Double(max(0, pageCount)) * secondsPerPage
    }

    /// The estimate rounded the way people say durations: under a minute; about a minute; to
    /// the minute below 10 minutes; to 5 minutes below 55; about an hour below 90 minutes;
    /// then to the hour.
    static func rounded(pageCount: Int) -> Rounded {
        let seconds = seconds(pageCount: pageCount)
        guard seconds >= 60 else { return .lessThanAMinute }
        let minutes = Int((seconds / 60).rounded())
        if minutes <= 1 { return .aboutAMinute }
        if minutes < 10 { return .minutes(minutes) }
        let toFive = Int((Double(minutes) / 5).rounded()) * 5
        if toFive < 60 { return .minutes(toFive) }
        if minutes < 90 { return .aboutAnHour }
        return .hours(Int((Double(minutes) / 60).rounded()))
    }

    /// The estimate as one sentence ("Estimated time: about 35 minutes."). Every case is a
    /// whole sentence of its own, so translations never join fragments; the counts are always 2
    /// or more, so the English plurals are right without the catalog.
    static func sentence(pageCount: Int) -> String {
        switch rounded(pageCount: pageCount) {
        case .lessThanAMinute:
            String(localized: "Estimated time: less than a minute.",
                   comment: "Scanned book notice and search status: how long making it searchable takes.")
        case .aboutAMinute:
            String(localized: "Estimated time: about a minute.",
                   comment: "Scanned book notice and search status: how long making it searchable takes.")
        case .minutes(let minutes):
            String(localized: "Estimated time: about \(minutes) minutes.",
                   comment: "Scanned book notice and search status: how long making it searchable takes. The argument is a number of minutes, 2 or more.")
        case .aboutAnHour:
            String(localized: "Estimated time: about an hour.",
                   comment: "Scanned book notice and search status: how long making it searchable takes.")
        case .hours(let hours):
            String(localized: "Estimated time: about \(hours) hours.",
                   comment: "Scanned book notice and search status: how long making it searchable takes. The argument is a number of hours, 2 or more.")
        }
    }
}

/// One book a scanned-book notice is about.
nonisolated struct ScanNoticeBook: Hashable, Sendable {
    var id: UUID
    var title: String
    var pageCount: Int
}

/// The notice's words: a title and a message for a system alert, with the two choices.
nonisolated enum ScanNoticeText {
    /// "“Lecture Notes” Looks Scanned", or "3 Books Look Scanned".
    static func title(for books: [ScanNoticeBook]) -> String {
        if books.count == 1, let book = books.first {
            return String(localized: "“\(book.title)” Looks Scanned",
                          comment: "Alert title after importing one scanned book. The argument is the book's title.")
        }
        return String(localized: "\(books.count) Books Look Scanned",
                      comment: "Alert title after importing several scanned books at once. The argument is the number of books, 2 or more.")
    }

    /// The three things the design asks for (it looks scanned, it can't be searched as it is,
    /// making it searchable reads every page on the iPad, which takes time and battery), the
    /// estimate from the page count (all the books' pages together), and where the offer comes
    /// back.
    static func message(for books: [ScanNoticeBook]) -> String {
        let pages = books.reduce(0) { $0 + $1.pageCount }
        let explanation = books.count == 1
            ? String(localized: "Its pages are pictures of text, so it can't be searched as it is. Making it searchable means reading every page on this iPad, which takes time and battery.",
                     comment: "Alert message after importing one scanned book: what scanned means and what making it searchable costs.")
            : String(localized: "Their pages are pictures of text, so they can't be searched as they are. Making them searchable means reading every page on this iPad, which takes time and battery.",
                     comment: "Alert message after importing several scanned books: what scanned means and what making them searchable costs.")
        let later = String(localized: "You can also do this later from Search.",
                           comment: "Alert message after importing scanned books, last sentence: the offer comes back in the reader's search panel.")
        return [explanation, RecognitionEstimate.sentence(pageCount: pages), later].joined(separator: " ")
    }

    static var makeSearchable: String {
        String(localized: "Make Searchable",
               comment: "Scanned book notice and search status: button that starts reading the book's pages so it can be searched.")
    }

    static var notNow: String {
        String(localized: "Not Now",
               comment: "Scanned book notice and search status: button that leaves the book unsearchable for now.")
    }
}

/// What the search panel shows about a scanned book's recognition (nothing for a book with a
/// text layer, or once it is complete). Built from the window's `SearchModel.recognitionState`,
/// which every window keeps current from the store, so every window on the book agrees.
nonisolated struct RecognitionStatus: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Not decided or declined: the explanation and the two choices.
        case offer
        case inProgress
        case paused
    }

    enum Action: Hashable, Sendable {
        case makeSearchable, notNow, pause, resume
    }

    var kind: Kind
    /// The first line, in bold.
    var title: String
    /// The explanation (offer) or "12 of 30 pages" (in progress, paused).
    var detail: String
    /// Pages done out of the total (in progress, paused).
    var progress: RecognitionProgress?
    /// Why it is paused when Low Power Mode or heat paused it, and that it resumes by itself.
    var note: String?
    /// The buttons, the main one first.
    var actions: [Action]

    /// `nil` for no state (a book with a text layer) and for complete.
    static func make(state: RecognitionState?, pageCount: Int) -> RecognitionStatus? {
        switch state {
        case nil, .complete?:
            return nil
        case .notDecided?, .declined?:
            let explanation = String(localized: "Its pages are pictures of text, so search can't find words in them yet. Making it searchable means reading every page on this iPad, which takes time and battery.",
                                     comment: "Search panel, scanned book not yet searchable: explanation under the title.")
            let annotations = String(localized: "Your notes and highlights are searched as usual.",
                                     comment: "Search panel, scanned book not yet searchable: last sentence of the explanation.")
            return RecognitionStatus(
                kind: .offer,
                title: String(localized: "This book looks scanned",
                              comment: "Search panel, scanned book not yet searchable: title of the status at the top."),
                detail: [explanation, RecognitionEstimate.sentence(pageCount: pageCount), annotations].joined(separator: " "),
                progress: nil, note: nil, actions: [.makeSearchable, .notNow])
        case .inProgress(let progress)?:
            return RecognitionStatus(
                kind: .inProgress,
                title: String(localized: "Making this book searchable…",
                              comment: "Search panel, scanned book: title of the status while its pages are being read."),
                detail: pagesDone(progress), progress: progress, note: nil, actions: [.pause])
        case .paused(let progress, let reasons)?:
            let byReader = reasons.contains(.reader)
            return RecognitionStatus(
                kind: .paused,
                title: String(localized: "Making this book searchable is paused",
                              comment: "Search panel, scanned book: title of the status while reading its pages is paused."),
                detail: pagesDone(progress), progress: progress,
                note: pauseNote(reasons),
                // Resume only undoes the reader's own Pause: with Low Power Mode or heat alone it
                // would do nothing, and recognition resumes by itself.
                actions: byReader ? [.resume] : [])
        }
    }

    /// "12 of 30 pages".
    static func pagesDone(_ progress: RecognitionProgress) -> String {
        if progress.totalPages == 1 {
            return String(localized: "\(progress.pagesDone) of 1 page",
                          comment: "Search panel, scanned book of one page: pages made searchable so far (0 or 1).")
        }
        return String(localized: "\(progress.pagesDone) of \(progress.totalPages) pages",
                      comment: "Search panel, scanned book: pages made searchable so far out of the book's pages (the second number is 2 or more).")
    }

    /// Why the system paused it, or `nil` when only the reader did.
    static func pauseNote(_ reasons: Set<RecognitionPauseReason>) -> String? {
        let lowPower = reasons.contains(.lowPowerMode), thermal = reasons.contains(.thermal)
        guard lowPower || thermal else { return nil }
        if reasons.contains(.reader) {
            switch (lowPower, thermal) {
            case (true, true):
                return String(localized: "Low Power Mode is on and the iPad is hot, so after you resume it waits until both have cleared.",
                              comment: "Search panel, scanned book paused by the reader and by the system: what else holds it.")
            case (true, false):
                return String(localized: "Low Power Mode is on, so after you resume it waits until Low Power Mode is off.",
                              comment: "Search panel, scanned book paused by the reader and by Low Power Mode: what else holds it.")
            default:
                return String(localized: "The iPad is hot, so after you resume it waits until the iPad has cooled down.",
                              comment: "Search panel, scanned book paused by the reader and by heat: what else holds it.")
            }
        }
        switch (lowPower, thermal) {
        case (true, true):
            return String(localized: "Paused while Low Power Mode is on and the iPad is hot. It resumes by itself once both have cleared.",
                          comment: "Search panel, scanned book paused by the system: why, and that it resumes by itself.")
        case (true, false):
            return String(localized: "Paused while Low Power Mode is on. It resumes by itself when Low Power Mode is off.",
                          comment: "Search panel, scanned book paused by Low Power Mode: why, and that it resumes by itself.")
        default:
            return String(localized: "Paused while the iPad is hot. It resumes by itself when the iPad has cooled down.",
                          comment: "Search panel, scanned book paused by heat: why, and that it resumes by itself.")
        }
    }

    /// The quiet line under the search status while page search covers only the pages made
    /// searchable so far (`SearchModel.isPageSearchPartial`).
    static var partialResultsLine: String {
        String(localized: "Page results include only the pages made searchable so far.",
               comment: "Search panel, scanned book not fully searchable: line under the result count.")
    }
}
