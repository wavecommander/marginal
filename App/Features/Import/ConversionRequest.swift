import Foundation
import ReaderCore

// The Convert to PDF step of an import (docs/FORMAT_IMPORT_PLAN.md, "Decision: tell the reader
// before converting"). `ImportService` makes one `ConversionRequest` per import batch that has a
// file needing conversion, addressed to the window that asked; that window's Library shows the
// sheet, and the reader's answer goes back through `ImportService.convert` or `.discard`.

/// One file waiting in a `ConversionRequest`. Nothing has been copied yet: `source` is the file as
/// it was chosen (security-scoped while `holdsSecurityScope`), dropped or handed over.
nonisolated struct ConversionItem: Identifiable, Sendable, Equatable {
    let id = UUID()
    let source: URL
    /// The name as the reader chose it.
    let fileName: String
    let format: ImportFormat
    /// Size and fingerprint of the original (the converted book's fingerprint).
    let probe: ImportPipeline.Probe
    /// The source is the app's own temporary copy (drop landing area, "Open in" inbox): delete it
    /// when the request is answered.
    let consumeSource: Bool
    /// `startAccessingSecurityScopedResource()` succeeded at the pick; stopped when the request is
    /// answered.
    let holdsSecurityScope: Bool
}

/// A file in the batch that cannot be imported, listed in the sheet with its reason.
nonisolated struct RejectedFile: Identifiable, Sendable, Equatable {
    let id = UUID()
    let fileName: String
    let error: ImportError
}

/// The files of one import batch that need the reader's go-ahead to be converted, plus the
/// batch's files that cannot be imported at all.
nonisolated struct ConversionRequest: Identifiable, Sendable, Equatable {
    let id: UUID
    /// The window whose Library shows the sheet (`ObjectIdentifier` of its `WindowContext`).
    /// `nil` until a window is chosen (a `-importFixture` import, addressed by the first window
    /// once launch work is done).
    var windowKey: ObjectIdentifier?
    let items: [ConversionItem]
    let rejected: [RejectedFile]
    /// Open the book in the requesting window once converted ("Open in" does; the picker and
    /// drops do not, as for PDFs).
    let opensBookWhenDone: Bool

    init(id: UUID = UUID(), windowKey: ObjectIdentifier?, items: [ConversionItem], rejected: [RejectedFile],
         opensBookWhenDone: Bool = false) {
        self.id = id
        self.windowKey = windowKey
        self.items = items
        self.rejected = rejected
        self.opensBookWhenDone = opensBookWhenDone
    }

    /// The limitation groups present, in `LimitationGroup.allCases` order.
    var groups: [LimitationGroup] {
        LimitationGroup.allCases.filter { group in items.contains { $0.format.limitationGroup == group } }
    }

    /// The batch's files in `group`, in batch order.
    func items(in group: LimitationGroup) -> [ConversionItem] {
        items.filter { $0.format.limitationGroup == group }
    }

    /// Whether the sheet shows the Text size setting.
    var offersTextSizeChoice: Bool { groups.contains(where: \.offersTextSizeChoice) }
}

/// What a converted book was made with, stored beside its PDF as `conversion.json`
/// (`ImportPipeline.conversionRecordFileName`), so a re-conversion (`restoreMissingDocument`)
/// can use the same settings. Small and versioned; unknown keys are ignored when read.
nonisolated struct ConversionRecord: Codable, Sendable, Equatable {
    var recordVersion = 1
    var sourceFormat: ImportFormat
    var converterVersion: Int
    var textSize: ConversionTextSize

    init(sourceFormat: ImportFormat, converterVersion: Int, options: ConversionOptions) {
        self.sourceFormat = sourceFormat
        self.converterVersion = converterVersion
        self.textSize = options.textSize
    }

    var options: ConversionOptions {
        var options = ConversionOptions()
        options.textSize = textSize
        return options
    }
}
