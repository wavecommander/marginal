import Foundation
import Testing
@testable import TactileTexts

/// Downloads the test holds open per book; cancelling a download makes it throw.
@MainActor
final class FakePDFDownloads {
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var failing: Set<UUID> = []
    private(set) var started: [UUID] = []
    private(set) var cancelled: [UUID] = []

    struct Refused: LocalizedError { var errorDescription: String? { "The PDF couldn’t be downloaded." } }

    func download(_ id: UUID) async throws {
        started.append(id)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { waiting[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        cancelled.append(id)
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    var inFlight: Set<UUID> { Set(waiting.keys) }

    /// Lets the book's download end (with an error when it is in `failing`).
    func finish(_ id: UUID) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        if failing.contains(id) { continuation.resume(throwing: Refused()) } else { continuation.resume() }
    }
}

/// `SyncPDFDownloads` (C4b): the policy (automatic on Wi‑Fi or only on open), expensive and
/// constrained paths, one download at a time, a download the reader asks for going first, and
/// Cancel.
@MainActor
@Suite(.serialized)
struct SyncPDFDownloadsTests {
    typealias Support = BackupTestSupport

    @MainActor
    final class Rig {
        var isActive = true
        var policy: SyncPDFPolicy = .automaticOnWiFi
        var path: SyncNetworkPath? = .wifi
        var synced: Set<UUID>
        var present: Set<UUID> = []
        let fake = FakePDFDownloads()
        var pdfs: SyncPDFDownloads!

        init(books: Int) {
            synced = Set((0..<books).map { _ in UUID() })
            pdfs = SyncPDFDownloads(isActive: { [unowned self] in isActive }, policy: { [unowned self] in policy },
                                    path: { [unowned self] in path },
                                    download: { [unowned self] id in
                                        try await fake.download(id)
                                        present.insert(id)
                                    },
                                    syncedBookIDs: { [unowned self] in synced },
                                    hasPDF: { [unowned self] id in present.contains(id) })
        }

        var sorted: [UUID] { synced.sorted { $0.uuidString < $1.uuidString } }
    }

    @Test func automaticOnWiFiDownloadsOneAtATime() async throws {
        let rig = Rig(books: 3)
        let ids = rig.sorted
        await rig.pdfs.refresh()
        #expect(rig.pdfs.booksWithoutPDF == rig.synced)
        #expect(await Support.waitUntil { rig.fake.inFlight == [ids[0]] })
        #expect(rig.pdfs.badge(for: ids[0]) == .downloading)
        #expect(rig.pdfs.badge(for: ids[1]) == .waiting)
        #expect(rig.pdfs.badge(for: UUID()) == nil, "not a synced book")
        rig.fake.finish(ids[0])
        #expect(await Support.waitUntil { rig.fake.inFlight == [ids[1]] }, "the next one starts only then")
        #expect(rig.pdfs.badge(for: ids[0]) == nil, "downloaded: an ordinary book")
        rig.fake.finish(ids[1])
        #expect(await Support.waitUntil { rig.fake.inFlight == [ids[2]] })
        rig.fake.finish(ids[2])
        #expect(await Support.waitUntil { !rig.pdfs.isDownloading })
        #expect(rig.fake.started == ids)
        #expect(rig.pdfs.booksWithoutPDF.isEmpty)
    }

    @Test func nothingAutomaticOnCellularInLowDataModeOrWhenOnlyOnOpen() async throws {
        for (policy, path) in [(SyncPDFPolicy.automaticOnWiFi, SyncNetworkPath.cellular),
                               (.automaticOnWiFi, SyncNetworkPath(isSatisfied: true, isExpensive: false, isConstrained: true)),
                               (.automaticOnWiFi, nil),
                               (.onOpen, .wifi)] {
            let rig = Rig(books: 2)
            rig.policy = policy
            rig.path = path
            await rig.pdfs.refresh()
            try await Task.sleep(for: .milliseconds(30))
            #expect(rig.fake.started.isEmpty, "\(policy) \(String(describing: path))")
            #expect(rig.pdfs.badge(for: rig.sorted[0]) == .notDownloaded)

            // Opening the book downloads it on any network.
            rig.pdfs.requestNow(rig.sorted[1])
            #expect(await Support.waitUntil { rig.fake.inFlight == [rig.sorted[1]] })
            #expect(rig.pdfs.badge(for: rig.sorted[1]) == .downloading)
            rig.fake.finish(rig.sorted[1])
            #expect(await Support.waitUntil { !rig.pdfs.isDownloading })
            #expect(rig.fake.started == [rig.sorted[1]], "and only that one")
        }
    }

    @Test func aBookTheReaderAsksForGoesFirst() async throws {
        let rig = Rig(books: 3)
        let ids = rig.sorted
        await rig.pdfs.refresh()
        #expect(await Support.waitUntil { rig.fake.inFlight == [ids[0]] })
        rig.pdfs.requestNow(ids[2])
        // The automatic one is set aside (still only one at a time) and comes back after.
        #expect(await Support.waitUntil { rig.fake.inFlight == [ids[2]] })
        #expect(rig.fake.cancelled == [ids[0]])
        #expect(rig.pdfs.badge(for: ids[0]) == .waiting)
        rig.fake.finish(ids[2])
        #expect(await Support.waitUntil { rig.fake.inFlight == [ids[0]] })
        rig.fake.finish(ids[0])
        #expect(await Support.waitUntil { rig.fake.inFlight == [ids[1]] })
        rig.fake.finish(ids[1])
        #expect(await Support.waitUntil { !rig.pdfs.isDownloading })
        #expect(rig.fake.started == [ids[0], ids[2], ids[0], ids[1]])
    }

    @Test func theNetworkTurningExpensiveStopsAutomaticDownloads() async throws {
        let rig = Rig(books: 2)
        let ids = rig.sorted
        await rig.pdfs.refresh()
        #expect(await Support.waitUntil { rig.fake.inFlight == [ids[0]] })
        rig.path = .cellular
        rig.pdfs.considerAutomatic()
        #expect(await Support.waitUntil { !rig.pdfs.isDownloading })
        #expect(rig.fake.cancelled == [ids[0]])
        #expect(rig.pdfs.badge(for: ids[0]) == .notDownloaded && rig.pdfs.badge(for: ids[1]) == .notDownloaded)
        // Back on Wi‑Fi it carries on.
        rig.path = .wifi
        rig.pdfs.considerAutomatic()
        #expect(await Support.waitUntil { rig.fake.inFlight == [ids[0]] })
    }

    @Test func aFailureShowsAndTryAgainDownloads() async throws {
        let rig = Rig(books: 1)
        let id = rig.sorted[0]
        rig.policy = .onOpen
        await rig.pdfs.refresh()
        rig.fake.failing = [id]
        rig.pdfs.requestNow(id)
        #expect(await Support.waitUntil { rig.fake.inFlight == [id] })
        rig.fake.finish(id)
        #expect(await Support.waitUntil { rig.pdfs.badge(for: id) == .failed("The PDF couldn’t be downloaded.") })
        // An automatic pass leaves a failed book alone; asking again retries.
        rig.policy = .automaticOnWiFi
        rig.pdfs.considerAutomatic()
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.fake.started == [id])
        rig.fake.failing = []
        rig.pdfs.requestNow(id)
        #expect(await Support.waitUntil { rig.fake.inFlight == [id] })
        rig.fake.finish(id)
        #expect(await Support.waitUntil { rig.pdfs.badge(for: id) == nil })
    }

    @Test func cancelStopsTheDownloadAndOffShowsNothing() async throws {
        let rig = Rig(books: 1)
        let id = rig.sorted[0]
        rig.policy = .onOpen
        await rig.pdfs.refresh()
        rig.pdfs.requestNow(id)
        #expect(await Support.waitUntil { rig.fake.inFlight == [id] })
        rig.pdfs.cancel(id)
        #expect(await Support.waitUntil { !rig.pdfs.isDownloading })
        #expect(rig.pdfs.badge(for: id) == .notDownloaded)
        // Asked for again right away, it starts again.
        rig.pdfs.requestNow(id)
        #expect(await Support.waitUntil { rig.fake.inFlight == [id] })
        rig.pdfs.stopAll()
        #expect(await Support.waitUntil { !rig.pdfs.isDownloading })

        // The switch off: a synced book without its PDF is an ordinary book whose PDF is missing.
        rig.isActive = false
        #expect(rig.pdfs.badge(for: id) == nil && !rig.pdfs.isSyncedWithoutPDF(id))
        await rig.pdfs.refresh()
        #expect(rig.pdfs.booksWithoutPDF.isEmpty)
        rig.pdfs.requestNow(id)
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.fake.started.count == 2, "nothing downloads while off")
    }
}
