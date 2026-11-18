import Foundation
import ReaderBackup
import ReaderCore
import Testing
@testable import ReaderSync

/// Every blob key a head names.
private func blobKeys(_ head: SyncHead, _ store: EncryptedSyncStore) throws -> Set<String> {
    Set(try head.references.blobs.map { try store.blobKey(sha256: $0.sha256) })
}

/// What must never be removed: every blob that a live head, a deleted head younger than 30 days
/// or a history object younger than 30 days names, and their PDFs.
private func expectNothingNeededIsGone(_ world: SimWorld, _ comment: Comment,
                                       sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let store = world.devices[0].syncStore
    let now = world.inner.now
    var needed = Set<String>()
    for listed in try await store.listHeads() {
        guard let head = try await store.readHead(bookKey: listed.bookKey)?.head else { continue }
        if head.isTombstone { continue }
        if head.isDeleted, let date = listed.lastModified, now.timeIntervalSince(date) >= SyncHousekeeping.deletedLifetime { continue }
        needed.formUnion(try blobKeys(head, store))
        needed.insert(try store.pdfKey(sha256: head.references.pdf.sha256))
    }
    for listed in try await store.allHistory() {
        guard let date = listed.lastModified, now.timeIntervalSince(date) < SyncHousekeeping.historyLifetime,
              let head = try await store.readHistory(bookKey: listed.bookKey, version: listed.version) else { continue }
        needed.formUnion(try blobKeys(head, store))
        needed.insert(try store.pdfKey(sha256: head.references.pdf.sha256))
    }
    let missing = needed.subtracting(world.inner.keys)
    #expect(missing.isEmpty, "\(comment): removed what is needed: \(missing.sorted())", sourceLocation: sourceLocation)
}

/// A blob nothing refers to, written now.
@discardableResult
private func orphanBlob(_ device: SimDevice, _ text: String) async throws -> String {
    let content = try await device.syncStore.putBlob(Data(text.utf8))
    return try device.syncStore.blobKey(sha256: content.sha256)
}

/// A PDF object nothing refers to, written now; returns its key and SHA-256.
private func orphanPDF(_ device: SimDevice, _ text: String) async throws -> (key: String, sha256: String) {
    let data = Data("%PDF-1.7 orphan \(text)\n%%EOF\n".utf8)
    let file = device.directory.deletingLastPathComponent().appendingPathComponent("orphan-\(UUID().uuidString).pdf")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let content = ContentDigest(of: data)
    try await device.syncStore.uploadPDF(fileAt: file, content: content)
    return (try device.syncStore.pdfKey(sha256: content.sha256), content.sha256)
}

/// The account's keys, but the clock probe.
private func accountKeys(_ world: SimWorld) -> Set<String> {
    Set(world.inner.keys).subtracting([SyncLayout.clockKey])
}

@Suite("Sync: housekeeping", .serialized)
struct SyncHousekeepingTests {
    // MARK: What goes

    @Test func historyOlderThanThirtyDaysGoesAndWhatOnlyItReferredToFollowsAfterSevenDays() async throws {
        let world = try await recoveryWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        let key = try bookKey0(a)
        // Old history: ink drawn and erased again (its blob then only in history).
        await editBook(a) { stroke(&$0, page: 5, "erased later") }
        _ = try await a.sync()
        await editBook(a) { $0.files[.pageInk(5)] = nil }
        _ = try await a.sync()
        let erasedInk = try await a.syncStore.blobKey(sha256: ContentDigest(of: TokenInk.encode(["erased later"])!).sha256)
        #expect(world.inner.keys.contains(erasedInk))
        world.inner.advance(by: 20 * day)
        await editBook(b) { setNote(&$0, rNoteN, "n0 later") }
        _ = try await b.sync()
        let recent = try await a.syncStore.history(bookKey: key).last!
        world.inner.advance(by: 15 * day)
        let old = try await a.syncStore.history(bookKey: key).filter { $0.version < recent.version }

        let run = try await a.engine.housekeep(snapshots: NoSnapshots())
        #expect(run.outcome == .finished, "\(run)")
        #expect(run.removedHistory == old.count && !old.isEmpty)
        #expect(try await a.syncStore.history(bookKey: key).map(\.version) == [recent.version])
        #expect(!world.inner.keys.contains(erasedInk), "only old history named it")
        try await expectNothingNeededIsGone(world, "after removing old history")
        var rng = SeededGenerator(state: 31)
        try await world.settle(&rng, "after housekeeping")
    }

    @Test func anOrphanedBlobGoesAfterSevenDaysAndAFreshOneStays() async throws {
        let world = try await recoveryWorld()
        let a = world.devices[0]
        let old = try await orphanBlob(a, "orphan, old")
        world.inner.advance(by: 6 * day)
        let young = try await orphanBlob(a, "orphan, six days younger")
        world.inner.advance(by: 1 * day + 60)
        // Not a blob name: never touched.
        world.inner.setObject(Data("x".utf8), at: SyncLayout.blobsPrefix + "not-a-blob", lastModified: InMemorySyncObjectStore.epoch)

        let run = try await a.engine.housekeep(snapshots: NoSnapshots())
        #expect(run.outcome == .finished && run.removedBlobs == 1, "\(run)")
        #expect(!world.inner.keys.contains(old))
        #expect(world.inner.keys.contains(young))
        #expect(world.inner.keys.contains(SyncLayout.blobsPrefix + "not-a-blob"))
        try await expectNothingNeededIsGone(world, "orphans")
        // The old blobs the live head names stay, whatever their age.
        let head = try #require(try await a.syncStore.readHead(bookKey: try bookKey0(a))?.head)
        #expect(try blobKeys(head, a.syncStore).isSubset(of: Set(world.inner.keys)))
    }

    @Test func aDeletedBookStaysRestorableForThirtyDaysThenBecomesATombstoneAndItsContentGoes() async throws {
        let world = try await recoveryWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        try await a.library.importBook(recoveryBook(UUID(), title: "Second"), pdf: Editor.pdfs[1],
                                       files: [.pageInk(2): TokenInk.encode(["second"])!])
        _ = try await a.sync()
        _ = try await b.sync()
        let key0 = try bookKey0(a), key1 = try a.bookKey(ContentDigest(of: Editor.pdfs[1]))
        let head1 = try #require(try await a.syncStore.readHead(bookKey: key1)?.head)
        // Book 1 deleted now; book 0 deleted 20 days later.
        await a.library.remove(try #require(await findBook(a, pdf: 1)?.0))
        _ = try await a.sync()
        world.inner.advance(by: 20 * day)
        await a.library.remove(try #require(await findBook(a, pdf: 0)?.0))
        _ = try await a.sync()
        let head0 = try #require(try await a.syncStore.readHead(bookKey: key0)?.head)
        world.inner.advance(by: 11 * day)

        let run = try await a.engine.housekeep(snapshots: NoSnapshots())
        #expect(run.outcome == .finished && run.tombstoned == 1, "\(run)")
        let tomb = try #require(try await a.syncStore.readHead(bookKey: key1)?.head)
        #expect(tomb.isTombstone && tomb.version == head1.version + 2 && tomb.deletedAt != nil)
        // Its content is gone (blobs, PDF); book 0, deleted 11 days ago, keeps everything.
        #expect(try blobKeys(head1, a.syncStore).isDisjoint(with: world.inner.keys))
        #expect(!world.inner.keys.contains(try a.syncStore.pdfKey(sha256: head1.references.pdf.sha256)))
        #expect(try blobKeys(head0, a.syncStore).isSubset(of: Set(world.inner.keys)))
        #expect(world.inner.keys.contains(try a.syncStore.pdfKey(sha256: head0.references.pdf.sha256)))
        #expect(try await b.engine.recentlyDeleted().map(\.bookKey) == [key0])
        try await expectNothingNeededIsGone(world, "tombstones")
        // A second run changes nothing (the tombstone stays a tombstone).
        world.inner.clearCalls()
        let again = try await a.engine.housekeep(snapshots: NoSnapshots())
        #expect(!again.removedAnything, "\(again)")
        #expect(storeWrites(world.inner.calls).map(\.key) == [SyncLayout.clockKey])
    }

    @Test func aPDFGoesOnlyWhenNothingAndNoSnapshotRefersToItAndTheSnapshotsWereRead() async throws {
        let world = try await recoveryWorld()
        let a = world.devices[0]
        let kept = try await orphanPDF(a, "in a snapshot")
        let lonely = try await orphanPDF(a, "in nothing")
        world.inner.advance(by: 6 * day)
        let young = try await orphanPDF(a, "young")
        world.inner.advance(by: 2 * day)
        let bookPDF = try a.syncStore.pdfKey(sha256: ContentDigest(of: Editor.pdfs[0]).sha256)

        // Snapshots that cannot all be read: no PDF goes (blobs may).
        var run = try await a.engine.housekeep(snapshots: FixedSnapshots(unreadable: true))
        #expect(run.pdfsLeftUnchecked && run.removedPDFs == 0, "\(run)")
        run = try await a.engine.housekeep(snapshots: nil)
        #expect(run.pdfsLeftUnchecked && run.removedPDFs == 0)
        #expect(Set([kept.key, lonely.key, young.key, bookPDF]).isSubset(of: Set(world.inner.keys)))

        run = try await a.engine.housekeep(snapshots: FixedSnapshots(pdfs: [kept.sha256]))
        #expect(run.outcome == .finished && run.removedPDFs == 1 && !run.pdfsLeftUnchecked, "\(run)")
        #expect(!world.inner.keys.contains(lonely.key))
        #expect(Set([kept.key, young.key, bookPDF]).isSubset(of: Set(world.inner.keys)))
    }

    // MARK: Never guessing

    @Test(arguments: ["damaged head", "damaged history", "newer writer", "newer format"])
    func anythingUnreadableMeansNothingIsRemoved(_ kind: String) async throws {
        let world = try await recoveryWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        // Plenty to remove: old history, an old orphan, an expired deletion, an old orphan PDF.
        try await a.library.importBook(recoveryBook(UUID(), title: "Second"), pdf: Editor.pdfs[1])
        _ = try await a.sync()
        await editBook(a) { stroke(&$0, page: 3, "a3") }
        _ = try await a.sync()
        await a.library.remove(try #require(await findBook(a, pdf: 1)?.0))
        _ = try await a.sync()
        try await orphanBlob(a, "orphan")
        _ = try await orphanPDF(a, "orphan")
        world.inner.advance(by: 40 * day)
        let key = try bookKey0(a)
        let headKey = try SyncLayout.headKey(bookKey: key)
        switch kind {
        case "damaged head":
            var bytes = try #require(world.inner.object(headKey)).data
            bytes[bytes.count - 1] ^= 0xFF
            world.inner.setObject(bytes, at: headKey, lastModified: world.inner.object(headKey)!.lastModified)
        case "damaged history":
            // A young history object that does not open.
            await editBook(b) { setNote(&$0, rNoteM, "m0 b") }
            _ = try await b.sync()
            let entry = try #require(try await a.syncStore.history(bookKey: key).last)
            let historyKey = try SyncLayout.historyKey(bookKey: key, version: entry.version)
            world.inner.setObject(Data("not a history object".utf8), at: historyKey)
        case "newer writer", "newer format":
            let read = try #require(try await a.syncStore.readHead(bookKey: key))
            var newer = read.head
            if kind == "newer writer" { newer.writerLevel = SyncFormat.writerLevel + 1 } else { newer.formatVersion += 1 }
            newer.version += 1
            newer.previousVersion = read.head.version
            newer.writeID = SyncHead.makeWriteID()
            try await a.syncStore.writeHead(newer, bookKey: key, condition: .ifMatch(eTag: read.eTag))
        default:
            Issue.record("unknown case")
        }
        let before = accountKeys(world)
        let beforeObjects = world.inner.contents.filter { $0.key != SyncLayout.clockKey }
        let run = try await a.engine.housekeep(snapshots: NoSnapshots())
        guard case .removedNothing(let hold) = run.outcome else {
            Issue.record("\(kind): removed things: \(run)")
            return
        }
        switch (kind, hold) {
        case ("newer writer", .newerWriter), ("damaged head", .unreadable), ("damaged history", .unreadable),
             ("newer format", .unreadable):
            break
        default:
            Issue.record("\(kind): \(hold)")
        }
        #expect(!run.removedAnything)
        #expect(accountKeys(world) == before)
        #expect(world.inner.contents.filter { $0.key != SyncLayout.clockKey } == beforeObjects, "nothing rewritten either")
    }

    @Test func aStoreWithoutDatesGetsNoRemovals() async throws {
        let world = try await recoveryWorld()
        let a = world.devices[0]
        struct Dateless: SyncObjectStore {
            let inner: InMemorySyncObjectStore
            func list(prefix: String) async throws -> [SyncObjectInfo] {
                try await inner.list(prefix: prefix).map { var o = $0; o.lastModified = nil; return o }
            }
            func get(_ key: String, maxBytes: Int) async throws -> SyncObjectData? { try await inner.get(key, maxBytes: maxBytes) }
            func put(_ data: Data, at key: String, metadata: [String: String], condition: SyncWriteCondition?) async throws -> String {
                try await inner.put(data, at: key, metadata: metadata, condition: condition)
            }
            func upload(fileAt file: URL, to key: String, metadata: [String: String]) async throws {
                try await inner.upload(fileAt: file, to: key, metadata: metadata)
            }
            func download(_ key: String, to file: URL) async throws { try await inner.download(key, to: file) }
            func head(_ key: String) async throws -> SyncObjectHead? {
                try await inner.head(key).map { var h = $0; h.lastModified = nil; return h }
            }
            func delete(_ key: String) async throws { try await inner.delete(key) }
        }
        try await orphanBlob(a, "orphan")
        world.inner.advance(by: 40 * day)
        let engine = SyncEngine(store: EncryptedSyncStore(store: Dateless(inner: world.inner), key: simulationKey,
                                                          temporaryDirectory: a.directory.appendingPathComponent("tmp2")),
                                library: a.library, inkMerger: a.merger, directory: a.directory, device: .init(id: a.id, name: a.name),
                                now: a.clock)
        let before = accountKeys(world)
        let run = try await engine.housekeep(snapshots: NoSnapshots())
        #expect(run.outcome == .removedNothing(.noStoreClock))
        #expect(accountKeys(world) == before)
    }

    // MARK: The race with a push

    /// A has decided blob X is unreferenced and old; B, about to push a head that names X, finds
    /// X stored. Without the reuse rule B would skip uploading it and A would then remove it.
    @Test(arguments: ["before the heads are read again", "after the heads were read again"])
    func housekeepingAndAPushThatReusesAnOldBlobNeverLoseIt(_ moment: String) async throws {
        let world = try await recoveryWorld(devices: 3)
        let (a, b, c) = (world.devices[0], world.devices[1], world.devices[2])
        let ink = TokenInk.encode(["x"])!
        let x = try await orphanBlob(a, String(decoding: ink, as: UTF8.self))
        world.inner.advance(by: 8 * day)
        // B draws exactly that ink: its push needs blob X, which is stored (and old).
        await editBook(b) { stroke(&$0, page: 5, "x") }
        let pushed = Collected<SyncReport>()
        await a.engine.setHousekeepingHook { step in
            let now: Bool
            switch step {
            case .readEverything: now = moment == "before the heads are read again"
            case .willRemoveBlobs(let keys): now = moment == "after the heads were read again" && keys.contains(x)
            default: now = false
            }
            guard now, pushed.values.isEmpty else { return }
            world.inner.clearCalls()
            pushed.append(try await b.sync())
        }
        let run = try await a.engine.housekeep(snapshots: NoSnapshots())
        let push = try #require(pushed.values.first, "B pushed in the middle of the run")
        #expect(push.count(.pushed) == 1)
        #expect(run.removedBlobs == 0, "\(moment): \(run)")
        #expect(world.inner.keys.contains(x), "\(moment): X is still there")
        #expect(try await c.sync().failures.isEmpty)
        #expect(TokenInk.decode(await findBook(c)?.1.files[.pageInk(5)]) == ["x"])
        var rng = SeededGenerator(state: 32)
        try await world.settle(&rng, "after the race")
    }

    @Test func theReuseRuleWritesAnOldBlobAgainSoItsDateIsFresh() async throws {
        let world = try SimWorld(deviceCount: 1)
        let a = world.devices[0]
        let x = try await orphanBlob(a, "x")
        world.inner.advance(by: 2 * day)
        world.inner.clearCalls()
        // Fresh enough (written within a day of the threshold): reused, not uploaded.
        try await a.syncStore.putBlob(Data("x".utf8), reuseIfWrittenAfter: world.inner.now.addingTimeInterval(-3 * day))
        #expect(!world.inner.calls.contains { $0.operation == .upload })
        // Older than the threshold: uploaded again, with today's date.
        try await a.syncStore.putBlob(Data("x".utf8), reuseIfWrittenAfter: world.inner.now.addingTimeInterval(-day))
        #expect(world.inner.calls.filter { $0.operation == .upload }.map(\.key) == [x])
        #expect(world.inner.object(x)?.lastModified == world.inner.now)
        // Without a threshold (the old behaviour, and what housekeeping's race needs to rule out).
        world.inner.advance(by: 9 * day)
        world.inner.clearCalls()
        try await a.syncStore.putBlob(Data("x".utf8))
        #expect(!world.inner.calls.contains { $0.operation == .upload })
    }

    /// The one moment rules cannot close: B refreshes X and writes its head between A's last look
    /// at X and A's removal. A pull then fails that book cleanly, and the device that holds X puts
    /// it back: its next housekeeping run, or its next push after a day.
    @Test(arguments: ["housekeeping", "push"])
    func aBlobLostInTheLastMomentFailsPullsCleanlyAndIsRepaired(_ repair: String) async throws {
        let world = try await recoveryWorld(devices: 3)
        let (a, b, c) = (world.devices[0], world.devices[1], world.devices[2])
        let ink = TokenInk.encode(["x"])!
        let x = try await orphanBlob(a, String(decoding: ink, as: UTF8.self))
        world.inner.advance(by: 8 * day)
        await editBook(b) { stroke(&$0, page: 5, "x") }
        world.inner.beforeNextCall(.delete, keyPrefix: x) { _ = try await b.sync() }
        let run = try await a.engine.housekeep(snapshots: NoSnapshots())
        #expect(run.removedBlobs == 1 && !world.inner.keys.contains(x), "the window: \(run)")

        // C's pull fails for that book, and nothing here changes.
        let before = await c.library.state
        let report = try await c.sync()
        let failure = try #require(report.failures.first?.failure?.syncError)
        #expect(failure == .objectNotFound(key: x))
        #expect(await c.library.state == before)

        switch repair {
        case "housekeeping":
            let fix = try await b.engine.housekeep(snapshots: NoSnapshots())
            #expect(fix.repairedBlobs == 1, "\(fix)")
        default:
            world.inner.advance(by: day + 60)
            await editBook(b) { setNote(&$0, rNoteN, "n0 b") }
            #expect(try await b.sync().count(.pushed) == 1)
        }
        #expect(world.inner.keys.contains(x))
        #expect(try await c.sync().failures.isEmpty)
        #expect(TokenInk.decode(await findBook(c)?.1.files[.pageInk(5)]) == ["x"])
        var rng = SeededGenerator(state: 33)
        try await world.settle(&rng, "after the repair")
    }

    @Test func aPullThatMeetsAMissingBlobChangesNothingAndTheHolderRepairsIt() async throws {
        let world = try await recoveryWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        await editBook(a) { stroke(&$0, page: 3, "y"); setNote(&$0, rNoteM, "m0 a") }
        _ = try await a.sync()
        let y = try a.syncStore.blobKey(sha256: ContentDigest(of: TokenInk.encode(["y"])!).sha256)
        world.inner.removeObject(y)
        let state = await b.library.state
        let baseFiles = b.directory.appendingPathComponent("bases")
        let bases = try FileManager.default.subpathsOfDirectory(atPath: baseFiles.path).sorted()
            .map { try? Data(contentsOf: baseFiles.appendingPathComponent($0)) }
        let report = try await b.sync()
        #expect(report.failures.count == 1)
        #expect(await b.library.state == state, "nothing changed here, not even the note that was there to take")
        #expect(try FileManager.default.subpathsOfDirectory(atPath: baseFiles.path).sorted()
            .map { try? Data(contentsOf: baseFiles.appendingPathComponent($0)) } == bases)
        let fix = try await a.engine.housekeep(snapshots: NoSnapshots())
        #expect(fix.repairedBlobs == 1)
        #expect(try await b.sync().failures.isEmpty)
        #expect(await findBook(b)?.1.archive.notes.first { $0.id == rNoteM }?.text == "m0 a")
    }

    // MARK: Safe to cut off; bounded

    /// A world with something of every kind to remove, and what must stay.
    private func messyWorld() async throws -> SimWorld {
        let world = try await recoveryWorld()
        let (a, b) = (world.devices[0], world.devices[1])
        try await a.library.importBook(recoveryBook(UUID(), title: "Second"), pdf: Editor.pdfs[1],
                                       files: [.pageInk(1): TokenInk.encode(["second"])!])
        _ = try await a.sync()
        _ = try await b.sync()
        await editBook(a) { stroke(&$0, page: 4, "a4") }
        _ = try await a.sync()
        await a.library.remove(try #require(await findBook(a, pdf: 1)?.0))
        _ = try await a.sync()
        try await orphanBlob(a, "orphan 1")
        try await orphanBlob(a, "orphan 2")
        _ = try await orphanPDF(a, "orphan")
        world.inner.advance(by: 35 * day)
        try await orphanBlob(a, "young orphan")
        await editBook(b) { setNote(&$0, rNoteM, "m0 recent") }
        _ = try await b.sync()
        _ = try await a.sync()
        world.inner.advance(by: 60)
        return world
    }

    @Test func housekeepingCutOffAtAnyStoreCallLosesNothingAndTheNextRunFinishes() async throws {
        let world = try await messyWorld()
        let a = world.devices[0]
        let start = try await world.checkpoint()
        let clean = try await a.engine.housekeep(snapshots: NoSnapshots())
        #expect(clean.outcome == .finished && clean.removedBlobs >= 3 && clean.tombstoned == 1 && clean.removedPDFs >= 2,
                "\(clean)")
        let finalKeys = accountKeys(world)
        let calls = clean.calls
        #expect(calls >= 20, "a run of \(calls) calls")
        for index in 0..<calls {
            for timing in [InMemorySyncObjectStore.FaultTiming.beforeEffect, .afterEffect] {
                try await world.restore(start)
                a.faulting.arm(at: index, timing)
                _ = try? await a.engine.housekeep(snapshots: NoSnapshots())
                a.faulting.reset()
                try await expectNothingNeededIsGone(world, "cut off at call \(index) \(timing)")
                let next = try await a.engine.housekeep(snapshots: NoSnapshots())
                #expect(next.outcome == .finished, "after call \(index) \(timing): \(next)")
                #expect(accountKeys(world) == finalKeys, "after call \(index) \(timing)")
            }
        }
        try await world.restore(start)
        var rng = SeededGenerator(state: 34)
        _ = try await a.engine.housekeep(snapshots: NoSnapshots())
        try await world.settle(&rng, "after housekeeping")
    }

    @Test func housekeepingCutOffBetweenAnyTwoStepsLosesNothing() async throws {
        let world = try await messyWorld()
        let a = world.devices[0]
        let start = try await world.checkpoint()
        let steps = Collected<SyncHousekeepingStep>()
        await a.engine.setHousekeepingHook { steps.append($0) }
        _ = try await a.engine.housekeep(snapshots: NoSnapshots())
        let finalKeys = accountKeys(world)
        struct Stop: Error {}
        for index in 0..<steps.values.count {
            try await world.restore(start)
            let seen = Collected<Bool>()
            await a.engine.setHousekeepingHook { _ in
                if seen.values.count == index { seen.append(true); throw Stop() }
                seen.append(false)
            }
            await #expect(throws: Stop.self) { try await a.engine.housekeep(snapshots: NoSnapshots()) }
            await a.engine.setHousekeepingHook(nil)
            try await expectNothingNeededIsGone(world, "stopped at step \(index)")
            _ = try await a.engine.housekeep(snapshots: NoSnapshots())
            #expect(accountKeys(world) == finalKeys, "stopped at step \(index)")
        }
    }

    @Test func aRunStopsAtItsLimitAndLaterRunsCarryOn() async throws {
        let world = try await messyWorld()
        let a = world.devices[0]
        let start = try await world.checkpoint()
        _ = try await a.engine.housekeep(snapshots: NoSnapshots())
        let finalKeys = accountKeys(world)
        try await world.restore(start)

        let limits = SyncHousekeepingLimits(maximumCalls: 12, batchSize: 1)
        var runs = 0
        var outcome = SyncHousekeepingReport.Outcome.stoppedAtLimit
        while outcome == .stoppedAtLimit && runs < 40 {
            let run = try await a.engine.housekeep(limits: limits, snapshots: NoSnapshots())
            #expect(run.calls <= 12)
            outcome = run.outcome
            runs += 1
            try await expectNothingNeededIsGone(world, "run \(runs)")
        }
        #expect(outcome == .finished && runs > 1, "\(runs) runs")
        #expect(accountKeys(world) == finalKeys)
    }

    @Test func aRoundAndHousekeepingNeverRunTogether() async throws {
        let world = try await recoveryWorld()
        let a = world.devices[0]
        let started = Collected<Bool>()
        await a.engine.setStepHook { step in
            guard case .roundStarted = step, started.values.isEmpty else { return }
            started.append(true)
            await #expect(throws: SyncEngineError.roundInProgress) { try await a.engine.housekeep(snapshots: NoSnapshots()) }
        }
        _ = try await a.sync()
        #expect(started.values == [true])
    }
}
