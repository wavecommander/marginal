import Foundation

/// Launch milestones for the DEBUG performance probe (`-perfProbe`, `ReaderPerfProbe`):
/// milliseconds from the process start to each named point, shown in the probe's value as
/// `marks name:ms,…`. A no-op in release builds and without `-perfProbe`.
@MainActor
enum PerfMarks {
    #if DEBUG
    private(set) static var marks: [(String, Int)] = []
    #endif

    static func mark(_ name: String) {
        #if DEBUG
        guard ReaderPerfProbe.isEnabled, !marks.contains(where: { $0.0 == name }) else { return }
        marks.append((name, Int(Date().timeIntervalSince(ReaderPerfProbe.processStart) * 1000)))
        #endif
    }
}
