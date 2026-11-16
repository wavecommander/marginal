import Foundation

/// The device conditions under which recognition pauses itself (design, "Recognition"): Low
/// Power Mode, and serious or critical thermal pressure. The engine maps them to
/// `RecognitionPauseReason.lowPowerMode` and `.thermal`.
@MainActor
protocol RecognitionConditionsMonitoring: AnyObject {
    /// Low Power Mode is on.
    var isLowPowerModeEnabled: Bool { get }
    /// The device is under serious or critical thermal pressure.
    var isUnderThermalPressure: Bool { get }
    /// Called on the main actor whenever either may have changed.
    var onChange: (@MainActor () -> Void)? { get set }
}

/// The real conditions, from `ProcessInfo` and its two notifications (posted on arbitrary
/// threads; forwarded to the main actor).
@MainActor
final class SystemRecognitionConditions: RecognitionConditionsMonitoring {
    var onChange: (@MainActor () -> Void)?
    private let observers = NotificationObservers()

    init() {
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.add(name) { [weak self] in
                Task { @MainActor in self?.onChange?() }
            }
        }
    }

    var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    var isUnderThermalPressure: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: true
        default: false
        }
    }
}

/// Block-based notification observers removed when the owner goes (usable from a nonisolated
/// `deinit`).
nonisolated final class NotificationObservers: @unchecked Sendable {
    // `@unchecked`: `tokens` is only appended to by the owner at set-up, and read in `deinit`.
    private var tokens: [any NSObjectProtocol] = []

    init() {}

    /// Calls `handler` on the posting thread for every `name` notification.
    func add(_ name: Notification.Name, handler: @escaping @Sendable () -> Void) {
        tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in handler() })
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}

/// Which page of a book to recognise next.
nonisolated enum TextRecognitionOrder {
    /// The next page from `remaining` (ascending): with no reader on the book, the first; with
    /// readers at `readerPages`, the remaining page nearest to any of them, the later page on a
    /// tie, so recognition spreads outward from the reader's place (16, 17, 15, 18, 14, …).
    static func nextPage(remaining: [Int], readerPages: [Int]) -> Int? {
        guard let first = remaining.first else { return nil }
        guard !readerPages.isEmpty else { return first }
        var best: (page: Int, distance: Int, later: Bool)?
        for reader in readerPages {
            // The nearest remaining pages on either side of this reader's page.
            let split = partitionPoint(remaining, reader)
            var candidates: [Int] = []
            if split < remaining.count { candidates.append(remaining[split]) }
            if split > 0 { candidates.append(remaining[split - 1]) }
            for page in candidates {
                let distance = abs(page - reader)
                let later = page >= reader
                if let current = best {
                    if distance < current.distance || (distance == current.distance && later && !current.later) {
                        best = (page, distance, later)
                    }
                } else {
                    best = (page, distance, later)
                }
            }
        }
        return best?.page ?? first
    }

    /// The index of the first element of `sorted` that is `>= value`.
    private static func partitionPoint(_ sorted: [Int], _ value: Int) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
