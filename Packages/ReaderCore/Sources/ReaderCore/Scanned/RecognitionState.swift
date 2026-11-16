import Foundation

/// How far recognition of a scanned book has got.
public struct RecognitionProgress: Hashable, Codable, Sendable {
    /// Pages recognised and saved so far.
    public var pagesDone: Int
    /// Pages to recognise in all (the book's page count).
    public var totalPages: Int

    /// `pagesDone` and `totalPages` are clamped so that `0 <= pagesDone <= totalPages`.
    public init(pagesDone: Int, totalPages: Int) {
        self.totalPages = max(0, totalPages)
        self.pagesDone = min(max(0, pagesDone), self.totalPages)
    }

    /// `pagesDone / totalPages` in `0...1`; 1 for a book with no pages.
    public var fractionDone: Double {
        totalPages == 0 ? 1 : Double(pagesDone) / Double(totalPages)
    }

    /// Every page is done.
    public var isFinished: Bool { pagesDone >= totalPages }
}

/// Why recognition is paused. Several can hold at once; it resumes when none does.
public enum RecognitionPauseReason: String, CaseIterable, Hashable, Codable, Sendable {
    /// The reader chose Pause.
    case reader
    /// Low Power Mode is on.
    case lowPowerMode
    /// The device is under serious (or critical) thermal pressure.
    case thermal
}

/// Where a scanned book stands with text recognition, stored in the book's sidecar
/// (`BookStorageLayout.recognitionStatePath`). A book with a text layer has no state at all
/// (`RecognisedTextStore.recognitionState` returns `nil`); a book found to be scanned starts at
/// `.notDecided`.
///
/// The transitions are the methods below. Each returns the next state, or `nil` when the event
/// does not apply in this state (the caller keeps the state it has). They are pure: the queue,
/// the notice and the search panel all go through them, so every window agrees.
///
/// | From | Event | To |
/// | --- | --- | --- |
/// | not decided | `declining()` | declined |
/// | not decided, declined | `accepting(totalPages:pagesDone:)` | in progress (complete if nothing is left) |
/// | in progress | `pausing(_:)` | paused |
/// | paused | `pausing(_:)` | paused, with the reason added |
/// | paused | `resuming(_:)` | paused without that reason, or in progress when none is left |
/// | in progress, paused | `finishingPage()` | one page more; complete after the last |
/// | in progress, paused | `finishing()` | complete |
///
/// Declining is never final: a declined book can be accepted later (from search). Declining a
/// book that is already declined, and resuming a book that is in progress, leave it as it is.
/// A page may finish while paused (the page in flight when the pause came is still saved).
public enum RecognitionState: Hashable, Sendable {
    /// Found to be scanned; the reader has not chosen yet.
    case notDecided
    /// The reader chose Not Now.
    case declined
    /// Recognition is running (or queued to run).
    case inProgress(RecognitionProgress)
    /// Recognition is paused for `reasons` (never empty).
    case paused(RecognitionProgress, reasons: Set<RecognitionPauseReason>)
    /// Every page has been recognised.
    case complete

    /// The progress while in progress or paused, else `nil`.
    public var progress: RecognitionProgress? {
        switch self {
        case .inProgress(let progress), .paused(let progress, _): progress
        default: nil
        }
    }

    /// The reader has not made the book searchable yet (not decided or declined): the search
    /// panel offers it, and nothing is recognised.
    public var isAwaitingDecision: Bool {
        switch self {
        case .notDecided, .declined: true
        default: false
        }
    }

    /// The reasons the book is paused (empty unless paused).
    public var pauseReasons: Set<RecognitionPauseReason> {
        if case .paused(_, let reasons) = self { return reasons }
        return []
    }

    // MARK: Transitions

    /// The reader chose Not Now. From not decided or declined; `nil` otherwise.
    public func declining() -> RecognitionState? {
        isAwaitingDecision ? .declined : nil
    }

    /// The reader chose Make Searchable, at import or later from search (also after declining).
    /// From not decided or declined; `nil` otherwise. `pagesDone` counts pages already in the
    /// store (normally 0). Complete at once when nothing is left to do.
    public func accepting(totalPages: Int, pagesDone: Int = 0) -> RecognitionState? {
        guard isAwaitingDecision else { return nil }
        let progress = RecognitionProgress(pagesDone: pagesDone, totalPages: totalPages)
        return progress.isFinished ? .complete : .inProgress(progress)
    }

    /// One more page was recognised and saved. From in progress or paused; complete after the
    /// last page. `nil` otherwise.
    public func finishingPage() -> RecognitionState? {
        switch self {
        case .inProgress(var progress):
            progress.pagesDone = min(progress.pagesDone + 1, progress.totalPages)
            return progress.isFinished ? .complete : .inProgress(progress)
        case .paused(var progress, let reasons):
            progress.pagesDone = min(progress.pagesDone + 1, progress.totalPages)
            return progress.isFinished ? .complete : .paused(progress, reasons: reasons)
        default:
            return nil
        }
    }

    /// Recognition pauses for `reason`. From in progress, or paused (the reason is added);
    /// `nil` otherwise.
    public func pausing(_ reason: RecognitionPauseReason) -> RecognitionState? {
        switch self {
        case .inProgress(let progress): .paused(progress, reasons: [reason])
        case .paused(let progress, let reasons): .paused(progress, reasons: reasons.union([reason]))
        default: nil
        }
    }

    /// `reason` no longer holds. From paused: the reason is removed, and recognition runs again
    /// when no reason is left. In progress stays as it is. `nil` otherwise.
    public func resuming(_ reason: RecognitionPauseReason) -> RecognitionState? {
        switch self {
        case .inProgress:
            return self
        case .paused(let progress, var reasons):
            reasons.remove(reason)
            return reasons.isEmpty ? .inProgress(progress) : .paused(progress, reasons: reasons)
        default:
            return nil
        }
    }

    /// Every page is recognised (the queue found nothing left to do). From in progress or
    /// paused; `nil` otherwise.
    public func finishing() -> RecognitionState? {
        progress == nil ? nil : .complete
    }
}

// MARK: - Coding

/// The sidecar's JSON: `{"state": "<kind>"}` plus, while in progress or paused, `pagesDone` and
/// `totalPages`, and while paused, `pausedFor` (the reasons' raw values, sorted). Readable, and
/// the same state always gives the same bytes with sorted keys.
extension RecognitionState: Codable {
    private enum CodingKeys: String, CodingKey {
        case state, pagesDone, totalPages, pausedFor
    }

    private enum Kind: String, Codable {
        case notDecided, declined, inProgress, paused, complete
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func progress() throws -> RecognitionProgress {
            RecognitionProgress(pagesDone: try container.decode(Int.self, forKey: .pagesDone),
                                totalPages: try container.decode(Int.self, forKey: .totalPages))
        }
        switch try container.decode(Kind.self, forKey: .state) {
        case .notDecided: self = .notDecided
        case .declined: self = .declined
        case .complete: self = .complete
        case .inProgress: self = .inProgress(try progress())
        case .paused:
            let reasons = Set(try container.decode([RecognitionPauseReason].self, forKey: .pausedFor))
            guard !reasons.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .pausedFor, in: container, debugDescription: "paused with no reason")
            }
            self = .paused(try progress(), reasons: reasons)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notDecided: try container.encode(Kind.notDecided, forKey: .state)
        case .declined: try container.encode(Kind.declined, forKey: .state)
        case .complete: try container.encode(Kind.complete, forKey: .state)
        case .inProgress(let progress):
            try container.encode(Kind.inProgress, forKey: .state)
            try container.encode(progress.pagesDone, forKey: .pagesDone)
            try container.encode(progress.totalPages, forKey: .totalPages)
        case .paused(let progress, let reasons):
            try container.encode(Kind.paused, forKey: .state)
            try container.encode(progress.pagesDone, forKey: .pagesDone)
            try container.encode(progress.totalPages, forKey: .totalPages)
            try container.encode(reasons.map(\.rawValue).sorted(), forKey: .pausedFor)
        }
    }
}
