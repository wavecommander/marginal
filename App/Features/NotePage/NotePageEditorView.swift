import PencilKit
import ReaderCore
import UIKit

/// Accessibility identifiers of the note page (UI tests mirror these strings).
nonisolated enum NotePageAccessibilityID {
    /// The editor's root view.
    static let editor = "notePage.editor"
    /// The note's text view (label "Note" or "Note with handwriting"; value = the text).
    static let text = "notePage.text"
    /// The note's ink: one element framed on the strokes (value "N strokes"); absent without ink.
    static let ink = "notePage.ink"
    /// The blank drawing space below the text (its top is the trailing band's top).
    static let writingSpace = "notePage.writingSpace"
}

/// The editable note page (UIKit core of `NotePageView`).
///
/// ## Structure (design: "Note page")
/// One zooming `UIScrollView` (owns scrolling and pinch, 100%–200%) whose zoomed content is the
/// page view: a `pageWidth`-wide (`NotePageStyle.pageWidth` unless the host gives the note more
/// room), non-scrolling `UITextView` and, above it, a `PKCanvasView` of the same frame. Text and
/// ink share the page view's coordinate space (note-page coordinates) at every zoom. Zoom never
/// changes line breaks; a new `pageWidth` re-wraps the text at the same text size and moves each
/// stroke with its paragraph (`NotePageModel.relayoutInk`). The page grows downward: it is at least
/// `NotePageStyle.minimumWritingRoom` below the text and `inkGrowthRoom` below the lowest stroke,
/// and at least as tall as the visible area.
///
/// ## Touch routing
/// - **Markup mode:** the canvas takes touches. The Pencil inks (text area and blank space
///   alike). A finger *tap* places the text cursor (and brings up the keyboard), so typing and
///   inking alternate without leaving markup mode. One finger scrolls, two fingers pinch-zoom.
///   When the drawing policy lets a finger draw (`.anyInput`, or `.default` with the system's
///   "Only Draw with Apple Pencil" off), a finger *drag* draws instead, scrolling takes two
///   fingers, and a finger tap still places the cursor without leaving a dot (the canvas waits
///   for the tap to fail before it starts a finger stroke). Finger text selection (drag handles,
///   double-tap) needs reading mode; hardware-keyboard selection works in both.
/// - **Reading mode:** the canvas takes no input and its ink is read-only; the text view gets
///   every touch, so Scribble, selection and the edit menu work as in any text view.
/// - Scribble is off in markup mode (the Pencil inks there) and on in reading mode.
/// - Nothing intercepts Pencil double-tap, squeeze or hover: the canvas and the shared tool
///   picker handle them.
///
/// ## Appearance
/// The whole page follows the system light/dark setting, live (design: "The notes pane follows
/// the system appearance"): `NotePageStyle.paperColor`, `.label` text, `.placeholderText`, the
/// system tint for the cursor and selection, and PencilKit's own light/dark ink rendering on the
/// canvas. Switching appearance re-renders only; it never writes to the canvas's drawing, so it
/// never reaches the model or the store.
///
/// ## Markup surface
/// With a session, the view registers itself as a `MarkupSurface` while it is in a window, and
/// its text view as the auxiliary responder: with a hardware keyboard the tool picker stays up
/// while typing; without one it steps aside for the on-screen keyboard and comes back when typing
/// ends, which a stroke on the note also does (`ReaderMarkupController.keepsPickerWhileTyping`). Ink undo
/// and redo use the model's `undoManager` (the surface's `markupUndoManager`, so the tool picker's
/// Undo/Redo, the toolbar's at compact width, and ⌘Z through the markup responder act on note ink
/// after a stroke on the note); the
/// canvas's own undo registration is switched off because the model owns ink undo (it must
/// survive relocation). Typing undo is the text view's own, while it has focus.
final class NotePageEditorView: UIView, MarkupSurface, NotePageEditing {
    // MARK: Public

    /// The note shown. Setting a different model while a stroke is in progress waits for the
    /// stroke to end (the stroke belongs to the old note), then switches and flushes the old one.
    var model: NotePageModel? {
        get { currentModel }
        set { requestModel(newValue) }
    }

    /// Zoom factor (1 = 100%), clamped to `NotePageStyle.zoomRange`.
    var zoom: CGFloat {
        get { scrollView.zoomScale }
        set { setZoom(newValue) }
    }

    /// Called when the reader pinches the note to a new zoom.
    var onZoomChange: ((CGFloat) -> Void)?

    /// The page's width in note-page points (before zoom), at least `NotePageStyle.pageWidth`.
    /// A wider host gives the note a wider page (TSOFT-226): the text re-wraps to it at the same
    /// text size, and each stroke moves with its paragraph, as after typing.
    var pageWidth: CGFloat {
        get { currentPageWidth }
        set { setPageWidth(newValue) }
    }

    /// Markup mode when there is no session (with a session, the session's mode applies).
    var isMarkupStandalone = false {
        didSet { if session == nil { applyMode(isMarkupStandalone) } }
    }

    /// Whether the editor paints its own opaque paper and panel backgrounds. `false` when hosted
    /// inside a translucent sheet whose own gradient provides the paper surface underneath.
    var showsPaperBackground = true {
        didSet {
            if showsPaperBackground != oldValue { applyBackgroundColors() }
        }
    }

    /// The reader window's session (tool picker, undo routing, flush, drawing policy).
    private(set) weak var session: ReaderSession?

    // MARK: Views

    private let scrollView = UIScrollView()
    private let pageView = NotePageContentView()
    let textView = NoteTextView(usingTextLayoutManager: true)
    private let noteCanvas = NoteCanvasView()
    private let placeholderLabel = UILabel()
    private lazy var fingerTap = UITapGestureRecognizer(target: self, action: #selector(handleFingerTap(_:)))

    // MARK: State

    private var currentModel: NotePageModel?
    private var pendingModel: NotePageModel??
    private var isMarkup = false
    private var isApplyingDrawing = false
    private var strokeActive = false
    /// The stroke in progress changed the drawing: end typing when it ends (`endTypingForInk`).
    private var endsTypingAfterStroke = false
    private var needsInkRedisplay = false
    private var isZoomingProgrammatically = false
    private var isRegistered = false
    private var pageHeight: CGFloat = 0
    private var currentPageWidth = NotePageStyle.pageWidth
    private var bandLayout: NoteBandLayout?
    private let editorID = UUID()
    private var keyboardOverlap: CGFloat = 0

    // MARK: Init

    init(session: ReaderSession?) {
        self.session = session
        super.init(frame: .zero)
        accessibilityIdentifier = NotePageAccessibilityID.editor
        applyBackgroundColors()

        scrollView.delegate = self
        scrollView.minimumZoomScale = NotePageStyle.zoomRange.lowerBound
        scrollView.maximumZoomScale = NotePageStyle.zoomRange.upperBound
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceVertical = true
        scrollView.delaysContentTouches = false
        scrollView.keyboardDismissMode = .none
        scrollView.contentInsetAdjustmentBehavior = .never
        // Owner rule "No scroll-to-top": a status-bar tap must not jump the note to its top.
        scrollView.scrollsToTop = false
        scrollView.backgroundColor = .clear
        addSubview(scrollView)

        // The page follows the system appearance (no style override): the dynamic paper, the
        // `.label` text, the placeholder and the canvas's ink all resolve against the trait
        // collection the editor is in and change live with it. PencilKit draws the stored
        // strokes converted for the appearance; the drawing itself is never touched.
        pageView.editor = self
        scrollView.addSubview(pageView)

        NotePageStyle.configure(textView)
        textView.delegate = self
        textView.isEditable = false
        textView.accessibilityIdentifier = NotePageAccessibilityID.text
        textView.accessibilityLabel = "Note"
        textView.addInteraction(UIScribbleInteraction(delegate: self))
        pageView.addSubview(textView)

        placeholderLabel.text = "Write a note…"
        placeholderLabel.font = NotePageStyle.font
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isAccessibilityElement = false
        textView.addSubview(placeholderLabel)

        noteCanvas.delegate = self
        noteCanvas.backgroundColor = .clear
        noteCanvas.isOpaque = false
        noteCanvas.isScrollEnabled = false
        noteCanvas.contentInsetAdjustmentBehavior = .never
        noteCanvas.showsVerticalScrollIndicator = false
        noteCanvas.showsHorizontalScrollIndicator = false
        noteCanvas.isAccessibilityElement = false
        noteCanvas.accessibilityElementsHidden = true
        noteCanvas.drawingPolicy = session?.drawingPolicy ?? .default
        pageView.addSubview(noteCanvas)

        fingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        fingerTap.cancelsTouchesInView = false
        fingerTap.delegate = self
        noteCanvas.addGestureRecognizer(fingerTap)

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)

        registerForTraitChanges([UITraitDisplayScale.self]) { (view: NotePageEditorView, _: UITraitCollection) in
            view.applyContentScale()
        }

        applyMode(false)
        setZoom(1)
        layoutPage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    private func applyBackgroundColors() {
        isOpaque = showsPaperBackground
        backgroundColor = showsPaperBackground ? .systemBackground : .clear
        pageView.backgroundColor = showsPaperBackground ? NotePageStyle.paperColor : .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView.frame != bounds {
            scrollView.frame = bounds
            layoutPage()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            registerSurface()
            applyContentScale()
        } else {
            unregisterSurface()
            if let model = currentModel {
                commitPendingInput(to: model)
                Task { await model.flush() }
            }
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // The system's "Only Draw with Apple Pencil" setting can change at any time; refresh the
        // finger routing before each new touch reaches the gesture recognisers.
        updateFingerRouting()
        return super.hitTest(point, with: event)
    }

    /// Sizes the page to the text, the ink and the visible area, and the canvas and text view
    /// to the page.
    private func layoutPage() {
        let zoom = max(scrollView.zoomScale, 0.01)
        let layout = bandLayout ?? NotePageTextLayout.bandLayout(of: textView)
        bandLayout = layout
        let textBottom = layout.trailingTop + NotePageStyle.textInsets.bottom
        let inkBottom = currentModel?.ink.pageBottom ?? 0
        let visible = scrollView.bounds.height > 0 ? (scrollView.bounds.height - keyboardOverlap) / zoom : 0
        let height = ceil(max(textBottom + NotePageStyle.minimumWritingRoom,
                              inkBottom + NotePageStyle.inkGrowthRoom, visible))
        let size = CGSize(width: currentPageWidth, height: height)
        if pageView.bounds.size != size {
            pageView.bounds = CGRect(origin: .zero, size: size)
            textView.frame = pageView.bounds
            noteCanvas.frame = pageView.bounds
            noteCanvas.contentSize = size
            pageHeight = height
        }
        let scaled = CGSize(width: size.width * zoom, height: size.height * zoom)
        pageView.center = CGPoint(x: scaled.width / 2, y: scaled.height / 2)
        scrollView.contentSize = scaled
        centerPage()
        placeholderLabel.frame = CGRect(x: NotePageStyle.textInsets.left, y: NotePageStyle.textInsets.top,
                                        width: size.width - NotePageStyle.textInsets.left - NotePageStyle.textInsets.right,
                                        height: NotePageStyle.lineHeight)
        pageView.updateAccessibility(layout: layout, inkBounds: inkPageBounds, strokeCount: currentModel?.strokeCount ?? 0,
                                     pageHeight: height)
        // The zoom for UI tests (the root view is not an accessibility element, so VoiceOver
        // never reads it): the page's width on screen no longer tells it.
        accessibilityValue = "\(Int((zoom * 100).rounded()))%"
    }

    private func setPageWidth(_ value: CGFloat) {
        let width = max(NotePageStyle.pageWidth, floor(value))
        guard width != currentPageWidth else { return }
        currentPageWidth = width
        // Re-wrap before measuring: the band layout is read from the text view at its new width.
        textView.frame.size.width = width
        bandLayout = nil
        currentModel?.relayoutInk()
        layoutPage()
    }

    private var inkPageBounds: CGRect {
        let bounds = noteCanvas.drawing.bounds
        return bounds.isNull ? .zero : bounds
    }

    private func centerPage() {
        let width = scrollView.contentSize.width
        let horizontal = max(0, (scrollView.bounds.width - width) / 2)
        let insets = UIEdgeInsets(top: 0, left: horizontal, bottom: keyboardOverlap, right: horizontal)
        if scrollView.contentInset != insets {
            scrollView.contentInset = insets
            scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: keyboardOverlap, right: 0)
        }
    }

    private func setZoom(_ value: CGFloat) {
        let clamped = NotePageStyle.clampZoom(value)
        guard abs(scrollView.zoomScale - clamped) > 0.0001 || pageView.bounds.isEmpty else { return }
        let oldZoom = max(scrollView.zoomScale, 0.01)
        let oldTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        isZoomingProgrammatically = true
        scrollView.setZoomScale(clamped, animated: false)
        isZoomingProgrammatically = false
        layoutPage()
        // Keep the same part of the page at the top (UIScrollView keeps the centre, which
        // scrolls the start of the note away when the panel is widened).
        let inset = scrollView.adjustedContentInset
        let maxY = max(-inset.top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        let y = min(max(oldTop * clamped / oldZoom - inset.top, -inset.top), maxY)
        let maxX = max(-inset.left, scrollView.contentSize.width + inset.right - scrollView.bounds.width)
        let x = min(max(scrollView.contentOffset.x, -inset.left), maxX)
        scrollView.contentOffset = CGPoint(x: x, y: y)
        applyContentScale()
    }

    /// Renders the text at the zoomed resolution (vector re-render, never an upscaled bitmap):
    /// the zoom transform is applied by the scroll view, so the text layers' scale factor is
    /// raised to `zoom × displayScale` once zooming settles. Ink is re-rendered sharp by
    /// PencilKit itself (verified at 183% on iOS 27 and 17.5).
    private func applyContentScale() {
        let scale = max(traitCollection.displayScale, 1) * max(scrollView.zoomScale, 1)
        setContentScale(scale, in: textView)
        // Not the canvas: PencilKit renders its strokes for the on-screen scale itself, and a
        // forced scale factor on its layers made it stop drawing after the page was resized at
        // zoom (iOS 27 simulator, notes sheet with the keyboard up).
    }

    private func setContentScale(_ scale: CGFloat, in view: UIView) {
        if view.contentScaleFactor != scale { view.contentScaleFactor = scale }
        for subview in view.subviews { setContentScale(scale, in: subview) }
    }

    // MARK: Mode and routing

    private func applyMode(_ markup: Bool) {
        isMarkup = markup
        let loaded = currentModel?.isLoaded == true
        noteCanvas.isUserInteractionEnabled = markup && loaded
        noteCanvas.drawingGestureRecognizer.isEnabled = markup && loaded
        fingerTap.isEnabled = markup
        if !markup && noteCanvas.isFirstResponder { noteCanvas.resignFirstResponder() }
        updateFingerRouting()
    }

    /// Whether a finger draws on the canvas under the current policy.
    private var fingerDraws: Bool {
        guard isMarkup else { return false }
        switch noteCanvas.drawingPolicy {
        case .anyInput: return true
        case .pencilOnly: return false
        default: return !UIPencilInteraction.prefersPencilOnlyDrawing
        }
    }

    private func updateFingerRouting() {
        let nonPencil: [NSNumber] = [UITouch.TouchType.direct, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        let all = nonPencil + [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        let panTypes = isMarkup ? nonPencil : all
        if scrollView.panGestureRecognizer.allowedTouchTypes != panTypes {
            scrollView.panGestureRecognizer.allowedTouchTypes = panTypes
        }
        let touches = fingerDraws ? 2 : 1
        if scrollView.panGestureRecognizer.minimumNumberOfTouches != touches {
            scrollView.panGestureRecognizer.minimumNumberOfTouches = touches
        }
    }

    /// Whether a finger tap in markup mode places the text cursor (and so brings up the
    /// keyboard). Not while the reader's own fingers draw (Draw with Finger, or no Pencil in
    /// use): there a tap is a dot of ink, and the keyboard coming up under a drawing hand is in
    /// the way. `.anyInput` is the `-inkAnyInput` test switch standing in for the Pencil, so it
    /// keeps the tap.
    private var fingerTapPlacesCursor: Bool {
        switch noteCanvas.drawingPolicy {
        case .anyInput, .pencilOnly: return true
        default: return UIPencilInteraction.prefersPencilOnlyDrawing
        }
    }

    @objc private func handleFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, currentModel?.isLoaded == true, fingerTapPlacesCursor else { return }
        placeCursor(at: recognizer.location(in: textView))
    }

    /// Places the text cursor at the position closest to `point` (text-view coordinates).
    private func placeCursor(at point: CGPoint) {
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
        if let position = textView.closestPosition(to: point) {
            textView.selectedTextRange = textView.textRange(from: position, to: position)
        }
    }

    // MARK: Model

    private func requestModel(_ newModel: NotePageModel?) {
        if newModel === currentModel {
            pendingModel = nil
            return
        }
        if strokeActive {
            pendingModel = .some(newModel)
            return
        }
        switchModel(to: newModel)
    }

    private func switchModel(to newModel: NotePageModel?) {
        pendingModel = nil
        if let old = currentModel {
            commitPendingInput(to: old)
            old.setEditingText(false)
            if old.editor === self { old.editor = nil }
            Task { await old.flush() }
        }
        if textView.isFirstResponder { textView.resignFirstResponder() }
        currentModel = newModel
        newModel?.editor = self
        showModelText()
        // The model's ink may last have been laid out at another width (in a pane since widened,
        // or with no editor): bring it to this page's layout before it is shown or drawn on, or a
        // new stroke would be filed under whichever paragraph the old layout had at that height.
        newModel?.relayoutInk()
        redisplayInk()
        applyMode(isMarkup)
        if let newModel {
            Task { await newModel.load() }
        }
    }

    private func showModelText() {
        let text = currentModel?.text ?? ""
        if textView.text != text {
            let selection = textView.selectedRange
            textView.attributedText = NotePageStyle.attributedText(text)
            textView.typingAttributes = NotePageStyle.textAttributes
            let length = (text as NSString).length
            textView.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        }
        textView.isEditable = currentModel?.isLoaded == true
        updatePlaceholder()
        bandLayout = nil
        layoutPage()
    }

    private func redisplayInk() {
        needsInkRedisplay = false
        isApplyingDrawing = true
        noteCanvas.drawing = currentModel?.displayInk() ?? PKDrawing()
        isApplyingDrawing = false
        updatePlaceholder()
        layoutPage()
        updateInkAccessibility()
    }

    /// The placeholder shows only on a blank page: no text, no ink, and no stroke in progress.
    private func updatePlaceholder() {
        placeholderLabel.isHidden = !(textView.text ?? "").isEmpty || strokeActive
            || !noteCanvas.drawing.strokes.isEmpty
    }

    private func updateInkAccessibility() {
        let hasInk = (currentModel?.strokeCount ?? 0) > 0
        textView.accessibilityLabel = hasInk ? "Note with handwriting" : "Note"
    }

    // MARK: NotePageEditing

    func liveBandLayout(for text: String) -> NoteBandLayout? {
        guard textView.text == text else { return nil }
        let layout = NotePageTextLayout.bandLayout(of: textView)
        bandLayout = layout
        return layout
    }

    func noteModelDidReplaceText(_ model: NotePageModel) {
        guard model === currentModel else { return }
        showModelText()
        applyMode(isMarkup)
    }

    func noteModelDidChangeInk(_ model: NotePageModel) {
        guard model === currentModel else { return }
        if strokeActive {
            needsInkRedisplay = true
        } else {
            redisplayInk()
        }
    }

    func commitPendingInput(to model: NotePageModel) {
        guard model === currentModel else { return }
        if textView.text != model.text { model.userDidEditText(textView.text ?? "") }
        if !isApplyingDrawing { model.applyUserDrawing(noteCanvas.drawing) }
    }

    var isComposingText: Bool { textView.markedTextRange != nil }

    // MARK: MarkupSurface

    var markupSurfaceID: String { "note-\(editorID.uuidString)" }
    var canvasView: PKCanvasView { noteCanvas }
    var markupUndoManager: UndoManager? { currentModel?.undoManager }

    func markupModeDidChange(_ isMarkup: Bool) {
        applyMode(isMarkup)
    }

    func flushPendingMarkup() async {
        guard let model = currentModel else { return }
        commitPendingInput(to: model)
        await model.flush()
    }

    private func registerSurface() {
        guard let session, !isRegistered else { return }
        isRegistered = true
        session.markup.register(self)
        session.markup.registerAuxiliaryResponder(textView)
    }

    private func unregisterSurface() {
        guard let session, isRegistered else { return }
        isRegistered = false
        session.markup.unregisterAuxiliaryResponder(textView)
        session.markup.unregister(self)
    }

    // MARK: Keyboard

    @objc private func keyboardWillChange(_ notification: Notification) {
        guard let window, let screen = window.windowScene?.screen,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let local = convert(screen.coordinateSpace.convert(frame, to: window), from: window)
        let overlap = notification.name == UIResponder.keyboardWillHideNotification
            ? 0 : max(0, bounds.maxY - local.minY)
        guard overlap != keyboardOverlap else { return }
        keyboardOverlap = overlap
        layoutPage()
        scrollCursorIntoView()
    }

    private func scrollCursorIntoView() {
        guard textView.isFirstResponder, let range = textView.selectedTextRange else { return }
        let caret = textView.caretRect(for: range.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        let rect = textView.convert(caret, to: scrollView).insetBy(dx: -8, dy: -16)
        scrollView.scrollRectToVisible(rect, animated: false)
    }
}

// MARK: - UIScrollViewDelegate

extension NotePageEditorView: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        scrollView === self.scrollView ? pageView : nil
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        layoutPage()
        if !isZoomingProgrammatically { onZoomChange?(scrollView.zoomScale) }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard scrollView === self.scrollView else { return }
        applyContentScale()
        onZoomChange?(scale)
    }
}

// MARK: - UITextViewDelegate

extension NotePageEditorView: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updatePlaceholder()
        bandLayout = nil
        currentModel?.userDidEditText(textView.text ?? "")
        layoutPage()
        scrollCursorIntoView()
        if textView.markedTextRange == nil { currentModel?.textEditingDidSettle() }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        scrollCursorIntoView()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        currentModel?.setEditingText(true)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        currentModel?.setEditingText(false)
        currentModel?.textEditingDidSettle()
        session?.markup.reassertToolPicker()
    }
}

// MARK: - PKCanvasViewDelegate

extension NotePageEditorView: PKCanvasViewDelegate {
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        strokeActive = true
        endsTypingAfterStroke = false
        updatePlaceholder()
        currentModel?.strokeDidBegin()
        session?.markup.surfaceDidBeginStroke(self)
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        strokeActive = false
        if let model = currentModel {
            // Take the finished stroke before anything replaces the canvas's drawing.
            commitPendingInput(to: model)
            model.strokeDidEnd()
        }
        session?.markup.surfaceDidEndStroke(self)
        if needsInkRedisplay { redisplayInk() }
        if let pending = pendingModel { switchModel(to: pending) }
        updatePlaceholder()
        layoutPage()
        if endsTypingAfterStroke {
            endsTypingAfterStroke = false
            endTypingForInk()
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isApplyingDrawing, let model = currentModel else { return }
        model.applyUserDrawing(canvasView.drawing)
        updatePlaceholder()
        layoutPage()
        updateInkAccessibility()
        // A stroke really inked (or erased) the note. A finger tap that places the cursor also
        // begins and ends a "stroke" when fingers can draw, but it is cancelled and changes
        // nothing, so it must not end the typing it just started.
        if strokeActive {
            endsTypingAfterStroke = true
        } else {
            endTypingForInk()
        }
    }

    /// Inking while typing with the on-screen keyboard (the tool picker stepped aside for it):
    /// the stroke ends typing, so the keyboard goes and the picker comes back as it was
    /// (`textViewDidEndEditing` re-asserts it). Called once the stroke has ended, not when it
    /// begins, so the page does not move under the Pencil as the keyboard leaves. With a
    /// hardware keyboard the picker never left, and typing carries on.
    private func endTypingForInk() {
        guard textView.isFirstResponder, let markup = session?.markup, !markup.keepsPickerWhileTyping else { return }
        textView.resignFirstResponder()
    }
}

// MARK: - Gestures and Scribble

extension NotePageEditorView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // When a finger can draw, a finger stroke waits until the touch is clearly not a tap.
        gestureRecognizer === fingerTap && otherGestureRecognizer === noteCanvas.drawingGestureRecognizer && fingerDraws
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === fingerTap && otherGestureRecognizer !== noteCanvas.drawingGestureRecognizer
    }
}

extension NotePageEditorView: UIScribbleInteractionDelegate {
    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        !isMarkup
    }
}

// MARK: - Subviews

/// The note's text view. Typing undo stays UIKit's own (⌘Z, the keyboard's undo key and the
/// edit menu while the text view has focus): UIKit's text input does not register typing with an
/// overridden `undoManager` (verified on iOS 27), so redirecting it would only break it.
final class NoteTextView: UITextView {}

/// The note's canvas. Its own undo registration goes to a disabled manager: the note model
/// registers ink undo itself, in band terms, so undo stays correct after the text moves strokes.
final class NoteCanvasView: PKCanvasView {
    private let silentUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()

    override var undoManager: UndoManager? { silentUndoManager }
}

/// The zoomed page: hosts the text view and canvas, and exposes the note's accessibility
/// elements (text, ink, writing space) in page coordinates.
final class NotePageContentView: UIView {
    weak var editor: NotePageEditorView?
    private var inkElement: UIAccessibilityElement?
    private var writingSpaceElement: UIAccessibilityElement?

    func updateAccessibility(layout: NoteBandLayout, inkBounds: CGRect, strokeCount: Int, pageHeight: CGFloat) {
        if strokeCount > 0 {
            let element = inkElement ?? UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityIdentifier = NotePageAccessibilityID.ink
            element.accessibilityLabel = "Handwriting"
            element.accessibilityValue = strokeCount == 1 ? "1 stroke" : "\(strokeCount) strokes"
            element.accessibilityTraits = .image
            element.accessibilityFrameInContainerSpace = inkBounds
            inkElement = element
        } else {
            inkElement = nil
        }
        let space = writingSpaceElement ?? UIAccessibilityElement(accessibilityContainer: self)
        space.accessibilityIdentifier = NotePageAccessibilityID.writingSpace
        space.accessibilityLabel = "Space for handwriting"
        space.accessibilityFrameInContainerSpace = CGRect(x: 0, y: layout.trailingTop, width: bounds.width,
                                                          height: max(pageHeight - layout.trailingTop, 1))
        writingSpaceElement = space
    }

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let text = editor?.textView { elements.append(text) }
            if let inkElement { elements.append(inkElement) }
            if let writingSpaceElement { elements.append(writingSpaceElement) }
            return elements
        }
        set {}
    }
}
