import Foundation
import ObjectiveC
import PDFKit
import PencilKit
import ReaderCore
import Testing
import UIKit
import WebKit
@testable import TactileTexts

/// One canary per framework workaround (`App/Support/FrameworkWorkarounds`): each checks, on the
/// system the tests run on, the piece of PDFKit, PencilKit, WebKit or QuickLook's inside that the
/// workaround leans on. When an iPadOS release changes it, the canary named after the workaround
/// fails, instead of the feature quietly going wrong.
///
/// `PDFKitWorkarounds.batchedSelection` has its canary in `ReaderPDFDocumentTests` (the batched
/// selection equals PDFKit's own).
@MainActor
@Suite(.serialized)
struct FrameworkWorkaroundCanaryTests {
    private func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func makeWindow(size: CGSize = CGSize(width: 700, height: 900)) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIViewController()
        window.isHidden = false
        return window
    }

    /// The reader's PDF view on `small.pdf`, in a window, laid out.
    private func makeReaderPDFView() async throws -> (view: ReaderPDFView, window: UIWindow) {
        let window = try makeWindow()
        let view = ReaderPDFView(frame: window.bounds)
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        try #require(window.rootViewController).view.addSubview(view)
        view.document = try #require(PDFDocument(url: PageInkTestSupport.fixture("small.pdf")))
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(await waitUntil { view.documentView != nil })
        return (view, window)
    }

    // MARK: PDFKit

    /// `PDFKitWorkarounds.scrollView(of:)`: the scroll view is the document view's superview.
    @Test func pdfKitScrollsTheDocumentInTheSuperviewOfItsDocumentView() async throws {
        let (view, window) = try await makeReaderPDFView()
        defer { window.isHidden = true }
        let documentView = try #require(view.documentView)
        #expect(documentView.superview is UIScrollView, "superview: \(String(describing: documentView.superview))")
        #expect(PDFKitWorkarounds.scrollView(of: view) != nil)
    }

    /// `PDFKitWorkarounds.disableScrollsToTop(in:)`: PDFKit's scroll view is within the depth the
    /// walk covers, and comes out with scroll-to-top off.
    @Test func pdfKitsScrollViewIsFoundAndOptedOutOfScrollToTop() async throws {
        let (view, window) = try await makeReaderPDFView()
        defer { window.isHidden = true }
        let scrollView = try #require(PDFKitWorkarounds.scrollView(of: view))
        scrollView.scrollsToTop = true
        PDFKitWorkarounds.disableScrollsToTop(in: view)
        #expect(!scrollView.scrollsToTop)
    }

    /// `PDFKitWorkarounds.isPDFKitView(_:in:)`: PDFKit's views come from PDFKit's bundle, and a
    /// view a feature adds does not.
    @Test func pdfKitsOwnViewsAreToldApartByTheirBundle() async throws {
        let (view, window) = try await makeReaderPDFView()
        defer { window.isHidden = true }
        let documentView = try #require(view.documentView)
        #expect(Bundle(for: type(of: documentView)) == Bundle(for: PDFView.self))
        let chrome = try #require(view.subviews.first { documentView.isDescendant(of: $0) })
        #expect(PDFKitWorkarounds.isPDFKitView(chrome, in: view))
        let added = UIView()
        view.addSubview(added)
        #expect(!PDFKitWorkarounds.isPDFKitView(added, in: view))
    }

    /// `PDFKitWorkarounds.visiblePageViews` and `hideTextInputProxies`: the document view is a
    /// text input (the element that must not be read whole), and the pages on screen are its
    /// subviews that are not text inputs.
    @Test func pdfKitsDocumentViewIsATextInputWithOneSubviewPerPage() async throws {
        let (view, window) = try await makeReaderPDFView()
        defer { window.isHidden = true }
        let documentView = try #require(view.documentView)
        #expect(documentView is UITextInput)
        #expect(await waitUntil { !PDFKitWorkarounds.visiblePageViews(in: view, horizontal: false).isEmpty })
        let pages = PDFKitWorkarounds.visiblePageViews(in: view, horizontal: false)
        #expect(pages.allSatisfy { $0.superview === documentView && !($0 is UITextInput) })
        #expect(pages.allSatisfy { Bundle(for: type(of: $0)) == Bundle(for: PDFView.self) })
        // The reader's accessibility children start with exactly these.
        let elements = try #require(view.accessibilityElements)
        #expect(elements.prefix(pages.count).map { ObjectIdentifier($0 as AnyObject) } == pages.map { ObjectIdentifier($0) })
        #expect(!elements.contains { ($0 as AnyObject) === documentView })
    }

    /// `PDFKitWorkarounds.routeSelectAll(from:)`: the document view's private class has its own
    /// `selectAll:` and `canPerformAction:withSender:` to replace, and once replaced Select All
    /// follows the reader's rule (offered only with a selection).
    @Test func pdfKitsDocumentViewAnswersSelectAllItself() async throws {
        let (view, window) = try await makeReaderPDFView()
        defer { window.isHidden = true }
        let documentView = try #require(view.documentView)
        let cls: AnyClass = type(of: documentView)
        let selectAll = #selector(UIResponderStandardEditActions.selectAll(_:))
        #expect(ObjectIdentifier(cls) != ObjectIdentifier(UIView.self), "the document view is a class of PDFKit's own")
        #expect(documentView.responds(to: selectAll))
        #expect(class_getInstanceMethod(cls, selectAll) != nil)
        #expect(class_getInstanceMethod(cls, #selector(UIResponder.canPerformAction(_:withSender:))) != nil)

        view.applyPDFKitPolicies()
        view.clearSelection()
        #expect(!documentView.canPerformAction(selectAll, withSender: nil), "no selection: Select All is not offered")
        let page = try #require(view.document?.page(at: 0))
        view.setCurrentSelection(try #require(page.selection(for: NSRange(location: 0, length: 5))), animate: false)
        #expect(documentView.canPerformAction(selectAll, withSender: nil))
    }

    // MARK: PencilKit

    private final class UndoResponderView: UIView {
        let manager = UndoManager()
        override var canBecomeFirstResponder: Bool { true }
        override var undoManager: UndoManager? { manager }
    }

    private final class ReceivedNotifications: @unchecked Sendable {
        var names: [Notification.Name] = []
    }

    /// `PencilKitWorkarounds.postUndoNotification`: the three notifications are the ones posted
    /// for the stand-in manager, and an observer of that manager receives them.
    ///
    /// This pins the app's side only. What the workaround leans on, that the system tool picker
    /// follows its first responder's undo manager through exactly these notifications, could not
    /// be made visible to a unit test: in the test host the picker, shown for a responder whose
    /// manager counted every read of `canUndo`, `canRedo`, the counts and the menu titles, read
    /// none of them when the notifications were posted. The picker's Undo and Redo buttons are
    /// checked where they can be pressed, in the UI tests.
    @Test func undoNotificationsPostedForTheStandInManagerReachItsObservers() {
        #expect(PencilKitWorkarounds.toolPickerUndoNotifications
            == [.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange])
        let standIn = UndoManager()
        let received = ReceivedNotifications()
        let tokens = PencilKitWorkarounds.toolPickerUndoNotifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: standIn, queue: nil) { notification in
                received.names.append(notification.name)
            }
        }
        defer { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
        for name in PencilKitWorkarounds.toolPickerUndoNotifications {
            PencilKitWorkarounds.postUndoNotification(name, as: standIn, userInfo: nil)
        }
        #expect(Set(received.names) == PencilKitWorkarounds.toolPickerUndoNotifications)
        #expect(received.names.count == 3)
    }

    /// `PencilKitWorkarounds.showToolPickerForTheFirstTime`: the palette is hosted in another
    /// window of the same scene (which is why the scene's windows are laid out).
    @Test func theToolPickersPaletteIsHostedInAnotherWindowOfTheScene() async throws {
        let window = try makeWindow()
        defer { window.isHidden = true }
        window.makeKeyAndVisible()
        let responder = UndoResponderView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        try #require(window.rootViewController).view.addSubview(responder)
        let picker = PKToolPicker()
        picker.setVisible(true, forFirstResponder: responder)
        PencilKitWorkarounds.showToolPickerForTheFirstTime(in: window) { _ = responder.becomeFirstResponder() }
        let shown = await waitUntil(timeout: 5) { picker.isVisible }
        try #require(shown, "the tool picker did not appear in the test window")

        func holdsPencilKitView(_ view: UIView) -> Bool {
            if Bundle(for: type(of: view)) == Bundle(for: PKToolPicker.self) { return true }
            return view.subviews.contains(where: holdsPencilKitView)
        }
        let sceneWindows = window.windowScene?.windows ?? []
        #expect(!holdsPencilKitView(window), "the palette is not in the window it was shown for")
        #expect(sceneWindows.contains { $0 !== window && holdsPencilKitView($0) },
                "scene windows: \(sceneWindows.map { String(describing: type(of: $0)) })")
        picker.setVisible(false, forFirstResponder: responder)
    }

    // MARK: WebKit

    /// `WebKitWorkarounds.ruleListBlockingEverything(except:)`: the list the converters use is
    /// the one they have always compiled, and WebKit's rule-list compiler accepts it.
    @Test func theNetworkBlockRuleListCompiles() async throws {
        let json = WebKitWorkarounds.ruleListBlockingEverything(except: ["tactile-content", "x-apple-ql-id"])
        #expect(json == #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},"#
            + #"{"trigger":{"url-filter":"^tactile-content:"},"action":{"type":"ignore-previous-rules"}},"#
            + #"{"trigger":{"url-filter":"^x-apple-ql-id:"},"action":{"type":"ignore-previous-rules"}}]"#)
        #expect(WebPDFRenderer.ruleListJSON == json)
        let store = try #require(WKContentRuleListStore.default())
        let identifier = "software.tactile.texts.canary.block-network"
        let compiled: Bool = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: list != nil) }
            }
        }
        #expect(compiled)
        await withCheckedContinuation { continuation in
            store.removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
        }
    }

    // MARK: QuickLook

    /// `QuickLookWorkarounds.mimeType(forFileExtension:format:)` and `convertedResourceScheme`:
    /// served with that MIME type, a Word file comes out of WebKit as a web page (QuickLook's
    /// conversion), and the page's picture is served under QuickLook's scheme.
    @Test func webKitConvertsAWordFileAndServesItsPictureUnderQuickLooksScheme() async throws {
        let file = F6Fixtures.fixture("f6-sample.docx")
        let mime = QuickLookWorkarounds.mimeType(forFileExtension: "docx", format: .word)
        var configuration = WebPDFRenderer.Configuration(pageSize: OfficePageGeometry.letter, margins: .zero)
        configuration.loadTimeout = 60
        let renderer = WebPDFRenderer(
            provider: WebFileResources(["document.docx": .init(source: .file(file), mimeType: mime, textEncodingName: nil)]),
            configuration: configuration)
        try await renderer.start()
        defer { renderer.tearDown() }
        try await renderer.load(path: "document.docx")
        let text = try await renderer.evaluate("return document.body ? document.body.innerText : '';")
        #expect(text.contains("F6WORD-intro"), "the document was not converted to a page")
        let sources = try await renderer.evaluate(
            "return Array.from(document.images).map(function (image) { return image.src; }).join('\\n');")
        let schemes = Set(sources.split(separator: "\n").compactMap { URL(string: String($0))?.scheme })
        #expect(schemes.contains(QuickLookWorkarounds.convertedResourceScheme), "picture sources: \(sources)")
    }
}
