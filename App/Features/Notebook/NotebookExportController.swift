import Observation
import ReaderCore
import SwiftUI
import UIKit

/// Runs one export at a time for one Notebook screen (per window) and hands the result to the
/// share sheet; removes the exported files when the share sheet is done with them. `notebook` is
/// the whole Notebook or the reader's selection of it (`Notebook.selecting`).
@Observable
@MainActor
final class NotebookExportController {
    enum State: Equatable {
        case idle
        case running(NotebookExportFormat, fraction: Double)
        /// Waiting for the share sheet to finish with the file.
        case sharing(NotebookExportResult)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { if case .running = state { true } else { false } }

    var sharedResult: NotebookExportResult? {
        if case .sharing(let result) = state { result } else { nil }
    }

    func start(_ format: NotebookExportFormat, notebook: Notebook, book: Book, store: LibraryStore) {
        guard !isRunning, sharedResult == nil else { return }
        state = .running(format, fraction: 0)
        task = Task { [weak self] in
            await NotebookExporter.purgeStale()
            do {
                let result = try await NotebookExporter.export(format, notebook: notebook, book: book, store: store) { fraction in
                    guard let self, case .running(let current, _) = self.state else { return }
                    self.state = .running(current, fraction: fraction)
                }
                guard let self else {
                    NotebookExporter.cleanUp(result)
                    return
                }
                self.state = .sharing(result)
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// The share sheet was dismissed (shared or not): remove the files.
    func shareDidFinish() {
        if let result = sharedResult { NotebookExporter.cleanUp(result) }
        state = .idle
    }

    func dismissError() {
        if case .failed = state { state = .idle }
    }
}

/// The progress card shown while an export runs (with Cancel).
struct NotebookExportProgressView: View {
    let format: NotebookExportFormat
    let fraction: Double
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Exporting \(format.title)…").font(.headline)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(width: 220)
                .accessibilityIdentifier(NotebookAccessibilityID.exportProgress)
            Button("Cancel", role: .cancel, action: cancel)
                .buttonStyle(.bordered)
                .accessibilityIdentifier(NotebookAccessibilityID.exportCancel)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 6)
        .accessibilityElement(children: .contain)
    }
}

/// An invisible anchor that presents the system share sheet (`UIActivityViewController`) for
/// `item`, as a popover pointing at the anchor, and reports when it is dismissed. The share
/// sheet offers "Save to Files" and every other destination for the file.
struct NotebookShareSheetAnchor: UIViewRepresentable {
    let item: URL?
    let onFinish: () -> Void

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.onFinish = onFinish
        view.update(item: item)
    }

    final class AnchorView: UIView {
        var onFinish: (() -> Void)?
        private var presentedURL: URL?
        private weak var controller: UIActivityViewController?

        func update(item: URL?) {
            guard let item else {
                presentedURL = nil
                return
            }
            guard item != presentedURL else { return }
            presentedURL = item
            // Present after the current update pass, when the view is in a window.
            DispatchQueue.main.async { [weak self] in self?.present(item) }
        }

        private func present(_ url: URL) {
            guard presentedURL == url, let window, var top = window.rootViewController else {
                onFinish?()
                return
            }
            while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = self
            controller.popoverPresentationController?.sourceRect = bounds
            controller.popoverPresentationController?.permittedArrowDirections = [.up, .down]
            controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
                self?.onFinish?()
            }
            self.controller = controller
            top.present(controller, animated: true)
        }
    }
}
