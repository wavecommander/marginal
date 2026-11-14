import Foundation
import UIKit

/// A least-recently-used cache bounded by entry count **and** total cost (bytes). Deterministic
/// (unlike `NSCache`), so the bounds are testable. Main actor only.
struct LRUCache<Key: Hashable, Value> {
    let countLimit: Int
    let costLimit: Int

    private var entries: [Key: (value: Value, cost: Int, tick: UInt64)] = [:]
    private var tick: UInt64 = 0
    private(set) var totalCost = 0

    init(countLimit: Int, costLimit: Int) {
        precondition(countLimit > 0 && costLimit > 0)
        self.countLimit = countLimit
        self.costLimit = costLimit
    }

    var count: Int { entries.count }

    /// The value, marking it most recently used.
    mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        tick += 1
        entry.tick = tick
        entries[key] = entry
        return entry.value
    }

    /// The value without changing recency.
    func peek(_ key: Key) -> Value? { entries[key]?.value }

    mutating func insert(_ value: Value, for key: Key, cost: Int) {
        if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
        tick += 1
        entries[key] = (value, max(0, cost), tick)
        totalCost += max(0, cost)
        evictIfNeeded()
    }

    mutating func removeAll() {
        entries.removeAll()
        totalCost = 0
    }

    private mutating func evictIfNeeded() {
        guard entries.count > countLimit || totalCost > costLimit else { return }
        // Evict oldest first. Sorting is O(n log n) but only runs when over a bound, and n is
        // at most a few hundred; evicting down to 90% amortises it.
        let targetCount = max(1, countLimit * 9 / 10)
        let targetCost = costLimit * 9 / 10
        let oldestFirst = entries.sorted { $0.value.tick < $1.value.tick }.map(\.key)
        for key in oldestFirst {
            guard entries.count > targetCount || totalCost > targetCost, entries.count > 1 else { break }
            if let removed = entries.removeValue(forKey: key) { totalCost -= removed.cost }
        }
    }
}

/// Page thumbnails for one reader window's sidebar (the Pages grid and the Bookmarks list).
///
/// - Rendering is done by the session's `PDFThumbnailRenderer` (an actor with its own private
///   `PDFDocument`), never on the main thread and never on the on-screen document.
/// - **Cancellation:** callers request from a SwiftUI `.task(id:)`, which is cancelled when the
///   cell scrolls away. A request first waits `startDelay`, so cells that only fly past during a
///   fast scroll never reach the renderer; a request cancelled while queued on the renderer
///   returns `nil` without rendering (the renderer checks `Task.isCancelled` first).
/// - **Bounds:** an LRU cache of at most `countLimit` images and `costLimit` bytes (decoded
///   bitmap size). Memory warnings purge it (and the renderer's document).
@MainActor
final class ThumbnailLoader {
    typealias Render = @Sendable (_ pageIndex: Int, _ size: CGSize, _ scale: CGFloat) async -> UIImage?

    struct Stats: Equatable, Sendable {
        var requests = 0
        var cacheHits = 0
        var rendered = 0
        /// Requests that ended without an image because their cell went away first.
        var cancelled = 0
        var purges = 0
    }

    static let defaultCountLimit = 240
    static let defaultCostLimit = 24 * 1024 * 1024

    private var cache: LRUCache<Int, UIImage>
    private let render: Render
    private let startDelay: Duration
    private(set) var stats = Stats()

    init(countLimit: Int = ThumbnailLoader.defaultCountLimit, costLimit: Int = ThumbnailLoader.defaultCostLimit,
         startDelay: Duration = .milliseconds(60), render: @escaping Render) {
        cache = LRUCache(countLimit: countLimit, costLimit: costLimit)
        self.startDelay = startDelay
        self.render = render
    }

    /// A loader rendering through the session's renderer.
    convenience init(session: ReaderSession) {
        let renderer = session.thumbnails
        self.init { pageIndex, size, scale in
            await renderer.thumbnail(forPageAt: pageIndex, size: size, scale: scale)
        }
    }

    var cachedCount: Int { cache.count }
    var cachedCost: Int { cache.totalCost }

    /// The cached image for a page, if any (no rendering).
    func cachedImage(forPage pageIndex: Int) -> UIImage? {
        cache.value(for: pageIndex)
    }

    /// The page's thumbnail: from the cache, or rendered off the main thread. `nil` when the
    /// calling task was cancelled (its cell scrolled away) or the page does not exist.
    func image(forPage pageIndex: Int, size: CGSize, scale: CGFloat) async -> UIImage? {
        stats.requests += 1
        if let hit = cache.value(for: pageIndex) {
            stats.cacheHits += 1
            return hit
        }
        do {
            try await Task.sleep(for: startDelay)
        } catch {
            stats.cancelled += 1
            return nil
        }
        // Another cell (or an earlier request for this page) may have filled it meanwhile.
        if let hit = cache.value(for: pageIndex) {
            stats.cacheHits += 1
            return hit
        }
        guard !Task.isCancelled else {
            stats.cancelled += 1
            return nil
        }
        guard let image = await render(pageIndex, size, scale) else {
            stats.cancelled += Task.isCancelled ? 1 : 0
            return nil
        }
        stats.rendered += 1
        cache.insert(image, for: pageIndex, cost: Self.cost(of: image))
        // A cancelled task still caches what was rendered (the work is done) but reports nil,
        // so a cell that went away never updates.
        return Task.isCancelled ? nil : image
    }

    /// Drops every cached image (memory warning).
    func purge() {
        cache.removeAll()
        stats.purges += 1
    }

    /// Decoded size in bytes.
    static func cost(of image: UIImage) -> Int {
        if let cg = image.cgImage { return cg.bytesPerRow * cg.height }
        return Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
}
