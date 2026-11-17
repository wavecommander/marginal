import Foundation
import os
import PencilKit

/// Whether this system can show and edit a stored drawing in full: the PencilKit content-version
/// rule (`docs/CLOUD_SYNC_FINDINGS.md` §3). A drawing made with an ink from a newer system may
/// load here with those strokes missing; edited and saved, or pushed, it would erase them on
/// every device. So a page or note whose ink is not supported here is shown as far as this
/// system can (or not at all), is never written over by this device, and sync reports it busy
/// every round (`SyncSurface`), so the engine never pushes it and keeps its base.
///
/// **The rule** (`isSupported(_:maximumSupportedVersion:)`), for stored ink data:
/// - data that does not decode, or decodes to no strokes (the app never stores empty ink;
///   PencilKit reads some damaged data as empty), is not supported;
/// - note ink whose band list names more strokes than PencilKit read lost strokes: not supported;
/// - otherwise, when both the drawing's `requiredContentVersion` and this system's maximum are
///   known, supported only if the drawing needs no more than the maximum;
/// - when either cannot be determined, supported (every stroke decoded).
///
/// **The system's maximum** is the default `maximumSupportedContentVersion` of a `PKCanvasView`
/// ("defaults to .latest": the running PencilKit's latest, so a newer system than this SDK
/// reports its own), read once on the main actor by `prepare()`. Until then the maximum is
/// worked out from the system version (the availability ladder in `fallbackMaximumVersion`).
/// Every API used exists at iPadOS 17.0.
nonisolated enum InkContentSupport {
    /// What was read from one stored drawing.
    struct Inspection: Hashable, Sendable {
        /// The data decoded as a drawing (for note ink: as `NoteInkArchive` or a plain drawing).
        var decodes: Bool
        /// Strokes PencilKit read.
        var strokeCount: Int
        /// Strokes the data says it holds (note ink's band list), `nil` when it does not say.
        var declaredStrokeCount: Int?
        /// `PKDrawing.requiredContentVersion`, `nil` when unknown.
        var requiredVersion: Int?

        static let undecodable = Inspection(decodes: false, strokeCount: 0, declaredStrokeCount: nil, requiredVersion: nil)
    }

    /// The rule (see the type).
    static func isSupported(_ inspection: Inspection, maximumSupportedVersion: Int?) -> Bool {
        guard inspection.decodes, inspection.strokeCount > 0 else { return false }
        if let declared = inspection.declaredStrokeCount, declared != inspection.strokeCount { return false }
        if let required = inspection.requiredVersion, let maximum = maximumSupportedVersion { return required <= maximum }
        return true
    }

    /// Page ink data (`PKDrawing.dataRepresentation()`).
    static func inspectPageInk(_ data: Data) -> Inspection {
        guard !data.isEmpty, let drawing = try? PKDrawing(data: data) else { return .undecodable }
        return Inspection(decodes: true, strokeCount: drawing.strokes.count, declaredStrokeCount: nil,
                          requiredVersion: drawing.requiredContentVersion.rawValue)
    }

    /// Note ink data (`NoteInkArchive`, or a plain drawing from older data).
    static func inspectNoteInk(_ data: Data) -> Inspection {
        guard !data.isEmpty, let (drawing, declared) = NoteInkArchive.inspect(data) else { return .undecodable }
        return Inspection(decodes: true, strokeCount: drawing.strokes.count, declaredStrokeCount: declared,
                          requiredVersion: drawing.requiredContentVersion.rawValue)
    }

    /// For the editors, which already treat data that does not decode as unreadable: `true` only
    /// for data that decodes but needs a newer system (a newer content version, or strokes
    /// dropped), which they must then leave alone.
    static func needsNewerSystem(_ inspection: Inspection, maximumSupportedVersion: Int?) -> Bool {
        guard inspection.decodes, inspection.strokeCount > 0 || inspection.declaredStrokeCount ?? 0 > 0 else { return false }
        return !isSupported(inspection, maximumSupportedVersion: maximumSupportedVersion)
    }

    static func needsNewerSystem(pageInk data: Data) -> Bool {
        needsNewerSystem(inspectPageInk(data), maximumSupportedVersion: maximumSupportedVersion)
    }

    static func needsNewerSystem(noteInk data: Data) -> Bool {
        needsNewerSystem(inspectNoteInk(data), maximumSupportedVersion: maximumSupportedVersion)
    }

    static func isSupported(pageInk data: Data) -> Bool {
        isSupported(inspectPageInk(data), maximumSupportedVersion: maximumSupportedVersion)
    }

    static func isSupported(noteInk data: Data) -> Bool {
        isSupported(inspectNoteInk(data), maximumSupportedVersion: maximumSupportedVersion)
    }

    // MARK: The system's maximum

    private static let measured = OSAllocatedUnfairLock<Int?>(initialState: nil)

    /// The highest content version this system supports.
    static var maximumSupportedVersion: Int {
        measured.withLock { $0 } ?? fallbackMaximumVersion
    }

    /// Reads the running PencilKit's maximum from a canvas (main actor; once).
    @MainActor
    static func prepare() {
        guard measured.withLock({ $0 }) == nil else { return }
        let value = PKCanvasView().maximumSupportedContentVersion.rawValue
        measured.withLock { $0 = max(value, 1) }
    }

    /// The maximum by system version, as the SDK's `PKContentVersion` cases are available:
    /// version 5 from iOS 27, 4 from 26, 3 from 17.5, else 2 (iOS 17.0). On a system newer than
    /// this SDK it says 5, which only errs towards treating newer ink as unsupported.
    static var fallbackMaximumVersion: Int {
        if #available(iOS 27.0, *) { return 5 }
        if #available(iOS 26.0, *) { return 4 }
        if #available(iOS 17.5, *) { return 3 }
        return 2
    }
}
