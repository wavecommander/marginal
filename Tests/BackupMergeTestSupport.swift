import Foundation
import PencilKit
import ReaderBackup
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// Helpers for the merge engine tests (M3): two libraries holding the same book that diverged,
/// real PencilKit page ink and note ink, and comparing ink by strokes.
@MainActor
enum BackupMergeTestSupport {
    typealias Support = BackupTestSupport

    // MARK: Strokes

    /// A horizontal stroke in note-page or PDF-page coordinates with a unique creation date.
    static func stroke(y: CGFloat, x: ClosedRange<CGFloat> = 20...120) -> PKStroke {
        NotePageTestSupport.stroke(from: CGPoint(x: x.lowerBound, y: y), to: CGPoint(x: x.upperBound, y: y))
    }

    static func layout(_ text: String) -> NoteBandLayout {
        NotePageLayoutEngine.shared.bandLayout(for: text)
    }

    /// A stroke across the middle of paragraph `paragraph` of `layout`, or `trailingOffset`
    /// below the end of the text when `paragraph` is `nil`. In note-page coordinates.
    static func noteStroke(_ paragraph: Int?, in layout: NoteBandLayout, trailingOffset: CGFloat = 30,
                           x: ClosedRange<CGFloat> = 20...120) -> PKStroke {
        if let paragraph {
            let band = layout.paragraphs[paragraph]
            return stroke(y: band.top + min(band.height, NotePageStyle.lineHeight) / 2, x: x)
        }
        return stroke(y: layout.trailingTop + trailingOffset, x: x)
    }

    /// Note ink with `pageStrokes` (note-page coordinates) anchored by geometry, as the editor does.
    static func noteInk(_ pageStrokes: [PKStroke], layout: NoteBandLayout) -> NoteInk {
        NoteInk(layout: layout, strokes: pageStrokes.map { stroke in
            let band = layout.band(for: stroke.renderBounds)
            return NoteInkStroke(band: band, local: stroke.translatedVertically(by: -(layout.top(of: band) ?? 0)))
        })
    }

    // MARK: Writing to a store

    static func savePageInk(_ store: LibraryStore, _ bookID: UUID, page: Int, _ strokes: [PKStroke]) async throws {
        try await store.savePageInk(PKDrawing(strokes: strokes).dataRepresentation(), bookID: bookID, pageIndex: page, origin: nil)
    }

    /// Adds strokes to a page's drawing (creating it).
    static func addPageInk(_ store: LibraryStore, _ bookID: UUID, page: Int, _ strokes: [PKStroke]) async throws {
        var existing: [PKStroke] = []
        if let data = try await store.pageInk(bookID: bookID, pageIndex: page) { existing = try PKDrawing(data: data).strokes }
        try await savePageInk(store, bookID, page: page, existing + strokes)
    }

    /// Writes the note on `target` with `text` and ink: the existing ink (relaid to `text`, as
    /// the editor does) plus a stroke on each of `strokesOver` (`nil`: the trailing space).
    /// Returns the new strokes as drawn (note-page coordinates of `text`'s layout).
    @discardableResult
    static func writeNote(_ store: LibraryStore, _ bookID: UUID, target: NoteTarget, text: String,
                          strokesOver: [Int?] = [], trailingOffset: CGFloat = 30) async throws -> [PKStroke] {
        let existing = try store.notes.note(bookID: bookID, target: target)
        let textLayout = layout(text)
        var ink = NoteInk(layout: textLayout)
        if let existing, let data = try await store.noteInk(bookID: bookID, noteID: existing.id) {
            ink = try NoteInkArchive.decode(data, fallbackLayout: existing.bandLayout ?? layout(existing.text)).relaid(to: textLayout)
        }
        let added = strokesOver.map { noteStroke($0, in: textLayout, trailingOffset: trailingOffset) }
        ink.strokes += noteInk(added, layout: textLayout).strokes
        let now = (existing?.modifiedAt ?? Date(timeIntervalSinceReferenceDate: 790_000_000)).addingTimeInterval(5)
        let note = Note(id: existing?.id ?? UUID(), bookID: bookID, target: target, text: text, hasInk: !ink.isEmpty,
                        bandLayout: ink.isEmpty ? nil : ink.layout, createdAt: existing?.createdAt ?? now, modifiedAt: now)
        try store.notes.save(note)
        if !ink.isEmpty {
            try await store.saveNoteInk(try NoteInkArchive.encode(ink), bookID: bookID, noteID: note.id, origin: nil)
        }
        return added
    }

    // MARK: Reading back

    static func pageDrawing(_ store: LibraryStore, _ bookID: UUID, page: Int) async throws -> PKDrawing? {
        guard let data = try await store.pageInk(bookID: bookID, pageIndex: page) else { return nil }
        return try PKDrawing(data: data)
    }

    /// The note's stored ink, decoded against the layout stored with it.
    static func storedNoteInk(_ store: LibraryStore, _ note: Note) async throws -> NoteInk? {
        guard let data = try await store.noteInk(bookID: note.bookID, noteID: note.id) else { return nil }
        return try NoteInkArchive.decode(data, fallbackLayout: note.bandLayout ?? layout(note.text))
    }

    static func identities(_ strokes: [PKStroke]) -> [StrokeIdentity] { strokes.map { StrokeIdentity($0) } }

    /// How many strokes of `strokes` have `stroke`'s identity.
    static func count(of stroke: PKStroke, in strokes: [PKStroke]) -> Int {
        let identity = StrokeIdentity(stroke)
        return strokes.filter { StrokeIdentity($0) == identity }.count
    }

    /// The stroke of `ink` with `stroke`'s identity, as placed on the note page.
    static func placed(_ stroke: PKStroke, in ink: NoteInk) -> (band: NoteBandRef, page: PKStroke)? {
        let identity = StrokeIdentity(stroke)
        guard let found = ink.strokes.first(where: { StrokeIdentity($0.local) == identity }) else { return nil }
        return (found.band, ink.pageStroke(found))
    }

    /// Placed strokes of a drawing as comparable values (identity and placement).
    static func fingerprints(_ strokes: [PKStroke]) -> [StrokeFingerprint] { strokes.map { StrokeFingerprint($0) } }

    // MARK: Library state with ink compared by strokes

    /// Every file of every book; `.drawing` files compared by their strokes (page ink) or their
    /// layout, bands and strokes (note ink), everything else by bytes.
    struct InkState: Equatable {
        var archives: [UUID: BookArchive]
        var files: [String: Data]
        var pageInk: [String: [StrokeFingerprint]]
        var noteInk: [String: NoteInkSummary]
    }

    struct NoteInkSummary: Equatable {
        var layout: NoteBandLayout
        var bands: [NoteBandRef]
        var strokes: [StrokeFingerprint]
    }

    static func inkState(_ store: LibraryStore) throws -> InkState {
        let state = try Support.libraryState(store)
        var files: [String: Data] = [:]
        var pages: [String: [StrokeFingerprint]] = [:]
        var notes: [String: NoteInkSummary] = [:]
        for (path, data) in state.files {
            if path.hasSuffix(".drawing"), path.contains("/ink/"), let drawing = try? PKDrawing(data: data) {
                pages[path] = fingerprints(drawing.strokes)
            } else if path.hasSuffix(".drawing"), path.contains("/notes/"),
                      let ink = try? NoteInkArchive.decode(data, fallbackLayout: NoteBandLayout(pageWidth: 0, paragraphs: [], trailingTop: 0)) {
                notes[path] = NoteInkSummary(layout: ink.layout, bands: ink.strokes.map(\.band),
                                             strokes: fingerprints(ink.strokes.map(\.local)))
            } else {
                files[path] = data
            }
        }
        return InkState(archives: state.archives, files: files, pageInk: pages, noteInk: notes)
    }

    // MARK: Two diverged copies

    /// One book in two libraries: `local` (this iPad) and `origin` (the backup's library), made
    /// equal through a backup, then changed in different ways. `backup` is a backup of `origin`
    /// after its changes.
    struct Diverged {
        var scratch: URL
        var local: LibraryStore
        var origin: LibraryStore
        var book: Book
        var backup: URL
        /// Strokes by role (see `makeDiverged`).
        var strokes: [String: PKStroke]
        /// The local book before the merge.
        var localBefore: BookArchive
        /// The backup's records of the book.
        var originArchive: BookArchive

        @MainActor
        func cleanUp() {
            for url in [scratch, local.rootDirectory, origin.rootDirectory] { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// The common start: `small.pdf` with a note "Alpha\nBeta" (a stroke on Alpha) on page 1,
    /// page ink on page 2, a highlight, a bookmark on page 0 and a reader-made heading. Then:
    /// - the backup's side changes the page 1 note to "Alpha\nGamma" with a stroke on Gamma,
    ///   adds a stroke to page 2, ink on page 5, a note with ink on page 3, a highlight, a
    ///   bookmark on page 4 and a heading;
    /// - this iPad adds a stroke on Beta, a stroke to page 2, ink on page 6, a note without ink
    ///   on page 7, a highlight, a bookmark on page 8 and a heading.
    static func makeDiverged(includePDFs: Bool = false) async throws -> Diverged {
        let scratch = try Support.scratch("BackupMerge")
        let local = try LibraryStore.ephemeral()
        let origin = try LibraryStore.ephemeral()
        let book = try #require(try await ImportService(store: local).importPDF(at: Support.small).book)
        var strokes: [String: PKStroke] = [:]
        let date = Date(timeIntervalSinceReferenceDate: 780_000_000)

        strokes["alpha"] = try await writeNote(local, book.id, target: .page(1), text: "Alpha\nBeta", strokesOver: [0]).first
        strokes["page2-base"] = stroke(y: 100)
        try await savePageInk(local, book.id, page: 2, [strokes["page2-base"]!])
        try local.highlights.save(Highlight(bookID: book.id, pageIndex: 2, rects: [CGRect(x: 10, y: 20, width: 100, height: 12)],
                                            color: .yellow, text: "base highlight", createdAt: date))
        try local.bookmarks.setBookmarked(true, bookID: book.id, pageIndex: 0)
        try local.headings.save(UserHeading(bookID: book.id, title: "Base heading", pageIndex: 2, parent: nil, createdAt: date))
        _ = try await local.contentDigest(of: book)

        // The same book in the backup's library, through a backup.
        let base = try await Support.makeService(local, scratch: scratch).backUpToFile(includePDFs: true).url
        let originService = Support.makeService(origin, scratch: scratch)
        let session = try await originService.openBackup(at: base)
        _ = try await originService.restore(Set(session.plan.items.map(\.id)), from: session, restorePDFs: true)
        session.close()
        #expect(try Support.archive(origin, book.id) == Support.archive(local, book.id))

        // The backup's side.
        strokes["gamma"] = try await writeNote(origin, book.id, target: .page(1), text: "Alpha\nGamma", strokesOver: [1]).first
        strokes["page2-origin"] = stroke(y: 200)
        try await addPageInk(origin, book.id, page: 2, [strokes["page2-origin"]!])
        strokes["page5-origin"] = stroke(y: 300)
        try await savePageInk(origin, book.id, page: 5, [strokes["page5-origin"]!])
        strokes["page3-note"] = try await writeNote(origin, book.id, target: .page(3), text: "From the backup", strokesOver: [0]).first
        try origin.highlights.save(Highlight(bookID: book.id, pageIndex: 4, rects: [CGRect(x: 30, y: 40, width: 80, height: 12)],
                                             color: .green, text: "backup highlight", createdAt: date.addingTimeInterval(10)))
        try origin.bookmarks.setBookmarked(true, bookID: book.id, pageIndex: 4)
        try origin.headings.save(UserHeading(bookID: book.id, title: "Backup heading", pageIndex: 5, parent: nil,
                                             createdAt: date.addingTimeInterval(10)))
        let backup = try await Support.makeService(origin, scratch: scratch).backUpToFile(includePDFs: includePDFs).url

        // This iPad.
        strokes["beta"] = try await writeNote(local, book.id, target: .page(1), text: "Alpha\nBeta", strokesOver: [1]).first
        strokes["page2-local"] = stroke(y: 400)
        try await addPageInk(local, book.id, page: 2, [strokes["page2-local"]!])
        strokes["page6-local"] = stroke(y: 500)
        try await savePageInk(local, book.id, page: 6, [strokes["page6-local"]!])
        try await writeNote(local, book.id, target: .page(7), text: "Only on this iPad")
        try local.highlights.save(Highlight(bookID: book.id, pageIndex: 6, rects: [CGRect(x: 50, y: 60, width: 70, height: 12)],
                                            color: .pink, text: "local highlight", createdAt: date.addingTimeInterval(20)))
        try local.bookmarks.setBookmarked(true, bookID: book.id, pageIndex: 8)
        try local.headings.save(UserHeading(bookID: book.id, title: "Local heading", pageIndex: 6, parent: nil,
                                            createdAt: date.addingTimeInterval(20)))
        var withPosition = try #require(try local.books.book(id: book.id))
        withPosition.lastReadPageIndex = 9
        try local.books.save(withPosition)

        return Diverged(scratch: scratch, local: local, origin: origin, book: withPosition, backup: backup, strokes: strokes,
                        localBefore: try #require(try Support.archive(local, book.id)),
                        originArchive: try #require(try Support.archive(origin, book.id)))
    }

    /// Merges `backup`'s copy of `bookID` into `store` with a new service (or `service`).
    static func merge(_ backup: URL, bookID: UUID, into store: LibraryStore, scratch: URL, restorePDFs: Bool = true,
                      service: BackupService? = nil) async throws -> RestoreSummary {
        let service = service ?? Support.makeService(store, scratch: scratch)
        let session = try await service.openBackup(at: backup)
        defer { session.close() }
        return try await service.restore([bookID: .merge], from: session, restorePDFs: restorePDFs)
    }
}
