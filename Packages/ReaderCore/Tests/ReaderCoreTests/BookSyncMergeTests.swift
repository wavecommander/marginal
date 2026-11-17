import Foundation
import CoreGraphics
import Testing
@testable import ReaderCore

// Each simulated device imported the book on its own, so each has its own book ID.
private let deviceA = UUID(uuidString: "AAAA0000-0000-0000-0000-00000000000A")!
private let deviceB = UUID(uuidString: "BBBB0000-0000-0000-0000-00000000000B")!
private let deviceC = UUID(uuidString: "CCCC0000-0000-0000-0000-00000000000C")!
private let contentID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

private func at(_ seconds: Double) -> Date { fixedDate.addingTimeInterval(seconds) }

private func makeBook(_ id: UUID, title: String = "Linear Algebra", page: Int = 0, opened: Double? = nil) -> Book {
    Book(id: id, title: title, fingerprint: "fp-\(id.uuidString.prefix(4))", fileName: "\(id.uuidString.prefix(4)).pdf",
         pageCount: 400, fileSize: 1_000, addedAt: at(0), lastOpenedAt: opened.map(at), lastReadPageIndex: page)
}

private let layout = NoteBandLayout(pageWidth: 320, paragraphs: [], trailingTop: 8)

private func note(_ n: Int, _ target: NoteTarget, _ text: String, book: UUID = deviceA, ink: Bool = false,
                  created: Double = 1, modified: Double = 2) -> Note {
    Note(id: uuid(n), bookID: book, target: target, text: text, hasInk: ink, bandLayout: ink ? layout : nil,
         createdAt: at(created), modifiedAt: at(modified))
}

private func highlight(_ n: Int, page: Int, color: HighlightColor = .yellow, book: UUID = deviceA, line: CGFloat = 0) -> Highlight {
    Highlight(id: uuid(n), bookID: book, pageIndex: page, rects: [CGRect(x: 72, y: 600 - line * 14, width: 200, height: 12)],
              color: color, text: "eigenvalue", createdAt: at(3))
}

private func bookmark(_ n: Int, page: Int, book: UUID = deviceA, created: Double = 4) -> Bookmark {
    Bookmark(id: uuid(n), bookID: book, pageIndex: page, createdAt: at(created))
}

private func heading(_ n: Int, _ title: String, page: Int, parent: HeadingAnchor? = nil, book: UUID = deviceA) -> UserHeading {
    UserHeading(id: uuid(n), bookID: book, title: title, pageIndex: page, parent: parent, createdAt: at(1))
}

private func user(_ n: Int) -> HeadingAnchor { HeadingAnchor(userHeadingID: uuid(n)) }
private let pdfChapter = HeadingAnchor(pdfPath: [4], pageIndex: 300, title: "5 Eigenvalues")

private func archive(_ id: UUID = deviceA, title: String = "Linear Algebra", _ notes: [Note] = [], _ highlights: [Highlight] = [],
                     _ bookmarks: [Bookmark] = [], _ headings: [UserHeading] = []) -> BookArchive {
    BookArchive(book: makeBook(id, title: title), notes: notes, highlights: highlights, bookmarks: bookmarks, userHeadings: headings)
}

/// The same content on another device: another `Book` identity, records keyed to it.
private func onDevice(_ archive: BookArchive, _ id: UUID) -> BookArchive {
    var book = makeBook(id, title: archive.book.title)
    book.lastOpenedAt = archive.book.lastOpenedAt
    book.lastReadPageIndex = archive.book.lastReadPageIndex
    var result = BookMerge.rekeyed(archive, to: id)
    result.book = book
    return result
}

/// What sync carries: the records (in canonical order, keyed to one ID) and the book's title and
/// reading position.
private func content(_ archive: BookArchive) -> BookArchive {
    var result = BookMerge.canonicalOrder(BookMerge.rekeyed(archive, to: contentID))
    result.book = Book(id: contentID, title: archive.book.title, fingerprint: "", fileName: "", pageCount: 0, fileSize: 0,
                       addedAt: fixedDate, lastOpenedAt: archive.book.lastOpenedAt, lastReadPageIndex: archive.book.lastReadPageIndex)
    return result
}

private func merge(_ local: BookArchive, _ remote: BookArchive, _ base: BookArchive?) -> BookSyncMergeResult {
    BookMerge.merge(local: local, remote: remote, base: base)
}

@Suite("BookMerge three-way (sync)")
struct BookSyncMergeTests {
    // MARK: Basics

    @Test func nothingChangesWhenAllThreeAreEqual() throws {
        let shared = archive(deviceA, [note(1, .page(1), "A\nB", ink: true), note(2, .heading(user(4)), "On it")],
                             [highlight(3, page: 2)], [bookmark(5, page: 7)], [heading(4, "Aside", page: 3)])
        let result = merge(shared, onDevice(shared, deviceB), shared)
        #expect(result.archive == BookMerge.canonicalOrder(shared))
        #expect(result.localChanges.isEmpty && !result.needsPush)
        #expect(result.noteDecisions.allSatisfy { $0.source == .local && $0.remote == nil })
        #expect(result.inkDecisions.isEmpty)
        try result.archive.validateForReplacement()
    }

    @Test func aLocalChangeIsKeptAndNeedsAPush() {
        let base = archive(deviceA, [note(1, .page(1), "A")], [highlight(2, page: 2)])
        var local = base
        local.notes[0].text = "A\nB"
        local.notes[0].modifiedAt = at(9)
        local.highlights.append(highlight(3, page: 4))
        let result = merge(local, onDevice(base, deviceB), base)
        #expect(result.archive == BookMerge.canonicalOrder(local))
        #expect(result.localChanges.isEmpty && result.needsPush)
        #expect(result.remoteChanges.notes.changed.map(\.id) == [uuid(1)])
        #expect(result.remoteChanges.highlights.added.map(\.id) == [uuid(3)])
        #expect(result.noteDecisions.map(\.source) == [.local])
    }

    @Test func aRemoteChangeIsAdoptedWithoutAPush() {
        let base = archive(deviceA, [note(1, .page(1), "A", ink: true)], [highlight(2, page: 2)])
        var remote = onDevice(base, deviceB)
        remote.notes[0].text = "A\nB"
        remote.notes[0].modifiedAt = at(9)
        remote.highlights[0].color = .green
        remote.book.title = "Renamed"
        let result = merge(base, remote, base)
        #expect(result.archive.book.id == deviceA && result.archive.book.fileName == base.book.fileName)
        #expect(content(result.archive) == content(remote))
        #expect(!result.needsPush)
        #expect(result.localChanges.notes.changed.map(\.text) == ["A\nB"])
        #expect(result.localChanges.highlights.changed.map(\.color) == [.green])
        #expect(result.localChanges.titleChanged)
        let decision = result.noteDecisions[0]
        #expect(decision.source == .remote && decision.local == nil && decision.remote?.noteID == uuid(1))
        #expect(result.inkDecisions.map(\.noteID) == [uuid(1)])
    }

    // MARK: Deletions

    @Test(arguments: [true, false])
    func aDeletionTravelsForEveryKind(deletedLocally: Bool) throws {
        let base = archive(deviceA, [note(1, .page(1), "A"), note(9, .page(2), "Stays")], [highlight(2, page: 2)],
                           [bookmark(3, page: 5)], [heading(4, "Aside", page: 3)])
        let emptied = archive(deviceA, [note(9, .page(2), "Stays")])
        let local = deletedLocally ? emptied : base
        let remote = onDevice(deletedLocally ? base : emptied, deviceB)
        let result = merge(local, remote, base)
        try result.archive.validateForReplacement()
        #expect(result.archive.notes.map(\.id) == [uuid(9)])
        #expect(result.archive.highlights.isEmpty && result.archive.bookmarks.isEmpty && result.archive.userHeadings.isEmpty)
        if deletedLocally {
            #expect(result.needsPush && result.localChanges.isEmpty)
            #expect(result.remoteChanges.notes.removed == [uuid(1)] && result.remoteChanges.highlights.removed == [uuid(2)])
            #expect(result.remoteChanges.bookmarks.removed == [uuid(3)] && result.remoteChanges.userHeadings.removed == [uuid(4)])
        } else {
            #expect(!result.needsPush)
            #expect(result.localChanges.notes.removed == [uuid(1)] && result.localChanges.highlights.removed == [uuid(2)])
            #expect(result.localChanges.bookmarks.removed == [uuid(3)] && result.localChanges.userHeadings.removed == [uuid(4)])
        }
    }

    @Test(arguments: [true, false])
    func anEditBeatsADeletion(editedLocally: Bool) throws {
        let base = archive(deviceA, [note(1, .page(1), "A")], [highlight(2, page: 2)], [], [heading(4, "Aside", page: 3)])
        var edited = base
        edited.notes[0].text = "A\nMore"
        edited.notes[0].modifiedAt = at(10)
        edited.highlights[0].color = .pink
        edited.userHeadings[0].title = "Interlude"
        let deleted = archive(deviceA)
        let result = merge(editedLocally ? edited : deleted, onDevice(editedLocally ? deleted : edited, deviceB), base)
        try result.archive.validateForReplacement()
        #expect(content(result.archive) == content(edited))
        #expect(result.needsPush == editedLocally)
        if !editedLocally {
            #expect(result.localChanges.notes.added.map(\.id) == [uuid(1)])
            #expect(result.noteDecisions.map(\.source) == [.remote])
        }
    }

    @Test func aBookmarkRemovedOnOneSideIsRemovedAndAdditionsFromBothApply() {
        let base = archive(deviceA, [], [], [bookmark(1, page: 1), bookmark(2, page: 2)])
        let local = archive(deviceA, [], [], [bookmark(2, page: 2), bookmark(3, page: 3)])
        let remote = archive(deviceB, [], [], [bookmark(1, page: 1, book: deviceB), bookmark(4, page: 4, book: deviceB)])
        let result = merge(local, remote, base)
        #expect(result.archive.bookmarks.map(\.pageIndex) == [3, 4])
        #expect(result.archive.bookmarks.allSatisfy { $0.bookID == deviceA })
        // A page re-flagged locally (new record) is still removed when the other side removed it.
        let reflagged = archive(deviceA, [], [], [bookmark(7, page: 1, created: 30), bookmark(2, page: 2)])
        #expect(merge(reflagged, archive(deviceB, [], [], [bookmark(2, page: 2, book: deviceB)]), base)
            .archive.bookmarks.map(\.pageIndex) == [2])
    }

    // MARK: Both sides changed

    @Test func theRemoteWinsAFieldBothChanged() {
        let base = archive(deviceA, title: "Base", [], [highlight(1, page: 2)], [], [heading(2, "Aside", page: 3), heading(3, "Proof", page: 4)])
        var local = base, remote = onDevice(base, deviceB)
        local.book.title = "Mine"; remote.book.title = "Theirs"
        local.highlights[0].color = .green; remote.highlights[0].color = .pink
        local.userHeadings[0].title = "Mine"; remote.userHeadings[0].title = "Theirs"
        // Different fields of one heading: both apply.
        local.userHeadings[1].title = "Proof of 5.1"; remote.userHeadings[1].pageIndex = 5
        remote.userHeadings[1].parent = pdfChapter
        let result = merge(local, remote, base)
        #expect(result.archive.book.title == "Theirs")
        #expect(result.archive.highlights.map(\.color) == [.pink])
        let byID = Dictionary(uniqueKeysWithValues: result.archive.userHeadings.map { ($0.id, $0) })
        #expect(byID[uuid(2)]?.title == "Theirs")
        #expect(byID[uuid(3)]?.title == "Proof of 5.1")
        #expect(byID[uuid(3)]?.pageIndex == 5 && byID[uuid(3)]?.parent == pdfChapter)
        #expect(result.needsPush, "the local heading title is new to the account")
        // Only one side renamed the book: that name.
        var renamed = base
        renamed.book.title = "Renamed"
        #expect(merge(renamed, onDevice(base, deviceB), base).archive.book.title == "Renamed")
    }

    @Test func theLaterReadingPositionWins() {
        var base = archive(deviceA)
        base.book.lastReadPageIndex = 1; base.book.lastOpenedAt = at(5)
        func position(_ local: (Int, Double), _ remote: (Int, Double)) -> Int {
            var l = base, r = onDevice(base, deviceB)
            l.book.lastReadPageIndex = local.0; l.book.lastOpenedAt = at(local.1)
            r.book.lastReadPageIndex = remote.0; r.book.lastOpenedAt = at(remote.1)
            let result = merge(l, r, base).archive.book
            return result.lastReadPageIndex
        }
        #expect(position((5, 10), (9, 20)) == 9)
        #expect(position((5, 30), (9, 20)) == 5)
        #expect(position((5, 20), (9, 20)) == 9, "a tie goes to the account")
        #expect(position((5, 10), (1, 5)) == 5, "changed here only")
        // A page turned without a new opening date is still a change.
        #expect(position((1, 5), (8, 5)) == 8)
    }

    @Test func aNoteBothChangedMergesThreeWay() throws {
        let base = archive(deviceA, [note(1, .page(1), "A\nB\nC", ink: true, created: 5, modified: 6)])
        var local = base, remote = onDevice(base, deviceB)
        local.notes[0].text = "A\nB1\nC"; local.notes[0].modifiedAt = at(10)
        remote.notes[0].text = "A\nB\nC\nD"; remote.notes[0].modifiedAt = at(20); remote.notes[0].createdAt = at(4)
        let result = merge(local, remote, base)
        try result.archive.validateForReplacement()
        let merged = result.archive.notes[0]
        #expect(merged.id == uuid(1) && merged.text == "A\nB1\nC\nD")
        #expect(merged.createdAt == at(4) && merged.modifiedAt == at(20))
        #expect(merged.hasInk && merged.bandLayout == nil)
        let decision = result.noteDecisions[0]
        #expect(decision.source == .merged && decision.textChanged && decision.needsBandLayout)
        #expect(decision.local == .init(side: .local, noteID: uuid(1), paragraphMap: [0, 1, 2]))
        #expect(decision.remote == .init(side: .remote, noteID: uuid(1), paragraphMap: [0, nil, 2, 3]))
        #expect(decision.base == .init(side: .base, noteID: uuid(1), paragraphMap: [0, nil, 2]))
        #expect(result.needsPush && result.localChanges.notes.changed.count == 1)
    }

    @Test func aParagraphBothRewordedKeepsBothWordings() {
        let base = archive(deviceA, [note(1, .page(1), "A\nB\nC")])
        var local = base, remote = onDevice(base, deviceB)
        local.notes[0].text = "A\nB mine\nC"
        remote.notes[0].text = "A\nB theirs\nC"
        #expect(merge(local, remote, base).archive.notes[0].text == "A\nB mine\nB theirs\nC")
    }

    @Test func aNoteBothSidesEmptiedIsRemoved() {
        let base = archive(deviceA, [note(1, .page(1), "A\nB")])
        var local = base, remote = onDevice(base, deviceB)
        local.notes[0].text = "B"; local.notes[0].modifiedAt = at(8)
        remote.notes[0].text = "A"; remote.notes[0].modifiedAt = at(9)
        let result = merge(local, remote, base)
        #expect(result.archive.notes.isEmpty && result.noteDecisions.isEmpty)
        #expect(result.localChanges.notes.removed == [uuid(1)] && result.remoteChanges.notes.removed == [uuid(1)])
    }

    // MARK: Added on both sides

    @Test func notesBothSidesAddedOnOneTargetCombineUnderTheRemoteID() throws {
        let base = archive(deviceA)
        let local = archive(deviceA, [note(1, .page(3), "Mine", ink: true, created: 10, modified: 11)])
        let remote = archive(deviceB, [note(2, .page(3), "Theirs", book: deviceB, ink: true, created: 5, modified: 6)])
        let result = merge(local, remote, base)
        try result.archive.validateForReplacement()
        let merged = try #require(result.archive.notes.first)
        #expect(result.archive.notes.count == 1)
        #expect(merged.id == uuid(2) && merged.text == "Mine\nTheirs" && merged.bookID == deviceA)
        #expect(merged.createdAt == at(5) && merged.modifiedAt == at(11))
        let decision = result.noteDecisions[0]
        #expect(decision.source == .merged && decision.base == nil)
        #expect(decision.local == .init(side: .local, noteID: uuid(1), paragraphMap: [0]))
        #expect(decision.remote == .init(side: .remote, noteID: uuid(2), paragraphMap: [1]))
        #expect(result.localChanges.notes.removed == [uuid(1)] && result.localChanges.notes.added.map(\.id) == [uuid(2)])
        #expect(result.needsPush)
    }

    @Test func aNoteKeptByAnEditCombinesWithOneTheOtherSideRecreated() {
        let base = archive(deviceA, [note(1, .page(3), "Old\nShared")])
        let local = archive(deviceA, [note(1, .page(3), "Old\nShared\nMine", modified: 9)])
        let remote = archive(deviceB, [note(2, .page(3), "Fresh", book: deviceB)])
        let result = merge(local, remote, base)
        #expect(result.archive.notes.map(\.text) == ["Old\nShared\nMine\nFresh"])
        #expect(result.archive.notes.map(\.id) == [uuid(2)])
    }

    @Test func highlightsBothSidesMadeAtOnePlaceKeepTheRemoteOne() {
        let base = archive(deviceA)
        let local = archive(deviceA, [], [highlight(1, page: 2, color: .green)])
        let remote = archive(deviceB, [], [highlight(2, page: 2, color: .pink, book: deviceB)])
        let result = merge(local, remote, base)
        #expect(result.archive.highlights.map(\.id) == [uuid(2)])
        #expect(!result.needsPush && result.localChanges.highlights.removed == [uuid(1)])
        // A highlight both sides already had is never folded into a new one at its place.
        let known = archive(deviceA, [], [highlight(1, page: 2)])
        let remoteAdds = archive(deviceB, [], [highlight(1, page: 2, book: deviceB), highlight(2, page: 2, book: deviceB)])
        #expect(merge(known, remoteAdds, known).archive.highlights.count == 2)
    }

    @Test func headingsBothSidesAddedMatchAndLocalNotesAndChildrenFollow() throws {
        let base = archive(deviceA)
        let local = archive(deviceA, [note(5, .heading(user(1)), "On mine")], [], [],
                            [heading(1, "Aside", page: 10, parent: pdfChapter), heading(6, "Sub", page: 11, parent: user(1))])
        let remote = archive(deviceB, [note(7, .heading(user(2)), "On theirs", book: deviceB)], [], [],
                             [heading(2, " Aside ", page: 10, parent: pdfChapter, book: deviceB)])
        let result = merge(local, remote, base)
        try result.archive.validateForReplacement()
        #expect(result.headingIDRemap == [uuid(1): uuid(2)])
        #expect(result.archive.userHeadings.map(\.id) == [uuid(2), uuid(6)])
        #expect(result.archive.userHeadings[1].parent == user(2))
        #expect(result.archive.notes.map(\.id) == [uuid(7)])
        #expect(result.archive.notes[0].text == "On mine\nOn theirs")
        #expect(result.noteDecisions[0].local?.noteID == uuid(5))
    }

    @Test func bookmarksBothSidesAddedOnOnePageAreOne() {
        let local = archive(deviceA, [], [], [bookmark(1, page: 3, created: 10)])
        let remote = archive(deviceB, [], [], [bookmark(2, page: 3, book: deviceB, created: 5)])
        let result = merge(local, remote, archive(deviceA))
        #expect(result.archive.bookmarks == [bookmark(2, page: 3, created: 5)])
        #expect(!result.needsPush)
    }

    // MARK: Generated archives

    @Test func noBaseIsTodaysMerge() {
        for seed in UInt64(1)...200 {
            var generator = SyncGenerator(seed: seed)
            let shared = generator.archive(deviceA)
            var local = shared, remote = onDevice(shared, deviceB)
            generator.mutate(&local)
            generator.mutate(&remote)
            if seed % 3 == 0 { remote = generator.archive(deviceB) }
            let today = BookMerge.merge(local: local, incoming: remote)
            let result = merge(local, remote, nil)
            let comment: Comment = "seed \(seed)"
            #expect(result.archive == today.archive, comment)
            #expect(result.headingIDRemap == today.headingIDRemap, comment)
            #expect(result.noteDecisions == today.noteDecisions.map(NoteSyncDecision.init(joining:)), comment)
            #expect(result.localChanges == BookArchiveDiff(from: BookMerge.canonicalOrder(local), to: today.archive), comment)
        }
    }

    @Test func propertiesOverGeneratedTriples() throws {
        for seed in UInt64(1)...300 {
            var generator = SyncGenerator(seed: seed)
            let base = generator.archive(deviceA)
            var local = base, remote = onDevice(base, deviceB)
            generator.mutate(&local)
            generator.mutate(&remote)
            let comment: Comment = "seed \(seed)"
            try local.validateForReplacement()
            try remote.validateForReplacement()

            let result = merge(local, remote, base)
            let merged = result.archive
            do { try merged.validateForReplacement() } catch { Issue.record("seed \(seed): \(error)") }
            #expect(merged.book.id == deviceA && merged.book.fileName == local.book.fileName, comment)
            #expect(result.noteDecisions.map(\.noteID) == merged.notes.map(\.id), comment)
            #expect(result.localChanges == BookArchiveDiff(from: BookMerge.canonicalOrder(local), to: merged), comment)
            #expect(result.needsPush == (content(merged) != content(remote)), comment)

            // Every decision's maps cover their notes and point into the merged text.
            let localNotes = Dictionary(uniqueKeysWithValues: local.notes.map { ($0.id, $0) })
            let remoteNotes = Dictionary(uniqueKeysWithValues: remote.notes.map { ($0.id, $0) })
            for (note, decision) in zip(merged.notes, result.noteDecisions) {
                let paragraphs = NoteBandLayout.paragraphs(of: note.text)
                let sources = [decision.local, decision.remote].compactMap { $0 } + decision.absorbed
                for source in sources {
                    let side = source.side == .local ? localNotes[source.noteID] : remoteNotes[source.noteID]
                    let sideParagraphs = NoteBandLayout.paragraphs(of: side?.text ?? "")
                    #expect(source.paragraphMap.count == sideParagraphs.count, comment)
                    for (k, index) in source.paragraphMap.enumerated().dropLast() {
                        guard let index else { continue }
                        #expect(paragraphs.indices.contains(index), comment)
                        if paragraphs.indices.contains(index) { #expect(paragraphs[index] == sideParagraphs[k], comment) }
                    }
                }
                #expect(decision.needsBandLayout == (note.hasInk && note.bandLayout == nil), comment)
            }

            // A side equal to the base gives the other side.
            let adopt = merge(base, remote, base)
            #expect(content(adopt.archive) == content(remote) && !adopt.needsPush, comment)
            #expect(merge(local, onDevice(base, deviceB), base).archive == BookMerge.canonicalOrder(local), comment)

            // Idempotence: the result as base and remote (as pushed) changes nothing; the result
            // against the remote it came from, with that remote as base, is the result.
            let again = merge(merged, onDevice(merged, deviceC), merged)
            #expect(again.archive == merged && again.localChanges.isEmpty && !again.needsPush, comment)
            #expect(merge(merged, remote, remote).archive == merged, comment)

            // Input order does not matter.
            var rng = SeededGenerator(state: seed &* 31)
            var l = local, r = remote, b = base
            l.notes.shuffle(using: &rng); l.highlights.shuffle(using: &rng); l.userHeadings.shuffle(using: &rng)
            r.notes.shuffle(using: &rng); r.bookmarks.shuffle(using: &rng); r.userHeadings.shuffle(using: &rng)
            b.notes.shuffle(using: &rng); b.highlights.shuffle(using: &rng)
            #expect(merge(l, r, b).archive == merged, comment)
        }
    }

    @Test func generatedTriplesExerciseEveryRule() {
        var sources = Set<NoteSyncDecision.Source>(), withBase = 0, remaps = 0, deletions = 0, both = 0
        for seed in UInt64(1)...300 {
            var generator = SyncGenerator(seed: seed)
            let base = generator.archive(deviceA)
            var local = base, remote = onDevice(base, deviceB)
            generator.mutate(&local)
            generator.mutate(&remote)
            let result = merge(local, remote, base)
            sources.formUnion(result.noteDecisions.map(\.source))
            withBase += result.noteDecisions.filter { $0.base != nil }.count
            both += result.noteDecisions.filter { $0.source == .merged && $0.base == nil }.count
            remaps += result.headingIDRemap.count
            deletions += result.localChanges.notes.removed.count + result.remoteChanges.highlights.removed.count
        }
        #expect(sources == [.local, .remote, .merged])
        #expect(withBase > 0 && both > 0 && remaps > 0 && deletions > 0)
    }

    // MARK: Convergence

    @Test(arguments: [2, 3])
    func devicesSyncingInAnyOrderEndEqual(deviceCount: Int) {
        for seed in UInt64(1)...150 {
            var generator = SyncGenerator(seed: seed &* 1_000 + UInt64(deviceCount))
            let ids = [deviceA, deviceB, deviceC]
            let shared = generator.archive(deviceA)
            var simulation: Simulation
            if seed % 2 == 0 {
                // All devices start in step with the account.
                simulation = Simulation(devices: (0..<deviceCount).map { k in
                    let copy = onDevice(shared, ids[k])
                    return SimulatedDevice(local: copy, base: copy)
                }, remote: shared)
            } else {
                // Each device starts with its own records and joins.
                simulation = Simulation(devices: (0..<deviceCount).map { k in
                    var own = onDevice(shared, ids[k])
                    if k > 0 { generator.mutate(&own) }
                    return SimulatedDevice(local: own, base: nil)
                }, remote: nil)
            }
            let comment: Comment = "seed \(seed), \(deviceCount) devices"
            for _ in 0..<40 {
                let k = generator.int(0...deviceCount - 1)
                if generator.chance(0.55) {
                    generator.mutate(&simulation.devices[k].local)
                } else {
                    simulation.sync(k, comment)
                }
            }
            simulation.settle(using: &generator, comment)
        }
    }

    @Test func twoDevicesConvergeInEitherOrderAndInterleaved() {
        for seed in UInt64(1)...150 {
            var generator = SyncGenerator(seed: seed)
            let shared = generator.archive(deviceA)
            var a = onDevice(shared, deviceA), b = onDevice(shared, deviceB)
            generator.mutate(&a)
            generator.mutate(&b)
            let start = Simulation(devices: [SimulatedDevice(local: a, base: onDevice(shared, deviceA)),
                                             SimulatedDevice(local: b, base: onDevice(shared, deviceB))], remote: shared)
            for (name, order) in [("A B A", [0, 1, 0]), ("B A B", [1, 0, 1]), ("A A B A", [0, 0, 1, 0])] {
                var simulation = start
                let comment: Comment = "seed \(seed), \(name)"
                for k in order { simulation.sync(k, comment) }
                simulation.expectSettled(comment)
            }
            // Interleaved: each edits again between rounds.
            var simulation = start
            let comment: Comment = "seed \(seed), interleaved"
            simulation.sync(0, comment)
            generator.mutate(&simulation.devices[0].local)
            simulation.sync(1, comment)
            generator.mutate(&simulation.devices[1].local)
            simulation.sync(0, comment)
            simulation.sync(1, comment)
            simulation.sync(0, comment)
            simulation.expectSettled(comment)
        }
    }

    // MARK: Bad input

    @Test func badInputNeitherLoopsNorTraps() throws {
        let local = archive(deviceA, [
            note(1, .page(1), "X"), note(1, .page(2), "Same ID"), note(3, .page(1), "Same target"), note(4, .page(5), " \n"),
            note(8, .heading(user(30)), "On a cycle"),
        ], [highlight(10, page: 1), highlight(10, page: 2)], [bookmark(20, page: 1), bookmark(21, page: 1), bookmark(20, page: 2)], [
            heading(30, "A", page: 10, parent: user(31)), heading(31, "B", page: 11, parent: user(30)),
            heading(32, "C", page: 12, parent: user(32)), heading(30, "Again", page: 1), heading(33, "D", page: 13, parent: user(99)),
        ])
        var remote = archive(deviceB, [
            note(1, .page(1), "Y", book: deviceB), note(11, .page(1), "Same target", book: deviceB),
            note(12, .heading(user(40)), "On theirs", book: deviceB),
        ], [highlight(10, page: 1, color: .pink, book: deviceB)], [bookmark(20, page: 3, book: deviceB)], [
            heading(40, "A", page: 10, parent: user(41), book: deviceB), heading(41, "B", page: 11, parent: user(40), book: deviceB),
            heading(42, "C", page: 12, parent: user(42), book: deviceB), heading(43, "D", page: 13, parent: user(99), book: deviceB),
        ])
        remote.notes.append(note(1, .page(7), "Same ID elsewhere", book: deviceA))   // stray book ID
        let base = archive(deviceC, [note(1, .page(1), "Z", book: deviceC), note(1, .page(1), "Z again", book: deviceC)],
                           [], [bookmark(20, page: 1, book: deviceC), bookmark(22, page: 1, book: deviceC)],
                           [heading(30, "A", page: 10, parent: user(30), book: deviceC)])
        for (l, r, b) in [(local, remote, base), (remote, local, base), (local, remote, local), (local, local, remote)] {
            let result = merge(l, r, b)
            try result.archive.validateForReplacement()
            #expect(result.noteDecisions.map(\.noteID) == result.archive.notes.map(\.id))
            let again = merge(result.archive, result.archive, result.archive)
            #expect(again.archive == result.archive && !again.needsPush)
        }
    }
}

// MARK: - Simulated devices

private struct SimulatedDevice {
    var local: BookArchive
    var base: BookArchive?
}

/// Devices syncing one book through a shared account copy, one whole round at a time.
private struct Simulation {
    var devices: [SimulatedDevice]
    var remote: BookArchive?

    /// One round on device `k`: pull, merge against its base, apply, push when needed.
    @discardableResult
    mutating func sync(_ k: Int, _ comment: Comment) -> BookSyncMergeResult? {
        guard let remote else {
            self.remote = devices[k].local
            devices[k].base = devices[k].local
            return nil
        }
        let result = BookMerge.merge(local: devices[k].local, remote: remote, base: devices[k].base)
        do { try result.archive.validateForReplacement() } catch { Issue.record("\(comment): \(error)") }
        #expect(result.archive.book.id == devices[k].local.book.id, comment)
        if !result.needsPush { #expect(content(result.archive) == content(remote), comment) }
        devices[k].local = result.archive
        devices[k].base = result.archive
        if result.needsPush { self.remote = result.archive }
        return result
    }

    /// Every device syncs twice in random orders; then all are equal and a further round changes
    /// nothing.
    mutating func settle(using generator: inout SyncGenerator, _ comment: Comment) {
        for _ in 0..<2 {
            for k in Array(devices.indices).shuffled(using: &generator.rng) { sync(k, comment) }
        }
        expectSettled(comment)
    }

    /// All devices hold the account's content, and another round on each changes nothing.
    mutating func expectSettled(_ comment: Comment) {
        // A device that has not synced since the last push adopts it here, without pushing.
        for k in devices.indices {
            let result = sync(k, comment)
            #expect(result?.needsPush == false, comment)
        }
        guard let remote else { return }
        for device in devices { #expect(content(device.local) == content(remote), comment) }
        for k in devices.indices {
            let result = sync(k, comment)
            #expect(result?.localChanges.isEmpty == true && result?.needsPush == false, comment)
        }
    }
}

/// Random valid archives of one book and random edits to them, as a reader makes them.
private struct SyncGenerator {
    var rng: SeededGenerator
    var clock: Double = 100
    var counter = 0

    init(seed: UInt64) { rng = SeededGenerator(state: seed) }

    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    /// A later (or, sometimes, the same) moment.
    mutating func tick() -> Date { clock += Double(int(0...2)); return at(clock) }
    mutating func id() -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for k in 0..<16 { bytes[k] = UInt8.random(in: 0...255, using: &rng) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    mutating func paragraph() -> String {
        if chance(0.3) { return ["Alpha", "Beta", "", "Gamma"][int(0...3)] }
        counter += 1
        return "Paragraph \(counter)"
    }

    mutating func text() -> String {
        let paragraphs = (0..<int(1...4)).map { _ in paragraph() }
        let text = paragraphs.joined(separator: "\n") + (chance(0.2) ? "\n" : "")
        return text.allSatisfy(\.isWhitespace) ? "Delta" : text
    }

    mutating func edit(_ text: String) -> String {
        var paragraphs = NoteBandLayout.paragraphs(of: text)
        for _ in 0..<int(1...2) {
            switch int(0...3) {
            case 0: paragraphs.insert(paragraph(), at: int(0...paragraphs.count))
            case 1: paragraphs[int(0...paragraphs.count - 1)] += " edited"
            case 2: if paragraphs.count > 1 { paragraphs.remove(at: int(0...paragraphs.count - 1)) }
            default: paragraphs.append(paragraph())
            }
        }
        return paragraphs.joined(separator: "\n")
    }

    /// A highlight at one of a few places, so two devices sometimes make the same one.
    mutating func highlight(_ bookID: UUID) -> Highlight {
        let line = CGFloat(int(0...2))
        return Highlight(id: id(), bookID: bookID, pageIndex: int(0...3),
                         rects: [CGRect(x: 72, y: 700 - line * 14, width: 100 + line * 20, height: 12)],
                         color: HighlightColor.allCases[int(0...3)], text: ["matrix", "rank", "kernel"][Int(line)], createdAt: tick())
    }

    mutating func heading(_ bookID: UUID, among existing: [UserHeading]) -> UserHeading {
        let parent: HeadingAnchor? = !existing.isEmpty && chance(0.3)
            ? existing[int(0...existing.count - 1)].anchor : (chance(0.5) ? pdfChapter : nil)
        return UserHeading(id: id(), bookID: bookID, title: ["Aside", "Proof", "Recap"][int(0...2)], pageIndex: int(0...4),
                           parent: parent, createdAt: tick())
    }

    mutating func newNote(_ bookID: UUID, on target: NoteTarget) -> Note {
        let ink = chance(0.3)
        let created = tick()
        return Note(id: id(), bookID: bookID, target: target, text: text(), hasInk: ink, bandLayout: ink ? layout : nil,
                    createdAt: created, modifiedAt: created)
    }

    func targets(_ archive: BookArchive) -> [NoteTarget] {
        (0..<6).map { NoteTarget.page($0) } + archive.userHeadings.map { .heading($0.anchor) } + [.heading(pdfChapter)]
    }

    mutating func archive(_ bookID: UUID) -> BookArchive {
        var archive = BookArchive(book: makeBook(bookID, page: int(0...20), opened: Double(int(0...50))))
        for _ in 0..<int(0...4) { archive.userHeadings.append(heading(bookID, among: archive.userHeadings)) }
        for target in targets(archive) where chance(0.35) { archive.notes.append(newNote(bookID, on: target)) }
        for _ in 0..<int(0...4) { archive.highlights.append(highlight(bookID)) }
        archive.highlights = unique(archive.highlights)
        for page in 0..<6 where chance(0.3) { archive.bookmarks.append(Bookmark(id: id(), bookID: bookID, pageIndex: page, createdAt: tick())) }
        return archive
    }

    /// Highlights at distinct places (a reader cannot make the same one twice on one device).
    func unique(_ highlights: [Highlight]) -> [Highlight] {
        var kept: [Highlight] = []
        for h in highlights where !kept.contains(where: { BookMerge.isDuplicate($0, h) }) { kept.append(h) }
        return kept
    }

    /// A reader's edits on one device since its last sync.
    mutating func mutate(_ archive: inout BookArchive) {
        let bookID = archive.book.id
        // Headings: delete, rename, move, re-parent (never into a cycle), add.
        if !archive.userHeadings.isEmpty && chance(0.15) { archive.userHeadings.remove(at: int(0...archive.userHeadings.count - 1)) }
        for k in archive.userHeadings.indices {
            if chance(0.1) { archive.userHeadings[k].title = ["Aside", "Proof", "Recap", "Summary"][int(0...3)] }
            if chance(0.05) { archive.userHeadings[k].pageIndex = int(0...4) }
            if chance(0.05) { archive.userHeadings[k].parent = chance(0.5) ? pdfChapter : nil }
        }
        for _ in 0..<int(0...1) { archive.userHeadings.append(heading(bookID, among: archive.userHeadings)) }

        // Notes: delete, edit text or ink, add.
        archive.notes.removeAll { _ in chance(0.1) }
        for k in archive.notes.indices where chance(0.35) {
            archive.notes[k].text = edit(archive.notes[k].text)
            if chance(0.25) { archive.notes[k].hasInk.toggle() }
            archive.notes[k].bandLayout = archive.notes[k].hasInk ? layout : nil
            archive.notes[k].modifiedAt = tick()
        }
        archive.notes.removeAll(where: \.isEmpty)
        var taken = Set(archive.notes.map(\.target))
        for target in targets(archive) where !taken.contains(target) && chance(0.12) {
            archive.notes.append(newNote(bookID, on: target))
            taken.insert(target)
        }

        // Highlights: delete, recolour, add.
        archive.highlights.removeAll { _ in chance(0.1) }
        for k in archive.highlights.indices where chance(0.15) { archive.highlights[k].color = HighlightColor.allCases[int(0...3)] }
        for _ in 0..<int(0...1) { archive.highlights.append(highlight(bookID)) }
        archive.highlights = unique(archive.highlights)

        // Bookmarks: flag and unflag pages.
        for page in 0..<6 where chance(0.1) {
            if let index = archive.bookmarks.firstIndex(where: { $0.pageIndex == page }) {
                archive.bookmarks.remove(at: index)
            } else {
                archive.bookmarks.append(Bookmark(id: id(), bookID: bookID, pageIndex: page, createdAt: tick()))
            }
        }

        // The book: rename, read on.
        if chance(0.1) { archive.book.title = ["Linear Algebra", "LA", "Strang"][int(0...2)] }
        if chance(0.3) {
            archive.book.lastReadPageIndex = int(0...30)
            if chance(0.8) { archive.book.lastOpenedAt = tick() }
        }
    }
}
