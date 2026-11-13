import Foundation
import Testing
@testable import ReaderCore

/// Collects every event a hub delivers while the recorder (and so its token) is alive.
@MainActor
final class EventRecorder {
    private(set) var events: [StoreChangeEvent] = []
    private var token: StoreChangeObservation?

    init(_ hub: StoreChangeHub) {
        token = hub.observe { [weak self] event in self?.events.append(event) }
    }

    var changes: [StoreChange] { events.map(\.change) }
    func reset() { events.removeAll() }
}

private let book1 = uuid(1001)

@MainActor
@Suite("StoreChangeHub")
struct StoreChangeHubTests {
    @Test func deliversInRegistrationOrderWithOrigin() {
        let hub = StoreChangeHub()
        var log: [String] = []
        let a = hub.observe { log.append("a:\($0.change.pageIndex ?? -1)") }
        let b = hub.observe { log.append("b:\($0.change.pageIndex ?? -1)") }
        let origin = ChangeOrigin(label: "window 1")
        var seenOrigin: ChangeOrigin?
        let c = hub.observe { seenOrigin = $0.origin }
        hub.post(.pageInkChanged(bookID: book1, pageIndex: 3), origin: origin)
        hub.post([.highlightsChanged(bookID: book1, pageIndex: 4), .bookmarksChanged(bookID: book1, pageIndex: 5)], origin: nil)
        #expect(log == ["a:3", "b:3", "a:4", "b:4", "a:5", "b:5"])
        #expect(seenOrigin == nil)
        #expect(hub.observerCount == 3)
        _ = (a, b, c)
    }

    @Test func cancelStopsDelivery() {
        let hub = StoreChangeHub()
        var count = 0
        let token = hub.observe { _ in count += 1 }
        hub.post(.bookSaved(bookID: book1), origin: nil)
        token.cancel()
        token.cancel()
        hub.post(.bookSaved(bookID: book1), origin: nil)
        #expect(count == 1)
        #expect(!token.isActive)
        #expect(hub.observerCount == 0)
    }

    @Test func droppingTheTokenStopsDeliveryAndReleasesTheObserver() {
        final class Session { var count = 0 }
        let hub = StoreChangeHub()
        weak var weakSession: Session?
        var token: StoreChangeObservation?
        do {
            let session = Session()
            weakSession = session
            token = hub.observe { _ in session.count += 1 }   // the handler captures the session strongly
            hub.post(.bookSaved(bookID: book1), origin: nil)
            #expect(session.count == 1)
        }
        #expect(weakSession != nil)       // kept alive by the token only
        token = nil
        #expect(weakSession == nil)       // the hub did not retain it
        hub.post(.bookSaved(bookID: book1), origin: nil)
        #expect(hub.observerCount == 0)
        _ = token
    }

    @Test func reentrantPostIsQueuedAndSeenInTheSameOrderByEveryone() {
        let hub = StoreChangeHub()
        var a: [Int] = [], b: [Int] = []
        let first = hub.observe { event in
            a.append(event.change.pageIndex!)
            if event.change.pageIndex == 1 {
                hub.post(.pageInkChanged(bookID: book1, pageIndex: 2), origin: nil)
                #expect(a == [1])                     // queued, not delivered yet
            }
        }
        let second = hub.observe { b.append($0.change.pageIndex!) }
        hub.post(.pageInkChanged(bookID: book1, pageIndex: 1), origin: nil)
        #expect(a == [1, 2])
        #expect(b == [1, 2])
        _ = (first, second)
    }

    @Test func cancellingAndAddingDuringDelivery() {
        let hub = StoreChangeHub()
        var log: [String] = []
        var second: StoreChangeObservation?
        var late: StoreChangeObservation?
        var first: StoreChangeObservation?
        first = hub.observe { event in
            log.append("first:\(event.change.pageIndex!)")
            second?.cancel()                         // cancels an observer not yet reached
            first?.cancel()                          // and itself
            late = hub.observe { log.append("late:\($0.change.pageIndex!)") }
        }
        second = hub.observe { log.append("second:\($0.change.pageIndex!)") }
        hub.post(.pageInkChanged(bookID: book1, pageIndex: 1), origin: nil)
        hub.post(.pageInkChanged(bookID: book1, pageIndex: 2), origin: nil)
        #expect(log == ["first:1", "late:2"])
        #expect(hub.observerCount == 1)
        _ = late
    }

    @Test func asyncStreamDeliversAndUnregistersWhenTheConsumerStops() async throws {
        let hub = StoreChangeHub()
        // The consumer task owns the only reference to the stream, as a session's task would.
        func consume(_ stream: AsyncStream<StoreChangeEvent>) -> Task<[Int], Never> {
            Task { @MainActor in
                var received: [Int] = []
                for await event in stream {
                    received.append(event.change.pageIndex!)
                    if received.count == 2 { break }
                }
                return received
            }
        }
        let consumer = consume(hub.events())
        #expect(hub.streamCount == 1)
        for page in 1...3 { hub.post(.pageInkChanged(bookID: book1, pageIndex: page), origin: nil) }
        #expect(await consumer.value == [1, 2])
        for _ in 0..<100 where hub.streamCount > 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(hub.streamCount == 0)
        hub.post(.bookSaved(bookID: book1), origin: nil)    // nobody listening: no crash
    }

    @Test func cancellingTheConsumingTaskUnregistersTheStream() async throws {
        let hub = StoreChangeHub()
        let stream = hub.events()
        let consumer = Task { @MainActor in
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        hub.post(.bookSaved(bookID: book1), origin: nil)
        try await Task.sleep(for: .milliseconds(20))
        consumer.cancel()
        #expect(await consumer.value == 1)                    // the loop ended
        for _ in 0..<100 where hub.streamCount > 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(hub.streamCount == 0)
    }

    @Test func asyncStreamFinishesWhenTheHubGoesAway() async {
        var hub: StoreChangeHub? = StoreChangeHub()
        let stream = hub!.events()
        hub!.post(.bookSaved(bookID: book1), origin: nil)
        hub = nil
        var count = 0
        for await _ in stream { count += 1 }                  // ends instead of hanging
        #expect(count == 1)
    }

    @Test func twoWindowsSeeEachOthersChangesAndFilterTheirOwn() {
        let hub = StoreChangeHub()
        let windowA = ChangeOrigin(label: "A"), windowB = ChangeOrigin(label: "B")
        var reloadsA: [StoreChange] = [], reloadsB: [StoreChange] = []
        let tokenA = hub.observe { event in if !event.isFrom(windowA) { reloadsA.append(event.change) } }
        let tokenB = hub.observe { event in if !event.isFrom(windowB) { reloadsB.append(event.change) } }
        hub.post(.pageInkChanged(bookID: book1, pageIndex: 7), origin: windowA)
        hub.post(.noteInkChanged(bookID: book1, noteID: uuid(5)), origin: windowB)
        hub.post(.bookSaved(bookID: book1), origin: nil)
        #expect(reloadsA == [.noteInkChanged(bookID: book1, noteID: uuid(5)), .bookSaved(bookID: book1)])
        #expect(reloadsB == [.pageInkChanged(bookID: book1, pageIndex: 7), .bookSaved(bookID: book1)])
        _ = (tokenA, tokenB)
    }

    @Test func changeAccessorsAndOrigins() {
        let target = NoteTarget.page(9)
        #expect(StoreChange.noteSaved(bookID: book1, target: target, noteID: uuid(1)).pageIndex == 9)
        #expect(StoreChange.noteRemoved(bookID: book1, target: .heading(HeadingAnchor(userHeadingID: uuid(2))), noteID: uuid(1)).pageIndex == nil)
        #expect(StoreChange.userHeadingsChanged(bookID: book1).bookID == book1)
        #expect(StoreChange.noteInkChanged(bookID: book1, noteID: uuid(3)).bookID == book1)
        let origin = ChangeOrigin(label: "x")
        #expect(origin != ChangeOrigin(label: "x"))
        #expect(StoreChangeEvent(change: .bookSaved(bookID: book1), origin: origin).isFrom(origin))
        #expect(!StoreChangeEvent(change: .bookSaved(bookID: book1), origin: nil).isFrom(origin))
    }
}
