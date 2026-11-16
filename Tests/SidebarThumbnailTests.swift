import Foundation
import Testing
import UIKit
@testable import TactileTexts

/// Contents sidebar: the thumbnail cache (bounded by count and cost), cancellation and purge.
@MainActor
struct SidebarThumbnailTests {
    /// Counts renders; each returns a `side`×`side` 1x bitmap (cost side² × 4 bytes).
    final class FakeRenderer: @unchecked Sendable {
        private let lock = NSLock()
        private var _rendered: [Int] = []
        let side: CGFloat
        let delay: Duration

        init(side: CGFloat = 10, delay: Duration = .zero) {
            self.side = side
            self.delay = delay
        }

        var rendered: [Int] { lock.withLock { _rendered } }

        func render(_ page: Int) async -> UIImage? {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return nil }
            lock.withLock { _rendered.append(page) }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
                UIColor.gray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            }
        }
    }

    private func loader(_ fake: FakeRenderer, count: Int = 100, cost: Int = 1 << 30,
                        delay: Duration = .milliseconds(1)) -> ThumbnailLoader {
        ThumbnailLoader(countLimit: count, costLimit: cost, startDelay: delay) { page, _, _ in await fake.render(page) }
    }

    private let size = CGSize(width: 10, height: 10)

    @Test func lruIsBoundedByCountAndCost() {
        var cache = LRUCache<Int, String>(countLimit: 10, costLimit: 1_000)
        for i in 0..<50 { cache.insert("\(i)", for: i, cost: 10) }
        #expect(cache.count <= 10)
        #expect(cache.peek(49) == "49")
        #expect(cache.peek(0) == nil)

        // Recently used entries survive eviction.
        var lru = LRUCache<Int, String>(countLimit: 5, costLimit: 1_000)
        for i in 0..<5 { lru.insert("\(i)", for: i, cost: 1) }
        _ = lru.value(for: 0)
        lru.insert("5", for: 5, cost: 1)
        #expect(lru.peek(0) == "0")
        #expect(lru.peek(1) == nil)

        // Cost bound.
        var heavy = LRUCache<Int, String>(countLimit: 1_000, costLimit: 100)
        for i in 0..<20 { heavy.insert("\(i)", for: i, cost: 30) }
        #expect(heavy.totalCost <= 100)
        #expect(heavy.count <= 3)
        heavy.removeAll()
        #expect(heavy.count == 0 && heavy.totalCost == 0)
    }

    @Test func loaderCachesAndStaysBoundedOverAWholeBook() async {
        let fake = FakeRenderer(side: 10)  // 400 bytes each
        let thumbnails = loader(fake, count: 50, cost: 12_000)
        for page in 0..<1_500 {
            _ = await thumbnails.image(forPage: page, size: size, scale: 1)
            #expect(thumbnails.cachedCount <= 50)
            #expect(thumbnails.cachedCost <= 12_000)
        }
        #expect(thumbnails.stats.rendered == 1_500)
        // The most recent pages are cached; asking again does not render.
        _ = await thumbnails.image(forPage: 1_499, size: size, scale: 1)
        #expect(thumbnails.stats.rendered == 1_500)
        #expect(thumbnails.stats.cacheHits == 1)
    }

    @Test func cancelledRequestsNeverRender() async {
        let fake = FakeRenderer()
        let thumbnails = loader(fake, delay: .milliseconds(200))
        // Cells that fly past during a fast scroll: requested, then cancelled within the start delay.
        var tasks: [Task<UIImage?, Never>] = []
        for page in 0..<100 {
            tasks.append(Task { @MainActor in await thumbnails.image(forPage: page, size: size, scale: 1) })
        }
        try? await Task.sleep(for: .milliseconds(20))
        for task in tasks { task.cancel() }
        for task in tasks { #expect(await task.value == nil) }
        #expect(fake.rendered.isEmpty)
        #expect(thumbnails.stats.cancelled == 100)

        // A cell that stays renders.
        let kept = await thumbnails.image(forPage: 7, size: size, scale: 1)
        #expect(kept != nil)
        #expect(fake.rendered == [7])
    }

    @Test func cancellationDuringRenderReturnsNil() async {
        let fake = FakeRenderer(delay: .milliseconds(300))
        let thumbnails = loader(fake)
        let task = Task { @MainActor in await thumbnails.image(forPage: 3, size: size, scale: 1) }
        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()
        #expect(await task.value == nil)
        #expect(fake.rendered.isEmpty)
    }

    @Test func purgeEmptiesTheCache() async {
        let fake = FakeRenderer()
        let thumbnails = loader(fake)
        for page in 0..<10 { _ = await thumbnails.image(forPage: page, size: size, scale: 1) }
        #expect(thumbnails.cachedCount == 10)
        #expect(thumbnails.cachedImage(forPage: 3) != nil)
        thumbnails.purge()
        #expect(thumbnails.cachedCount == 0)
        #expect(thumbnails.cachedCost == 0)
        #expect(thumbnails.cachedImage(forPage: 3) == nil)
        #expect(thumbnails.stats.purges == 1)
    }

    @Test func realRendererProducesThumbnailsOffTheMainThread() async throws {
        let fixture = try SidebarTestSupport.makeFixture()
        defer { SidebarTestSupport.cleanUp(fixture) }
        let session = SidebarTestSupport.makeSession(fixture)
        let thumbnails = ThumbnailLoader(session: session)
        let image = await thumbnails.image(forPage: 3, size: CGSize(width: 120, height: 155), scale: 2)
        let rendered = try #require(image)
        #expect(rendered.size.width <= 121 && rendered.size.width > 50)
        #expect(ThumbnailLoader.cost(of: rendered) > 0)
        // A page that does not exist.
        #expect(await thumbnails.image(forPage: 99, size: CGSize(width: 120, height: 155), scale: 2) == nil)
    }
}
