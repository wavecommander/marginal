import ReaderCore
import SwiftUI

/// The "Continue reading" card: cover, title, where you are, progress, and the two shortcuts.
/// Wide windows lay it out in one row; compact windows stack it.
struct ContinueReadingCard: View {
    @Environment(\.accentTheme) private var accentTheme
    let book: Book
    let annotationCount: Int
    /// The book's PDF is not on this iPad: the cover carries the "PDF missing" badge.
    var isMissingPDF = false
    let onResume: () -> Void
    let onNotebook: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                HStack(spacing: 20) {
                    cover
                    info
                    Spacer(minLength: 0)
                    HStack(spacing: 12) { notebookButton; resumeButton }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) { cover; info }
                    HStack(spacing: 12) { notebookButton; resumeButton }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.continueCard")
    }

    private var cover: some View {
        Color.clear
            .frame(width: 88, height: 116)
            .overlay { BookCoverView(book: book, isMissingPDF: isMissingPDF) }
            .bookCoverStyle(cornerRadius: 6)
            .overlay(alignment: .bottom) {
                if isMissingPDF {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Palette.ink)
                        .padding(Space.xs + 2)
                        .background(.regularMaterial, in: Circle())
                        .padding(.bottom, Space.xs)
                }
            }
            .accessibilityHidden(true)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Continue reading")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(book.title)
                .font(.title3.weight(.bold))
                .lineLimit(2)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ProgressView(value: LibraryLogic.progressFraction(book))
                .padding(.top, 6)
                .frame(maxWidth: 420)
                .accessibilityLabel(progressLabel)
        }
    }

    private var detail: String {
        [LibraryLogic.pageLine(book), LibraryLogic.annotationLine(count: annotationCount),
         isMissingPDF ? MissingPDFText.badge : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var progressLabel: String {
        LibraryLogic.percentRead(book).map { "\($0) percent read" } ?? "Not started"
    }

    private var notebookButton: some View {
        Button("Open Notebook", action: onNotebook)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("library.continue.notebook")
    }

    private var resumeButton: some View {
        Button("Resume", action: onResume)
            .buttonStyle(.borderedProminent)
            .foregroundStyle(accentTheme.onAccent)
            .controlSize(.large)
            .accessibilityIdentifier("library.continue.resume")
    }
}

/// One import in progress: file name, a progress bar for the copy, and Cancel.
struct ImportProgressRow: View {
    let job: ImportJob

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(job.fileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: job.phase == .waiting || job.phase == .checking || job.phase == .finishing ? nil : job.fraction)
            }
            Button(role: .cancel) {
                job.cancel()
            } label: {
                Label("Cancel Import", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("library.import.cancel")
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.import.\(job.fileName)")
    }

    private var status: String {
        let percent = Int((job.fraction * 100).rounded())
        return switch job.phase {
        case .waiting:
            String(localized: "Waiting…", comment: "Library import progress row: the import has not started.")
        case .checking:
            String(localized: "Checking…", comment: "Library import progress row: reading the file's format.")
        case .copying:
            String(localized: "Importing… \(percent)%", comment: "Library import progress row: copying the file. The argument is a percentage.")
        case .converting:
            String(localized: "Converting to PDF… \(percent)%", comment: "Library import progress row: converting the file. The argument is a percentage.")
        case .finishing:
            String(localized: "Finishing…", comment: "Library import progress row: final checks.")
        }
    }
}
