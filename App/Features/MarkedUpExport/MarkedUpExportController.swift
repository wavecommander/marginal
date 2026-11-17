import Observation
import ReaderCore
import SwiftUI
import UIKit

/// A reader window's part of marked-up PDF exports (`ReaderSession.markedUpExport`): the
/// confirmation before one starts and the one before the user stops one. The exports themselves,
/// their progress and their files belong to the app (`MarkedUpExportLibrary`), so leaving the
/// book or closing the window does not stop one.
@Observable
@MainActor
final class MarkedUpExportController {
    struct Confirmation: Equatable {
        let includesNotes: Bool
        /// The size of the book's PDF, when known.
        let sourceByteCount: Int64?
        /// Trying an unfinished export again.
        let retryOf: UUID?
    }

    /// Waiting for the user to confirm an export.
    var confirmation: Confirmation?
    /// Waiting for the user to confirm stopping this running export.
    var stopCandidate: UUID?
}

/// What the confirmations and status lines say, in the reader and the Notebook.
enum MarkedUpExportWording {
    static func confirmationTitle(includesNotes: Bool) -> String {
        includesNotes ? "Export Book with Notes?" : "Export Marked-Up PDF?"
    }

    static func confirmationMessage(sourceByteCount: Int64?) -> String {
        let size = sourceByteCount.map { " (\($0.formatted(.byteCount(style: .file))))" } ?? ""
        return "This can take a long time, and Tactile Texts will create a file at least as big as the "
            + "current PDF\(size). It keeps going while you read or leave the book, and the finished PDF "
            + "is kept in this book's Notebook until you delete it."
    }

    static let stopTitle = "Stop Exporting?"
    static let stopMessage = "The PDF made so far is deleted. You can export again later."
    static let stopButton = "Stop Export"
    static let keepButton = "Keep Exporting"

    static let deleteTitle = "Delete Exported PDF?"
    static func deleteMessage(_ record: MarkedUpExportRecord) -> String {
        let size = record.byteCount.map { " (\($0.formatted(.byteCount(style: .file))))" } ?? ""
        return "“\(record.fileName)”\(size) is deleted from Tactile Texts. Copies you saved or shared "
            + "elsewhere are not affected. This can't be undone."
    }

    static func runningTitle(includesNotes: Bool) -> String {
        includesNotes ? "Exporting Book with Notes" : "Exporting Marked-Up PDF"
    }

    /// "48 MB · Today at 13:05".
    static func finishedDetail(_ record: MarkedUpExportRecord) -> String {
        let size = record.byteCount.map { $0.formatted(.byteCount(style: .file)) } ?? ""
        let date = (record.finishedAt ?? record.startedAt)
            .formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide))
        return [size, date].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Commands

/// The two ways to export, offered by the reader's More menu and the menu bar's Book menu.
nonisolated enum MarkedUpExportChoice: CaseIterable, Identifiable, Sendable {
    /// The book with its ink and highlights.
    case bookOnly
    /// The same, with the notes appended.
    case withNotes

    var id: Self { self }
    var includesNotes: Bool { self == .withNotes }

    var title: String {
        switch self {
        case .bookOnly: "Book Only"
        case .withNotes: "Book with Notes"
        }
    }

    var subtitle: String {
        switch self {
        case .bookOnly: "Ink and highlights drawn on the pages"
        case .withNotes: "Your notes added at the end"
        }
    }

    var systemImage: String {
        switch self {
        case .bookOnly: "doc.richtext"
        case .withNotes: "doc.on.doc"
        }
    }

    var accessibilityID: String {
        switch self {
        case .bookOnly: AccessibilityID.MarkedUpExport.bookOnly
        case .withNotes: AccessibilityID.MarkedUpExport.withNotes
        }
    }
}

extension ReaderSession {
    /// The command's title (More menu, menu bar).
    static let markedUpExportTitle = "Export Marked-Up PDF"

    /// The app's exports (`nil` in unit tests that build a session without one).
    var markedUpExports: MarkedUpExportLibrary? { configuration.markedUpExports }

    /// Whether this window can start an export now: the book is open, no export of it is running
    /// and none is waiting to be confirmed here.
    var canExportMarkedUpPDF: Bool {
        guard let markedUpExports, loadState == .ready, closeReason == nil else { return false }
        return !markedUpExports.isRunning(bookID: book.id) && markedUpExport.confirmation == nil
    }

    /// Whether `choice` is offered: "Book with Notes" only when the book has notes (or before the
    /// reader knows).
    func isMarkedUpExportAvailable(_ choice: MarkedUpExportChoice) -> Bool {
        guard canExportMarkedUpPDF else { return false }
        guard choice.includesNotes, let notebook else { return true }
        return notebook.totalCounts.notes > 0
    }

    /// Asks the user to confirm, then (`confirmMarkedUpExport()`) exports this book as a marked-up
    /// PDF. Every way of starting the export comes here.
    func exportMarkedUpPDF(_ choice: MarkedUpExportChoice) {
        guard isMarkedUpExportAvailable(choice) else { return }
        markedUpExport.confirmation = .init(includesNotes: choice.includesNotes,
                                            sourceByteCount: Self.byteCount(of: store.documentURL(for: book)),
                                            retryOf: nil)
    }

    /// Asks to confirm trying an unfinished export again.
    func retryMarkedUpExport(_ record: MarkedUpExportRecord) {
        guard canExportMarkedUpPDF else { return }
        markedUpExport.confirmation = .init(includesNotes: record.includesNotes,
                                            sourceByteCount: Self.byteCount(of: store.documentURL(for: book)),
                                            retryOf: record.id)
    }

    /// The user confirmed the export asked for: it starts, with its progress card in this window.
    func confirmMarkedUpExport() {
        guard let confirmation = markedUpExport.confirmation else { return }
        markedUpExport.confirmation = nil
        guard let markedUpExports, loadState == .ready, closeReason == nil else { return }
        if let retry = confirmation.retryOf {
            markedUpExports.retry(retry, book: book, store: store, cardOwner: id)
        } else {
            markedUpExports.start(book: book, store: store, includeNotes: confirmation.includesNotes, cardOwner: id)
        }
    }

    /// The export this reader shows (its card or pill): the book's running export, else its
    /// latest one the user has not seen end.
    var markedUpExportNotice: MarkedUpExportRecord? {
        markedUpExports?.notice(for: book.id)
    }

    nonisolated static func byteCount(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

/// The "Export Marked-Up PDF" submenu: one item per choice, each with what it holds.
struct MarkedUpExportMenu: View {
    let session: ReaderSession

    var body: some View {
        Menu {
            ForEach(MarkedUpExportChoice.allCases) { choice in
                Button { session.exportMarkedUpPDF(choice) } label: {
                    Label(choice.title, systemImage: choice.systemImage)
                    Text(choice.subtitle)
                }
                .disabled(!session.isMarkedUpExportAvailable(choice))
                .accessibilityIdentifier(choice.accessibilityID)
            }
        } label: {
            Label(ReaderSession.markedUpExportTitle, systemImage: "square.and.arrow.up")
        }
        .disabled(!session.canExportMarkedUpPDF)
        .accessibilityIdentifier(AccessibilityID.MarkedUpExport.menu)
    }
}

// MARK: - Presentation

extension View {
    /// The marked-up export's confirmation, progress card (Cancel, Continue in Background),
    /// status pill, share sheet (a popover from the toolbar's trailing end) and alerts, for the
    /// reader of `session`.
    func markedUpExportPresentation(_ session: ReaderSession) -> some View {
        modifier(MarkedUpExportPresentation(session: session))
    }

    /// The "Export Marked-Up PDF?" confirmation, shown while `confirmation` is set.
    func markedUpExportConfirmation(_ confirmation: Binding<MarkedUpExportController.Confirmation?>,
                                    onConfirm: @escaping () -> Void) -> some View {
        alert(MarkedUpExportWording.confirmationTitle(includesNotes: confirmation.wrappedValue?.includesNotes ?? false),
              isPresented: Binding(get: { confirmation.wrappedValue != nil }, set: { _ in })) {
            // Dismissal always goes through a button (Escape picks Cancel), which sets the state;
            // the binding's setter must not, since it can run before Export's action.
            Button("Export") { onConfirm() }
                .accessibilityIdentifier(AccessibilityID.MarkedUpExport.confirmExport)
            Button("Cancel", role: .cancel) { confirmation.wrappedValue = nil }
                .accessibilityIdentifier(AccessibilityID.MarkedUpExport.confirmCancel)
        } message: {
            Text(MarkedUpExportWording.confirmationMessage(sourceByteCount: confirmation.wrappedValue?.sourceByteCount))
        }
    }

    /// The "Stop Exporting?" confirmation, shown while `candidate` is set.
    func markedUpExportStopConfirmation(_ candidate: Binding<UUID?>, library: MarkedUpExportLibrary?) -> some View {
        alert(MarkedUpExportWording.stopTitle, isPresented: Binding(get: { candidate.wrappedValue != nil }, set: { _ in })) {
            Button(MarkedUpExportWording.stopButton, role: .destructive) {
                if let id = candidate.wrappedValue { library?.cancel(id) }
                candidate.wrappedValue = nil
            }
            .accessibilityIdentifier(AccessibilityID.MarkedUpExport.confirmStop)
            Button(MarkedUpExportWording.keepButton, role: .cancel) { candidate.wrappedValue = nil }
        } message: {
            Text(MarkedUpExportWording.stopMessage)
        }
    }
}

private struct MarkedUpExportPresentation: ViewModifier {
    let session: ReaderSession
    @Bindable private var controller: MarkedUpExportController

    init(session: ReaderSession) {
        self.session = session
        self.controller = session.markedUpExport
    }

    private var library: MarkedUpExportLibrary? { session.markedUpExports }
    private var notice: MarkedUpExportRecord? { session.markedUpExportNotice }
    private var showsCard: Bool {
        guard let notice, notice.isRunning else { return false }
        return library?.cardOwners[notice.id] == session.id
    }

    private var sharedURL: URL? {
        guard let library, let id = library.shareRequests[session.id], let record = library.record(id) else { return nil }
        return library.fileURL(for: record)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                NotebookShareSheetAnchor(item: sharedURL, onFinish: { library?.shareDidFinish(in: session.id) })
                    .frame(width: 1, height: 1)
                    .padding(.trailing, 28)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .top) {
                if !showsCard, let notice, let library {
                    MarkedUpExportPill(record: notice, library: library, session: session).padding(.top, 10)
                }
            }
            .overlay {
                if showsCard, let notice, let library {
                    MarkedUpExportCard(record: notice, library: library, session: session)
                }
            }
            .markedUpExportConfirmation($controller.confirmation) { session.confirmMarkedUpExport() }
            .markedUpExportStopConfirmation($controller.stopCandidate, library: library)
            .alert("Export Didn't Finish", isPresented: failed) {
                Button("OK") { library?.dismissFailureAlert(in: session.id) }
            } message: {
                if let message = library?.failureAlerts[session.id] { Text(message) }
            }
    }

    private var failed: Binding<Bool> {
        Binding(get: { library?.failureAlerts[session.id] != nil },
                set: { if !$0 { library?.dismissFailureAlert(in: session.id) } })
    }
}

/// The progress card of a running export, in the window that started it.
private struct MarkedUpExportCard: View {
    let record: MarkedUpExportRecord
    let library: MarkedUpExportLibrary
    let session: ReaderSession

    var body: some View {
        let fraction = library.progress[record.id]?.fraction ?? 0
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(MarkedUpExportWording.runningTitle(includesNotes: record.includesNotes) + "…").font(.headline)
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 260)
                    .accessibilityIdentifier(AccessibilityID.MarkedUpExport.progress)
                Text(MarkedUpExportTimeEstimate.text(remaining: library.remaining(record.id)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier(AccessibilityID.MarkedUpExport.timeLeft)
                HStack(spacing: 12) {
                    Button("Cancel", role: .cancel) { session.markedUpExport.stopCandidate = record.id }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(AccessibilityID.MarkedUpExport.cancel)
                    Button("Continue in Background") { library.moveToBackground(record.id) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(AccessibilityID.MarkedUpExport.background)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 6)
            .accessibilityElement(children: .contain)
        }
    }
}

/// The status pill at the top of a reader: a running export (tap for its progress card), or how
/// the latest one ended until the user shares or hides it. Hiding keeps the file (it stays in
/// the Notebook).
private struct MarkedUpExportPill: View {
    let record: MarkedUpExportRecord
    let library: MarkedUpExportLibrary
    let session: ReaderSession

    var body: some View {
        Group {
            if record.isRunning {
                running
            } else if record.isFinished {
                finished
            } else {
                unfinished
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var running: some View {
        let fraction = library.progress[record.id]?.fraction ?? 0
        return HStack(spacing: 12) {
            Button { library.showCard(record.id, in: session.id) } label: {
                HStack(spacing: 10) {
                    MarkedUpExportProgressRing(fraction: fraction)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(MarkedUpExportWording.runningTitle(includesNotes: record.includesNotes))
                            .font(.subheadline.weight(.semibold))
                        Text(MarkedUpExportTimeEstimate.text(remaining: library.remaining(record.id)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .accessibilityIdentifier(AccessibilityID.MarkedUpExport.timeLeft)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.MarkedUpExport.status)
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
            .accessibilityHint("Shows the export's progress")
            closeButton(label: "Stop Export", identifier: AccessibilityID.MarkedUpExport.backgroundCancel) {
                session.markedUpExport.stopCandidate = record.id
            }
        }
    }

    private var finished: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Marked-Up PDF Ready").font(.subheadline.weight(.semibold))
                Text("Kept in this book's Notebook").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.MarkedUpExport.status)
            Button("Share") { library.share(record.id, in: session.id) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.MarkedUpExport.share)
            closeButton(label: "Hide", identifier: AccessibilityID.MarkedUpExport.hide) {
                library.acknowledge(record.id)
            }
        }
    }

    private var unfinished: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Export Didn't Finish").font(.subheadline.weight(.semibold))
                Text(record.unfinishedReason ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 320, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.MarkedUpExport.status)
            Button("Try Again") { session.retryMarkedUpExport(record) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!session.canExportMarkedUpPDF)
                .accessibilityIdentifier(AccessibilityID.MarkedUpExport.retry)
            closeButton(label: "Hide", identifier: AccessibilityID.MarkedUpExport.hide) {
                library.acknowledge(record.id)
            }
        }
    }

    private func closeButton(label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// A small ring filled to `fraction`.
struct MarkedUpExportProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, min(fraction, 1)))
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: fraction)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
