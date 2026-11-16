import Foundation
import CoreGraphics

/// Executable contract checks for store implementations. ReaderStore calls these from its own tests
/// against the SwiftData repositories and the file-backed ink store; ReaderCore's tests run them
/// against the in-memory reference stores. Each check creates its own book with a fresh ID,
/// and removes everything it created, also when it fails.
public enum RepositoryConformance {
    /// A violated contract rule.
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    private static func expectError(_ expected: RepositoryError, _ label: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as RepositoryError {
            try check(error == expected, "\(label): expected \(expected), got \(error)")
            return
        }
        throw Failure(description: "\(label): expected \(expected), but no error was thrown")
    }

    /// Checks every rule of `verifyRecordStores` on one record store.
    @MainActor
    public static func verifyRecordStore(_ records: some RecordStore) throws {
        try verifyRecordStores(books: records, notes: records, highlights: records, bookmarks: records, headings: records)
    }

    /// Checks a record store, read under each of the five names `LibraryStore` gives it (pass
    /// the same store five times, or `store.books`, `store.notes`, … of a `LibraryStore`; see
    /// `verifyRecordStore(_:)`). Covers: book save/fetch/fingerprint, note upsert by target, the
    /// empty-note rule, one note per target, retarget, page-note range queries, highlight order
    /// and range queries, idempotent bookmarks, user headings, counts, and cascade delete.
    @MainActor
    public static func verifyRecordStores(books: some RecordStore, notes: some RecordStore,
                                          highlights: some RecordStore,
                                          bookmarks: some RecordStore,
                                          headings: some RecordStore) throws {
        let bookID = UUID()
        let fingerprint = "conformance-\(bookID.uuidString)"
        defer { try? books.deleteBook(id: bookID) }

        // Books
        let book = Book(id: bookID, title: "Conformance", fingerprint: fingerprint, fileName: "c.pdf",
                        pageCount: 100, fileSize: 1234, addedAt: Date(timeIntervalSince1970: 1_000))
        try books.save(book)
        try check(try books.book(id: bookID) == book, "book(id:) must return the saved book")
        try check(try books.book(fingerprint: fingerprint)?.id == bookID, "book(fingerprint:) must find the book")
        var renamed = book
        renamed.title = "Renamed"
        try books.save(renamed)
        try check(try books.book(id: bookID)?.title == "Renamed", "save(book) must replace by id")
        try check(try books.allBooks().filter { $0.id == bookID }.count == 1, "allBooks must hold the book once")

        // Notes: upsert by target, one per target, empty rule
        let created = Date(timeIntervalSince1970: 2_000)
        let page3 = Note(bookID: bookID, target: .page(3), text: "first", createdAt: created)
        try check(try notes.save(page3) == page3, "save(new note) must return the note")
        try check(try notes.note(bookID: bookID, target: .page(3)) == page3, "note(target:) must find the saved note")
        try check(try notes.note(id: page3.id) == page3, "note(id:) must find the saved note")
        var edited = page3
        edited.text = "second"
        try notes.save(edited)
        try check(try notes.note(bookID: bookID, target: .page(3))?.text == "second", "save must update in place")
        try check(try notes.noteCount(bookID: bookID) == 1, "updating must not add a note")
        try expectError(.noteTargetOccupied(existingNoteID: page3.id), "second note for one target") {
            try notes.save(Note(bookID: bookID, target: .page(3), text: "other"))
        }
        var moved = edited
        moved.target = .page(4)
        try expectError(.noteTargetMismatch(noteID: page3.id), "save under another target") {
            try notes.save(moved)
        }
        var emptied = edited
        emptied.text = " \n "
        try check(try notes.save(emptied) == nil, "saving an empty note must return nil")
        try check(try notes.note(bookID: bookID, target: .page(3)) == nil, "saving an empty note must delete it")
        try check(try notes.save(Note(bookID: bookID, target: .page(5), text: "")) == nil, "an empty new note must not be stored")
        try check(try notes.noteCount(bookID: bookID) == 0, "no empty notes may be stored")
        var inkOnly = Note(bookID: bookID, target: .page(6), text: "", hasInk: true)
        inkOnly.bandLayout = NoteBandLayout(pageWidth: 320, paragraphs: [NoteParagraphBand(text: "", top: 0, height: 20)], trailingTop: 20)
        try check(try notes.save(inkOnly) == inkOnly, "a note with ink and no text is not empty")
        try check(try notes.note(id: inkOnly.id)?.bandLayout == inkOnly.bandLayout, "bandLayout must round-trip")

        let anchor = HeadingAnchor(pdfPath: [0, 1], pageIndex: 10, title: "1.2 Something")
        let headingNote = Note(bookID: bookID, target: .heading(anchor), text: "section")
        try notes.save(headingNote)
        try notes.save(Note(bookID: bookID, target: .page(20), text: "twenty"))
        try notes.save(Note(bookID: bookID, target: .page(2), text: "two"))
        let inRange = try notes.pageNotes(bookID: bookID, in: 2...6)
        try check(inRange.compactMap(\.target.pageIndex) == [2, 6], "pageNotes(in:) must filter page notes and sort by page, got \(inRange.map(\.target))")
        try check(try notes.notes(bookID: bookID).count == 4, "notes(bookID:) must return page and heading notes")

        // Retarget
        let newAnchor = HeadingAnchor(pdfPath: [0, 2], pageIndex: 10, title: "1.2 Something")
        try notes.retarget(noteID: headingNote.id, to: .heading(newAnchor))
        try check(try notes.note(bookID: bookID, target: .heading(newAnchor))?.id == headingNote.id, "retarget must move the note")
        try check(try notes.note(bookID: bookID, target: .heading(anchor)) == nil, "retarget must free the old target")
        let pageTwo = try notes.note(bookID: bookID, target: .page(2))!
        try expectError(.noteTargetOccupied(existingNoteID: pageTwo.id), "retarget onto an occupied target") {
            try notes.retarget(noteID: headingNote.id, to: .page(2))
        }
        try expectError(.bookNotFound(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!), "note for unknown book") {
            try notes.save(Note(bookID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, target: .page(0), text: "x"))
        }
        try notes.deleteNote(id: pageTwo.id)
        try notes.deleteNote(id: pageTwo.id)
        try check(try notes.note(id: pageTwo.id) == nil, "deleteNote must delete, and be idempotent")

        // Highlights
        let low = Highlight(bookID: bookID, pageIndex: 7, rects: [CGRect(x: 50, y: 100, width: 100, height: 12)], color: .yellow, text: "low")
        let high = Highlight(bookID: bookID, pageIndex: 7, rects: [CGRect(x: 50, y: 600, width: 100, height: 12)], color: .green, text: "high")
        let other = Highlight(bookID: bookID, pageIndex: 9, rects: [CGRect(x: 0, y: 0, width: 10, height: 10)], color: .pink, text: "other")
        try highlights.save(low)
        try highlights.save(high)
        try highlights.save(other)
        try check(try highlights.highlight(id: high.id) == high, "highlight(id:) must find the saved highlight")
        try check(try highlights.highlight(id: UUID()) == nil, "highlight(id:) must return nil for an unknown id")
        try check(try highlights.highlights(bookID: bookID, pageIndex: 7).map(\.text) == ["high", "low"], "highlights must be in reading order (top first)")
        try check(try highlights.highlights(bookID: bookID, in: 8...9).map(\.id) == [other.id], "highlights(in:) must filter by page")
        var recoloured = low
        recoloured.color = .blue
        try highlights.save(recoloured)
        try check(try highlights.highlights(bookID: bookID).first { $0.id == low.id }?.color == .blue, "save(highlight) must replace by id")
        try highlights.deleteHighlight(id: other.id)
        try check(try highlights.highlightCount(bookID: bookID) == 2, "deleteHighlight must delete")

        // Bookmarks
        try bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 12)
        try bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 12)
        try bookmarks.setBookmarked(true, bookID: bookID, pageIndex: 1)
        try check(try bookmarks.bookmarks(bookID: bookID).map(\.pageIndex) == [1, 12], "bookmarks: one per page, sorted by page")
        try bookmarks.setBookmarked(false, bookID: bookID, pageIndex: 1)
        try check(try !bookmarks.isBookmarked(bookID: bookID, pageIndex: 1), "setBookmarked(false) must remove")
        try check(try bookmarks.isBookmarked(bookID: bookID, pageIndex: 12), "isBookmarked must report a bookmark")

        // User headings
        var heading = UserHeading(bookID: bookID, title: "Mine", pageIndex: 30, parent: anchor)
        try headings.save(heading)
        heading.title = "Mine, renamed"
        try headings.save(heading)
        try check(try headings.userHeadings(bookID: bookID) == [heading], "save(heading) must upsert by id")
        try check(try headings.userHeading(id: heading.id) == heading, "userHeading(id:) must find the heading")
        let doomed = UserHeading(bookID: bookID, title: "Doomed", pageIndex: 31, parent: nil)
        try headings.save(doomed)
        try headings.deleteUserHeading(id: doomed.id)
        try headings.deleteUserHeading(id: doomed.id)
        try check(try headings.userHeading(id: doomed.id) == nil, "deleteUserHeading must delete, and be idempotent")

        // Counts and cascade
        let counts = try books.recordCounts(bookID: bookID)
        try check(counts == BookRecordCounts(notes: 3, highlights: 2, bookmarks: 1, userHeadings: 1), "recordCounts wrong: \(counts)")
        try books.deleteBook(id: bookID)
        try check(try books.book(id: bookID) == nil, "deleteBook must delete the book")
        try check(try books.recordCounts(bookID: bookID) == BookRecordCounts(), "deleteBook must cascade to every record")
        try check(try notes.notes(bookID: bookID).isEmpty && headings.userHeadings(bookID: bookID).isEmpty
                  && highlights.highlights(bookID: bookID).isEmpty && bookmarks.bookmarks(bookID: bookID).isEmpty,
                  "deleteBook must leave no records behind")

        try verifyBookReplacement(books: books, notes: notes, highlights: highlights, bookmarks: bookmarks, headings: headings)
    }

    /// Checks `RecordStore.replaceBook(_:removing:)` (also run by `verifyRecordStores`):
    /// verbatim insert of a new book (every field, IDs and dates, and the lookups that depend on
    /// derived columns: note by target, page ranges, highlight order, bookmarked pages); replacing
    /// a book with the same ID, including reused record IDs, a freed note target and a freed
    /// bookmark page; removing other IDs (a book with the archive's fingerprint, an unknown ID);
    /// idempotence; every refusal leaving the store untouched; and other books never touched.
    @MainActor
    public static func verifyBookReplacement(books: some RecordStore, notes: some RecordStore,
                                             highlights: some RecordStore,
                                             bookmarks: some RecordStore,
                                             headings: some RecordStore) throws {
        let fresh = UUID(), target = UUID(), other = UUID(), extra = UUID(), successor = UUID()
        let all = [fresh, target, other, extra, successor]
        defer { for id in all { try? books.deleteBook(id: id) } }

        func normalized(_ archive: BookArchive) -> BookArchive {
            var a = archive
            a.notes.sort { $0.id.uuidString < $1.id.uuidString }
            a.highlights.sort(by: Highlight.readingOrder)
            a.bookmarks.sort { $0.pageIndex < $1.pageIndex }
            a.userHeadings.sort { $0.id.uuidString < $1.id.uuidString }
            return a
        }
        func stored(_ id: UUID) throws -> BookArchive? {
            guard let book = try books.book(id: id) else { return nil }
            return normalized(BookArchive(book: book, notes: try notes.notes(bookID: id),
                                          highlights: try highlights.highlights(bookID: id),
                                          bookmarks: try bookmarks.bookmarks(bookID: id),
                                          userHeadings: try headings.userHeadings(bookID: id)))
        }
        func state() throws -> [BookArchive?] { try all.map(stored) }
        func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_600_000_000 + seconds) }
        func book(_ id: UUID, _ title: String) -> Book {
            Book(id: id, title: title, fingerprint: "replace-\(id.uuidString)", fileName: "\(title).pdf", pageCount: 200,
                 fileSize: 4_321, addedAt: date(0.25), lastOpenedAt: date(9.5), lastReadPageIndex: 17)
        }
        /// Seeds a book through the ordinary save paths.
        func seed(_ id: UUID, _ title: String) throws -> BookArchive {
            try books.save(book(id, title))
            try notes.save(Note(bookID: id, target: .page(1), text: "\(title) p1", createdAt: date(1), modifiedAt: date(2)))
            try notes.save(Note(bookID: id, target: .page(2), text: "\(title) p2", createdAt: date(1), modifiedAt: date(2)))
            try highlights.save(Highlight(bookID: id, pageIndex: 3, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)],
                                          color: .green, text: title, createdAt: date(3)))
            try bookmarks.setBookmarked(true, bookID: id, pageIndex: 5)
            try bookmarks.setBookmarked(true, bookID: id, pageIndex: 6)
            try headings.save(UserHeading(bookID: id, title: title, pageIndex: 7, parent: nil, createdAt: date(4)))
            return try stored(id)!
        }

        let otherBefore = try seed(other, "Other")
        let targetBefore = try seed(target, "Target")
        let extraBefore = try seed(extra, "Extra")

        // 1. A new book, inserted verbatim.
        let anchor = HeadingAnchor(pdfPath: [0, 3], pageIndex: 12, title: "2.1 Restored")
        let layout = NoteBandLayout(pageWidth: 400.5, paragraphs: [NoteParagraphBand(text: "a", top: 0.5, height: 19.25)],
                                    trailingTop: 19.75)
        let parentHeading = UserHeading(bookID: fresh, title: "Parent", pageIndex: 20, parent: anchor, createdAt: date(5.125))
        let freshArchive = BookArchive(
            book: book(fresh, "Fresh"),
            notes: [Note(bookID: fresh, target: .page(9), text: "nine", hasInk: true, bandLayout: layout,
                         createdAt: date(6.5), modifiedAt: date(7.75)),
                    Note(bookID: fresh, target: .page(4), text: "", hasInk: true, createdAt: date(6), modifiedAt: date(6)),
                    Note(bookID: fresh, target: .heading(anchor), text: "section", createdAt: date(8), modifiedAt: date(8.5)),
                    Note(bookID: fresh, target: .heading(parentHeading.anchor), text: "mine", createdAt: date(8), modifiedAt: date(8))],
            highlights: [Highlight(bookID: fresh, pageIndex: 9, rects: [], color: .pink, text: "no rects", createdAt: date(1)),
                         Highlight(bookID: fresh, pageIndex: 9, rects: [CGRect(x: 10.5, y: 100.25, width: 50, height: 12)],
                                   color: .yellow, text: "low", createdAt: date(2)),
                         Highlight(bookID: fresh, pageIndex: 9, rects: [CGRect(x: 10.5, y: 600.75, width: 50, height: 12)],
                                   color: .blue, text: "high", createdAt: date(3)),
                         Highlight(bookID: fresh, pageIndex: 2, rects: [CGRect(x: 0, y: 0, width: 1, height: 1)],
                                   color: .green, text: "early", createdAt: date(4))],
            bookmarks: [Bookmark(bookID: fresh, pageIndex: 30, createdAt: date(10.5)),
                        Bookmark(bookID: fresh, pageIndex: 3, createdAt: date(11))],
            userHeadings: [parentHeading,
                           UserHeading(bookID: fresh, title: "Child", pageIndex: 21, parent: parentHeading.anchor, createdAt: date(12))])
        try books.replaceBook(freshArchive, removing: [])
        try check(try stored(fresh) == normalized(freshArchive), "replaceBook must insert the archive verbatim")
        try check(try books.book(fingerprint: freshArchive.book.fingerprint)?.id == fresh, "replaceBook: book(fingerprint:) must find the book")
        try check(try notes.note(bookID: fresh, target: .heading(anchor))?.text == "section", "replaceBook: note(bookID:target:) must find an inserted note")
        try check(try notes.pageNotes(bookID: fresh, in: 0...10).compactMap(\.target.pageIndex) == [4, 9], "replaceBook: pageNotes(in:) must see inserted notes")
        try check(try highlights.highlights(bookID: fresh, pageIndex: 9).map(\.text) == ["high", "low", "no rects"],
                  "replaceBook: inserted highlights must be in reading order")
        try check(try bookmarks.isBookmarked(bookID: fresh, pageIndex: 30) && !bookmarks.isBookmarked(bookID: fresh, pageIndex: 5),
                  "replaceBook: isBookmarked must see inserted bookmarks")
        try check(try books.recordCounts(bookID: fresh) == BookRecordCounts(notes: 4, highlights: 4, bookmarks: 2, userHeadings: 2),
                  "replaceBook: recordCounts wrong after insert")
        try check(try stored(other) == otherBefore && stored(target) == targetBefore && stored(extra) == extraBefore,
                  "replaceBook must not touch other books")

        // 2. Replacing a book with the same ID: reused IDs, a freed target, a freed bookmark page.
        let keptNote = targetBefore.notes.first { $0.target == .page(1) }!
        let droppedNote = targetBefore.notes.first { $0.target == .page(2) }!
        let keptBookmark = targetBefore.bookmarks.first { $0.pageIndex == 5 }!
        let droppedBookmark = targetBefore.bookmarks.first { $0.pageIndex == 6 }!
        var renamed = book(target, "Target restored")
        renamed.lastReadPageIndex = 99
        renamed.lastOpenedAt = nil
        var movedNote = keptNote
        movedNote.text = "kept, edited"
        movedNote.modifiedAt = date(50)
        var movedHighlight = targetBefore.highlights[0]
        movedHighlight.pageIndex = 40
        movedHighlight.color = .pink
        let replacement = BookArchive(
            book: renamed,
            notes: [movedNote, Note(bookID: target, target: .page(2), text: "new owner of page 2", createdAt: date(51), modifiedAt: date(52))],
            highlights: [movedHighlight],
            bookmarks: [Bookmark(id: keptBookmark.id, bookID: target, pageIndex: 8, createdAt: date(53)),
                        Bookmark(bookID: target, pageIndex: 6, createdAt: date(54))],
            userHeadings: [])
        try books.replaceBook(replacement, removing: [])
        try check(try stored(target) == normalized(replacement), "replaceBook must replace a book with the same ID verbatim")
        try check(try notes.note(id: droppedNote.id) == nil && bookmarks.bookmarks(bookID: target).allSatisfy { $0.id != droppedBookmark.id },
                  "replaceBook must delete the replaced book's records that are not in the archive")
        try check(try notes.note(bookID: target, target: .page(2))?.text == "new owner of page 2", "replaceBook must free and reuse a note target")
        try check(try highlights.highlights(bookID: target, pageIndex: 3).isEmpty && highlights.highlights(bookID: target, pageIndex: 40).count == 1,
                  "replaceBook must move a reused highlight's page")
        try books.replaceBook(replacement, removing: [])
        try check(try stored(target) == normalized(replacement), "replaceBook must be idempotent (same ID)")

        // 3. Removing another book: the successor takes the removed book's fingerprint and one of
        //    its record IDs; an unknown ID in `ids` is skipped.
        let inherited = extraBefore.notes.first { $0.target == .page(1) }!
        var successorBook = book(successor, "Successor")
        successorBook.fingerprint = extraBefore.book.fingerprint
        let successorArchive = BookArchive(
            book: successorBook,
            notes: [Note(id: inherited.id, bookID: successor, target: .page(1), text: "inherited", createdAt: date(60), modifiedAt: date(61))],
            highlights: [], bookmarks: [Bookmark(bookID: successor, pageIndex: 5, createdAt: date(62))], userHeadings: [])
        try books.replaceBook(successorArchive, removing: [extra, UUID()])
        let afterSuccession = try state()
        try check(try books.book(id: extra) == nil && books.recordCounts(bookID: extra) == BookRecordCounts(),
                  "replaceBook must delete each removed book and all its records")
        try check(try stored(successor) == normalized(successorArchive), "replaceBook must insert the successor verbatim")
        try check(try notes.note(id: inherited.id)?.bookID == successor, "replaceBook: a removed book's record ID may be reused")
        try check(try books.book(fingerprint: successorBook.fingerprint)?.id == successor, "replaceBook: the successor must own the fingerprint")
        try books.replaceBook(successorArchive, removing: [extra, UUID()])
        try check(try state() == afterSuccession, "replaceBook must be idempotent (with removals)")
        try check(try stored(other) == otherBefore && stored(fresh) == normalized(freshArchive), "replaceBook must not touch other books")

        // 4. Refusals change nothing.
        let before = try state()
        func refuses(_ expected: RepositoryError, _ label: String, _ archive: BookArchive, removing ids: Set<UUID> = []) throws {
            try expectError(expected, "replaceBook refuses \(label)") { try books.replaceBook(archive, removing: ids) }
            try check(try state() == before, "replaceBook refusing \(label) must leave the store untouched")
        }
        var base = replacement
        base.book.title = "Refused"

        var a = base
        let stray = Highlight(bookID: other, pageIndex: 1, rects: [], color: .blue, text: "stray")
        a.highlights.append(stray)
        try refuses(.archiveInconsistent(recordID: stray.id), "an inconsistent archive", a)

        a = base
        a.highlights.append(a.highlights[0])
        try refuses(.archiveDuplicateRecordID(movedHighlight.id), "a repeated record ID", a)

        a = base
        let twin = Note(bookID: target, target: movedNote.target, text: "twin")
        a.notes.append(twin)
        try refuses(.archiveDuplicateNoteTarget(noteID: twin.id), "two notes on one target", a)

        a = base
        a.bookmarks.append(Bookmark(bookID: target, pageIndex: 8))
        try refuses(.archiveDuplicateBookmarkPage(pageIndex: 8), "two bookmarks on one page", a)

        a = base
        let blank = Note(bookID: target, target: .page(77), text: " \n")
        a.notes.append(blank)
        try refuses(.archiveEmptyNote(noteID: blank.id), "an empty note", a)

        a = base
        a.book.fingerprint = otherBefore.book.fingerprint
        try refuses(.fingerprintInUse(existingBookID: other), "another book's fingerprint", a)
        var newcomer = book(UUID(), "Newcomer")
        newcomer.fingerprint = renamed.fingerprint
        try refuses(.fingerprintInUse(existingBookID: target), "a fingerprint held by a book not being removed",
                    BookArchive(book: newcomer))

        let foreignNote = otherBefore.notes[0], foreignHighlight = otherBefore.highlights[0]
        let foreignBookmark = otherBefore.bookmarks[0], foreignHeading = otherBefore.userHeadings[0]
        a = base
        a.notes.append(Note(id: foreignNote.id, bookID: target, target: .page(70), text: "stolen"))
        try refuses(.recordOwnedByOtherBook(recordID: foreignNote.id, bookID: other), "another book's note ID", a)
        a = base
        a.highlights.append(Highlight(id: foreignHighlight.id, bookID: target, pageIndex: 70, rects: [], color: .blue, text: "stolen"))
        try refuses(.recordOwnedByOtherBook(recordID: foreignHighlight.id, bookID: other), "another book's highlight ID", a)
        a = base
        a.bookmarks.append(Bookmark(id: foreignBookmark.id, bookID: target, pageIndex: 70))
        try refuses(.recordOwnedByOtherBook(recordID: foreignBookmark.id, bookID: other), "another book's bookmark ID", a)
        a = base
        a.userHeadings.append(UserHeading(id: foreignHeading.id, bookID: target, title: "stolen", pageIndex: 70, parent: nil))
        try refuses(.recordOwnedByOtherBook(recordID: foreignHeading.id, bookID: other), "another book's user heading ID", a)
        // The same IDs are fine once their book is being removed.
        try books.replaceBook(a, removing: [other])
        try check(try books.book(id: other) == nil && headings.userHeading(id: foreignHeading.id)?.bookID == target,
                  "replaceBook must allow the IDs of a book it removes")
    }

    /// Checks an ink store: round trips, replacement, idempotent deletes, the sorted inked-page
    /// list, note ink, and whole-book removal.
    public static func verifyInkStore(_ store: some InkStore) async throws {
        let bookID = UUID()
        let noteID = UUID()
        do {
            try check(try await store.pageInk(bookID: bookID, pageIndex: 0) == nil, "missing page ink must read as nil")
            try await store.savePageInk(Data([1, 2, 3]), bookID: bookID, pageIndex: 10)
            try await store.savePageInk(Data([4]), bookID: bookID, pageIndex: 2)
            try await store.savePageInk(Data([5, 6]), bookID: bookID, pageIndex: 10)
            try check(try await store.pageInk(bookID: bookID, pageIndex: 10) == Data([5, 6]), "savePageInk must replace")
            try check(try await store.inkedPageIndices(bookID: bookID) == [2, 10], "inkedPageIndices must be sorted")
            try await store.deletePageInk(bookID: bookID, pageIndex: 2)
            try await store.deletePageInk(bookID: bookID, pageIndex: 2)
            try check(try await store.inkedPageIndices(bookID: bookID) == [10], "deletePageInk must delete, idempotently")

            try check(try await store.noteInk(bookID: bookID, noteID: noteID) == nil, "missing note ink must read as nil")
            try await store.saveNoteInk(Data([9]), bookID: bookID, noteID: noteID)
            try check(try await store.noteInk(bookID: bookID, noteID: noteID) == Data([9]), "note ink must round-trip")
            try check(try await store.inkedPageIndices(bookID: bookID) == [10], "note ink must not count as page ink")
            try await store.deleteNoteInk(bookID: bookID, noteID: noteID)
            try await store.deleteNoteInk(bookID: bookID, noteID: noteID)
            try check(try await store.noteInk(bookID: bookID, noteID: noteID) == nil, "deleteNoteInk must delete, idempotently")

            try await store.saveNoteInk(Data([9]), bookID: bookID, noteID: noteID)
            try await store.removeBook(bookID: bookID)
            try check(try await store.inkedPageIndices(bookID: bookID).isEmpty, "removeBook must remove page ink")
            try check(try await store.noteInk(bookID: bookID, noteID: noteID) == nil, "removeBook must remove note ink")
            try await store.removeBook(bookID: bookID)
        } catch {
            try? await store.removeBook(bookID: bookID)
            throw error
        }
    }

    // MARK: What posts what

    /// Checks what every record write announces on `store.hub`, and with which origin: the
    /// table on `LibraryStore` ("What posts what"), write by write, including the writes that
    /// must announce nothing (no-ops and writes that throw). A changed or missing post would
    /// leave other windows showing stale data with nothing else failing, so every store
    /// implementation is run through this behind a `LibraryStore`.
    ///
    /// Creates two books with fresh IDs and removes everything it created, also when it fails.
    @MainActor
    public static func verifyChangePosting(_ store: LibraryStore) async throws {
        let first = UUID(), second = UUID()
        let window = ChangeOrigin(label: "conformance window")
        var received: [StoreChangeEvent] = []
        let observation = store.hub.observe { event in
            if event.change.bookID == first || event.change.bookID == second { received.append(event) }
        }
        defer {
            observation.cancel()
            try? store.books.deleteBook(id: first)
            try? store.books.deleteBook(id: second)
        }

        /// Runs `write` and checks that exactly `expected` was posted, in order, with `origin`.
        func expect(_ label: String, _ expected: [StoreChange], origin: ChangeOrigin?, _ write: () throws -> Void) throws {
            received.removeAll()
            try store.perform(as: origin) { try write() }
            try check(received.map(\.change) == expected,
                      "\(label): expected \(expected), posted \(received.map(\.change))")
            try check(received.allSatisfy { $0.origin == origin },
                      "\(label): every post must carry the origin of the perform it was made in")
        }
        /// Runs a write that must throw and checks that nothing was posted.
        func expectRefused(_ label: String, _ write: () throws -> Void) throws {
            received.removeAll()
            var threw = false
            do { try store.perform(as: window) { try write() } } catch { threw = true }
            try check(threw, "\(label): the write must throw")
            try check(received.isEmpty, "\(label): a write that throws must post nothing, posted \(received.map(\.change))")
        }

        // Books
        let book = Book(id: first, title: "Posting", fingerprint: "posting-\(first.uuidString)", fileName: "p.pdf",
                        pageCount: 50, fileSize: 1)
        let other = Book(id: second, title: "Other", fingerprint: "posting-\(second.uuidString)", fileName: "o.pdf",
                         pageCount: 50, fileSize: 1)
        try expect("insert a book", [.bookSaved(bookID: first)], origin: window) { try store.books.save(book) }
        var renamed = book
        renamed.title = "Renamed"
        try expect("save a book again, unattributed", [.bookSaved(bookID: first)], origin: nil) { try store.books.save(renamed) }
        try expect("insert a second book", [.bookSaved(bookID: second)], origin: window) { try store.books.save(other) }

        // Notes
        let note = Note(bookID: first, target: .page(3), text: "first")
        try expect("insert a note", [.noteSaved(bookID: first, target: .page(3), noteID: note.id)], origin: window) {
            _ = try store.notes.save(note)
        }
        var edited = note
        edited.text = "second"
        try expect("edit a note, unattributed", [.noteSaved(bookID: first, target: .page(3), noteID: note.id)], origin: nil) {
            _ = try store.notes.save(edited)
        }
        try expectRefused("a second note for an occupied target") {
            _ = try store.notes.save(Note(bookID: first, target: .page(3), text: "other"))
        }
        try expectRefused("a note for an unknown book") {
            _ = try store.notes.save(Note(bookID: UUID(), target: .page(3), text: "x"))
        }
        try expect("retarget a note",
                   [.noteRemoved(bookID: first, target: .page(3), noteID: note.id),
                    .noteSaved(bookID: first, target: .page(4), noteID: note.id)], origin: window) {
            try store.notes.retarget(noteID: note.id, to: .page(4))
        }
        try expect("retarget a note to where it is", [], origin: window) {
            try store.notes.retarget(noteID: note.id, to: .page(4))
        }
        try expectRefused("retarget an unknown note") { try store.notes.retarget(noteID: UUID(), to: .page(9)) }
        var emptied = edited
        emptied.target = .page(4)
        emptied.text = " \n "
        try expect("save a note empty", [.noteRemoved(bookID: first, target: .page(4), noteID: note.id)], origin: window) {
            _ = try store.notes.save(emptied)
        }
        try expect("save an empty note where there is none", [], origin: window) { _ = try store.notes.save(emptied) }
        try expect("insert the note again", [.noteSaved(bookID: first, target: .page(3), noteID: note.id)], origin: window) {
            _ = try store.notes.save(note)
        }
        try expect("delete a note", [.noteRemoved(bookID: first, target: .page(3), noteID: note.id)], origin: window) {
            try store.notes.deleteNote(id: note.id)
        }
        try expect("delete an unknown note", [], origin: window) { try store.notes.deleteNote(id: note.id) }

        // Highlights
        var highlight = Highlight(bookID: first, pageIndex: 4, rects: [CGRect(x: 0, y: 0, width: 1, height: 1)],
                                  color: .yellow, text: "h")
        try expect("insert a highlight", [.highlightsChanged(bookID: first, pageIndex: 4)], origin: window) {
            try store.highlights.save(highlight)
        }
        highlight.color = .blue
        try expect("recolour a highlight, unattributed", [.highlightsChanged(bookID: first, pageIndex: 4)], origin: nil) {
            try store.highlights.save(highlight)
        }
        highlight.pageIndex = 6
        try expect("move a highlight to another page",
                   [.highlightsChanged(bookID: first, pageIndex: 4), .highlightsChanged(bookID: first, pageIndex: 6)],
                   origin: window) { try store.highlights.save(highlight) }
        highlight.bookID = second
        try expect("move a highlight to another book",
                   [.highlightsChanged(bookID: first, pageIndex: 6), .highlightsChanged(bookID: second, pageIndex: 6)],
                   origin: window) { try store.highlights.save(highlight) }
        try expectRefused("a highlight for an unknown book") {
            try store.highlights.save(Highlight(bookID: UUID(), pageIndex: 1, rects: [], color: .green, text: "x"))
        }
        try expect("delete a highlight", [.highlightsChanged(bookID: second, pageIndex: 6)], origin: window) {
            try store.highlights.deleteHighlight(id: highlight.id)
        }
        try expect("delete an unknown highlight", [], origin: window) { try store.highlights.deleteHighlight(id: highlight.id) }

        // Bookmarks
        try expect("bookmark a page", [.bookmarksChanged(bookID: first, pageIndex: 2)], origin: window) {
            try store.bookmarks.setBookmarked(true, bookID: first, pageIndex: 2)
        }
        try expect("bookmark a bookmarked page", [], origin: window) {
            try store.bookmarks.setBookmarked(true, bookID: first, pageIndex: 2)
        }
        try expectRefused("bookmark a page of an unknown book") {
            try store.bookmarks.setBookmarked(true, bookID: UUID(), pageIndex: 2)
        }
        try expect("remove a bookmark, unattributed", [.bookmarksChanged(bookID: first, pageIndex: 2)], origin: nil) {
            try store.bookmarks.setBookmarked(false, bookID: first, pageIndex: 2)
        }
        try expect("remove a bookmark that is not there", [], origin: window) {
            try store.bookmarks.setBookmarked(false, bookID: first, pageIndex: 2)
        }

        // User headings
        var heading = UserHeading(bookID: first, title: "Mine", pageIndex: 7, parent: nil)
        try expect("insert a heading", [.userHeadingsChanged(bookID: first)], origin: window) { try store.headings.save(heading) }
        heading.title = "Renamed"
        try expect("rename a heading, unattributed", [.userHeadingsChanged(bookID: first)], origin: nil) {
            try store.headings.save(heading)
        }
        heading.bookID = second
        try expect("move a heading to another book",
                   [.userHeadingsChanged(bookID: first), .userHeadingsChanged(bookID: second)], origin: window) {
            try store.headings.save(heading)
        }
        try expectRefused("a heading for an unknown book") {
            try store.headings.save(UserHeading(bookID: UUID(), title: "x", pageIndex: 1, parent: nil))
        }
        try expect("delete a heading", [.userHeadingsChanged(bookID: second)], origin: window) {
            try store.headings.deleteUserHeading(id: heading.id)
        }
        try expect("delete an unknown heading", [], origin: window) { try store.headings.deleteUserHeading(id: heading.id) }

        // Whole books
        _ = try store.notes.save(Note(bookID: first, target: .page(1), text: "kept until the book goes"))
        try store.highlights.save(Highlight(bookID: first, pageIndex: 1, rects: [], color: .green, text: "h"))
        let archive = BookArchive(book: renamed, notes: [Note(bookID: first, target: .page(2), text: "restored")],
                                  highlights: [], bookmarks: [], userHeadings: [])
        let bothAscending = [first, second].sorted { $0.uuidString < $1.uuidString }
        try expect("replace a book, removing another",
                   bothAscending.map { .bookDeleted(bookID: $0) } + [.bookSaved(bookID: first)], origin: window) {
            try store.books.replaceBook(archive, removing: [second, UUID()])
        }
        try expect("replace a book again", [.bookDeleted(bookID: first), .bookSaved(bookID: first)], origin: nil) {
            try store.books.replaceBook(archive, removing: [second])
        }
        var inconsistent = archive
        inconsistent.notes = [Note(bookID: second, target: .page(2), text: "of another book")]
        try expectRefused("replace a book with an inconsistent archive") {
            try store.books.replaceBook(inconsistent, removing: [])
        }
        try expect("delete a book with records: one post, none for the records", [.bookDeleted(bookID: first)], origin: window) {
            try store.books.deleteBook(id: first)
        }
        try expect("delete an unknown book", [], origin: window) { try store.books.deleteBook(id: first) }

        // The compound operations.
        try store.books.save(book)
        let inked = Note(bookID: first, target: .page(5), text: "with ink", hasInk: true)
        _ = try store.notes.save(inked)
        received.removeAll()
        try await store.deleteNote(id: inked.id, origin: window)
        try check(received == [StoreChangeEvent(change: .noteRemoved(bookID: first, target: .page(5), noteID: inked.id), origin: window),
                               StoreChangeEvent(change: .noteInkChanged(bookID: first, noteID: inked.id), origin: window)],
                  "deleteNote(id:origin:) must post noteRemoved then noteInkChanged for a note with ink, posted \(received)")
        received.removeAll()
        try await store.deleteBook(id: first, origin: window)
        try check(received == [StoreChangeEvent(change: .bookDeleted(bookID: first), origin: window)],
                  "deleteBook(id:origin:) must post bookDeleted once, posted \(received)")
    }
}
