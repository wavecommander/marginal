import SwiftUI

extension View {
    /// Shows the window's scanned-book notice (`ScanNoticeQueue`) as a system alert while
    /// `isBlocked` is false. The Library attaches it (S3).
    func scannedBookNotice(_ queue: ScanNoticeQueue, windowKey: ObjectIdentifier, isBlocked: Bool,
                           environment: AppEnvironment) -> some View {
        modifier(ScanNoticeAlert(queue: queue, windowKey: windowKey, isBlocked: isBlocked, environment: environment))
    }
}

/// The scanned-book notice: a system alert naming the book (or saying how many), with
/// **Make Searchable** (the default) and **Not Now**. Its books are re-checked against the store
/// first (`ScanNoticeQueue.check`), so a notice whose books were decided meanwhile never shows.
private struct ScanNoticeAlert: ViewModifier {
    let queue: ScanNoticeQueue
    let windowKey: ObjectIdentifier
    let isBlocked: Bool
    let environment: AppEnvironment

    private var candidate: ScanNotice? { isBlocked ? nil : queue.notice(for: windowKey) }
    private var shown: ScanNotice? { candidate.flatMap { $0.isChecked ? $0 : nil } }

    func body(content: Content) -> some View {
        content
            .task(id: candidate?.id) {
                guard let candidate, !candidate.isChecked else { return }
                await queue.check(candidate.id, store: environment.store)
            }
            .alert(shown?.title ?? "", isPresented: binding, presenting: shown) { notice in
                Button(ScanNoticeText.makeSearchable) { answer(notice, makeSearchable: true) }
                    .keyboardShortcut(.defaultAction)
                Button(ScanNoticeText.notNow, role: .cancel) { answer(notice, makeSearchable: false) }
            } message: { notice in
                Text(notice.message)
            }
    }

    /// Only a button closes the notice: the setter has nothing to do.
    private var binding: Binding<Bool> {
        Binding(get: { shown != nil }, set: { _ in })
    }

    private func answer(_ notice: ScanNotice, makeSearchable: Bool) {
        queue.answer(notice.id, makeSearchable: makeSearchable, recognition: environment.textRecognition)
    }
}
