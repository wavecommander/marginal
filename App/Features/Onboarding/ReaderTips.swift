import Observation
import SwiftUI
import TipKit
import UIKit

/// "Write with Apple Pencil", on the toolbar's Markup toggle.
nonisolated struct MarkupTip: Tip {
    let generation: Int
    var id: String { "onboarding.markup.\(generation)" }
    var title: Text { Text("Write with Apple Pencil") }
    var message: Text? { Text("Tap Markup to write on the page or in a note. Your finger still scrolls.") }
    var image: Image? { Image(systemName: "pencil.tip.crop.circle") }
}

/// "One note for the whole section", on the notes panel's tabs.
nonisolated struct SectionNoteTip: Tip {
    let generation: Int
    var id: String { "onboarding.sectionNote.\(generation)" }
    var title: Text { Text("One note for the whole section") }
    var message: Text? { Text("Section note keeps a note for the heading this page is in.") }
    var image: Image? { Image(systemName: "note.text") }
}

/// One reader's tips (docs/DESIGN.md, "First-run onboarding"): a session shows at most one tip,
/// never in the Quick Guide, never in markup mode and never while the keyboard is up. The tip
/// popovers are TipKit's; which tip is offered, and that each is offered once, is decided here
/// (`ReaderTipRules`, `OnboardingState`) so the rules can be tested and reset.
///
/// A view anchors a tip with `.onboardingTip(.markup, session:)`. `ReaderTipsDriver` (on
/// `ReaderScreen`) feeds this object the session's state.
@Observable
@MainActor
final class ReaderTips {
    /// The tip to show now, or `nil`.
    private(set) var active: OnboardingTipKind?

    @ObservationIgnored private weak var session: ReaderSession?
    @ObservationIgnored private let onboarding: OnboardingCoordinator
    /// The one tip this session was given (it may since have been closed or retired).
    @ObservationIgnored private var chosen: OnboardingTipKind?
    @ObservationIgnored private var isSettled = false
    @ObservationIgnored private var isKeyboardUp = false
    @ObservationIgnored private var hasCountedNotesPanel = false
    @ObservationIgnored private var seenTipResetCount: Int

    init(session: ReaderSession, onboarding: OnboardingCoordinator) {
        self.session = session
        self.onboarding = onboarding
        self.seenTipResetCount = onboarding.tipResetCount
    }

    static func forSession(_ session: ReaderSession, onboarding: OnboardingCoordinator) -> ReaderTips {
        session.featureState { ReaderTips(session: session, onboarding: onboarding) }
    }

    /// Part of each tip's TipKit ID (`OnboardingState.tipGeneration`).
    var generation: Int { onboarding.state.tipGeneration }

    // MARK: Inputs (from `ReaderTipsDriver`)

    /// The first page has been on screen for a moment.
    func settle() {
        isSettled = true
        evaluate()
    }

    func keyboardChanged(isUp: Bool) {
        isKeyboardUp = isUp
        evaluate()
    }

    /// Re-reads the session: retires tips whose action the reader has just performed, picks
    /// this session's tip if it has none yet, and decides whether it can be on screen now.
    func evaluate() {
        guard let session else { active = nil; return }
        let state = onboarding.state
        if seenTipResetCount != onboarding.tipResetCount {
            // "Show Tips Again": this reader may offer a tip once more.
            seenTipResetCount = onboarding.tipResetCount
            chosen = nil
            isChosenRetired = false
            hasCountedNotesPanel = false
        }
        // Using the control a tip points at retires that tip, here or in the Quick Guide.
        if session.isMarkupMode { state.markTipDone(.markup) }
        if session.isNotesVisible && session.notesTab == .section { state.markTipDone(.sectionNote) }

        let hasHeadingPath = !session.headingPath.isEmpty
        if !hasCountedNotesPanel, session.isNotesVisible, hasHeadingPath, !state.isSuppressed {
            hasCountedNotesPanel = true
            state.countNotesPanelSession()
        }
        let isGuide = state.guideBookID == session.book.id
        let context = ReaderTipContext(isSuppressed: state.isSuppressed, isGuide: isGuide, isSettled: isSettled,
                                       isNotesVisible: session.isNotesVisible, hasHeadingPath: hasHeadingPath,
                                       notesPanelSessions: state.notesPanelSessions)
        if let next = ReaderTipRules.next(in: context, done: state.doneTips, chosen: chosen) {
            chosen = next
            state.markTipDone(next)  // offered once, whether or not the reader acts on it
        }
        let retired = (chosen == .markup && session.isMarkupMode)
            || (chosen == .sectionNote && session.notesTab == .section)
        if retired { isChosenRetired = true }
        let canShow = !isGuide && !session.isMarkupMode && !isKeyboardUp && !isChosenRetired
        let now = canShow ? chosen : nil
        if active != now { active = now }
    }

    @ObservationIgnored private var isChosenRetired = false
}

/// Feeds a reader's `ReaderTips` from its session. Applied once, by `ReaderScreen`.
private struct ReaderTipsDriver: ViewModifier {
    let session: ReaderSession
    @Environment(AppEnvironment.self) private var environment

    private struct Inputs: Equatable {
        var isMarkupMode: Bool
        var isNotesVisible: Bool
        var notesTab: ReaderSession.NotesTab
        var hasHeadingPath: Bool
        var tipResetCount: Int
    }

    func body(content: Content) -> some View {
        let tips = ReaderTips.forSession(session, onboarding: environment.onboarding)
        let inputs = Inputs(isMarkupMode: session.isMarkupMode, isNotesVisible: session.isNotesVisible,
                            notesTab: session.notesTab, hasHeadingPath: !session.headingPath.isEmpty,
                            tipResetCount: environment.onboarding.tipResetCount)
        content
            .onChange(of: inputs, initial: true) { tips.evaluate() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                tips.keyboardChanged(isUp: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                tips.keyboardChanged(isUp: false)
            }
            .task(id: session.loadState == .ready) {
                guard session.loadState == .ready else { return }
                // Let the first page and the panels settle before anything points at them.
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                tips.settle()
            }
            .overlay { MarkupTipAnchor(session: session) }
    }
}

extension View {
    /// Drives the reader's onboarding tips from `session` (see `ReaderTips`).
    func readerOnboardingTips(_ session: ReaderSession) -> some View {
        modifier(ReaderTipsDriver(session: session))
    }

    /// Anchors the onboarding tip `kind` to this view while it is the session's active tip.
    func onboardingTip(_ kind: OnboardingTipKind, session: ReaderSession) -> some View {
        modifier(OnboardingTipAnchor(kind: kind, session: session))
    }
}

/// The popover is attached only while its tip is active. The tips are passed as concrete types:
/// that is the `popoverTip` form available at the iPadOS 17 floor.
private struct OnboardingTipAnchor: ViewModifier {
    let kind: OnboardingTipKind
    let session: ReaderSession

    @ViewBuilder
    func body(content: Content) -> some View {
        let tips = session.existingFeatureState(ReaderTips.self)
        switch tips?.active == kind ? kind : nil {
        case .markup?:
            content.popoverTip(MarkupTip(generation: tips?.generation ?? 0), arrowEdge: .top)
        case .sectionNote?:
            content.popoverTip(SectionNoteTip(generation: tips?.generation ?? 0), arrowEdge: .top)
        case nil:
            content
        }
    }
}

/// Where the Markup tip hangs from. A popover attached to a toolbar item never presents (the
/// item becomes a bar button item; the search popover met the same limit, see
/// `SearchAnchorReader`), so an invisible view is laid over the reader at the Markup item's
/// frame and the tip is attached to that.
private struct MarkupTipAnchor: View {
    let session: ReaderSession
    @State private var frame: CGRect?

    var body: some View {
        let isActive = session.existingFeatureState(ReaderTips.self)?.active == .markup
        ZStack(alignment: .topLeading) {
            BarItemFrameReader(titles: ["Markup"], isActive: isActive) { frame = $0 }
            if isActive, let frame {
                Color.clear
                    .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                    .onboardingTip(.markup, session: session)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Reports the frame, in its own coordinates, of the navigation bar's trailing item with one
/// of `titles`: once when it becomes active and again on every layout while it is.
private struct BarItemFrameReader: UIViewRepresentable {
    let titles: [String]
    let isActive: Bool
    let onMeasure: (CGRect?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.titles = titles
        view.onMeasure = onMeasure
        view.isActive = isActive
    }

    final class ReaderView: UIView {
        var titles: [String] = []
        var onMeasure: ((CGRect?) -> Void)?
        var isActive = false {
            didSet {
                guard isActive && !oldValue else { return }
                reported = nil
                scheduleMeasure()
            }
        }
        private var reported: CGRect??

        override func layoutSubviews() {
            super.layoutSubviews()
            if isActive { scheduleMeasure() }
        }

        /// After the current update pass (SwiftUI state must not change during one).
        private func scheduleMeasure() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive else { return }
                let frame = self.itemFrame()
                if let reported = self.reported, reported == frame { return }
                self.reported = .some(frame)
                self.onMeasure?(frame)
            }
        }

        private func itemFrame() -> CGRect? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController {
                    let navigationItem = controller.navigationItem
                    let items = navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
                        + (navigationItem.rightBarButtonItems ?? [])
                    if let item = items.first(where: { titles.contains($0.title ?? "") }),
                       let frame = item.frame(in: self) {
                        return frame
                    }
                }
                responder = next
            }
            return nil
        }
    }
}
