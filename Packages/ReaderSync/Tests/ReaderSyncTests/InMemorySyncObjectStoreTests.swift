import Foundation
import Testing
@testable import ReaderSync

/// The test double keeps the `SyncObjectStore` contract, including compare-and-swap under races.
struct InMemorySyncObjectStoreTests {
    @Test(arguments: [2, 12, 50])
    func concurrentCreatesHaveExactlyOneWinner(writers: Int) async throws {
        let store = InMemorySyncObjectStore()
        let winners = Collected<Int>()
        let refused = Collected<Int>()
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<writers {
                group.addTask {
                    do {
                        _ = try await store.put(Data("writer \(writer)".utf8), at: "Sync/v1/books/k", metadata: [:],
                                                condition: .ifAbsent)
                        winners.append(writer)
                    } catch SyncError.preconditionFailed(key: "Sync/v1/books/k") {
                        refused.append(writer)
                    } catch {
                        Issue.record("unexpected \(error)")
                    }
                }
            }
        }
        #expect(winners.values.count == 1)
        #expect(refused.values.count == writers - 1)
        let winner = try #require(winners.values.first)
        #expect(store.object("Sync/v1/books/k")?.data == Data("writer \(winner)".utf8))
    }

    @Test(arguments: [2, 12, 50])
    func concurrentReplacesFromOneETagHaveExactlyOneWinner(writers: Int) async throws {
        let store = InMemorySyncObjectStore()
        let first = try await store.put(Data("v1".utf8), at: "k", metadata: [:], condition: .ifAbsent)
        let winners = Collected<(Int, String)>()
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<writers {
                group.addTask {
                    if let eTag = try? await store.put(Data("v2 from \(writer)".utf8), at: "k", metadata: ["write-id": "\(writer)"],
                                                       condition: .ifMatch(eTag: first)) {
                        winners.append((writer, eTag))
                    }
                }
            }
        }
        #expect(winners.values.count == 1)
        let (winner, eTag) = try #require(winners.values.first)
        let stored = try #require(store.object("k"))
        #expect(stored.data == Data("v2 from \(winner)".utf8))
        #expect(stored.eTag == eTag)
        #expect(stored.metadata == ["write-id": "\(winner)"])
        #expect(store.calls.filter { $0.outcome == .preconditionFailed }.count == writers - 1)
    }

    @Test func conditionsAreCheckedAgainstTheCurrentETag() async throws {
        let store = InMemorySyncObjectStore()
        await #expect(throws: SyncError.preconditionFailed(key: "k")) {
            try await store.put(Data("x".utf8), at: "k", metadata: [:], condition: .ifMatch(eTag: "\"none\""))
        }
        let a = try await store.put(Data("a".utf8), at: "k", metadata: [:], condition: nil)
        let b = try await store.put(Data("b".utf8), at: "k", metadata: [:], condition: .ifMatch(eTag: a))
        #expect(a != b)
        await #expect(throws: SyncError.preconditionFailed(key: "k")) {
            try await store.put(Data("c".utf8), at: "k", metadata: [:], condition: .ifMatch(eTag: a))
        }
        // Equal bytes keep the ETag, as S3's do.
        #expect(try await store.put(Data("b".utf8), at: "k", metadata: [:], condition: nil) == b)
        #expect(try await store.get("k", maxBytes: 10)?.data == Data("b".utf8))
    }

    @Test func readsListAndMissingObjects() async throws {
        let dir = try TemporaryDirectory()
        let store = InMemorySyncObjectStore(objects: ["Sync/v1/books/b": Data("2".utf8), "Sync/v1/books/a": Data("1".utf8),
                                                      "PDFs/x.ttenc": Data("p".utf8)])
        let listed = try await store.list(prefix: "Sync/v1/books/")
        #expect(listed.map(\.key) == ["Sync/v1/books/a", "Sync/v1/books/b"])
        #expect(listed.map(\.size) == [1, 1])
        #expect(listed[0].eTag == store.object("Sync/v1/books/a")?.eTag)
        #expect(try await store.head("Sync/v1/books/a")?.eTag == listed[0].eTag)
        #expect(try await store.get("missing", maxBytes: 10) == nil)
        #expect(try await store.head("missing") == nil)
        await #expect(throws: SyncError.objectNotFound(key: "missing")) {
            try await store.download("missing", to: dir.url.appendingPathComponent("f"))
        }
        try await store.delete("missing")
        await #expect(throws: SyncError.objectTooLarge(key: "PDFs/x.ttenc", limit: 0)) {
            try await store.get("PDFs/x.ttenc", maxBytes: 0)
        }
        let file = try dir.file("up", Data("uploaded".utf8))
        try await store.upload(fileAt: file, to: "Sync/v1/blobs/u", metadata: ["m": "1"])
        let target = dir.url.appendingPathComponent("down")
        try await store.download("Sync/v1/blobs/u", to: target)
        #expect(try Data(contentsOf: target) == Data("uploaded".utf8))
        #expect(try await store.head("Sync/v1/blobs/u")?.metadata == ["m": "1"])
        try await store.delete("Sync/v1/blobs/u")
        #expect(!store.keys.contains("Sync/v1/blobs/u"))
    }

    @Test func faultsBeforeAndAfterTheEffect() async throws {
        let store = InMemorySyncObjectStore()
        store.injectFault(.beforeEffect, on: .put, keyPrefix: "Sync/")
        await #expect(throws: InMemorySyncObjectStore.InjectedFault.self) {
            try await store.put(Data("x".utf8), at: "Sync/k", metadata: [:], condition: .ifAbsent)
        }
        #expect(store.object("Sync/k") == nil, "nothing written before the effect")

        store.injectFault(.afterEffect, on: .put)
        await #expect(throws: InMemorySyncObjectStore.InjectedFault.self) {
            try await store.put(Data("y".utf8), at: "Sync/k", metadata: [:], condition: .ifAbsent)
        }
        #expect(store.object("Sync/k")?.data == Data("y".utf8), "written, then the answer was lost")

        // The retry of that write meets its own object.
        await #expect(throws: SyncError.preconditionFailed(key: "Sync/k")) {
            try await store.put(Data("y".utf8), at: "Sync/k", metadata: [:], condition: .ifAbsent)
        }
        struct Custom: Error {}
        store.injectFault(.beforeEffect, on: .get, count: 2, error: Custom())
        for _ in 0..<2 { await #expect(throws: Custom.self) { try await store.get("Sync/k", maxBytes: 10) } }
        #expect(try await store.get("Sync/k", maxBytes: 10) != nil)
        // A fault on another operation or key does not strike.
        store.injectFault(.beforeEffect, on: .delete, keyPrefix: "Other/")
        try await store.delete("Sync/k")
        #expect(store.calls.map(\.outcome) == [.faultBeforeEffect, .faultAfterEffect, .preconditionFailed,
                                               .faultBeforeEffect, .faultBeforeEffect, .succeeded, .succeeded])
        #expect(store.calls.map(\.operation) == [.put, .put, .put, .get, .get, .get, .delete])
        #expect(store.calls[0].condition == .ifAbsent)
        store.clearCalls()
        #expect(store.calls.isEmpty)
    }

    @Test func everyWriteIsStampedWithTheClockAndListAndHeadReportIt() async throws {
        let store = InMemorySyncObjectStore()
        #expect(store.now == InMemorySyncObjectStore.epoch)
        _ = try await store.put(Data("a".utf8), at: "Sync/a", metadata: [:], condition: nil)
        store.advance(by: 3_600)
        _ = try await store.put(Data("b".utf8), at: "Sync/b", metadata: [:], condition: nil)
        #expect(try await store.list(prefix: "Sync/").map(\.lastModified)
            == [InMemorySyncObjectStore.epoch, InMemorySyncObjectStore.epoch.addingTimeInterval(3_600)])
        // Writing the same bytes again keeps the ETag and moves the date, as S3 does.
        let eTag = try #require(try await store.head("Sync/a")).eTag
        store.advance(by: 60)
        _ = try await store.put(Data("a".utf8), at: "Sync/a", metadata: [:], condition: nil)
        let again = try #require(try await store.head("Sync/a"))
        #expect(again.eTag == eTag && again.lastModified == store.now)
        store.setLastModified(InMemorySyncObjectStore.epoch, of: "Sync/a")
        #expect(try await store.head("Sync/a")?.lastModified == InMemorySyncObjectStore.epoch)
        // A step slipped in just before a call.
        let ran = Collected<Bool>()
        store.beforeNextCall(.delete, keyPrefix: "Sync/b") {
            ran.append(store.object("Sync/b") != nil)
        }
        try await store.delete("Sync/a")
        #expect(ran.values.isEmpty, "only the matching call")
        try await store.delete("Sync/b")
        #expect(ran.values == [true] && store.keys.isEmpty)
    }
}
