import Foundation
import ReaderBackup
import ReaderCore
import Testing
@testable import ReaderSync

/// Two and three simulated iPads with their own libraries, bases and rollback guards, sharing one
/// account, editing offline and syncing in random order.
@Suite("Sync engine: simulated devices")
struct SyncEngineSimulationTests {
    @Test func twoDevicesExchangeABook() async throws {
        let world = try SimWorld(deviceCount: 2)
        let (a, b) = (world.devices[0], world.devices[1])
        var editor = Editor(seed: 7)
        let (archive, files) = editor.newBook(pdf: 0, prefix: "A")
        try await a.library.importBook(archive, pdf: Editor.pdfs[0], files: files)

        let first = try await a.sync()
        #expect(first.count(.uploadedNew) == 1 && first.failures.isEmpty)
        let second = try await b.sync()
        #expect(second.count(.createdHere) == 1 && second.failures.isEmpty)
        try await world.expectEqualAndValid("after one round each")

        // B's book has no PDF until it is downloaded.
        let bID = try #require(await b.library.bookIDs.first)
        #expect(await b.library.book(bID)?.pdfPresent == false)
        try await b.engine.downloadPDF(bookID: bID)
        #expect(await b.library.book(bID)?.pdfPresent == true)

        var rng = SeededGenerator(state: 1)
        try await world.settle(&rng, "exchange")
    }

    @Test(arguments: [2, 3])
    func devicesEditingOfflineAndSyncingInAnyOrderEndEqual(deviceCount: Int) async throws {
        let seeds: ClosedRange<UInt64> = deviceCount == 2 ? 1...60 : 1...40
        var actions: [SyncBookAction: Int] = [:]
        var skips = Set<String>()
        var inkMerges = (page: 0, note: 0, threeWay: 0)
        for seed in seeds {
            let world = try SimWorld(deviceCount: deviceCount)
            var editor = Editor(seed: seed &* 7_919 + UInt64(deviceCount))
            // Each device starts with books of its own, some of them the same PDF.
            for device in world.devices {
                for _ in 0..<editor.int(1...3) {
                    let index = editor.int(0...Editor.pdfs.count - 1)
                    let pdf = ContentDigest(of: Editor.pdfs[index])
                    var have = false
                    for id in await device.library.bookIDs where await device.library.book(id)?.pdf == pdf { have = true }
                    guard !have else { continue }
                    let (archive, files) = editor.newBook(pdf: index, prefix: device.name)
                    try await device.library.importBook(archive, pdf: Editor.pdfs[index], files: files)
                }
            }
            let comment: Comment = "seed \(seed), \(deviceCount) devices"
            for _ in 0..<36 {
                let device = world.devices[editor.int(0...deviceCount - 1)]
                if editor.chance(0.5) {
                    try await editor.work(on: device)
                } else {
                    if editor.chance(0.15) { await editor.busy(on: device) }
                    let mode: SyncMode = editor.chance(0.1) ? .pullOnly : .full
                    let report = try await device.sync(mode)
                    for failure in report.failures { Issue.record("\(comment): \(failure.failure!.description)") }
                    for book in report.books {
                        actions[book.action, default: 0] += 1
                        for reason in book.skipped {
                            switch reason {
                            case .busy: skips.insert("busy")
                            case .pullOnly: skips.insert("pullOnly")
                            default: skips.insert("\(reason)")
                            }
                        }
                    }
                    await device.library.clearBusy()
                    for id in await device.library.bookIDs {
                        if let book = await device.library.book(id) { expectValid(book.archive, "\(comment)") }
                    }
                }
            }
            try await world.settle(&editor.rng, comment)
            for device in world.devices {
                for kind in device.merger.calls.values {
                    if case .page = kind { inkMerges.page += 1 } else { inkMerges.note += 1 }
                }
                inkMerges.threeWay += device.merger.threeWay.values.count
            }
        }
        // The random work reached every kind of outcome.
        for action in [SyncBookAction.pulled, .pushed, .merged, .joined, .uploadedNew, .createdHere, .deletedHere,
                       .deletedInAccount] {
            #expect(actions[action, default: 0] > 0, "never \(action): \(actions)")
        }
        #expect(skips.isSuperset(of: ["busy", "pullOnly"]), "\(skips)")
        #expect(inkMerges.page > 0 && inkMerges.note > 0 && inkMerges.threeWay > 0, "\(inkMerges)")
    }

    /// The same, with random rounds failing at a random store call (before or after it takes
    /// effect) or cut off or cancelled between two of the engine's steps, each followed by a
    /// "crash" (a fresh engine on the same directory).
    @Test(arguments: [2, 3])
    func devicesEndEqualWithFaultsAndInterruptionsAlongTheWay(deviceCount: Int) async throws {
        var faulted = 0, interrupted = 0, failedBooks = 0
        for seed in UInt64(1)...30 {
            let world = try SimWorld(deviceCount: deviceCount)
            var editor = Editor(seed: seed &* 104_729 + UInt64(deviceCount))
            for device in world.devices {
                for _ in 0..<editor.int(1...3) { try await editor.work(on: device) }
                for _ in 0..<2 {
                    let index = editor.int(0...Editor.pdfs.count - 1)
                    var have = false
                    for id in await device.library.bookIDs where await device.library.book(id)?.pdf == ContentDigest(of: Editor.pdfs[index]) {
                        have = true
                    }
                    guard !have else { continue }
                    let (archive, files) = editor.newBook(pdf: index, prefix: device.name)
                    try await device.library.importBook(archive, pdf: Editor.pdfs[index], files: files)
                }
            }
            let comment: Comment = "seed \(seed), \(deviceCount) devices, with faults"
            for _ in 0..<36 {
                let device = world.devices[editor.int(0...deviceCount - 1)]
                if editor.chance(0.45) {
                    try await editor.work(on: device)
                    continue
                }
                if editor.chance(0.1) { await editor.busy(on: device) }
                if editor.chance(0.35) {
                    device.faulting.arm(at: editor.int(0...40), editor.chance(0.5) ? .beforeEffect : .afterEffect)
                } else if editor.chance(0.3) {
                    let interrupter = StepInterrupter(stopAt: editor.int(0...20))
                    let hook = interrupter.hook()
                    let cancel = editor.chance(0.5)
                    await device.engine.setStepHook(cancel ? { step in
                        do { try await hook(step) } catch { withUnsafeCurrentTask { $0?.cancel() } }
                    } : hook)
                }
                let round = Task { try await device.sync() }
                do {
                    let report = try await round.value
                    failedBooks += report.failures.count
                    if !report.failures.isEmpty { faulted += 1 }
                    await device.engine.setStepHook(nil)
                } catch {
                    interrupted += 1
                    device.restart()
                }
                device.faulting.reset()
                await device.library.clearBusy()
                for id in await device.library.bookIDs {
                    if let book = await device.library.book(id) { expectValid(book.archive, "\(comment)") }
                }
            }
            try await world.settle(&editor.rng, comment)
        }
        #expect(faulted > 20 && interrupted > 20 && failedBooks >= faulted, "faulted \(faulted), interrupted \(interrupted)")
    }
}
