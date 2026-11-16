#if DEBUG
import Darwin
import PDFKit
import QuartzCore
import UIKit

/// DEBUG-only performance probe (WP12), switched on by `LaunchOptions` (`perfProbe`,
/// `perfAutoScroll`).
///
/// `-perfProbe` adds an accessibility element `reader.perfStats` to the reader whose value is
/// `launchToFirstPageMS L openToFirstPageMS O page P footprintMB F phase …` and, after an
/// auto-scroll, the scroll figures:
/// - `launchToFirstPageMS`: from the process start (kernel start time) to the first display-link
///   frame at which the document is attached, positioned on its first page and PDFKit reports
///   that page visible;
/// - `openToFirstPageMS`: the same, from the session's creation (the reader being opened).
///
/// `-perfAutoScroll` (with `-perfProbe`): three seconds after the first page, the probe scrolls
/// the PDF itself, one step per display-link frame (no XCUITest gestures or queries while it
/// runs, so the frame figures are the app's own): `slow` (24 pt a frame, ~1,400 pt/s) for 8 s,
/// then `fast` (96 pt a frame, ~5,800 pt/s, a hard fling) for 8 s. For each phase: frames, the
/// longest frame gap, frames longer than 50 ms (`long`) and longer than 2× the display's frame
/// time (`dropped`); pages crossed; and the footprint before, at its highest, and after.
@MainActor
final class ReaderPerfProbe: UIView {
    static let isEnabled = LaunchOptions.current.perfProbe
    static let autoScroll = LaunchOptions.current.perfAutoScroll

    private weak var controller: ReaderPDFController?
    private let createdAt = CACurrentMediaTime()
    private var link: CADisplayLink?
    private var firstPageAt: CFTimeInterval?
    private var firstPageWall: Date?
    private var phase = "loading"
    private var figures: [String] = []

    // Scroll phase state.
    private var phaseStart: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var frames = 0
    private var maxGap: CFTimeInterval = 0
    private var longFrames = 0
    private var droppedFrames = 0
    private var startPage = 0
    private var footprintBefore: Double = 0
    private var footprintMax: Double = 0

    init(controller: ReaderPDFController) {
        self.controller = controller
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Performance"
        accessibilityIdentifier = "reader.perfStats"
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var accessibilityValue: String? {
        get {
            var parts: [String] = []
            if let firstPageAt {
                parts.append(String(format: "launchToFirstPageMS %.0f", (firstPageWall.map { $0.timeIntervalSince(Self.processStart) } ?? 0) * 1000))
                parts.append(String(format: "openToFirstPageMS %.0f", (firstPageAt - createdAt) * 1000))
            }
            parts.append("page \(currentPage() ?? -1)")
            parts.append(String(format: "footprintMB %.0f", Self.footprintMB()))
            parts.append("phase \(phase)")
            parts.append("marks " + PerfMarks.marks.map { "\($0.0):\($0.1)" }.joined(separator: ","))
            return (parts + figures).joined(separator: " ")
        }
        set {}
    }

    // MARK: Ticks

    @objc private func tick(_ link: CADisplayLink) {
        guard let controller else { link.invalidate(); return }
        if firstPageAt == nil {
            guard controller.document != nil, controller.hasPositionedInitially,
                  !controller.view.visiblePages.isEmpty else { return }
            firstPageAt = link.timestamp
            firstPageWall = Date()
            phase = Self.autoScroll ? "waiting" : "idle"
            NSLog("PerfProbe: %@", accessibilityValue ?? "")
            if Self.autoScroll {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.begin("slow") }
            }
            return
        }
        guard phase == "slow" || phase == "fast", let scrollView = controller.scrollView else { return }
        if lastTick > 0 {
            let gap = link.timestamp - lastTick
            let nominal = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
            maxGap = max(maxGap, gap)
            if gap > 0.05 { longFrames += 1 }
            if gap > nominal * 2.0 + 0.002 { droppedFrames += 1 }
        }
        lastTick = link.timestamp
        frames += 1
        footprintMax = max(footprintMax, Self.footprintMB())
        let step: CGFloat = phase == "slow" ? 24 : 96
        var offset = scrollView.contentOffset
        let maxY = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        offset.y = min(offset.y + step, maxY)
        scrollView.setContentOffset(offset, animated: false)
        if link.timestamp - phaseStart >= 8 { end() }
    }

    private func begin(_ name: String) {
        phase = name
        phaseStart = CACurrentMediaTime()
        lastTick = 0
        frames = 0
        maxGap = 0
        longFrames = 0
        droppedFrames = 0
        startPage = centrePage() ?? 0
        footprintBefore = Self.footprintMB()
        footprintMax = footprintBefore
    }

    private func end() {
        let name = phase
        let pages = (centrePage() ?? 0) - startPage
        figures.append(String(format: "%@Frames %d %@MaxGapMS %.0f %@Long %d %@Dropped %d %@Pages %d %@FootprintMB %.0f/%.0f/%.0f",
                              name, frames, name, maxGap * 1000, name, longFrames, name, droppedFrames, name, pages,
                              name, footprintBefore, footprintMax, Self.footprintMB()))
        NSLog("PerfProbe: %@", figures.last ?? "")
        if name == "slow" {
            phase = "pause"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.begin("fast") }
        } else {
            phase = "done"
        }
    }

    /// PDFKit's current page, 1-based.
    private func currentPage() -> Int? {
        guard let controller, let page = controller.view.currentPage else { return nil }
        return controller.pageIndex(of: page).map { $0 + 1 }
    }

    /// The page at the view's centre, 1-based (PDFKit's `currentPage` lags behind offsets set
    /// frame by frame).
    private func centrePage() -> Int? {
        guard let controller else { return nil }
        let view = controller.view
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let page = view.page(for: centre, nearest: true) else { return nil }
        return controller.pageIndex(of: page).map { $0 + 1 }
    }

    // MARK: Process

    /// When the kernel started this process.
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
#endif
