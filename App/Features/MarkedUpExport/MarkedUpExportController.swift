import Observation
import ReaderCore
import SwiftUI
import UIKit

/// Runs one marked-up PDF export at a time for one reader window (`ReaderSession.markedUpExport`)
/// and hands the file to the share sheet; removes it when the share sheet is done with it. Before
/// reading, it saves everything pending in every open editor on the store (this window's ink and
/// notes, and any other window's), so the export holds what is on screen.
///
/// An export starts only after the user confirms it (`requestConfirmation`, then `confirm`). While
/// it runs, the user can send it to the background (`moveToBackground`): the progress card gives
/// way to a small status pill and the reader can be used; when it finishes there, a notification
/// says so and the pill offers Share. It keeps running when the app leaves the foreground
/// (`MarkedUpExportBackgroundRun`).
@Observable
@MainActor
final class MarkedUpExportController {
    enum State: Equatable {
        case idle
        /// Waiting for the user to confirm the export (it may be slow and makes a big file).
        /// `sourceByteCount`: the size of the book's PDF, when known.
        case confirming(includesNotes: Bool, sourceByteCount: Int64?)
        case running(includesNotes: Bool, fraction: Double)
        /// Finished in the background: waiting for the user to share it (or let it go).
        case ready(NotebookExportResult)
        /// Waiting for the share sheet to finish with the file.
        case sharing(NotebookExportResult)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The running export was sent to the background: the reader shows the status pill, not the
    /// progress card.
    private(set) var isInBackground = false
    /// When the running export started, for the time left.
    @ObservationIgnored private(set) var startedAt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var backgroundRun: MarkedUpExportBackgroundRun?
    /// The identifier of this export's notification.
    @ObservationIgnored private let notificationID = "markedUpExport." + UUID().uuidString
    /// Set once in `init`, read only in `deinit`.
    @ObservationIgnored nonisolated(unsafe) private var notificationObserver: (any NSObjectProtocol)?

    init() {
        notificationObserver = NotificationCenter.default.addObserver(forName: MarkedUpExportNotifications.opened,
                                                                      object: nil, queue: .main) { [weak self] note in
            guard let identifier = note.object as? String else { return }
            MainActor.assumeIsolated { self?.notificationOpened(identifier) }
        }
    }

    deinit {
        if let notificationObserver { NotificationCenter.default.removeObserver(notificationObserver) }
    }

    var isRunning: Bool { if case .running = state { true } else { false } }
    var isIdle: Bool { state == .idle }

    var sharedResult: NotebookExportResult? {
        if case .sharing(let result) = state { result } else { nil }
    }

    var readyResult: NotebookExportResult? {
        if case .ready(let result) = state { result } else { nil }
    }

    /// How long the running export has left, or `nil` until it can tell.
    func remaining(now: Date = Date()) -> TimeInterval? {
        guard case .running(_, let fraction) = state, let startedAt else { return nil }
        return MarkedUpExportTimeEstimate.remaining(elapsed: now.timeIntervalSince(startedAt), fraction: fraction)
    }

    /// Asks the user to confirm an export before it starts.
    func requestConfirmation(includeNotes: Bool, sourceByteCount: Int64?) {
        guard state == .idle else { return }
        state = .confirming(includesNotes: includeNotes, sourceByteCount: sourceByteCount)
    }

    /// The user confirmed: starts the export asked for.
    func confirm(book: Book, store: LibraryStore) {
        guard case .confirming(let includeNotes, _) = state else { return }
        state = .idle
        start(book: book, store: store, includeNotes: includeNotes)
    }

    func start(book: Book, store: LibraryStore, includeNotes: Bool) {
        guard state == .idle else { return }
        state = .running(includesNotes: includeNotes, fraction: 0)
        isInBackground = false
        startedAt = Date()
        MarkedUpExportNotifications.remove(identifier: notificationID)
        let fileTitle = MarkedUpExport.fileName(forBookTitle: book.title, includesNotes: includeNotes)
        backgroundRun = MarkedUpExportBackgroundRun(title: includeNotes ? "Exporting Book with Notes" : "Exporting Marked-Up PDF",
                                                    subtitle: book.title) { [weak self] in
            self?.cancel()
        }
        #if DEBUG
        let pageDelay = Duration.milliseconds(LaunchOptions.current.exportPageDelayMs ?? 0)
        #else
        let pageDelay = Duration.zero
        #endif
        task = Task { [weak self] in
            await OpenEditorRegistry.shared.flushAll(store: store)
            await NotebookExporter.purgeStale(root: MarkedUpExporter.defaultRoot)
            do {
                try Task.checkCancellation()
                let result = try await MarkedUpExporter.export(book: book, store: store, includeNotes: includeNotes,
                                                               pageDelay: pageDelay, progress: { fraction in
                    guard let self, case .running(let notes, _) = self.state else { return }
                    self.state = .running(includesNotes: notes, fraction: fraction)
                    self.backgroundRun?.update(fraction: fraction)
                })
                guard let self else {
                    NotebookExporter.cleanUp(result)
                    return
                }
                if Task.isCancelled {
                    NotebookExporter.cleanUp(result)
                    self.finish(success: false)
                    self.state = .idle
                } else if self.isInBackground || UIApplication.shared.applicationState != .active {
                    // Not in front of the user: wait for them to ask for the share sheet.
                    self.state = .ready(result)
                    self.finish(success: true)
                    MarkedUpExportNotifications.post(identifier: self.notificationID, title: "Export Finished",
                                                     body: "“\(fileTitle)” is ready to share from Tactile Texts.")
                } else {
                    self.state = .sharing(result)
                    self.finish(success: true)
                }
            } catch is CancellationError {
                self?.finish(success: false)
                self?.state = .idle
            } catch {
                guard let self else { return }
                let notify = self.isInBackground || UIApplication.shared.applicationState != .active
                self.state = .failed(error.localizedDescription)
                self.finish(success: false)
                if notify {
                    MarkedUpExportNotifications.post(identifier: self.notificationID, title: "Export Failed",
                                                     body: "“\(fileTitle)”: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finish(success: Bool) {
        backgroundRun?.end(success: success)
        backgroundRun = nil
        task = nil
        isInBackground = false
        startedAt = nil
    }

    /// Lets the reader be used while the export runs; asks to notify when it finishes.
    func moveToBackground() {
        guard isRunning, !isInBackground else { return }
        isInBackground = true
        MarkedUpExportNotifications.requestAuthorization()
    }

    /// Shows the progress card again.
    func bringToForeground() {
        guard isRunning else { return }
        isInBackground = false
    }

    /// Opens the share sheet for an export that finished in the background.
    func share() {
        guard let result = readyResult else { return }
        MarkedUpExportNotifications.remove(identifier: notificationID)
        state = .sharing(result)
    }

    private func notificationOpened(_ identifier: String) {
        guard identifier == notificationID else { return }
        share()
    }

    /// Stops a running export (its files are removed), lets go of a finished file, or drops a
    /// confirmation not yet given.
    func cancel() {
        task?.cancel()
        switch state {
        case .confirming:
            state = .idle
        case .sharing(let result), .ready(let result):
            NotebookExporter.cleanUp(result)
            MarkedUpExportNotifications.remove(identifier: notificationID)
            state = .idle
        default:
            break
        }
    }

    /// The share sheet was dismissed (shared or not): remove the file.
    func shareDidFinish() {
        if let result = sharedResult { NotebookExporter.cleanUp(result) }
        state = .idle
    }

    func dismissError() {
        if case .failed = state {
            MarkedUpExportNotifications.remove(identifier: notificationID)
            state = .idle
        }
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

    /// Whether this window can export now: the book is open and no export of this window is
    /// running or waiting for the share sheet.
    var canExportMarkedUpPDF: Bool {
        loadState == .ready && closeReason == nil && markedUpExport.isIdle
    }

    /// Whether `choice` is offered: "Book with Notes" only when the book has notes (or before the
    /// reader knows).
    func isMarkedUpExportAvailable(_ choice: MarkedUpExportChoice) -> Bool {
        guard canExportMarkedUpPDF else { return false }
        guard choice.includesNotes, let notebook else { return true }
        return notebook.totalCounts.notes > 0
    }

    /// Asks the user to confirm, then (`confirmMarkedUpExport()`) exports this book as a marked-up
    /// PDF and offers it in the share sheet. Every way of starting the export comes here.
    func exportMarkedUpPDF(_ choice: MarkedUpExportChoice) {
        guard isMarkedUpExportAvailable(choice) else { return }
        let source = store.documentURL(for: book)
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value
        markedUpExport.requestConfirmation(includeNotes: choice.includesNotes, sourceByteCount: size)
    }

    /// The user confirmed the export asked for by `exportMarkedUpPDF(_:)`.
    func confirmMarkedUpExport() {
        guard loadState == .ready, closeReason == nil else {
            markedUpExport.cancel()
            return
        }
        markedUpExport.confirm(book: book, store: store)
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
    /// The marked-up export's confirmation, progress card (with Cancel and Continue in Background),
    /// status pill while it runs in the background, share sheet (a popover from the toolbar's
    /// trailing end) and failure alert, for the reader of `session`.
    func markedUpExportPresentation(_ session: ReaderSession) -> some View {
        modifier(MarkedUpExportPresentation(session: session))
    }
}

private struct MarkedUpExportPresentation: ViewModifier {
    let session: ReaderSession
    private var export: MarkedUpExportController { session.markedUpExport }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                NotebookShareSheetAnchor(item: export.sharedResult?.fileURL, onFinish: export.shareDidFinish)
                    .frame(width: 1, height: 1)
                    .padding(.trailing, 28)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .top) { statusPill.padding(.top, 10) }
            .overlay { progress }
            .alert(confirmationTitle, isPresented: confirming) {
                Button("Export") { session.confirmMarkedUpExport() }
                    .accessibilityIdentifier(AccessibilityID.MarkedUpExport.confirmExport)
                Button("Cancel", role: .cancel) { export.cancel() }
                    .accessibilityIdentifier(AccessibilityID.MarkedUpExport.confirmCancel)
            } message: {
                Text(confirmationMessage)
            }
            .alert("Export Failed", isPresented: failed) {
                Button("OK") { export.dismissError() }
            } message: {
                if case .failed(let message) = export.state { Text(message) }
            }
    }

    // MARK: Confirmation

    private var confirmationTitle: String {
        if case .confirming(true, _) = export.state { "Export Book with Notes?" } else { "Export Marked-Up PDF?" }
    }

    private var confirmationMessage: String {
        guard case .confirming(_, let bytes) = export.state else { return "" }
        let size = bytes.map { " (\($0.formatted(.byteCount(style: .file))))" } ?? ""
        return "This can take a long time, and Tactile Texts will create a file at least as big as the "
            + "current PDF\(size). You can keep reading while it runs in the background."
    }

    private var confirming: Binding<Bool> {
        // Dismissal always goes through a button (Escape picks Cancel), which sets the state; the
        // setter must not, since it can run before the Export button's action.
        Binding(get: { if case .confirming = export.state { true } else { false } }, set: { _ in })
    }

    // MARK: Progress card

    @ViewBuilder
    private var progress: some View {
        if case .running(let includesNotes, let fraction) = export.state, !export.isInBackground {
            ZStack {
                Color.black.opacity(0.12).ignoresSafeArea()
                VStack(spacing: 14) {
                    Text(includesNotes ? "Exporting Book with Notes…" : "Exporting Marked-Up PDF…").font(.headline)
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 260)
                        .accessibilityIdentifier(AccessibilityID.MarkedUpExport.progress)
                    Text(MarkedUpExportTimeEstimate.text(remaining: export.remaining()))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier(AccessibilityID.MarkedUpExport.timeLeft)
                    HStack(spacing: 12) {
                        Button("Cancel", role: .cancel) { export.cancel() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(AccessibilityID.MarkedUpExport.cancel)
                        Button("Continue in Background") { export.moveToBackground() }
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

    // MARK: Status pill

    @ViewBuilder
    private var statusPill: some View {
        if case .running(let includesNotes, let fraction) = export.state, export.isInBackground {
            HStack(spacing: 12) {
                Button { export.bringToForeground() } label: {
                    HStack(spacing: 10) {
                        ProgressRing(fraction: fraction)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(includesNotes ? "Exporting Book with Notes" : "Exporting Marked-Up PDF")
                                .font(.subheadline.weight(.semibold))
                            Text(MarkedUpExportTimeEstimate.text(remaining: export.remaining()))
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
                Button { export.cancel() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel Export")
                .accessibilityIdentifier(AccessibilityID.MarkedUpExport.backgroundCancel)
            }
            .pillChrome()
        } else if export.readyResult != nil {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Marked-Up PDF Ready").font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier(AccessibilityID.MarkedUpExport.status)
                Button("Share") { export.share() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.MarkedUpExport.share)
                Button { export.cancel() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Discard Export")
                .accessibilityIdentifier(AccessibilityID.MarkedUpExport.discard)
            }
            .pillChrome()
        }
    }

    private var failed: Binding<Bool> {
        Binding(get: { if case .failed = export.state { true } else { false } },
                set: { if !$0 { export.dismissError() } })
    }
}

/// A small ring filled to `fraction`.
private struct ProgressRing: View {
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

private extension View {
    func pillChrome() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .accessibilityElement(children: .contain)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
