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
}
