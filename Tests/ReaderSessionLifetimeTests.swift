import Foundation
import PDFKit
import ReaderCore
import Testing
import UIKit
@testable import TactileTexts

/// Sleeping readers: a released session is deallocated, and a closed one holds nothing heavy
/// even while something (SwiftUI's state of a finished screen) still holds the session.
@MainActor
struct ReaderSessionLifetimeTests {
    private func openHost() async throws -> PageInkTestSupport.Host {
        let (store, book) = try PageInkTestSupport.makeStore(pdf: PageInkTestSupport.fixture("links.pdf"), pageCount: 12)
        let host = PageInkTestSupport.Host(book: book, store: store)
        #expect(await PageInkTestSupport.waitUntil {
            host.session.isOutlineLoaded && host.session.pdf.hasPositionedInitially && host.session.notebook != nil
        })
        return host
    }

    @Test func aReleasedSessionIsDeallocated() async throws {
        weak var weakSession: ReaderSession?
        do {
            let host = try await openHost()
            weakSession = host.session
            await host.close()
        }
        try? await Task.sleep(for: .milliseconds(500))
        #expect(weakSession == nil)
    }

    @Test func aClosedSessionLetsItsDocumentAndFeaturesGo() async throws {
        let host = try await openHost()
        let session = host.session
        weak var document = session.document
        weak var highlights = session.highlights
        weak var notes = session.notesPanelIfCreated
        #expect(document != nil && highlights != nil && notes != nil)

        await session.suspend()
        session.close()
        #expect(session.isClosed)
        // PDFKit lets the document go shortly after (its rendering finishes first).
        #expect(await PageInkTestSupport.waitUntil(timeout: 20) { document == nil }, "the PDF document and its pages")
        #expect(highlights == nil && notes == nil, "the feature controllers")
        #expect(session.notebook == nil && session.outline.nodes.isEmpty)
        #expect(session.pdf.view.superview == nil)
        #expect(!OpenEditorRegistry.shared.sessions(of: session.store).contains { $0 === session })
        await host.close()
    }

    /// `PDFView` keeps the page it last navigated away from after its document is cleared, and
    /// that page keeps PDFKit's mapping of the whole file. A closed session (which SwiftUI may
    /// keep) must hold neither the view nor any page of the book, however it was read.
    @Test func aClosedSessionKeepsNoPageOfTheBook() async throws {
        let host = try await openHost()
        let session = host.session
        final class WeakPage { weak var page: PDFPage?; init(_ page: PDFPage?) { self.page = page } }
        let pages: [WeakPage]
        do {
            let document = try #require(session.document)
            pages = (0..<document.pageCount).map { WeakPage(document.page(at: $0)) }
        }
        #expect(pages.allSatisfy { $0.page != nil })
        weak var pdfView = session.pdf.view

        // Navigate, so PDFKit has a page it went from.
        for target in [3, 7, 5] {
            #expect(session.jump(toPage: target))
            #expect(await PageInkTestSupport.waitUntil { session.currentPageIndex == target })
        }

        await session.suspend()
        session.close()
        #expect(session.isClosed)
        #expect(await PageInkTestSupport.waitUntil(timeout: 20) { pdfView == nil }, "the PDF view")
        #expect(await PageInkTestSupport.waitUntil(timeout: 20) { pages.allSatisfy { $0.page == nil } },
                "pages still alive: \(pages.indices.filter { pages[$0].page != nil })")
        await host.close()
    }
}
