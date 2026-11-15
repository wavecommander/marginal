import CoreGraphics
import Foundation
import ReaderCore

// The contract between the import flow and the converters that turn a non-PDF file into the PDF
// the app reads. The flow owns the files (staging directory, the kept original, the commit); a
// converter only reads the original and writes one PDF. See docs/FORMAT_IMPORT_PLAN.md.

/// Body text size for formats the app lays out itself (EPUB, text, Markdown, HTML). Chosen in the
/// Convert to PDF sheet; it cannot be changed after converting.
nonisolated enum ConversionTextSize: String, Sendable, CaseIterable, Codable {
    case small, medium, large
}

/// What the reader chose in the Convert to PDF sheet.
nonisolated struct ConversionOptions: Sendable, Equatable {
    var textSize: ConversionTextSize = .medium

    /// The page for formats the app lays out itself: a 6 × 9 inch trade page, in points.
    /// Documents, slides and images keep their own page size.
    static let reflowPageSize = CGSize(width: 432, height: 648)
}

/// What a converter is given.
nonisolated struct ConversionInput: Sendable {
    /// The original file. Read-only: a converter never writes to or moves it.
    var original: URL
    var format: ImportFormat
    /// The original's name as the reader chose it, for titles and error messages.
    var fileName: String
    /// An existing directory the converter may write into. The flow removes it on failure or cancel.
    var directory: URL
    /// File name the PDF must be written to inside `directory`.
    var outputFileName: String
    var options: ConversionOptions

    var outputURL: URL { directory.appendingPathComponent(outputFileName, isDirectory: false) }
}

/// What a converter hands back.
nonisolated struct ConvertedDocument: Sendable, Equatable {
    /// The generated PDF (`ConversionInput.outputURL`). Its outline, when the format has a table
    /// of contents, is already inside the file.
    var pdf: URL
    var pageCount: Int
    /// The document's own title (EPUB metadata, for instance); `nil` to use the file name.
    var title: String?
    /// An image file inside the staging directory to use as the cover; `nil` to render page one.
    var coverImage: URL?
}

/// Why a conversion did not produce a PDF. The import flow turns these into `ImportError`s.
nonisolated enum ConversionError: Error, Sendable, Equatable {
    /// The file is copy-protected and cannot be read.
    case protected
    /// The file is of a kind the converter recognises but does not handle (fixed-layout EPUB).
    case unsupported(reason: String)
    /// The file could not be read or rendered.
    case failed(reason: String)
}

/// Turns files of some formats into a PDF. Implementations are stateless and may be called for
/// several files at once. Cancellation is the task's: check `Task.isCancelled` between units of
/// work and throw `CancellationError`.
nonisolated protocol DocumentConverter: Sendable {
    /// Stored in `Book.converterVersion`. Raise it when the output for the same input changes.
    var version: Int { get }
    /// The formats this converter takes.
    var formats: Set<ImportFormat> { get }
    /// Writes the PDF to `input.outputURL`. `progress` receives `0...1` and may be called from
    /// any thread.
    func convert(_ input: ConversionInput, progress: @escaping @Sendable (Double) -> Void) async throws -> ConvertedDocument
}

/// The converters the app has, by format.
nonisolated struct ConverterRegistry: Sendable {
    private var byFormat: [ImportFormat: any DocumentConverter] = [:]

    init(_ converters: [any DocumentConverter] = []) {
        for converter in converters { register(converter) }
    }

    /// Adds a converter for each of its formats. A later registration for a format replaces an
    /// earlier one. PDF is never registered: PDFs are imported as they are.
    mutating func register(_ converter: any DocumentConverter) {
        for format in converter.formats where format != .pdf { byFormat[format] = converter }
    }

    func converter(for format: ImportFormat) -> (any DocumentConverter)? { byFormat[format] }

    /// Formats that can be imported by conversion right now.
    var convertibleFormats: Set<ImportFormat> { Set(byFormat.keys) }

    /// The app's converters. Each converter package adds its line here.
    static let standard = ConverterRegistry([
        ImagesConverter(),
    ])
}
