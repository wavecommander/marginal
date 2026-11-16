#if DEBUG
import Darwin
import QuartzCore
import SwiftUI

/// DEBUG-only measurement hook for UI tests (`LaunchOptions.sidebarDebugStats` and
/// `sidebarAutoScroll`): `-sidebarDebugStats` shows a small button over the Pages grid
/// whose accessibility value is
/// `requests R hits H rendered N cancelled C cached K bytes B footprintMB F maxGapMS G longFrames L`.
/// - thumbnail loader counters and cache size/bytes;
/// - the app's physical memory footprint (`task_vm_info.phys_footprint`);
/// - the longest main-thread frame gap seen by a display link since the last reset, and the
///   number of frames longer than 50 ms (a stall of the main thread, which drives the PDF view).
/// Tapping the button resets the frame counters.
enum SidebarDebugStats {
    static let isEnabled = LaunchOptions.current.sidebarDebugStats

    /// `-sidebarAutoScroll` (with `-sidebarDebugStats`): when the Pages tab opens, the app scrolls
    /// its own grid through the whole book and back, one step every 16 ms (no XCUITest gestures
    /// or queries while it runs, so the frame figures are the app's own). The phase shows in the
    /// stats value (`phase down|up|done`); the frame counters are reset when it starts, and
    /// `doneMaxGapMS` / `doneLongFrames` freeze them when it ends.
    static let autoScroll = LaunchOptions.current.sidebarAutoScroll
    @MainActor static var phase = "idle"
    @MainActor static var doneFigures = ""

    @MainActor
    static func runAutoScroll(scrollTo: @escaping @MainActor (Int) -> Void, pageCount: Int) {
        guard autoScroll, phase == "idle" else { return }
        phase = "waiting"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            FrameGapMonitor.shared.start()
            FrameGapMonitor.shared.reset()
            let pages = Array(stride(from: 0, to: pageCount, by: 6))
            phase = "down"
            for page in pages {
                scrollTo(page)
                try? await Task.sleep(for: .milliseconds(16))
            }
            phase = "up"
            for page in pages.reversed() {
                scrollTo(page)
                try? await Task.sleep(for: .milliseconds(16))
            }
            let monitor = FrameGapMonitor.shared
            doneFigures = String(format: "doneMaxGapMS %.0f doneLongFrames %d", monitor.maxGap * 1000, monitor.longFrames)
            phase = "done"
        }
    }

    /// Physical footprint in MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }
}

/// Watches frame-to-frame gaps on the main run loop.
@MainActor
final class FrameGapMonitor: NSObject {
    static let shared = FrameGapMonitor()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var maxGap: CFTimeInterval = 0
    private(set) var longFrames = 0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func reset() {
        maxGap = 0
        longFrames = 0
        last = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let gap = link.timestamp - last
        maxGap = max(maxGap, gap)
        if gap > 0.05 { longFrames += 1 }
    }
}

struct SidebarDebugStatsView: View {
    let model: ContentsSidebarModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let stats = model.thumbnails.stats
            let monitor = FrameGapMonitor.shared
            let value = "requests \(stats.requests) hits \(stats.cacheHits) rendered \(stats.rendered) "
                + "cancelled \(stats.cancelled) cached \(model.thumbnails.cachedCount) "
                + "bytes \(model.thumbnails.cachedCost) "
                + String(format: "footprintMB %.1f maxGapMS %.0f longFrames %d",
                         SidebarDebugStats.footprintMB(), monitor.maxGap * 1000, monitor.longFrames)
                + " phase \(SidebarDebugStats.phase) " + SidebarDebugStats.doneFigures
            Button { monitor.reset() } label: {
                Text(verbatim: "stats").font(.caption2).foregroundStyle(.secondary).frame(width: 44, height: 20)
            }
            .accessibilityLabel("Sidebar stats")
            .accessibilityValue(value)
            .accessibilityIdentifier(SidebarAccessibilityID.debugStats)
        }
        .onAppear { FrameGapMonitor.shared.start() }
    }
}
#endif
