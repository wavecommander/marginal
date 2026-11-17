import Foundation
import ReaderBackup
import ReaderCore
import Testing
@testable import ReaderSync

private let noteN = UUID(uuidString: "11111111-0000-4000-8000-00000000000A")!
private let noteM = UUID(uuidString: "11111111-0000-4000-8000-00000000000B")!

/// A book with two notes and a page of ink, as device `id` imported it.
private func sharedBook(_ id: UUID, title: String = "Shared") -> BookArchive {
    BookArchive(book: Book(id: id, title: title, fingerprint: "fp-shared", fileName: "shared.pdf", pageCount: 10,
                           fileSize: 100, addedAt: simulationEpoch),
                notes: [Note(id: noteN, bookID: id, target: .page(0), text: "n0", createdAt: simulationEpoch),
                        Note(id: noteM, bookID: id, target: .page(2), text: "m0", createdAt: simulationEpoch)])
}

/// The device's book made from PDF `pdf`.
private func find(_ device: SimDevice, pdf: Int = 0) async -> (UUID, FakeLibrary.Book)? {
    let content = ContentDigest(of: Editor.pdfs[pdf])
    for id in await device.library.bookIDs {
        if let book = await device.library.book(id), book.pdf == content { return (id, book) }
    }
    return nil
}

/// Edits the device's book as the reader would.
private func edit(_ device: SimDevice, pdf: Int = 0, _ body: (inout FakeLibrary.Book) -> Void) async {
    guard let (id, book) = await find(device, pdf: pdf) else { Issue.record("no book \(pdf) on \(device.name)"); return }
    var edited = book
    body(&edited)
    await device.library.put(id, edited)
}

private func text(_ device: SimDevice, _ note: UUID, pdf: Int = 0) async -> String? {
    await find(device, pdf: pdf)?.1.archive.notes.first { $0.id == note }?.text
}

private func setText(_ book: inout FakeLibrary.Book, _ note: UUID, _ text: String) {
    guard let k = book.archive.notes.firstIndex(where: { $0.id == note }) else { return }
    book.archive.notes[k].text = text
    book.archive.notes[k].modifiedAt = book.archive.notes[k].modifiedAt.addingTimeInterval(1)
}

private func addStroke(_ book: inout FakeLibrary.Book, page: Int, _ token: String) {
    var tokens = TokenInk.decode(book.files[.pageInk(page)])
    tokens.insert(token)
    book.files[.pageInk(page)] = TokenInk.encode(tokens)
}

/// Two (or more) devices that share the book from PDF 0 and agree on it.
private func sharedWorld(devices: Int = 2) async throws -> SimWorld {
    let world = try SimWorld(deviceCount: devices)
    let a = world.devices[0]
    try await a.library.importBook(sharedBook(UUID()), pdf: Editor.pdfs[0], files: [.pageInk(1): TokenInk.encode(["s0"])!])
    _ = try await a.sync()
    for device in world.devices.dropFirst() { _ = try await device.sync() }
    try await world.expectEqualAndValid("shared start")
    return world
}

private func writes(_ calls: [InMemorySyncObjectStore.Call]) -> [InMemorySyncObjectStore.Call] {
    calls.filter { [.put, .upload, .delete].contains($0.operation) }
}

@Suite("Sync engine: behaviour")
struct SyncEngineBehaviourTests {
    // MARK: Races and the two merge hazards

    @Test func concurrentRoundsOnOneBookHaveOneWinnerAndTheLoserMergesFromItsUntouchedCopy() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        let headKey = try SyncLayout.headKey(bookKey: try a.bookKey(ContentDigest(of: Editor.pdfs[0])))
        // B rewords N and pushes; A rewords N too, offline.
        await edit(b) { setText(&$0, noteN, "n0 b") }
        _ = try await b.sync()
        await edit(a) { setText(&$0, noteN, "n0 a") }

        // A merges with B's "n0 b"; just before A's head write, B rewords again and wins the write.
        let raced = Collected<Bool>()
        await a.engine.setStepHook { step in
            guard case .wroteIntent = step, raced.values.isEmpty else { return }
            raced.append(true)
            await edit(b) { setText(&$0, noteN, "n0 b2") }
            let report = try await b.sync()
            #expect(report.count(.pushed) == 1)
        }
        world.inner.clearCalls()
        let report = try await a.sync()
        #expect(report.failures.isEmpty && report.count(.merged) == 1)
        let headPuts = world.inner.calls.filter { $0.operation == .put && $0.key == headKey }
        #expect(headPuts.map(\.outcome) == [.succeeded, .preconditionFailed, .succeeded], "\(headPuts)")

        // A merged again from its own untouched "n0 a" and the old base "n0": B's stale "n0 b" is gone.
        #expect(await text(a, noteN) == "n0 a\nn0 b2")
        _ = try await b.sync()
        var rng = SeededGenerator(state: 3)
        try await world.settle(&rng, "after the race")
        #expect(await text(b, noteN) == "n0 a\nn0 b2")
    }

    @Test func aRoundCutOffAfterApplyingButBeforeTheBaseMovesDoesNotRepeatParagraphs() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        await edit(b) { setText(&$0, noteN, "n0 b") }
        _ = try await b.sync()
        await edit(a) { setText(&$0, noteN, "n0 a") }

        // A merges, pushes and applies "n0 a / n0 b", and is cut off before its base moves.
        let interrupter = StepInterrupter(stopAt: nil)
        await a.engine.setStepHook { step in
            if case .appliedLocally = step { throw StepInterrupter.Interrupted() }
            try await interrupter.hook()(step)
        }
        await #expect(throws: StepInterrupter.Interrupted.self) { try await a.sync() }
        #expect(await text(a, noteN) == "n0 a\nn0 b")

        // Meanwhile B takes the merge and rewords its paragraph again.
        _ = try await b.sync()
        await edit(b) { setText(&$0, noteN, "n0 a\nn0 b2") }
        _ = try await b.sync()

        // A comes back: its applied copy is not merged against the old base, so "n0 b" does not return.
        a.restart()
        let report = try await a.sync()
        #expect(report.failures.isEmpty)
        #expect(await text(a, noteN) == "n0 a\nn0 b2")
        var rng = SeededGenerator(state: 4)
        try await world.settle(&rng, "after the cut-off round")
    }

    @Test func aPutThatTimedOutButCommittedIsReconciledAsWon() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        let bookKey = try a.bookKey(ContentDigest(of: Editor.pdfs[0]))
        let headKey = try SyncLayout.headKey(bookKey: bookKey)
        let before = try #require(try await a.syncStore.readHead(bookKey: bookKey)).head.version
        await edit(a) { setText(&$0, noteM, "m0 a") }

        world.inner.injectFault(.afterEffect, on: .put, keyPrefix: SyncLayout.headsPrefix)
        world.inner.clearCalls()
        let report = try await a.sync()
        #expect(report.failures.isEmpty && report.count(.pushed) == 1)
        let headPuts = world.inner.calls.filter { $0.operation == .put && $0.key == headKey }
        #expect(headPuts.map(\.outcome) == [.faultAfterEffect], "retried into a second version: \(headPuts)")
        #expect(try await a.syncStore.readHead(bookKey: bookKey)?.head.version == before + 1)
        #expect(try await a.syncStore.historyVersions(bookKey: bookKey) == Array(1...before))

        // A's base is the head it wrote: its next round is a no-op; B pulls the change.
        world.inner.clearCalls()
        #expect(try await a.sync().changedAnything == false)
        #expect(writes(world.inner.calls).isEmpty)
        #expect(try await b.sync().count(.pulled) == 1)
        #expect(await text(b, noteM) == "m0 a")
    }

    @Test func theAppTouchingInkFieldsAfterAMergeTakesOneMorePushAndThenGoesQuiet() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        // N has ink everywhere.
        await edit(a) { book in
            book.files[.noteInk(noteN)] = TokenInk.encode(["k0"])
            if let k = book.archive.notes.firstIndex(where: { $0.id == noteN }) {
                book.archive.notes[k].hasInk = true
                book.archive.notes[k].bandLayout = testLayout
            }
        }
        _ = try await a.sync()
        _ = try await b.sync()
        // A erases N's ink; B edits N's text. The record merge keeps `hasInk` (either side has
        // it) but the ink merge leaves none, so the app clears it after applying.
        await edit(a) { book in
            book.files[.noteInk(noteN)] = nil
            if let k = book.archive.notes.firstIndex(where: { $0.id == noteN }) {
                book.archive.notes[k].hasInk = false
                book.archive.notes[k].bandLayout = nil
                book.archive.notes[k].modifiedAt = book.archive.notes[k].modifiedAt.addingTimeInterval(5)
            }
        }
        await edit(b) { setText(&$0, noteN, "n0\nb") }
        _ = try await a.sync()
        let merge = try await b.sync()
        #expect(merge.count(.merged) == 1)
        let touched = await find(b)!.1.archive.notes.first { $0.id == noteN }
        #expect(touched?.hasInk == false && touched?.text == "n0\nb")
        // One more push carries the touched fields; then all is quiet.
        #expect(try await b.sync().count(.pushed) == 1)
        var rng = SeededGenerator(state: 5)
        try await world.settle(&rng, "after the touch")
    }

    @Test func aSecondRoundWhileOneRunsIsRefused() async throws {
        let world = try await sharedWorld()
        let a = world.devices[0]
        let engine = a.engine
        await engine.setStepHook { step in
            guard case .roundStarted = step else { return }
            await #expect(throws: SyncEngineError.roundInProgress) { try await engine.sync(joinConfirmed: true) }
        }
        _ = try await a.sync()
    }

    // MARK: Join

    @Test func joiningPreviewsCountsRemovesNothingAndWaitsForConfirmation() async throws {
        let world = try SimWorld(deviceCount: 2)
        let (a, b) = (world.devices[0], world.devices[1])
        var editor = Editor(seed: 99)
        for (device, pdfs) in [(a, [0, 1]), (b, [0, 2])] {
            for pdf in pdfs {
                var (archive, files) = editor.newBook(pdf: pdf, prefix: device.name)
                editor.mutate(&archive, &files, prefix: device.name)
                archive.notes.append(Note(bookID: archive.book.id, target: .page(9), text: "\(device.name) only",
                                          createdAt: simulationEpoch))
                try await device.library.importBook(archive, pdf: Editor.pdfs[pdf], files: files)
            }
        }
        let aBefore = try await a.content(), bBefore = try await b.content()

        // The first device to join an empty account still confirms.
        #expect(try await b.engine.needsJoinConfirmation())
        await #expect(throws: SyncEngineError.joinConfirmationRequired) { try await b.engine.sync() }
        #expect(writes(world.inner.calls).isEmpty)
        _ = try await b.engine.sync(joinConfirmed: true)
        #expect(try await b.engine.needsJoinConfirmation() == false)

        #expect(try await a.engine.needsJoinConfirmation())
        #expect(try await a.engine.joinPreview() == SyncJoinPreview(onlyHere: 1, onlyInAccount: 1, inBoth: 1))
        world.inner.clearCalls()
        await #expect(throws: SyncEngineError.joinConfirmationRequired) { try await a.engine.sync() }
        await #expect(throws: SyncEngineError.joinConfirmationRequired) { try await a.engine.sync(mode: .pullOnly) }
        #expect(writes(world.inner.calls).isEmpty)
        #expect(try await a.content() == aBefore)

        let joined = try await a.engine.sync(joinConfirmed: true)
        #expect(joined.count(.joined) == 1 && joined.count(.createdHere) == 1 && joined.count(.uploadedNew) == 1)
        _ = try await b.sync()
        var rng = SeededGenerator(state: 6)
        try await world.settle(&rng, "join")

        // Nothing was removed on either side: every record each had is still there.
        let after = try await a.content()
        for before in [aBefore, bBefore] {
            for (key, book) in before {
                let now = try #require(after[key])
                for note in book.archive.notes {
                    let merged = try #require(now.archive.notes.first { $0.target == note.target }, "lost \(note.text)")
                    for paragraph in NoteBandLayout.paragraphs(of: note.text) where !paragraph.isEmpty {
                        #expect(NoteBandLayout.paragraphs(of: merged.text).contains(paragraph))
                    }
                }
                #expect(Set(book.archive.bookmarks.map(\.pageIndex)).isSubset(of: Set(now.archive.bookmarks.map(\.pageIndex))))
                #expect(book.archive.highlights.allSatisfy { h in now.archive.highlights.contains { BookMerge.isDuplicate($0, h) } })
                for (fileKey, data) in book.files where fileKey != .cover {
                    #expect(TokenInk.decode(data).isSubset(of: TokenInk.decode(now.files[fileKey])))
                }
            }
        }
        #expect(try await a.engine.needsJoinConfirmation() == false)
    }

    // MARK: Deletions

    @Test(arguments: [true, false])
    func aDeletionTravels(fromFirst: Bool) async throws {
        let world = try await sharedWorld()
        let (deleter, other) = fromFirst ? (world.devices[0], world.devices[1]) : (world.devices[1], world.devices[0])
        let id = try #require(await find(deleter)?.0)
        await deleter.library.remove(id)
        #expect(try await deleter.sync().count(.deletedInAccount) == 1)
        #expect(try await other.sync().count(.deletedHere) == 1)
        #expect(await find(other) == nil)
        let bookKey = try deleter.bookKey(ContentDigest(of: Editor.pdfs[0]))
        #expect(try await deleter.syncStore.readHead(bookKey: bookKey)?.head.isDeleted == true)
        var rng = SeededGenerator(state: 7)
        try await world.settle(&rng, "deletion")
        #expect(try await deleter.content().isEmpty)
        #expect(try await other.content().isEmpty)
    }

    @Test func anEditHereBeatsADeletionInTheAccount() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        await a.library.remove(try #require(await find(a)?.0))
        _ = try await a.sync()
        await edit(b) { setText(&$0, noteM, "m0 kept") }
        #expect(try await b.sync().count(.keptOverDeletionInAccount) == 1)
        #expect(try await a.sync().count(.createdHere) == 1)
        #expect(await text(a, noteM) == "m0 kept")
        var rng = SeededGenerator(state: 8)
        try await world.settle(&rng, "edit beats deletion in the account")
    }

    @Test func anEditInTheAccountBeatsADeletionHere() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        await edit(b) { setText(&$0, noteM, "m0 kept") }
        _ = try await b.sync()
        await a.library.remove(try #require(await find(a)?.0))
        #expect(try await a.sync().count(.restoredHere) == 1)
        #expect(await text(a, noteM) == "m0 kept")
        var rng = SeededGenerator(state: 9)
        try await world.settle(&rng, "edit beats deletion here")
    }

    @Test func aBookWithNoBaseIsNeverDeletedHere() async throws {
        let world = try await sharedWorld(devices: 2)
        let a = world.devices[0]
        await a.library.remove(try #require(await find(a)?.0))
        _ = try await a.sync()

        // A third iPad, never synced, imported the same PDF on its own and joins.
        let late = try SimWorld(deviceCount: 3)
        let c = SimDevice(name: "late", index: 9, inner: world.inner, root: late.root.url)
        var own = sharedBook(UUID(), title: "Mine")
        own.notes = [Note(bookID: own.book.id, target: .page(4), text: "c only", createdAt: simulationEpoch)]
        try await c.library.importBook(own, pdf: Editor.pdfs[0])
        let report = try await c.engine.sync(joinConfirmed: true)
        #expect(report.count(.keptOverDeletionInAccount) == 1)
        #expect(await text(c, own.notes[0].id) == "c only")
        // Its copy is in the account again, live, and the other iPads get it back.
        #expect(try await a.sync().count(.createdHere) == 1)
        #expect(await find(a)?.1.archive.notes.map(\.text) == ["c only"])
    }

    @Test func aBookDeletedElsewhereIsKeptWhileTheReaderWorksInIt() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        await a.library.remove(try #require(await find(a)?.0))
        _ = try await a.sync()
        let bID = try #require(await find(b)?.0)
        await b.library.setBusy(bID, [.page(3)])
        let report = try await b.sync()
        #expect(report.books.first?.skipped == [.busy([.page(3)])])
        #expect(await find(b) != nil)
        await b.library.clearBusy()
        #expect(try await b.sync().count(.deletedHere) == 1)
    }

    @Test func anEmptiedAccountIsFilledAgainWithoutLosingAnything() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        await edit(a) { setText(&$0, noteN, "n0 a") }
        await edit(b) { setText(&$0, noteM, "m0 b"); addStroke(&$0, page: 1, "b1") }
        for key in world.inner.keys { world.inner.removeObject(key) }

        #expect(try await a.sync().count(.uploadedNew) == 1)
        #expect(try await b.sync().count(.merged) == 1)
        var rng = SeededGenerator(state: 13)
        try await world.settle(&rng, "refilled")
        #expect(await text(b, noteN) == "n0 a")
        #expect(await text(a, noteM) == "m0 b")
        #expect(TokenInk.decode(await find(a)!.1.files[.pageInk(1)]) == ["s0", "b1"])
    }

    @Test func onlyOneOfTwoBooksWithTheSamePDFSyncs() async throws {
        let world = try await sharedWorld()
        let a = world.devices[0]
        let first = try #require(await find(a)?.0)
        var copy = sharedBook(UUID(), title: "Copy")
        copy.notes = []
        try await a.library.importBook(copy, pdf: Editor.pdfs[0])
        let report = try await a.sync()
        let ids = [first, copy.book.id].sorted { $0.uuidString < $1.uuidString }
        #expect(report.books.contains { $0.bookID == ids[1] && $0.skipped == [.duplicatePDF(of: ids[0])] })
    }

    // MARK: Modes and versions

    @Test func aPullOnlyRoundWritesNothingAndLocalChangesWait() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        await edit(b) { setText(&$0, noteM, "m0 b") }
        _ = try await b.sync()
        await edit(a) { setText(&$0, noteN, "n0 a"); addStroke(&$0, page: 3, "a1") }

        world.inner.clearCalls()
        let report = try await a.sync(.pullOnly)
        #expect(writes(world.inner.calls).isEmpty, "\(writes(world.inner.calls))")
        #expect(report.count(.pulled) == 1 && report.isPending)
        #expect(report.books.first?.skipped == [.pullOnly])
        #expect(await text(a, noteM) == "m0 b")
        #expect(await text(a, noteN) == "n0 a")
        // Still waiting on the next pull-only round, and still writing nothing.
        world.inner.clearCalls()
        #expect(try await a.sync(.pullOnly).isPending)
        #expect(writes(world.inner.calls).isEmpty)

        #expect(try await a.sync().count(.pushed) == 1)
        _ = try await b.sync()
        #expect(await text(b, noteN) == "n0 a")
        var rng = SeededGenerator(state: 10)
        try await world.settle(&rng, "after pull-only")
    }

    @Test func aHeadFromANewerAppIsPulledButNeverPushed() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        let bookKey = try a.bookKey(ContentDigest(of: Editor.pdfs[0]))
        await edit(a) { setText(&$0, noteM, "m0 newer") }
        _ = try await a.sync()
        // A newer app rewrites the head at a higher writer level.
        let read = try #require(try await a.syncStore.readHead(bookKey: bookKey))
        var newer = read.head
        newer.writerLevel = SyncFormat.writerLevel + 1
        newer.version += 1
        newer.previousVersion = read.head.version
        newer.writeID = SyncHead.makeWriteID()
        try await a.syncStore.writeHead(newer, bookKey: bookKey, condition: .ifMatch(eTag: read.eTag))

        await edit(b) { setText(&$0, noteN, "n0 b") }
        world.inner.clearCalls()
        let report = try await b.sync()
        #expect(report.books.first?.action == .pulled)
        #expect(report.books.first?.skipped == [.readOnly(requiredLevel: SyncFormat.writerLevel + 1)])
        #expect(writes(world.inner.calls).isEmpty)
        #expect(await text(b, noteM) == "m0 newer")
        #expect(await text(b, noteN) == "n0 b")
        #expect(try await b.syncStore.readHead(bookKey: bookKey)?.head == newer)
        // Deleting it here does not push either.
        await b.library.remove(try #require(await find(b)?.0))
        world.inner.clearCalls()
        #expect(try await b.sync().isPending)
        #expect(writes(world.inner.calls).isEmpty)
    }

    @Test func aHeadInANewerFormatStopsTheRoundWithNothingChanged() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        // Another book, changed in the account, which B must not take either.
        try await a.library.importBook(sharedBook(UUID(), title: "Other"), pdf: Editor.pdfs[1])
        _ = try await a.sync()
        _ = try await b.sync()
        await edit(a, pdf: 1) { setText(&$0, noteM, "m0 changed") }
        _ = try await a.sync()
        let bookKey = try a.bookKey(ContentDigest(of: Editor.pdfs[0]))
        let read = try #require(try await a.syncStore.readHead(bookKey: bookKey))
        var future = read.head
        future.formatVersion = SyncFormat.formatVersion + 1
        future.version += 1
        future.previousVersion = read.head.version
        future.writeID = SyncHead.makeWriteID()
        try await a.syncStore.writeHead(future, bookKey: bookKey, condition: .ifMatch(eTag: read.eTag))

        await edit(b) { setText(&$0, noteN, "n0 b") }
        let before = try await b.content()
        world.inner.clearCalls()
        await #expect(throws: SyncEngineError.formatTooNew(formatVersion: SyncFormat.formatVersion + 1)) { try await b.sync() }
        #expect(writes(world.inner.calls).isEmpty)
        #expect(try await b.content() == before)
        #expect(await text(b, noteM, pdf: 1) == "m0")
    }

    @Test func anOlderHeadThanSeenIsRefused() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        let bookKey = try a.bookKey(ContentDigest(of: Editor.pdfs[0]))
        let headKey = try SyncLayout.headKey(bookKey: bookKey)
        await edit(a) { setText(&$0, noteM, "m0 1") }
        _ = try await a.sync()
        let older = try #require(world.inner.object(headKey))
        await edit(a) { setText(&$0, noteM, "m0 2") }
        _ = try await a.sync()
        _ = try await b.sync()
        #expect(await text(b, noteM) == "m0 2")

        // The store serves the older head again.
        world.inner.setObject(older.data, at: headKey, metadata: older.metadata)
        let report = try await b.sync()
        let failure = try #require(report.failures.first?.failure)
        guard case .rollback(_, let highest, let offered) = failure.syncError else {
            Issue.record("not a rollback: \(failure)")
            return
        }
        #expect(offered == highest - 1)
        #expect(await text(b, noteM) == "m0 2")
    }

    // MARK: Busy surfaces

    @Test func aBusyNoteIsLeftAloneThenMergedNextRoundWithNothingLost() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        let bookKey = try a.bookKey(ContentDigest(of: Editor.pdfs[0]))
        // A is typing in N; B changes N and M.
        await edit(a) { setText(&$0, noteN, "n0\na typing") }
        let aID = try #require(await find(a)?.0)
        await a.library.setBusy(aID, [.note(noteN)])
        await edit(b) { setText(&$0, noteN, "n0\nb"); setText(&$0, noteM, "m0 b") }
        _ = try await b.sync()

        let report = try await a.sync()
        #expect(report.books.first?.skipped == [.busy([.note(noteN)])])
        #expect(await text(a, noteN) == "n0\na typing")   // left alone here
        #expect(await text(a, noteM) == "m0 b")            // the rest merged
        // The head does not claim A's version of N.
        let head = try #require(try await a.syncStore.readHead(bookKey: bookKey)).head
        let records = try SyncRecords.decode(try await a.syncStore.blob(head.references.records), key: "records")
        #expect(records.notes.first { $0.id == noteN }?.text == "n0\nb")

        // Next round, N merges with B's change kept.
        await a.library.clearBusy()
        _ = try await a.sync()
        let merged = try #require(await text(a, noteN))
        #expect(NoteBandLayout.paragraphs(of: merged).contains("b") && NoteBandLayout.paragraphs(of: merged).contains("a typing"))
        var rng = SeededGenerator(state: 11)
        try await world.settle(&rng, "busy note")
    }

    @Test func aBusyPageIsLeftAloneThenMergedNextRoundWithNothingLost() async throws {
        let world = try await sharedWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        let aID = try #require(await find(a)?.0)
        await edit(a) { addStroke(&$0, page: 1, "a-stroke") }
        await a.library.setBusy(aID, [.page(1)])
        await edit(b) { addStroke(&$0, page: 1, "b-stroke"); addStroke(&$0, page: 2, "b-other") }
        _ = try await b.sync()

        let report = try await a.sync()
        #expect(report.books.first?.skipped == [.busy([.page(1)])])
        #expect(TokenInk.decode(await find(a)!.1.files[.pageInk(1)]) == ["s0", "a-stroke"])
        #expect(TokenInk.decode(await find(a)!.1.files[.pageInk(2)]) == ["b-other"])

        await a.library.clearBusy()
        _ = try await a.sync()
        #expect(TokenInk.decode(await find(a)!.1.files[.pageInk(1)]) == ["s0", "a-stroke", "b-stroke"])
        var rng = SeededGenerator(state: 12)
        try await world.settle(&rng, "busy page")
    }
}
