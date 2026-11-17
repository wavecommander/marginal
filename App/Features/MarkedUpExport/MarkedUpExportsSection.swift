import ReaderCore
import SwiftUI

/// "Exported PDFs" at the top of a book's Notebook (design: "Export Marked-Up PDF", *Exported
/// PDFs*): every marked-up PDF export of the book, newest first. A running one shows its progress
/// and time left (Stop asks first); a finished one its size and date, with Share and Delete
/// (Delete asks first); one that did not finish says why, with Try Again and Remove. Shown only
/// when the book has exports; it can be folded away.
struct MarkedUpExportsSection: View {
    let book: Book?
    let bookID: UUID
    let library: MarkedUpExportLibrary
    let store: LibraryStore
    var isWide = true

    @SceneStorage private var isExpanded: Bool
    @State private var stopCandidate: UUID?
    @State private var deleteCandidate: MarkedUpExportRecord?
    @State private var confirmation: MarkedUpExportController.Confirmation?

    init(book: Book?, bookID: UUID, library: MarkedUpExportLibrary, store: LibraryStore, isWide: Bool = true) {
        self.book = book
        self.bookID = bookID
        self.library = library
        self.store = store
        self.isWide = isWide
        _isExpanded = SceneStorage(wrappedValue: true, "notebook.\(bookID.uuidString).exportsExpanded")
    }

    private var records: [MarkedUpExportRecord] { library.records(for: bookID) }

    var body: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isExpanded {
                    // Three rows at their own height; more scroll inside the section.
                    if records.count > 3 {
                        ScrollView { rows }
                            .frame(height: 230)
                    } else {
                        rows
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: 780)
            .padding(.horizontal, isWide ? 36 : 16)
            .padding(.top, 12)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.MarkedUpExport.notebookSection)
            .markedUpExportStopConfirmation($stopCandidate, library: library)
            .markedUpExportConfirmation($confirmation) { confirmRetry() }
            .alert(MarkedUpExportWording.deleteTitle,
                   isPresented: Binding(get: { deleteCandidate != nil }, set: { _ in })) {
                Button("Delete", role: .destructive) {
                    if let record = deleteCandidate { library.delete(record.id) }
                    deleteCandidate = nil
                }
                .accessibilityIdentifier(AccessibilityID.MarkedUpExport.confirmDelete)
                Button("Cancel", role: .cancel) { deleteCandidate = nil }
            } message: {
                if let deleteCandidate { Text(MarkedUpExportWording.deleteMessage(deleteCandidate)) }
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(records) { record in
                row(record)
                if record.id != records.last?.id { Divider().padding(.leading, 44) }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Text("Exported PDFs").font(.headline)
                Text(summary).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, isExpanded ? 6 : 0)
        .accessibilityLabel("Exported PDFs")
        .accessibilityValue(summary)
        .accessibilityHint(isExpanded ? "Hides the exported PDFs" : "Shows the exported PDFs")
    }

    /// "2 · 96 MB" (count, and the space the files take).
    private var summary: String {
        let bytes = records.compactMap(\.byteCount).reduce(0, +)
        let count = records.count.formatted()
        return bytes > 0 ? "\(count) · \(bytes.formatted(.byteCount(style: .file)))" : count
    }

    @ViewBuilder
    private func row(_ record: MarkedUpExportRecord) -> some View {
        HStack(spacing: 12) {
            icon(record)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.fileName)
                    .font(.body)
                    .lineLimit(2)
                detail(record)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.MarkedUpExport.notebookRow + "." + record.fileName)
            actions(record)
        }
        .padding(.vertical, 8)
        .contextMenu {
            if record.isFinished {
                ShareLink(item: library.fileURL(for: record)) { Label("Share", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { deleteCandidate = record } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    @ViewBuilder
    private func icon(_ record: MarkedUpExportRecord) -> some View {
        if record.isRunning {
            MarkedUpExportProgressRing(fraction: library.progress[record.id]?.fraction ?? 0)
        } else if record.isFinished {
            Image(systemName: record.includesNotes ? "doc.on.doc.fill" : "doc.richtext.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func detail(_ record: MarkedUpExportRecord) -> some View {
        if record.isRunning {
            Text(MarkedUpExportTimeEstimate.text(remaining: library.remaining(record.id)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else if record.isFinished {
            Text(MarkedUpExportWording.finishedDetail(record))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Text("Didn't finish: \(record.unfinishedReason ?? "")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private func actions(_ record: MarkedUpExportRecord) -> some View {
        if record.isRunning {
            Button("Stop", role: .destructive) { stopCandidate = record.id }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Stop Export")
                .accessibilityIdentifier(AccessibilityID.MarkedUpExport.notebookStop)
        } else if record.isFinished {
            ShareLink(item: library.fileURL(for: record)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .simultaneousGesture(TapGesture().onEnded { library.acknowledge(record.id) })
            .accessibilityIdentifier(AccessibilityID.MarkedUpExport.notebookShare)
            Button(role: .destructive) { deleteCandidate = record } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Delete")
            .accessibilityIdentifier(AccessibilityID.MarkedUpExport.notebookDelete)
        } else {
            Button("Try Again") { askToRetry(record) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(book == nil || library.isRunning(bookID: bookID))
                .accessibilityIdentifier(AccessibilityID.MarkedUpExport.notebookRetry)
            // Nothing was made: removing the line deletes no file.
            Button { library.delete(record.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Remove")
        }
    }

    private func askToRetry(_ record: MarkedUpExportRecord) {
        guard let book else { return }
        confirmation = .init(includesNotes: record.includesNotes,
                             sourceByteCount: ReaderSession.byteCount(of: store.documentURL(for: book)),
                             retryOf: record.id)
    }

    private func confirmRetry() {
        guard let pending = confirmation, let retry = pending.retryOf, let book else {
            confirmation = nil
            return
        }
        confirmation = nil
        library.retry(retry, book: book, store: store, cardOwner: nil)
    }
}
