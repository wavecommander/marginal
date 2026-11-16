import Foundation
import PencilKit
import ReaderCore

/// The persisted form of a note's ink (the `Data` stored with `LibraryStore.saveNoteInk`).
///
/// **Format (version 1):** a binary property list (`PropertyListEncoder`, `.binary`) of
///
///     format:  "software.tactile.texts.note-ink"
///     version: 1
///     layout:  NoteBandLayout   — the band layout the strokes are anchored to
///     bands:   [Int]            — per stroke, in z-order: paragraph index, or -1 for trailing
///     drawing: Data             — PKDrawing.dataRepresentation() of the strokes, each in
///                                 band-local coordinates (page y minus its band's top)
///
/// Ink is only ever PencilKit vector data. The layout is stored *inside* the ink data as well as
/// in `Note.bandLayout`, so the strokes and the layout their band references point into can never
/// disagree (the record and the ink file are separate writes). Readers use the embedded layout and
/// fall back to `Note.bandLayout` only for foreign data.
///
/// **Compatibility:** data that is not this archive but is a plain `PKDrawing` is accepted as
/// strokes in note-page coordinates against `fallbackLayout`, anchored by geometry. A `bands`
/// array whose length does not match the drawing's strokes is ignored the same way.
nonisolated enum NoteInkArchive {
    static let formatIdentifier = "software.tactile.texts.note-ink"
    static let currentVersion = 1

    private struct Payload: Codable {
        var format: String
        var version: Int
        var layout: NoteBandLayout
        var bands: [Int]
        var drawing: Data
    }

    enum DecodingFailure: Error, Equatable {
        /// Neither an archive nor a PencilKit drawing.
        case unreadable
        /// An archive written by a newer version of the app.
        case unsupportedVersion(Int)
    }

    /// Encodes ink. The strokes keep their band-local form, so decoding returns exactly what was
    /// encoded (no coordinate arithmetic on the way).
    static func encode(_ ink: NoteInk) throws -> Data {
        let drawing = PKDrawing(strokes: ink.strokes.map(\.local))
        let payload = Payload(format: formatIdentifier, version: currentVersion, layout: ink.layout,
                              bands: ink.strokes.map { code(for: $0.band) },
                              drawing: drawing.dataRepresentation())
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(payload)
    }

    /// Decodes ink against the layout stored in it (see the type documentation for foreign data).
    /// The result's `layout` is the stored layout: relocate it to the current text's layout with
    /// `NoteInk.relayout(to:)`.
    static func decode(_ data: Data, fallbackLayout: NoteBandLayout) throws -> NoteInk {
        if let payload = try? PropertyListDecoder().decode(Payload.self, from: data),
           payload.format == formatIdentifier {
            guard payload.version <= currentVersion else { throw DecodingFailure.unsupportedVersion(payload.version) }
            let drawing = try PKDrawing(data: payload.drawing)
            let strokes = drawing.strokes
            if payload.bands.count == strokes.count {
                let anchored = zip(strokes, payload.bands).map { stroke, code in
                    NoteInkStroke(band: band(for: code), local: stroke)
                }
                return NoteInk(layout: payload.layout, strokes: anchored)
            }
            // Damaged band list: the bands cannot be known, so read the strokes as page
            // coordinates of the stored layout and anchor them by geometry (never drop them).
            return anchoredByGeometry(strokes, layout: payload.layout)
        }
        guard let drawing = try? PKDrawing(data: data) else { throw DecodingFailure.unreadable }
        return anchoredByGeometry(drawing.strokes, layout: fallbackLayout)
    }

    private static func anchoredByGeometry(_ strokes: [PKStroke], layout: NoteBandLayout) -> NoteInk {
        NoteInk(layout: layout, strokes: strokes.map { stroke in
            let band = layout.band(for: stroke.renderBounds)
            return NoteInkStroke(band: band, local: stroke.translatedVertically(by: -(layout.top(of: band) ?? 0)))
        })
    }

    private static func code(for band: NoteBandRef) -> Int {
        switch band {
        case .trailing: -1
        case .paragraph(let index): index
        }
    }

    private static func band(for code: Int) -> NoteBandRef {
        code < 0 ? .trailing : .paragraph(code)
    }
}
