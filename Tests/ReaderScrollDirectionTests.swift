import Foundation
import Testing
@testable import TactileTexts

struct ReaderScrollDirectionTests {
    private func makeStore() -> (ReaderScrollDirectionStore, UserDefaults, String) {
        let suite = "ReaderScrollDirectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ReaderScrollDirectionStore(defaults: defaults), defaults, suite)
    }

    @Test func eachBookKeepsItsOwnDirection() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = UUID(), b = UUID()
        #expect(store.direction(for: a) == .vertical)
        store.setDirection(.horizontal, for: a)
        #expect(store.direction(for: a) == .horizontal)
        #expect(store.direction(for: b) == .vertical)
        store.setDirection(.vertical, for: a)
        #expect(store.direction(for: a) == .vertical)
        #expect(defaults.object(forKey: ReaderScrollDirectionStore.key(for: a)) == nil, "vertical leaves nothing behind")
    }

    @Test func removeAndRemoveAllClearOnlyDirections() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = UUID(), b = UUID()
        store.setDirection(.horizontal, for: a)
        store.setDirection(.horizontal, for: b)
        defaults.set("keep", forKey: "library.sort")
        store.removeDirection(for: a)
        #expect(store.direction(for: a) == .vertical)
        #expect(store.direction(for: b) == .horizontal)
        store.removeAll()
        #expect(store.direction(for: b) == .vertical)
        #expect(defaults.string(forKey: "library.sort") == "keep")
    }

    @Test func unknownStoredValueReadsVertical() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = UUID()
        defaults.set("diagonal", forKey: ReaderScrollDirectionStore.key(for: a))
        #expect(store.direction(for: a) == .vertical)
    }

    @Test func parsesLaunchArgument() {
        #expect(LaunchOptions(arguments: ["app", "-scrollDirection", "horizontal"]).scrollDirection == .horizontal)
        #expect(LaunchOptions(arguments: ["app", "-scrollDirection", "sideways"]).scrollDirection == nil)
        #expect(LaunchOptions(arguments: ["app"]).scrollDirection == nil)
    }
}
