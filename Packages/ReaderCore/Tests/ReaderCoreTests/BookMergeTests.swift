import Foundation
import CoreGraphics
import Testing
@testable import ReaderCore

private let localBookID = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
private let backupBookID = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!

private func at(_ seconds: Double) -> Date { fixedDate.addingTimeInterval(seconds) }

private func makeBook(_ id: UUID, title: String = "Linear Algebra") -> Book {
    Book(id: id, title: title, fingerprint: "fp", fileName: "book.pdf", pageCount: 400, fileSize: 1_000,
         addedAt: at(0), lastOpenedAt: at(50), lastReadPageIndex: 12)
}

private func heading(_ n: Int, _ title: String, page: Int, parent: HeadingAnchor? = nil,
                     book: UUID = localBookID, created: Double = 1) -> UserHeading {
    UserHeading(id: uuid(n), bookID: book, title: title, pageIndex: page, parent: parent, createdAt: at(created))
}

private func note(_ n: Int, _ target: NoteTarget, _ text: String, book: UUID = localBookID, ink: Bool = false,
                  created: Double = 1, modified: Double = 2) -> Note {
    Note(id: uuid(n), bookID: book, target: target, text: text, hasInk: ink,
         bandLayout: ink ? NoteBandLayout(pageWidth: 320, paragraphs: [], trailingTop: 8) : nil,
         createdAt: at(created), modifiedAt: at(modified))
}

private func highlight(_ n: Int, page: Int, text: String = "eigenvalue", rects: [CGRect] = [CGRect(x: 72, y: 600, width: 200, height: 12)],
                       color: HighlightColor = .yellow, book: UUID = localBookID) -> Highlight {
    Highlight(id: uuid(n), bookID: book, pageIndex: page, rects: rects, color: color, text: text, createdAt: at(3))
}

private func bookmark(_ n: Int, page: Int, book: UUID = localBookID, created: Double = 4) -> Bookmark {
    Bookmark(id: uuid(n), bookID: book, pageIndex: page, createdAt: at(created))
}

private func user(_ n: Int) -> HeadingAnchor { HeadingAnchor(userHeadingID: uuid(n)) }
private let pdfChapter = HeadingAnchor(pdfPath: [4], pageIndex: 300, title: "5 Eigenvalues")

private func local(_ notes: [Note] = [], _ highlights: [Highlight] = [], _ bookmarks: [Bookmark] = [],
                   _ headings: [UserHeading] = []) -> BookArchive {
    BookArchive(book: makeBook(localBookID), notes: notes, highlights: highlights, bookmarks: bookmarks, userHeadings: headings)
}

private func backup(_ notes: [Note] = [], _ highlights: [Highlight] = [], _ bookmarks: [Bookmark] = [],
                    _ headings: [UserHeading] = []) -> BookArchive {
    BookArchive(book: makeBook(backupBookID, title: "Backup title"), notes: notes, highlights: highlights,
                bookmarks: bookmarks, userHeadings: headings)
}

@Suite("BookMerge")
struct BookMergeTests {
    // MARK: Book and re-keying

    @Test func keepsTheLocalBookAndRekeysIncomingRecords() throws {
        let mine = local([note(1, .page(1), "Mine")])
        let theirs = backup([note(2, .page(2), "Theirs", book: backupBookID)],
                            [highlight(3, page: 2, book: backupBookID)],
                            [bookmark(4, page: 2, book: backupBookID)],
                            [heading(5, "Interlude", page: 30, book: backupBookID)])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        #expect(result.archive.book == mine.book)
        #expect(result.archive.isConsistent)
        try result.archive.validateForReplacement()
        #expect(result.archive.notes.map(\.id) == [uuid(1), uuid(2)])
        #expect(result.archive.highlights.map(\.id) == [uuid(3)])
        #expect(result.archive.bookmarks.map(\.id) == [uuid(4)])
        #expect(result.archive.userHeadings.map(\.id) == [uuid(5)])
        #expect(result.report.notesAdded == 1 && result.report.highlightsAdded == 1)
        #expect(result.report.bookmarksAdded == 1 && result.report.headingsAdded == 1)
    }

    // MARK: Headings

    @Test func headingWithTheSameIDKeepsTheLocalFields() {
        let mine = local([], [], [], [heading(1, "Local name", page: 10)])
        let theirs = backup([], [], [], [heading(1, "Renamed in backup", page: 11, parent: pdfChapter, book: backupBookID)])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        #expect(result.archive.userHeadings == mine.userHeadings)
        #expect(result.headingIDRemap.isEmpty)
        #expect(result.report.headingsMatched == 1 && result.report.headingsAdded == 0)
    }

    @Test func headingWithTheSameNormalisedTitlePageAndParentIsTheLocalOne() {
        let mine = local([], [], [], [heading(1, "The  Interlude", page: 10, parent: pdfChapter)])
        let theirs = backup([], [], [], [heading(2, " The Interlude\n", page: 10, parent: pdfChapter, book: backupBookID)])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        #expect(result.archive.userHeadings == mine.userHeadings)
        #expect(result.headingIDRemap == [uuid(2): uuid(1)])
        #expect(result.report.headingsMatched == 1)
    }

    @Test func headingOnAnotherPageOrUnderAnotherParentIsAdded() {
        let otherChapter = HeadingAnchor(pdfPath: [5], pageIndex: 350, title: "6 Orthogonality")
        let mine = local([], [], [], [heading(1, "Interlude", page: 10, parent: pdfChapter)])
        let theirs = backup([], [], [], [
            heading(2, "Interlude", page: 11, parent: pdfChapter, book: backupBookID),
            heading(3, "Interlude", page: 10, parent: otherChapter, book: backupBookID),
            heading(4, "Interlude", page: 10, parent: nil, book: backupBookID),
            heading(5, "Interludes", page: 10, parent: pdfChapter, book: backupBookID),
        ])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        #expect(Set(result.archive.userHeadings.map(\.id)) == Set([1, 2, 3, 4, 5].map(uuid)))
        #expect(result.headingIDRemap.isEmpty)
        #expect(result.report.headingsAdded == 4)
    }

    @Test func remapChainThreeDeep() {
        // Local: Part ⊃ Chapter ⊃ Section. The backup has the same three under other IDs, listed
        // child first so the merge has to resolve parents before children.
        let mine = local([], [], [], [
            heading(1, "Part", page: 10),
            heading(2, "Chapter", page: 10, parent: user(1)),
            heading(3, "Section", page: 12, parent: user(2)),
        ])
        let theirs = backup([note(30, .heading(user(13)), "On the section", book: backupBookID)], [], [], [
            heading(13, "Section", page: 12, parent: user(12), book: backupBookID),
            heading(12, "Chapter", page: 10, parent: user(11), book: backupBookID),
            heading(11, "Part", page: 10, book: backupBookID),
            heading(14, "Subsection", page: 13, parent: user(13), book: backupBookID),
        ])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        #expect(result.headingIDRemap == [uuid(11): uuid(1), uuid(12): uuid(2), uuid(13): uuid(3)])
        let added = result.archive.userHeadings.filter { $0.id == uuid(14) }
        #expect(added.map(\.parent) == [user(3)], "an added child follows its matched parent")
        #expect(result.archive.notes.map(\.target) == [.heading(user(3))])
        #expect(result.report.headingsMatched == 3 && result.report.headingsAdded == 1)
    }

    @Test func headingMatchedByTitleUnderAParentThatWasItselfRemapped() {
        let mine = local([], [], [], [heading(1, "Chapter", page: 10), heading(2, "Aside", page: 15, parent: user(1))])
        let theirs = backup([], [], [], [
            heading(11, "Chapter", page: 10, book: backupBookID),
            heading(12, "Aside", page: 15, parent: user(11), book: backupBookID),
        ])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        #expect(result.headingIDRemap == [uuid(11): uuid(1), uuid(12): uuid(2)])
        #expect(BookMerge.canonicalOrder(result.archive) == BookMerge.canonicalOrder(mine))
    }

    @Test func parentCyclesAndMissingParentsDoNotLoop() throws {
        let mine = local([], [], [], [heading(1, "A", page: 10)])
        let theirs = backup([], [], [], [
            heading(11, "A", page: 10, parent: user(12), book: backupBookID),   // 11 → 12 → 11
            heading(12, "B", page: 11, parent: user(11), book: backupBookID),
            heading(13, "C", page: 12, parent: user(13), book: backupBookID),   // its own parent
            heading(14, "D", page: 13, parent: user(99), book: backupBookID),   // parent nowhere
        ])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        try result.archive.validateForReplacement()
        #expect(result.headingIDRemap.isEmpty)
        let byID = Dictionary(uniqueKeysWithValues: result.archive.userHeadings.map { ($0.id, $0) })
        #expect(byID.count == 5)
        #expect(byID[uuid(11)]?.parent == user(12) && byID[uuid(12)]?.parent == user(11))
        #expect(byID[uuid(13)]?.parent == user(13))
        #expect(byID[uuid(14)]?.parent == user(99))
        // And merging again changes nothing.
        #expect(BookMerge.merge(local: result.archive, incoming: theirs).archive == result.archive)
    }

    @Test func aCycleMemberCanStillMatchALocalHeading() {
        // Local B's parent points at a heading the Library no longer has (11); the backup has the
        // cycle 11 ⇄ 12. Walking from 11 cuts the cycle at 12's parent, which compares as it is
        // and matches local B; 11 is then compared under B and matches nothing.
        let mine = local([], [], [], [heading(2, "B", page: 11, parent: user(11))])
        let theirs = backup([], [], [], [
            heading(11, "A", page: 10, parent: user(12), book: backupBookID),
            heading(12, "B", page: 11, parent: user(11), book: backupBookID),
        ])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        #expect(result.headingIDRemap == [uuid(12): uuid(2)])
        #expect(result.archive.userHeadings.first { $0.id == uuid(11) }?.parent == user(2))
        #expect(BookMerge.merge(local: result.archive, incoming: theirs).archive == result.archive)
    }

    @Test func eachLocalHeadingAbsorbsOneIncomingHeading() {
        let mine = local([], [], [], [heading(1, "Aside", page: 10)])
        let theirs = backup([], [], [], [heading(11, "Aside", page: 10, book: backupBookID, created: 1),
                                         heading(12, "Aside", page: 10, book: backupBookID, created: 2)])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        #expect(result.headingIDRemap == [uuid(11): uuid(1)])
        #expect(result.archive.userHeadings.map(\.id) == [uuid(1), uuid(12)])
    }

    @Test func noMatchWhenTheBackupHasNotesOnBothHeadings() throws {
        // The backup deleted heading 1, re-created it as 11 and kept the orphaned note on 1.
        let mine = local([note(20, .heading(user(1)), "Local")], [], [], [heading(1, "Aside", page: 10)])
        let theirs = backup([note(21, .heading(user(1)), "Orphan", book: backupBookID),
                             note(22, .heading(user(11)), "New", book: backupBookID)], [], [], [
                                heading(11, "Aside", page: 10, book: backupBookID)])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        try result.archive.validateForReplacement()
        #expect(result.headingIDRemap.isEmpty)
        #expect(result.archive.notes.map(\.target) == [.heading(user(1)), .heading(user(11))])
        #expect(result.archive.notes.first?.text == "Local\nOrphan")
    }

    // MARK: Notes

    @Test func noteOnOneSideIsKeptOrAdded() {
        let mine = local([note(1, .page(1), "Mine", ink: true)])
        let theirs = backup([note(2, .page(2), "Theirs", book: backupBookID)])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        #expect(result.archive.notes[0] == mine.notes[0])
        #expect(result.archive.notes[1].id == uuid(2) && result.archive.notes[1].bookID == localBookID)
        #expect(result.noteDecisions.map(\.source) == [.localOnly, .incomingOnly])
        #expect(result.noteDecisions[0].localNoteID == uuid(1) && result.noteDecisions[0].incomingNoteID == nil)
        #expect(result.noteDecisions[1].localNoteID == nil && result.noteDecisions[1].incomingNoteID == uuid(2))
        #expect(result.noteDecisions.allSatisfy { !$0.textChanged && !$0.needsBandLayout })
        #expect(result.report.notesAdded == 1)
    }

    @Test func noteWithEqualTextIsOneNote() {
        let layout = NoteBandLayout(pageWidth: 320, paragraphs: [NoteParagraphBand(text: "Same", top: 8, height: 20)], trailingTop: 28)
        var mine = note(1, .page(1), "Same", created: 10, modified: 20)
        mine.hasInk = false
        var theirs = note(2, .page(1), "Same", book: backupBookID, ink: true, created: 5, modified: 30)
        theirs.bandLayout = layout
        let result = BookMerge.merge(local: local([mine]), incoming: backup([theirs]))
        let merged = result.archive.notes[0]
        #expect(result.archive.notes.count == 1)
        #expect(merged.id == uuid(1) && merged.text == "Same")
        #expect(merged.createdAt == at(5) && merged.modifiedAt == at(30))
        #expect(merged.hasInk)
        #expect(merged.bandLayout == nil, "the local note's layout, which it did not have")
        let decision = result.noteDecisions[0]
        #expect(decision.source == .unchangedText && !decision.textChanged)
        #expect(decision.localNoteID == uuid(1) && decision.incomingNoteID == uuid(2))
        #expect(decision.needsBandLayout)
        #expect(result.report.notesIdentical == 1 && result.report.notesCombined == 0)
    }

    @Test func noteWithDifferentTextIsCombined() {
        let mine = note(1, .page(1), "Intro\nMine\nEnd", ink: true, created: 1, modified: 40)
        let theirs = note(2, .page(1), "Intro\nTheirs\nEnd", book: backupBookID, created: 3, modified: 30)
        let result = BookMerge.merge(local: local([mine]), incoming: backup([theirs]))
        let merged = result.archive.notes[0]
        #expect(merged.id == uuid(1))
        #expect(merged.text == "Intro\nMine\nTheirs\nEnd")
        #expect(merged.createdAt == at(1) && merged.modifiedAt == at(40))
        #expect(merged.hasInk && merged.bandLayout == nil)
        let decision = result.noteDecisions[0]
        #expect(decision.source == .combined && decision.textChanged && decision.needsBandLayout)
        #expect(decision.localParagraphMap == [0, 1, 3] && decision.incomingParagraphMap == [0, 2, 3])
        #expect(result.report.notesCombined == 1)
    }

    @Test func incomingTextTheLocalOneContainsLeavesTheNoteUnchanged() {
        let mine = note(1, .page(1), "A\nB\nC", ink: true)
        let theirs = note(2, .page(1), "A\nC", book: backupBookID, ink: true)
        let result = BookMerge.merge(local: local([mine]), incoming: backup([theirs]))
        #expect(result.archive.notes == [mine])
        #expect(result.noteDecisions[0].source == .unchangedText)
        #expect(result.noteDecisions[0].incomingParagraphMap == [0, 2])
        #expect(result.report.notesIdentical == 1)
    }

    @Test func noteOnARemappedHeadingCombinesWithTheLocalNote() {
        let mine = local([note(1, .heading(user(1)), "Mine")], [], [], [heading(1, "Aside", page: 10)])
        let theirs = backup([note(2, .heading(user(11)), "Theirs", book: backupBookID)], [], [], [
            heading(11, "Aside", page: 10, book: backupBookID)])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        #expect(result.archive.notes.count == 1)
        #expect(result.archive.notes[0].id == uuid(1))
        #expect(result.archive.notes[0].target == .heading(user(1)))
        #expect(result.archive.notes[0].text == "Mine\nTheirs")
        #expect(result.noteDecisions[0].incomingNoteID == uuid(2))
    }

    @Test func addedNoteWhoseIDIsTakenLocallyGetsAFreshStableID() throws {
        let mine = local([note(1, .page(1), "Mine"), note(3, .page(3), "Three")])
        let theirs = backup([note(1, .page(2), "Same ID, other page", book: backupBookID),
                             note(2, .page(4), "Another", book: backupBookID)])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        try result.archive.validateForReplacement()
        let added = try #require(result.archive.notes.first { $0.target == .page(2) })
        #expect(added.id != uuid(1) && ![uuid(2), uuid(3)].contains(added.id))
        #expect(added.id == BookMerge.freshID(for: uuid(1), in: localBookID, attempt: 0))
        let decision = try #require(result.noteDecisions.first { $0.noteID == added.id })
        #expect(decision.incomingNoteID == uuid(1), "the ink is found under the backup's ID")
        #expect(BookMerge.merge(local: mine, incoming: theirs) == result)
        #expect(result.archive.notes.first { $0.target == .page(1) }?.id == uuid(1))
    }

    @Test func emptyIncomingNotesAreLeftOut() {
        let theirs = backup([note(2, .page(2), " \n", book: backupBookID)])
        let result = BookMerge.merge(local: local(), incoming: theirs)
        #expect(result.archive.notes.isEmpty)
    }

    // MARK: Highlights

    @Test func highlightWithTheSameIDKeepsTheLocalOne() {
        let mine = highlight(1, page: 5, color: .yellow)
        let theirs = highlight(1, page: 5, color: .pink, book: backupBookID)
        let result = BookMerge.merge(local: local([], [mine]), incoming: backup([], [theirs]))
        #expect(result.archive.highlights == [mine])
        #expect(result.report.highlightsAdded == 0 && result.report.duplicatesSkipped == 0)
    }

    @Test func nearDuplicateHighlightsWithinTheTolerance() {
        let rect = CGRect(x: 72, y: 600, width: 200, height: 12)
        let mine = highlight(1, page: 5, rects: [rect, rect.offsetBy(dx: 0, dy: -14)])
        for (dx, dy) in [(0.0, 0.0), (0.5, 0), (0, -0.5), (0.3, 0.4)] {
            let moved = [rect.offsetBy(dx: dx, dy: dy), rect.offsetBy(dx: 0, dy: -14)]
            let theirs = highlight(2, page: 5, rects: moved, color: .green, book: backupBookID)
            let result = BookMerge.merge(local: local([], [mine]), incoming: backup([], [theirs]))
            #expect(result.archive.highlights == [mine], "offset \(dx), \(dy)")
            #expect(result.report.duplicatesSkipped == 1)
        }
        // A width change moves maxX only.
        let wider = highlight(2, page: 5, rects: [CGRect(x: 72, y: 600, width: 200.5, height: 12), rect.offsetBy(dx: 0, dy: -14)],
                              book: backupBookID)
        #expect(BookMerge.merge(local: local([], [mine]), incoming: backup([], [wider])).report.duplicatesSkipped == 1)
    }

    @Test func highlightsJustOutsideTheToleranceOrDifferentAreAdded() {
        let rect = CGRect(x: 72, y: 600, width: 200, height: 12)
        let mine = highlight(1, page: 5, rects: [rect])
        let others = [
            highlight(2, page: 5, rects: [rect.offsetBy(dx: 0.51, dy: 0)], book: backupBookID),
            highlight(3, page: 5, rects: [rect.offsetBy(dx: 0, dy: -0.6)], book: backupBookID),
            highlight(4, page: 5, rects: [CGRect(x: 72, y: 600, width: 200.6, height: 12)], book: backupBookID),
            highlight(5, page: 5, text: "eigenvalues", rects: [rect], book: backupBookID),
            highlight(6, page: 6, rects: [rect], book: backupBookID),
            highlight(7, page: 5, rects: [rect, rect], book: backupBookID),
        ]
        for other in others {
            let result = BookMerge.merge(local: local([], [mine]), incoming: backup([], [other]))
            #expect(result.archive.highlights.count == 2, "\(other.id)")
            #expect(result.report.highlightsAdded == 1 && result.report.duplicatesSkipped == 0)
        }
    }

    // MARK: Bookmarks

    @Test func bookmarksUnionByPageWithTheEarlierDate() throws {
        let mine = local([], [], [bookmark(1, page: 5, created: 20), bookmark(2, page: 6, created: 5)])
        let theirs = backup([], [], [bookmark(11, page: 5, book: backupBookID, created: 10),
                                     bookmark(12, page: 6, book: backupBookID, created: 30),
                                     bookmark(13, page: 7, book: backupBookID, created: 1)])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        try result.archive.validateForReplacement()
        #expect(result.archive.bookmarks.map(\.id) == [uuid(1), uuid(2), uuid(13)])
        #expect(result.archive.bookmarks.map(\.createdAt) == [at(10), at(5), at(1)])
        #expect(result.archive.bookmarks.allSatisfy { $0.bookID == localBookID })
        #expect(result.report.bookmarksAdded == 1)
    }

    @Test func addedBookmarkWhoseIDIsTakenLocallyGetsAFreshID() throws {
        let mine = local([], [], [bookmark(1, page: 5)])
        let theirs = backup([], [], [bookmark(1, page: 9, book: backupBookID)])
        let result = BookMerge.merge(local: mine, incoming: theirs)
        try result.archive.validateForReplacement()
        #expect(result.archive.bookmarks.map(\.pageIndex) == [5, 9])
        #expect(result.archive.bookmarks[1].id == BookMerge.freshID(for: uuid(1), in: localBookID, attempt: 0))
    }

    // MARK: Simple properties

    @Test func emptyIncomingArchiveReturnsTheLocalArchive() {
        let mine = local([note(2, .page(9), "B"), note(1, .heading(pdfChapter), "A")],
                         [highlight(3, page: 2)], [bookmark(4, page: 1)], [heading(5, "H", page: 3)])
        let result = BookMerge.merge(local: mine, incoming: backup())
        #expect(result.archive == BookMerge.canonicalOrder(mine))
        #expect(result.report == BookMergeReport())
        #expect(result.noteDecisions.map(\.source) == [.localOnly, .localOnly])
    }

    @Test func freshIDsAreStableAndDistinct() {
        let a = BookMerge.freshID(for: uuid(1), in: localBookID, attempt: 0)
        #expect(a == BookMerge.freshID(for: uuid(1), in: localBookID, attempt: 0))
        let all: Set<UUID> = [a, BookMerge.freshID(for: uuid(1), in: localBookID, attempt: 1),
                              BookMerge.freshID(for: uuid(2), in: localBookID, attempt: 0),
                              BookMerge.freshID(for: uuid(1), in: backupBookID, attempt: 0)]
        #expect(all.count == 4)
        #expect(a.uuidString.dropFirst(14).first == "4", "version 4 UUID")
    }

    // MARK: Generated archives

    @Test func propertiesOverGeneratedArchivePairs() throws {
        for seed in UInt64(1)...300 {
            var generator = ArchivePairGenerator(seed: seed)
            let (mine, theirs) = generator.pair()
            let comment: Comment = "seed \(seed)"
            try mine.validateForReplacement()

            let result = BookMerge.merge(local: mine, incoming: theirs)
            let archive = result.archive

            // A valid archive of the local book.
            #expect(archive.book == mine.book, comment)
            do { try archive.validateForReplacement() } catch { Issue.record("seed \(seed): \(error)") }
            #expect(result.noteDecisions.map(\.noteID) == archive.notes.map(\.id), comment)

            // Nothing local is removed.
            let notesByID = Dictionary(uniqueKeysWithValues: archive.notes.map { ($0.id, $0) })
            for note in mine.notes {
                #expect(notesByID[note.id]?.target == note.target, comment)
                let paragraphs = NoteBandLayout.paragraphs(of: notesByID[note.id]?.text ?? "")
                let decision = result.noteDecisions.first { $0.noteID == note.id }
                let map = decision?.localParagraphMap ?? []
                for (k, paragraph) in NoteBandLayout.paragraphs(of: note.text).enumerated().dropLast() {
                    #expect(paragraphs[map[k]] == paragraph, comment)
                }
            }
            #expect(Set(mine.highlights).isSubset(of: Set(archive.highlights)), comment)
            #expect(Set(mine.userHeadings).isSubset(of: Set(archive.userHeadings)), comment)
            let bookmarkIDs = Set(archive.bookmarks.map(\.id))
            #expect(mine.bookmarks.allSatisfy { bookmarkIDs.contains($0.id) }, comment)

            // Idempotence.
            let again = BookMerge.merge(local: archive, incoming: theirs)
            #expect(again.archive == archive, comment)
            #expect(again.report.addsNothing, comment)
            #expect(again.headingIDRemap == result.headingIDRemap, comment)

            // Empty incoming.
            #expect(BookMerge.merge(local: mine, incoming: BookArchive(book: theirs.book)).archive
                    == BookMerge.canonicalOrder(mine), comment)

            // Input order does not matter.
            var rng = SeededGenerator(state: seed &* 31)
            var shuffledMine = mine, shuffledTheirs = theirs
            shuffledMine.notes.shuffle(using: &rng)
            shuffledMine.highlights.shuffle(using: &rng)
            shuffledMine.bookmarks.shuffle(using: &rng)
            shuffledMine.userHeadings.shuffle(using: &rng)
            shuffledTheirs.notes.shuffle(using: &rng)
            shuffledTheirs.highlights.shuffle(using: &rng)
            shuffledTheirs.bookmarks.shuffle(using: &rng)
            shuffledTheirs.userHeadings.shuffle(using: &rng)
            #expect(BookMerge.merge(local: shuffledMine, incoming: shuffledTheirs) == result, comment)
        }
    }

    @Test func generatedPairsExerciseEveryRule() {
        // Guards the generator: across the seeds every kind of outcome occurs.
        var total = BookMergeReport(), remaps = 0, freshNotes = 0
        for seed in UInt64(1)...300 {
            var generator = ArchivePairGenerator(seed: seed)
            let (mine, theirs) = generator.pair()
            let result = BookMerge.merge(local: mine, incoming: theirs)
            let r = result.report
            total.notesAdded += r.notesAdded; total.notesCombined += r.notesCombined
            total.notesIdentical += r.notesIdentical; total.highlightsAdded += r.highlightsAdded
            total.duplicatesSkipped += r.duplicatesSkipped; total.bookmarksAdded += r.bookmarksAdded
            total.headingsAdded += r.headingsAdded; total.headingsMatched += r.headingsMatched
            remaps += result.headingIDRemap.count
            freshNotes += result.noteDecisions.filter { $0.incomingNoteID != nil && $0.localNoteID == nil && $0.incomingNoteID != $0.noteID }.count
        }
        #expect(total.notesAdded > 0 && total.notesCombined > 0 && total.notesIdentical > 0)
        #expect(total.highlightsAdded > 0 && total.duplicatesSkipped > 0 && total.bookmarksAdded > 0)
        #expect(total.headingsAdded > 0 && total.headingsMatched > 0 && remaps > 0 && freshNotes > 0)
    }
}

/// Two diverged copies of one book: a shared history, then independent edits on each side, the
/// backup's copy sometimes imported under another book ID, with headings re-created under new
/// IDs, highlights re-made with tiny rect differences and IDs reused on other targets.
private struct ArchivePairGenerator {
    var rng: SeededGenerator

    init(seed: UInt64) { rng = SeededGenerator(state: seed) }

    mutating func id() -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for k in 0..<16 { bytes[k] = UInt8.random(in: 0...255, using: &rng) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func date() -> Date { at(Double(int(0...100))) }

    mutating func text() -> String {
        let words = ["Alpha", "Beta", "Gamma", "Delta", "", "Epsilon", "Zeta"]
        var paragraphs = (0..<int(1...5)).map { _ in words[int(0...words.count - 1)] }
        if paragraphs.allSatisfy(\.isEmpty) { paragraphs[0] = "Eta" }
        return paragraphs.joined(separator: "\n") + (chance(0.3) ? "\n" : "")
    }

    mutating func edit(_ text: String) -> String {
        var paragraphs = NoteBandLayout.paragraphs(of: text)
        switch int(0...3) {
        case 0: paragraphs.insert("Inserted \(int(0...3))", at: int(0...paragraphs.count))
        case 1: paragraphs[int(0...paragraphs.count - 1)] += " edited"
        case 2: if paragraphs.count > 1 { paragraphs.remove(at: int(0...paragraphs.count - 1)) }
        default: paragraphs.append("Appended")
        }
        let result = paragraphs.joined(separator: "\n")
        return result.allSatisfy(\.isWhitespace) ? "Theta" : result
    }

    mutating func pair() -> (BookArchive, BookArchive) {
        let book = makeBook(localBookID)
        var base = BookArchive(book: book)
        let chapters = [nil, pdfChapter, HeadingAnchor(pdfPath: [1, 2], pageIndex: 40, title: "1.3 Rank")]
        let titles = ["Aside", "Proof", "Summary", "Exercises"]
        for _ in 0..<int(0...5) {
            let parent: HeadingAnchor? = !base.userHeadings.isEmpty && chance(0.5)
                ? base.userHeadings[int(0...base.userHeadings.count - 1)].anchor
                : chapters[int(0...2)]
            base.userHeadings.append(UserHeading(id: id(), bookID: book.id, title: titles[int(0...3)],
                                                 pageIndex: int(0...6), parent: parent, createdAt: date()))
        }
        func targets(_ archive: BookArchive) -> [NoteTarget] {
            (0..<8).map { NoteTarget.page($0) } + archive.userHeadings.map { .heading($0.anchor) } + [.heading(pdfChapter)]
        }
        for target in targets(base) where chance(0.4) {
            base.notes.append(Note(id: id(), bookID: book.id, target: target, text: text(), hasInk: chance(0.3),
                                   createdAt: date(), modifiedAt: date()))
        }
        for _ in 0..<int(0...4) { base.highlights.append(randomHighlight(book.id)) }
        for page in 0..<8 where chance(0.3) { base.bookmarks.append(Bookmark(id: id(), bookID: book.id, pageIndex: page, createdAt: date())) }

        var mine = base
        mutate(&mine)
        var theirs = base
        mutate(&theirs)
        // The backup's copy of the book was imported separately: another book ID, and some of
        // its headings re-created under new IDs (with their notes and children following).
        if chance(0.5) {
            theirs.book = makeBook(backupBookID, title: "Backup copy")
            for index in theirs.userHeadings.indices where chance(0.4) {
                let old = theirs.userHeadings[index].id, new = id()
                theirs.userHeadings[index].id = new
                for k in theirs.userHeadings.indices where theirs.userHeadings[k].parent == HeadingAnchor(userHeadingID: old) {
                    theirs.userHeadings[k].parent = HeadingAnchor(userHeadingID: new)
                }
                for k in theirs.notes.indices where theirs.notes[k].target == .heading(HeadingAnchor(userHeadingID: old)) {
                    theirs.notes[k].target = .heading(HeadingAnchor(userHeadingID: new))
                }
            }
            theirs.notes = theirs.notes.map { var n = $0; n.bookID = backupBookID; return n }
            theirs.highlights = theirs.highlights.map { var h = $0; h.bookID = backupBookID; return h }
            theirs.bookmarks = theirs.bookmarks.map { var b = $0; b.bookID = backupBookID; return b }
            theirs.userHeadings = theirs.userHeadings.map { var h = $0; h.bookID = backupBookID; return h }
        }
        // The same highlight made again on the other device, a hair apart.
        if let original = mine.highlights.first, chance(0.5) {
            var copy = original
            copy.id = id()
            copy.bookID = theirs.book.id
            copy.rects = copy.rects.map { $0.offsetBy(dx: chance(0.5) ? 0.25 : 0, dy: 0) }
            theirs.highlights.append(copy)
        }
        // A note ID reused on another target.
        if let taken = mine.notes.first, let free = (0..<8).map(NoteTarget.page).first(where: { t in
            !theirs.notes.contains { $0.target == t } && !theirs.notes.contains { $0.id == taken.id }
        }), chance(0.5) {
            theirs.notes.append(Note(id: taken.id, bookID: theirs.book.id, target: free, text: text(), createdAt: date()))
        }
        return (mine, theirs)
    }

    mutating func randomHighlight(_ bookID: UUID) -> Highlight {
        let line = CGFloat(int(0...20))
        let rect = CGRect(x: 72, y: 700 - line * 14, width: CGFloat(int(20...300)), height: 12)
        return Highlight(id: id(), bookID: bookID, pageIndex: int(0...7), rects: [rect],
                         color: HighlightColor.allCases[int(0...3)], text: ["matrix", "rank", "kernel"][int(0...2)], createdAt: date())
    }

    /// Independent edits on one side: removals, edits, additions.
    mutating func mutate(_ archive: inout BookArchive) {
        let bookID = archive.book.id
        archive.userHeadings.removeAll { _ in chance(0.15) }
        for _ in 0..<int(0...2) {
            archive.userHeadings.append(UserHeading(id: id(), bookID: bookID, title: ["Aside", "Note", "Recap"][int(0...2)],
                                                    pageIndex: int(0...6), parent: chance(0.5) ? pdfChapter : nil,
                                                    createdAt: date()))
        }
        archive.notes.removeAll { _ in chance(0.15) }
        for index in archive.notes.indices where chance(0.4) {
            archive.notes[index].text = edit(archive.notes[index].text)
            archive.notes[index].modifiedAt = date()
            if chance(0.3) { archive.notes[index].hasInk.toggle() }
        }
        var taken = Set(archive.notes.map(\.target))
        let targets = (0..<8).map { NoteTarget.page($0) } + archive.userHeadings.map { .heading($0.anchor) }
        for target in targets where !taken.contains(target) && chance(0.2) {
            archive.notes.append(Note(id: id(), bookID: bookID, target: target, text: text(), hasInk: chance(0.3),
                                      createdAt: date(), modifiedAt: date()))
            taken.insert(target)
        }
        archive.highlights.removeAll { _ in chance(0.15) }
        for _ in 0..<int(0...2) { archive.highlights.append(randomHighlight(bookID)) }
        archive.bookmarks.removeAll { _ in chance(0.2) }
        var pages = Set(archive.bookmarks.map(\.pageIndex))
        for page in 0..<8 where !pages.contains(page) && chance(0.15) {
            archive.bookmarks.append(Bookmark(id: id(), bookID: bookID, pageIndex: page, createdAt: date()))
            pages.insert(page)
        }
    }
}
