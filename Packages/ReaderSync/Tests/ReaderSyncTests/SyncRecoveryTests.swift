import Foundation
import ReaderBackup
import ReaderCore
import Testing
@testable import ReaderSync

let rNoteN = UUID(uuidString: "22222222-0000-4000-8000-00000000000A")!
let rNoteM = UUID(uuidString: "22222222-0000-4000-8000-00000000000B")!
let day: TimeInterval = 86_400

/// A book with two notes, as device `id` imported it.
func recoveryBook(_ id: UUID, title: String = "Shared") -> BookArchive {
    BookArchive(book: Book(id: id, title: title, fingerprint: "fp-shared", fileName: "shared.pdf", pageCount: 10,
                           fileSize: 100, addedAt: simulationEpoch),
                notes: [Note(id: rNoteN, bookID: id, target: .page(0), text: "n0", createdAt: simulationEpoch),
                        Note(id: rNoteM, bookID: id, target: .page(2), text: "m0", createdAt: simulationEpoch)])
}

/// The device's book made from PDF `pdf`.
func findBook(_ device: SimDevice, pdf: Int = 0) async -> (UUID, FakeLibrary.Book)? {
    let content = ContentDigest(of: Editor.pdfs[pdf])
    for id in await device.library.bookIDs {
        if let book = await device.library.book(id), book.pdf == content { return (id, book) }
    }
    return nil
}

func editBook(_ device: SimDevice, pdf: Int = 0, _ body: (inout FakeLibrary.Book) -> Void) async {
    guard let (id, book) = await findBook(device, pdf: pdf) else { Issue.record("no book \(pdf) on \(device.name)"); return }
    var edited = book
    body(&edited)
    await device.library.put(id, edited)
}

func setNote(_ book: inout FakeLibrary.Book, _ note: UUID, _ text: String) {
    guard let k = book.archive.notes.firstIndex(where: { $0.id == note }) else { return }
    book.archive.notes[k].text = text
    book.archive.notes[k].modifiedAt = book.archive.notes[k].modifiedAt.addingTimeInterval(1)
}

func stroke(_ book: inout FakeLibrary.Book, page: Int, _ token: String) {
    var tokens = TokenInk.decode(book.files[.pageInk(page)])
    tokens.insert(token)
    book.files[.pageInk(page)] = TokenInk.encode(tokens)
}

/// Devices sharing the book from PDF 0 (two notes, ink on page 1), agreed.
func recoveryWorld(devices: Int = 2) async throws -> SimWorld {
    let world = try SimWorld(deviceCount: devices)
    try await world.devices[0].library.importBook(recoveryBook(UUID()), pdf: Editor.pdfs[0],
                                                  files: [.pageInk(1): TokenInk.encode(["s0"])!])
    _ = try await world.devices[0].sync()
    for device in world.devices.dropFirst() { _ = try await device.sync() }
    try await world.expectEqualAndValid("shared start")
    return world
}

func bookKey0(_ device: SimDevice) throws -> String { try device.bookKey(ContentDigest(of: Editor.pdfs[0])) }

func storeWrites(_ calls: [InMemorySyncObjectStore.Call]) -> [InMemorySyncObjectStore.Call] {
    calls.filter { [.put, .upload, .delete].contains($0.operation) }
}

@Suite("Sync: Recently Deleted and earlier versions")
struct SyncRecoveryTests {
    // MARK: Recently Deleted

    @Test func aDeletedBookIsListedOnEveryDeviceAndComesBackEverywhereWithItsNotesAndInk() async throws {
        let world = try await recoveryWorld(devices: 3)
        let (a, b, c) = (world.devices[0], world.devices[1], world.devices[2])
        await editBook(a) { setNote(&$0, rNoteN, "n0 before deleting"); stroke(&$0, page: 1, "a1") }
        _ = try await a.sync()
        _ = try await b.sync()
        // C goes offline now, with its copy as it is (an old base, unchanged).
        _ = try await c.sync()

        let deletedAt = world.inner.now
        await a.library.remove(try #require(await findBook(a)?.0))
        #expect(try await a.sync().count(.deletedInAccount) == 1)
        #expect(try await b.sync().count(.deletedHere) == 1)
        #expect(await findBook(b) == nil)

        // Listed on B (which never deleted anything itself): title, when, which device, days left.
        world.inner.advance(by: 3 * day)
        let listed = try await b.engine.recentlyDeleted()
        #expect(listed.count == 1)
        let entry = try #require(listed.first)
        #expect(entry.title == "Shared" && entry.deviceName == a.name && entry.deviceID == a.id)
        #expect(entry.deletedAt == deletedAt)
        #expect(entry.daysLeft(now: world.inner.now) == 27)

        // B restores it: the head is live again above every version seen, and the book is here at once.
        let before = try #require(try await b.syncStore.readHead(bookKey: try bookKey0(b)))
        let report = try await b.engine.restoreDeleted(bookKey: entry.bookKey)
        #expect(report?.action == .createdHere)
        let head = try #require(try await b.syncStore.readHead(bookKey: try bookKey0(b)))
        #expect(!head.head.isDeleted && head.head.version == before.head.version + 1)
        #expect(head.head.deviceID == b.id)
        let restored = try #require(await findBook(b))
        #expect(restored.1.archive.notes.first { $0.id == rNoteN }?.text == "n0 before deleting")
        #expect(TokenInk.decode(restored.1.files[.pageInk(1)]) == ["s0", "a1"])
        #expect(try await b.engine.recentlyDeleted().isEmpty)

        // A, which deleted it, gets it back; C, offline throughout with an old base, keeps its copy
        // and takes the content.
        #expect(try await a.sync().count(.createdHere) == 1)
        _ = try await c.sync()
        var rng = SeededGenerator(state: 21)
        try await world.settle(&rng, "restored from Recently Deleted")
        #expect(await findBook(c)?.1.archive.notes.first { $0.id == rNoteN }?.text == "n0 before deleting")
        #expect(try await a.content().count == 1)
    }

    @Test func aDeviceThatNeverHadTheBookRestoresIt() async throws {
        let world = try await recoveryWorld(devices: 2)
        let (a, b) = (world.devices[0], world.devices[1])
        await a.library.remove(try #require(await findBook(a)?.0))
        _ = try await a.sync()
        _ = try await b.sync()

        // A new device joins after the deletion: no base, no copy.
        let late = try SimWorld(deviceCount: 1)
        let c = SimDevice(name: "late", index: 7, inner: world.inner, root: late.root.url)
        _ = try await c.sync()
        #expect(try await c.content().isEmpty)
        let listed = try await c.engine.recentlyDeleted()
        #expect(listed.map(\.title) == ["Shared"])
        #expect(try await c.engine.restoreDeleted(bookKey: listed[0].bookKey)?.action == .createdHere)
        #expect(await findBook(c)?.1.archive.notes.count == 2)
        _ = try await a.sync()
        _ = try await b.sync()
        try await world.expectEqualAndValid("restored by a new device")
        #expect(try await c.content() == (try await a.content()))
    }

    @Test func aDeviceWithAnOldBaseAndAnEditMeetsTheRestoredBookAndKeepsBoth() async throws {
        let world = try await recoveryWorld(devices: 3)
        let (a, b, c) = (world.devices[0], world.devices[1], world.devices[2])
        // C edits offline; A deletes; B restores; C comes back: its edit and the account's book merge.
        await editBook(c) { setNote(&$0, rNoteM, "m0 c") }
        await a.library.remove(try #require(await findBook(a)?.0))
        _ = try await a.sync()
        _ = try await b.sync()
        let key = try bookKey0(b)
        try await b.engine.restoreDeleted(bookKey: key)
        await editBook(b) { setNote(&$0, rNoteN, "n0 b") }
        #expect(try await b.sync().count(.pushed) == 1)
        #expect(try await c.sync().count(.merged) == 1)
        var rng = SeededGenerator(state: 22)
        try await world.settle(&rng, "old base after a restore")
        #expect(await findBook(a)?.1.archive.notes.first { $0.id == rNoteM }?.text == "m0 c")
        #expect(await findBook(a)?.1.archive.notes.first { $0.id == rNoteN }?.text == "n0 b")
    }

    @Test func restoringIsRefusedCleanlyWhenTheContentIsGoneOrTheBookIsNotDeleted() async throws {
        let world = try await recoveryWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        let key = try bookKey0(a)
        await #expect(throws: SyncRestoreError.notDeleted) { try await b.engine.restoreDeleted(bookKey: key) }
        await a.library.remove(try #require(await findBook(a)?.0))
        _ = try await a.sync()
        _ = try await b.sync()

        // Its ink blob is gone: refused, and nothing in the account changes.
        let head = try #require(try await b.syncStore.readHead(bookKey: key)?.head)
        let ink = try #require(head.references.pageInk.first?.content)
        world.inner.removeObject(try b.syncStore.blobKey(sha256: ink.sha256))
        let objects = world.inner.contents
        await #expect(throws: SyncRestoreError.contentGone) { try await b.engine.restoreDeleted(bookKey: key) }
        #expect(world.inner.contents == objects)
        #expect(await findBook(b) == nil)
        // Pull-only: refused before anything.
        await #expect(throws: SyncRestoreError.needsFullAccess) { try await b.engine.restoreDeleted(bookKey: key, mode: .pullOnly) }
    }

    @Test func aTombstoneCannotBeRestoredAndIsNotListed() async throws {
        let world = try await recoveryWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        await a.library.remove(try #require(await findBook(a)?.0))
        _ = try await a.sync()
        world.inner.advance(by: 31 * day)
        let run = try await a.engine.housekeep(snapshots: NoSnapshots())
        #expect(run.tombstoned == 1)
        #expect(try await b.engine.recentlyDeleted().isEmpty)
        await #expect(throws: SyncRestoreError.noLongerRestorable) { try await b.engine.restoreDeleted(bookKey: try bookKey0(b)) }
    }

    // MARK: Tombstones and devices that were away

    @Test func aDeviceWithAnOldUnchangedBaseDeletesItsCopyOnMeetingATombstone() async throws {
        let world = try await recoveryWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        // B is away (old base, unchanged) for over 30 days; A deletes; housekeeping tombstones.
        await a.library.remove(try #require(await findBook(a)?.0))
        _ = try await a.sync()
        world.inner.advance(by: 40 * day)
        #expect(try await a.engine.housekeep(snapshots: NoSnapshots()).tombstoned == 1)
        let tomb = try #require(try await a.syncStore.readHead(bookKey: try bookKey0(a))?.head)
        #expect(tomb.isTombstone && tomb.writerLevel == SyncFormat.tombstoneLevel)
        #expect(try await b.sync().count(.deletedHere) == 1)
        #expect(try await b.content().isEmpty)
        var rng = SeededGenerator(state: 23)
        try await world.settle(&rng, "after a tombstone")
    }

    @Test func aDeviceWithAnOldBaseAndAnEditPutsItsCopyBackOverATombstone() async throws {
        let world = try await recoveryWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        await editBook(b) { setNote(&$0, rNoteM, "m0 edited while away"); stroke(&$0, page: 4, "b4") }
        await a.library.remove(try #require(await findBook(a)?.0))
        _ = try await a.sync()
        world.inner.advance(by: 40 * day)
        let run = try await a.engine.housekeep(snapshots: NoSnapshots())
        #expect(run.tombstoned == 1 && run.removedBlobs > 0, "\(run)")

        // The edit wins: B's copy goes back up as it is (nothing to merge with), and A gets it.
        let report = try await b.sync()
        #expect(report.failures.isEmpty && report.count(.keptOverDeletionInAccount) == 1, "\(report)")
        let head = try #require(try await b.syncStore.readHead(bookKey: try bookKey0(b))?.head)
        #expect(!head.isDeleted && head.version > 2)
        #expect(try await a.sync().count(.createdHere) == 1)
        #expect(await findBook(a)?.1.archive.notes.first { $0.id == rNoteM }?.text == "m0 edited while away")
        #expect(TokenInk.decode(await findBook(a)?.1.files[.pageInk(4)]) == ["b4"])
        var rng = SeededGenerator(state: 24)
        try await world.settle(&rng, "an edit over a tombstone")
    }

    @Test func aDeviceWithNoBaseMeetsATombstone() async throws {
        let world = try await recoveryWorld()
        let a = world.devices[0]
        await a.library.remove(try #require(await findBook(a)?.0))
        _ = try await a.sync()
        world.inner.advance(by: 40 * day)
        _ = try await a.engine.housekeep(snapshots: NoSnapshots())

        // A new device with nothing: nothing happens. One that imported the same PDF on its own:
        // its copy goes up as it is.
        let late = try SimWorld(deviceCount: 1)
        let empty = SimDevice(name: "empty", index: 8, inner: world.inner, root: late.root.url)
        world.inner.clearCalls()
        #expect(try await empty.sync().books.isEmpty)
        #expect(storeWrites(world.inner.calls).isEmpty)
        let own = SimDevice(name: "own", index: 9, inner: world.inner, root: late.root.url)
        var mine = recoveryBook(UUID(), title: "Mine")
        mine.notes = [Note(bookID: mine.book.id, target: .page(5), text: "own copy", createdAt: simulationEpoch)]
        try await own.library.importBook(mine, pdf: Editor.pdfs[0])
        #expect(try await own.sync().count(.keptOverDeletionInAccount) == 1)
        #expect(try await a.sync().count(.createdHere) == 1)
        #expect(await findBook(a)?.1.archive.notes.map(\.text) == ["own copy"])
    }

    // MARK: Earlier versions

    @Test func earlierVersionsAreListedNewestFirstWithWhatTheyHeld() async throws {
        let world = try await recoveryWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        let key = try bookKey0(a)
        world.inner.advance(by: 3600)
        await editBook(a) { stroke(&$0, page: 3, "a3") }
        _ = try await a.sync()
        world.inner.advance(by: 3600)
        await editBook(a) { $0.archive.notes.removeAll { $0.id == rNoteM } }
        _ = try await a.sync()
        world.inner.advance(by: 3600)

        let versions = try await b.engine.versions(bookKey: key)
        let current = try #require(try await b.syncStore.readHead(bookKey: key)?.head.version)
        #expect(versions.map(\.version) == [current - 1, current - 2])
        #expect(versions.allSatisfy { $0.deviceName == a.name })
        #expect(versions[0].summary == SyncContentSummary(notes: 2, highlights: 0, bookmarks: 0, headings: 0, inkedPages: 2))
        #expect(versions[1].summary == SyncContentSummary(notes: 2, highlights: 0, bookmarks: 0, headings: 0, inkedPages: 1))

        // Versions written close together are one entry (the last of the run).
        await editBook(a) { setNote(&$0, rNoteN, "n0 1") }
        _ = try await a.sync()
        world.inner.advance(by: 60)
        await editBook(a) { setNote(&$0, rNoteN, "n0 2") }
        _ = try await a.sync()
        let again = try await b.engine.versions(bookKey: key)
        #expect(again.count == versions.count + 1, "\(again.map(\.version))")
    }

    @Test func restoringAnEarlierVersionTravelsToTheOtherDevicesWithItsRemovals() async throws {
        let world = try await recoveryWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        let key = try bookKey0(a)
        world.inner.advance(by: 3600)
        // After the version to go back to: a new note, more ink, a note removed, a highlight.
        let added = UUID()
        await editBook(a) { book in
            book.archive.notes.append(Note(id: added, bookID: book.archive.book.id, target: .page(7), text: "added later",
                                           createdAt: simulationEpoch))
            book.archive.notes.removeAll { $0.id == rNoteM }
            stroke(&book, page: 1, "later")
            stroke(&book, page: 6, "p6")
            book.archive.book.title = "Renamed later"
        }
        _ = try await a.sync()
        _ = try await b.sync()
        try await world.expectEqualAndValid("before the restore")

        let target = try #require(try await b.engine.versions(bookKey: key).first)
        let planned = Collected<SyncVersionRestorePlan>()
        let plan = try await b.engine.restoreVersion(bookKey: key, version: target.version) { planned.append($0) }
        #expect(planned.values.count == 1 && planned.values.first == plan)
        #expect(plan?.restored.notes == 2 && plan?.current.notes == 2 && plan?.restored.inkedPages == 1)
        // Here at once, as an ordinary local change: nothing written to the account yet.
        let here = try #require(await findBook(b)).1
        #expect(Set(here.archive.notes.map(\.id)) == [rNoteN, rNoteM])
        #expect(here.archive.book.title == "Shared")
        #expect(TokenInk.decode(here.files[.pageInk(1)]) == ["s0"] && here.files[.pageInk(6)] == nil)

        // The next round pushes it; A takes it as ordinary changes, removals included.
        #expect(try await b.sync().count(.pushed) == 1)
        #expect(try await a.sync().count(.pulled) == 1)
        let there = try #require(await findBook(a)).1
        #expect(Set(there.archive.notes.map(\.id)) == [rNoteN, rNoteM])
        #expect(there.files[.pageInk(6)] == nil && TokenInk.decode(there.files[.pageInk(1)]) == ["s0"])
        #expect(there.archive.book.title == "Shared")
        var rng = SeededGenerator(state: 25)
        try await world.settle(&rng, "after restoring an earlier version")
        // History was not rewritten: the restore is a new version on top.
        let versions = try await a.engine.versions(bookKey: key)
        #expect(versions.contains { $0.title == "Renamed later" })
    }

    @Test func restoringAnEarlierVersionIsRefusedCleanly() async throws {
        let world = try await recoveryWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        let key = try bookKey0(a)
        world.inner.advance(by: 3600)
        await editBook(a) { stroke(&$0, page: 2, "a2") }
        _ = try await a.sync()
        _ = try await b.sync()
        let target = try #require(try await b.engine.versions(bookKey: key).first)
        let before = await b.library.state

        // The reader is working in it.
        let id = try #require(await findBook(b)?.0)
        await b.library.setBusy(id, [.note(rNoteN)])
        await #expect(throws: SyncRestoreError.bookBusy) {
            try await b.engine.restoreVersion(bookKey: key, version: target.version) { _ in }
        }
        await b.library.clearBusy()
        // The safety copy failed: nothing changes.
        struct NoCopy: Error {}
        await #expect(throws: NoCopy.self) {
            try await b.engine.restoreVersion(bookKey: key, version: target.version) { _ in throw NoCopy() }
        }
        #expect(await b.library.state == before)
        // A version that is not kept.
        await #expect(throws: SyncRestoreError.versionNotFound) {
            try await b.engine.restoreVersion(bookKey: key, version: 999) { _ in }
        }
        // Its records are gone.
        let entry = try #require(try await b.syncStore.readHistory(bookKey: key, version: target.version))
        world.inner.removeObject(try b.syncStore.blobKey(sha256: entry.references.records.sha256))
        await #expect(throws: SyncRestoreError.contentGone) {
            try await b.engine.restoreVersion(bookKey: key, version: target.version) { _ in }
        }
        #expect(await b.library.state == before)
    }
}

/// Snapshots that refer to the given PDFs (or cannot be read).
struct FixedSnapshots: SyncSnapshotReferences {
    var pdfs: Set<String> = []
    var unreadable = false

    func referencedPDFs() async throws -> Set<String> {
        struct Unreadable: Error {}
        if unreadable { throw Unreadable() }
        return pdfs
    }
}

/// No snapshots at all.
struct NoSnapshots: SyncSnapshotReferences {
    func referencedPDFs() async throws -> Set<String> { [] }
}
