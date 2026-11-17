import Foundation
import ReaderBackup
import ReaderCore
import Testing
@testable import ReaderSync

/// A round cut off at every store call (before and after it takes effect) and between every two
/// of the engine's own steps, then retried: the devices end in the same state as without the
/// interruption.
@Suite("Sync engine: faults and interruptions")
struct SyncEngineFaultTests {
    /// Devices that agree, then each does offline work so that device 0's next round has every
    /// kind of work: a merge, a pull, a deletion each way, an edit over a deletion, a book to
    /// make here and one to upload.
    static func scenario(deviceCount: Int, seed: UInt64) async throws -> (SimWorld, Editor) {
        let world = try SimWorld(deviceCount: deviceCount)
        var editor = Editor(seed: seed)
        let a = world.devices[0], b = world.devices[1]
        func importBook(_ device: SimDevice, _ pdf: Int) async throws {
            var (archive, files) = editor.newBook(pdf: pdf, prefix: device.name)
            editor.mutate(&archive, &files, prefix: device.name)
            try await device.library.importBook(archive, pdf: Editor.pdfs[pdf], files: files)
        }
        try await importBook(a, 0)
        try await importBook(b, 0)
        try await importBook(a, 1)
        try await importBook(b, 2)
        try await importBook(a, 3)
        if deviceCount > 2 { try await importBook(world.devices[2], 2) }
        var rng = SeededGenerator(state: seed)
        try await world.settle(&rng, "scenario seed \(seed) setup")

        func book(_ device: SimDevice, _ pdf: Int) async -> (UUID, FakeLibrary.Book)? {
            for id in await device.library.bookIDs {
                if let book = await device.library.book(id), book.pdf == ContentDigest(of: Editor.pdfs[pdf]) { return (id, book) }
            }
            return nil
        }
        func edit(_ device: SimDevice, _ pdf: Int) async {
            guard let (id, found) = await book(device, pdf) else { return }
            var book = found
            editor.mutate(&book.archive, &book.files, prefix: device.name)
            // Always a note both sides change, so merges are three-way on text and ink.
            if let k = book.archive.notes.indices.first {
                book.archive.notes[k].text = editor.edit(book.archive.notes[k].text)
                book.archive.notes[k].modifiedAt = editor.tick()
            }
            var tokens = TokenInk.decode(book.files[.pageInk(1)])
            tokens.insert(editor.token("\(device.name)s"))
            book.files[.pageInk(1)] = TokenInk.encode(tokens)
            await device.library.put(id, book)
        }

        // The others work and sync first.
        await edit(b, 0)
        await edit(b, 2)
        if let (id, _) = await book(b, 3) { await b.library.remove(id) }
        try await importBook(b, 4)
        _ = try await b.sync()
        if deviceCount > 2 {
            await edit(world.devices[2], 0)
            await edit(world.devices[2], 2)
            _ = try await world.devices[2].sync()
        }
        // Device 0's own offline work.
        await edit(a, 0)
        await edit(a, 3)
        if let (id, _) = await book(a, 1) { await a.library.remove(id) }
        try await importBook(a, 5)
        return (world, editor)
    }

    /// Device 0 finishes, then every device syncs in a fixed order until quiet.
    static func finish(_ world: SimWorld, _ comment: Comment) async throws -> [[String: BookContent]] {
        let a = world.devices[0]
        a.restart()
        _ = try await a.sync()
        var quiet = false
        for _ in 0..<10 where !quiet {
            quiet = true
            for device in world.devices {
                let report = try await device.sync()
                for failure in report.failures { Issue.record("\(comment): \(device.name) \(failure.failure!.description)") }
                if report.changedAnything || report.isPending { quiet = false }
            }
        }
        #expect(quiet, "\(comment): never went quiet")
        try await world.expectEqualAndValid(comment)
        world.inner.clearCalls()
        for device in world.devices { _ = try await device.sync() }
        let writes = world.inner.calls.filter { [.put, .upload, .delete].contains($0.operation) }
        #expect(writes.isEmpty, "\(comment): a settled round wrote \(writes.map(\.key))")
        var contents: [[String: BookContent]] = []
        for device in world.devices { contents.append(try await device.content()) }
        return contents
    }

    @Test(arguments: [(2, UInt64(11)), (2, 12), (3, 13)])
    func aFaultAtEveryStoreCallOfARoundStillEndsAsWithout(deviceCount: Int, seed: UInt64) async throws {
        let (world, _) = try await Self.scenario(deviceCount: deviceCount, seed: seed)
        let a = world.devices[0]
        let start = try await world.checkpoint()

        // Without a fault.
        a.faulting.reset()
        let clean = try await a.sync()
        let calls = a.faulting.callCount
        #expect(clean.failures.isEmpty)
        for action in [SyncBookAction.merged, .deletedInAccount, .keptOverDeletionInAccount, .createdHere, .uploadedNew] {
            #expect(clean.count(action) == 1, "\(action) in \(clean.books.map(\.action))")
        }
        let expected = try await Self.finish(world, "clean, seed \(seed)")

        var failedRounds = 0
        for index in 0..<calls {
            for timing in [InMemorySyncObjectStore.FaultTiming.beforeEffect, .afterEffect] {
                try await world.restore(start)
                let comment: Comment = "seed \(seed), \(deviceCount) devices, fault \(timing) call \(index) of \(calls)"
                a.faulting.arm(at: index, timing)
                do {
                    let report = try await a.sync()
                    if !report.failures.isEmpty { failedRounds += 1 }
                } catch {
                    failedRounds += 1
                }
                a.faulting.reset()
                let contents = try await Self.finish(world, comment)
                #expect(contents == expected, "\(comment): ended differently from the round without the fault")
            }
        }
        #expect(failedRounds > calls / 2)
    }

    @Test(arguments: [(2, UInt64(21)), (3, 22)])
    func aRoundInterruptedBetweenAnyTwoStepsStillEndsAsWithout(deviceCount: Int, seed: UInt64) async throws {
        let (world, _) = try await Self.scenario(deviceCount: deviceCount, seed: seed)
        let a = world.devices[0]
        let start = try await world.checkpoint()

        let counter = StepInterrupter(stopAt: nil)
        await a.engine.setStepHook(counter.hook())
        _ = try await a.sync()
        let steps = counter.steps
        #expect(steps > 15)
        let expected = try await Self.finish(world, "clean, seed \(seed)")

        var interrupted = 0
        for stop in 0..<steps {
            for cancel in [false, true] {
                try await world.restore(start)
                let comment: Comment = "seed \(seed), \(deviceCount) devices, \(cancel ? "cancelled" : "cut off") at step \(stop) of \(steps)"
                let interrupter = StepInterrupter(stopAt: stop)
                let hook = interrupter.hook()
                await a.engine.setStepHook(cancel ? { step in
                    do { try await hook(step) } catch { withUnsafeCurrentTask { $0?.cancel() } }
                } : hook)
                // Its own task, so cancelling it cancels only the round.
                let round = Task { try await a.sync() }
                do {
                    _ = try await round.value
                    // Cancelled at the last step, nothing is left to cancel.
                    if !(cancel && stop == steps - 1) { Issue.record("\(comment): the round was not interrupted") }
                } catch is StepInterrupter.Interrupted {
                    #expect(!cancel, comment)
                } catch is CancellationError {
                    #expect(cancel, comment)
                }
                let contents = try await Self.finish(world, comment)
                #expect(contents == expected, "\(comment): ended differently from the round without the interruption")
                interrupted += 1
            }
        }
        #expect(interrupted == steps * 2)
    }
}
