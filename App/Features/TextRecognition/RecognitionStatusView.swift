import ReaderCore
import SwiftUI

/// Accessibility identifiers of the scanned-book notice and search status. UI tests mirror these.
nonisolated enum TextRecognitionAccessibilityID {
    /// The status at the top of the search panel.
    static let status = "recognition.status"
    static let title = "recognition.status.title"
    static let detail = "recognition.status.detail"
    static let progress = "recognition.status.progress"
    static let note = "recognition.status.note"
    static let makeSearchable = "recognition.makeSearchable"
    static let notNow = "recognition.notNow"
    static let pause = "recognition.pause"
    static let resume = "recognition.resume"
    /// The quiet line saying page results cover only the pages made searchable so far.
    static let partial = "search.partial"
}

/// The search panel's status for a scanned book whose recognition is not complete (S3; design,
/// "Scanned books" ▸ "The choice can be revisited from search"): the offer with Make Searchable
/// and Not Now, or pages done out of the total with a bar and Pause or Resume. Built from
/// `RecognitionStatus`; the panel passes the actions on to the app's one recognition queue.
///
/// Fits narrow panels and large text: the buttons sit beside each other when they fit and stack
/// otherwise, and every line wraps.
struct RecognitionStatusView: View {
    let status: RecognitionStatus
    let perform: (RecognitionStatus.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status.title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(TextRecognitionAccessibilityID.title)
            if let progress = status.progress {
                ProgressView(value: progress.fractionDone)
                    .accessibilityLabel(Text(status.title))
                    .accessibilityValue(Text(status.detail))
                    .accessibilityIdentifier(TextRecognitionAccessibilityID.progress)
            }
            Text(status.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(TextRecognitionAccessibilityID.detail)
            if let note = status.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(TextRecognitionAccessibilityID.note)
            }
            if !status.actions.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { buttons }
                    VStack(alignment: .leading, spacing: 8) { buttons }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TextRecognitionAccessibilityID.status)
    }

    @ViewBuilder
    private var buttons: some View {
        ForEach(status.actions, id: \.self) { action in
            button(action)
        }
    }

    @ViewBuilder
    private func button(_ action: RecognitionStatus.Action) -> some View {
        switch action {
        case .makeSearchable:
            Button(ScanNoticeText.makeSearchable) { perform(.makeSearchable) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(TextRecognitionAccessibilityID.makeSearchable)
        case .notNow:
            Button(ScanNoticeText.notNow) { perform(.notNow) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier(TextRecognitionAccessibilityID.notNow)
        case .pause:
            Button {
                perform(.pause)
            } label: {
                Text("Pause", comment: "Search panel, scanned book: button that pauses making the book searchable.")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(Text("Pause making this book searchable",
                                     comment: "Search panel, scanned book: VoiceOver label of the Pause button."))
            .accessibilityIdentifier(TextRecognitionAccessibilityID.pause)
        case .resume:
            Button {
                perform(.resume)
            } label: {
                Text("Resume", comment: "Search panel, scanned book: button that resumes making the book searchable.")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityLabel(Text("Resume making this book searchable",
                                     comment: "Search panel, scanned book: VoiceOver label of the Resume button."))
            .accessibilityIdentifier(TextRecognitionAccessibilityID.resume)
        }
    }
}

/// The search panel's slot (S3): the status for the window's book, live from the window's
/// `SearchModel.recognitionState` (kept current from the store in every window), with its
/// actions sent to the app's one `TextRecognitionEngine`, and the quiet "partial" line under the
/// search status.
struct SearchRecognitionStatus: View {
    let session: ReaderSession
    let model: SearchModel
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Tallest the status may be at accessibility text sizes, where the offer alone would fill
    /// the panel above the keyboard: beyond it, the status scrolls and the field and results
    /// keep their room.
    static let maximumAccessibilityHeight: CGFloat = 260

    var body: some View {
        if let status = RecognitionStatus.make(state: model.recognitionState, pageCount: session.pageCount) {
            let view = RecognitionStatusView(status: status, perform: perform)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    ViewThatFits(in: .vertical) {
                        view
                        ScrollView { view }
                            .scrollIndicators(.visible)
                    }
                    .frame(maxHeight: Self.maximumAccessibilityHeight)
                } else {
                    view
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private func perform(_ action: RecognitionStatus.Action) {
        let engine = environment.textRecognition
        let bookID = session.book.id
        Task {
            switch action {
            case .makeSearchable: await engine.accept(bookID: bookID)
            // Not Now here records the choice (not decided becomes declined) and closes nothing:
            // the offer stays where it is, as declining is never final.
            case .notNow: await engine.decline(bookID: bookID)
            case .pause: await engine.pause(bookID: bookID)
            case .resume: await engine.resume(bookID: bookID)
            }
        }
    }
}

/// "Page results include only the pages made searchable so far.", under the search status while
/// a scanned book's page search is partial and a query has been searched.
struct SearchPartialResultsLine: View {
    let model: SearchModel

    var body: some View {
        if model.isPageSearchPartial, model.phase != .idle {
            Text(RecognitionStatus.partialResultsLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier(TextRecognitionAccessibilityID.partial)
        }
    }
}
