import CoreGraphics
import Foundation
import ReaderBackup
import ReaderCore
import Testing
@testable import ReaderSync

// MARK: - Ink as tokens

/// Test ink: a drawing is a set of stroke tokens, stored as sorted lines. No strokes is no file.
enum TokenInk {
    static func encode(_ tokens: Set<String>) -> Data? {
        tokens.isEmpty ? nil : Data(tokens.sorted().joined(separator: "\n").utf8)
    }

    static func decode(_ data: Data?) -> Set<String> {
        guard let data, !data.isEmpty else { return [] }
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
    }
}

/// The ink merger the tests use: three-way set semantics on tokens (a stroke added on either side
/// is kept; one erased on one side is removed when the other side still has it as the base did;
/// no base: the union), plus the union of absorbed notes. Paragraph maps do not move tokens.
struct TokenInkMerger: SyncInkMerger {
    let calls = Collected<SyncInkMergeRequest.Kind>()
    /// Merges that had a base to merge against.
    let threeWay = Collected<SyncInkMergeRequest.Kind>()
    /// The notes each note merge named.
    let notes = Collected<SyncInkNotes>()

    func merge(_ request: SyncInkMergeRequest) async throws -> Data? {
        calls.append(request.kind)
        if let notes = request.notes { self.notes.append(notes) }
        if case .ink = request.base { threeWay.append(request.kind) }
        let l = TokenInk.decode(request.local), r = TokenInk.decode(request.remote)
        var result: Set<String>
        switch request.base {
        case .unavailable:
            result = l.union(r)
        case .none:
            result = l.union(r)
        case .ink(let data):
            let b = TokenInk.decode(data)
            result = l.intersection(r).union(l.subtracting(b)).union(r.subtracting(b))
        }
        for data in request.absorbed { result.formUnion(TokenInk.decode(data)) }
        return TokenInk.encode(result)
    }
}

// MARK: - A library in memory

let testLayout = NoteBandLayout(pageWidth: 320, paragraphs: [], trailingTop: 8)

/// The local library of one simulated iPad. It applies a change record by record (so the diff the
/// engine computes is what is checked) and then does what the app does after an ink merge: sets
/// `hasInk` from the note's ink file, lays out a note with ink and no layout, and removes a note
/// left empty.
actor FakeLibrary: SyncLibrary {
    struct Book: Hashable, Sendable {
        var archive: BookArchive
        var files: [SyncFileKey: Data]
        var pdf: ContentDigest
        var pdfPresent: Bool
        var revision = 0
    }

    struct State: Hashable, Sendable {
        var books: [UUID: Book] = [:]
        var busy: [UUID: Set<SyncSurface>] = [:]
    }

    private(set) var state = State()
    let pdfDirectory: URL
    /// Every apply that did not reproduce the engine's target.
    private(set) var problems: [String] = []
    private(set) var applied = 0

    init(pdfDirectory: URL) {
        self.pdfDirectory = pdfDirectory
    }

    // MARK: Test controls

    func restore(_ state: State) {
        self.state = state
    }

    func book(_ id: UUID) -> Book? { state.books[id] }

    var bookIDs: [UUID] { state.books.keys.sorted { $0.uuidString < $1.uuidString } }

    /// Replaces a book as the reader's edits leave it (bumps its revision).
    func put(_ id: UUID, _ book: Book) {
        var book = book
        book.revision = (state.books[id]?.revision ?? 0) + 1
        state.books[id] = book
    }

    func remove(_ id: UUID) {
        state.books[id] = nil
        state.busy[id] = nil
    }

    func setBusy(_ id: UUID, _ surfaces: Set<SyncSurface>) {
        state.busy[id] = surfaces.isEmpty ? nil : surfaces
    }

    func clearBusy() { state.busy = [:] }

    /// Adds a book imported from `pdf` (bytes), with the given archive.
    func importBook(_ archive: BookArchive, pdf: Data, files: [SyncFileKey: Data] = [:]) throws {
        try FileManager.default.createDirectory(at: pdfDirectory, withIntermediateDirectories: true)
        let content = ContentDigest(of: pdf)
        try pdf.write(to: pdfFile(content))
        put(archive.book.id, Book(archive: archive, files: files, pdf: content, pdfPresent: true))
    }

    private func pdfFile(_ content: ContentDigest) -> URL {
        pdfDirectory.appendingPathComponent("\(content.sha256).pdf", isDirectory: false)
    }

    // MARK: SyncLibrary

    func books() -> [SyncLibraryBook] {
        state.books.values.map { SyncLibraryBook(bookID: $0.archive.book.id, pdf: $0.pdf) }
    }

    func snapshot(bookID: UUID) -> SyncLocalSnapshot? {
        guard let book = state.books[bookID] else { return nil }
        return SyncLocalSnapshot(archive: book.archive, files: book.files.mapValues { ContentDigest(of: $0) }, pdf: book.pdf,
                                 pdfFile: book.pdfPresent ? pdfFile(book.pdf) : nil, busy: state.busy[bookID] ?? [],
                                 token: "\(book.revision)")
    }

    func fileData(_ file: SyncFileKey, bookID: UUID) -> Data? {
        state.books[bookID]?.files[file]
    }

    func apply(_ change: SyncLocalChange, bookID: UUID, snapshotToken: String) throws {
        guard var book = state.books[bookID], "\(book.revision)" == snapshotToken else {
            throw SyncLibraryError.changedSinceSnapshot(bookID: bookID)
        }
        let busy = state.busy[bookID] ?? []
        for surface in busy {
            switch surface {
            case .page(let page):
                if change.filesToWrite[.pageInk(page)] != nil || change.filesToRemove.contains(.pageInk(page)) {
                    problems.append("wrote busy page \(page)")
                }
            case .note(let id):
                let touched = change.records.notes.changed.contains { $0.id == id } || change.records.notes.removed.contains(id)
                    || change.filesToWrite[.noteInk(id)] != nil || change.filesToRemove.contains(.noteInk(id))
                if touched { problems.append("touched busy note \(id)") }
            }
        }
        var a = book.archive
        Self.apply(change.records.notes, to: &a.notes)
        Self.apply(change.records.highlights, to: &a.highlights)
        Self.apply(change.records.bookmarks, to: &a.bookmarks)
        Self.apply(change.records.userHeadings, to: &a.userHeadings)
        a.book.title = change.archive.book.title
        a.book.lastReadPageIndex = change.archive.book.lastReadPageIndex
        a.book.lastOpenedAt = change.archive.book.lastOpenedAt
        if !SyncPlanning.sameContent(a, change.archive) { problems.append("the diff does not give the target") }
        for (key, data) in change.filesToWrite { book.files[key] = data }
        for key in change.filesToRemove { book.files[key] = nil }
        book.archive = a
        Self.touch(&book)
        book.revision += 1
        state.books[bookID] = book
        applied += 1
    }

    func createBook(_ new: SyncNewBook) throws {
        let id = new.archive.book.id
        if state.books[id] != nil { problems.append("created over an existing book") }
        var book = Book(archive: new.archive, files: new.files, pdf: new.pdf, pdfPresent: false, revision: 1)
        Self.touch(&book)
        state.books[id] = book
    }

    func deleteBook(bookID: UUID, snapshotToken: String) throws {
        guard let book = state.books[bookID], "\(book.revision)" == snapshotToken else {
            throw SyncLibraryError.changedSinceSnapshot(bookID: bookID)
        }
        state.books[bookID] = nil
    }

    func installPDF(bookID: UUID, from file: URL, content: ContentDigest) throws {
        guard var book = state.books[bookID] else { throw SyncLibraryError.bookNotFound(bookID: bookID) }
        let data = try Data(contentsOf: file)
        guard ContentDigest(of: data) == content else { throw SyncError.contentMismatch(key: "pdf") }
        try FileManager.default.createDirectory(at: pdfDirectory, withIntermediateDirectories: true)
        try data.write(to: pdfFile(content))
        book.pdfPresent = true
        state.books[bookID] = book
    }

    // MARK: Helpers

    private static func apply<R: Identifiable & Hashable & Sendable>(_ diff: RecordDiff<R>, to records: inout [R])
        where R.ID == UUID {
        let removed = Set(diff.removed)
        records.removeAll { removed.contains($0.id) }
        for record in diff.changed {
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        }
        records.append(contentsOf: diff.added)
    }

    /// What the app does after writing merged ink.
    static func touch(_ book: inout Book) {
        for k in book.archive.notes.indices {
            var note = book.archive.notes[k]
            note.bookID = book.archive.book.id
            let inked = book.files[.noteInk(note.id)] != nil
            note.hasInk = inked
            if inked && note.bandLayout == nil { note.bandLayout = testLayout }
            if !inked { note.bandLayout = nil }
            book.archive.notes[k] = note
        }
        book.archive.notes.removeAll(where: \.isEmpty)
        let ids = Set(book.archive.notes.map(\.id))
        for key in book.files.keys {
            if case .noteInk(let id) = key, !ids.contains(id) { book.files[key] = nil }
        }
    }
}

// MARK: - A store that fails on a chosen call

/// Wraps the shared store for one device, numbering its calls, and makes the chosen call fail
/// before or after it takes effect.
final class FaultingStore: SyncObjectStore, @unchecked Sendable {
    let inner: InMemorySyncObjectStore
    private let lock = NSLock()
    private var count = 0
    private var fault: (index: Int, timing: InMemorySyncObjectStore.FaultTiming)?

    init(_ inner: InMemorySyncObjectStore) {
        self.inner = inner
    }

    /// Calls made so far.
    var callCount: Int { lock.withLock { count } }

    func arm(at index: Int, _ timing: InMemorySyncObjectStore.FaultTiming) {
        lock.withLock { count = 0; fault = (index, timing) }
    }

    func reset() { lock.withLock { count = 0; fault = nil } }

    private func next() -> InMemorySyncObjectStore.FaultTiming? {
        lock.withLock {
            defer { count += 1 }
            guard let fault, fault.index == count else { return nil }
            self.fault = nil
            return fault.timing
        }
    }

    private func run<T>(_ body: () async throws -> T) async throws -> T {
        let timing = next()
        if timing == .beforeEffect { throw InMemorySyncObjectStore.InjectedFault() }
        let value = try await body()
        if timing == .afterEffect { throw InMemorySyncObjectStore.InjectedFault() }
        return value
    }

    func list(prefix: String) async throws -> [SyncObjectInfo] { try await run { try await inner.list(prefix: prefix) } }
    func get(_ key: String, maxBytes: Int) async throws -> SyncObjectData? {
        try await run { try await inner.get(key, maxBytes: maxBytes) }
    }
    func put(_ data: Data, at key: String, metadata: [String: String], condition: SyncWriteCondition?) async throws -> String {
        try await run { try await inner.put(data, at: key, metadata: metadata, condition: condition) }
    }
    func upload(fileAt file: URL, to key: String, metadata: [String: String]) async throws {
        try await run { try await inner.upload(fileAt: file, to: key, metadata: metadata) }
    }
    func download(_ key: String, to file: URL) async throws { try await run { try await inner.download(key, to: file) } }
    func head(_ key: String) async throws -> SyncObjectHead? { try await run { try await inner.head(key) } }
    func delete(_ key: String) async throws { try await run { try await inner.delete(key) } }
}

/// Counts a round's steps and throws at a chosen one.
final class StepInterrupter: @unchecked Sendable {
    struct Interrupted: Error {}
    private let lock = NSLock()
    private var count = 0
    private var stopAt: Int?

    init(stopAt: Int?) { self.stopAt = stopAt }

    var steps: Int { lock.withLock { count } }

    func hook() -> @Sendable (SyncStep) async throws -> Void {
        { [self] _ in
            let stop = lock.withLock { () -> Bool in
                defer { count += 1 }
                return stopAt == count
            }
            if stop { throw Interrupted() }
        }
    }
}

// MARK: - Simulated devices

let simulationKey = try! BackupEncryptionKey(rawBytes: (0..<32).map { UInt8(255 - $0) })

/// One simulated iPad: its library, its engine directory, and a fresh engine after each "crash".
final class SimDevice: @unchecked Sendable {
    let name: String
    let id: UUID
    let library: FakeLibrary
    let directory: URL
    let faulting: FaultingStore
    let syncStore: EncryptedSyncStore
    let merger = TokenInkMerger()
    private(set) var engine: SyncEngine

    init(name: String, index: Int, inner: InMemorySyncObjectStore, root: URL) {
        self.name = name
        id = UUID(uuidString: String(format: "DE000000-0000-4000-8000-%012d", index))!
        let base = root.appendingPathComponent(name, isDirectory: true)
        library = FakeLibrary(pdfDirectory: base.appendingPathComponent("pdfs", isDirectory: true))
        directory = base.appendingPathComponent("sync", isDirectory: true)
        faulting = FaultingStore(inner)
        syncStore = EncryptedSyncStore(store: faulting, key: simulationKey,
                                       temporaryDirectory: base.appendingPathComponent("tmp", isDirectory: true))
        // Every simulated device's clock is the store's, so ages are deterministic.
        clock = { [inner] in inner.now }
        engine = SyncEngine(store: syncStore, library: library, inkMerger: merger, directory: directory,
                            device: .init(id: id, name: name), now: clock)
    }

    let clock: @Sendable () -> Date

    /// A crash: the engine's memory is gone; its directory, the library and the store remain.
    func restart() {
        engine = SyncEngine(store: syncStore, library: library, inkMerger: merger, directory: directory,
                            device: .init(id: id, name: name), now: clock)
    }

    func sync(_ mode: SyncMode = .full) async throws -> SyncReport {
        try await engine.sync(mode: mode, joinConfirmed: true)
    }

    func bookKey(_ pdf: ContentDigest) throws -> String { try syncStore.bookKey(pdfSHA256: pdf.sha256) }

    /// The library as sync carries it, by book key.
    func content() async throws -> [String: BookContent] {
        var result: [String: BookContent] = [:]
        for id in await library.bookIDs {
            guard let book = await library.book(id) else { continue }
            result[try bookKey(book.pdf)] = BookContent(book)
        }
        return result
    }
}

/// What sync carries of a book: records keyed to one ID in canonical order, the title and the
/// reading position, and the files.
struct BookContent: Hashable, CustomStringConvertible {
    var archive: BookArchive
    var files: [SyncFileKey: Data]

    static let contentID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

    init(_ book: FakeLibrary.Book) {
        var archive = BookMerge.canonicalOrder(BookMerge.rekeyed(book.archive, to: Self.contentID))
        archive.book = Book(id: Self.contentID, title: book.archive.book.title, fingerprint: "", fileName: "", pageCount: 0,
                            fileSize: 0, addedAt: Date(timeIntervalSince1970: 0), lastOpenedAt: book.archive.book.lastOpenedAt,
                            lastReadPageIndex: book.archive.book.lastReadPageIndex)
        self.archive = archive
        files = book.files
    }

    var description: String {
        let notes = archive.notes.map { "\($0.target): \($0.text.replacingOccurrences(of: "\n", with: " | ")) ink=\($0.hasInk)" }
        let files = files.keys.sorted().map { "\($0): \(TokenInk.decode(self.files[$0]).sorted())" }
        return "title \(archive.book.title) page \(archive.book.lastReadPageIndex)\n  notes \(notes)\n  highlights \(archive.highlights.count) bookmarks \(archive.bookmarks.map(\.pageIndex)) headings \(archive.userHeadings.map(\.title))\n  files \(files)"
    }
}

/// Several iPads sharing one account.
final class SimWorld: @unchecked Sendable {
    let root: TemporaryDirectory
    let inner: InMemorySyncObjectStore
    let devices: [SimDevice]

    init(deviceCount: Int) throws {
        let root = try TemporaryDirectory()
        let inner = InMemorySyncObjectStore()
        self.root = root
        self.inner = inner
        devices = (0..<deviceCount).map { SimDevice(name: "iPad\($0)", index: $0, inner: inner, root: root.url) }
    }

    /// The account's objects and every device's library and engine directory.
    struct Checkpoint {
        var objects: [String: InMemorySyncObjectStore.StoredObject]
        var libraries: [FakeLibrary.State]
        var directory: URL
        /// The store's clock.
        var now: Date
    }

    func checkpoint() async throws -> Checkpoint {
        var objects: [String: InMemorySyncObjectStore.StoredObject] = [:]
        for key in inner.keys { objects[key] = inner.object(key) }
        var libraries: [FakeLibrary.State] = []
        for device in devices { libraries.append(await device.library.state) }
        let saved = root.url.appendingPathComponent("checkpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        for device in devices where FileManager.default.fileExists(atPath: device.directory.path) {
            try FileManager.default.copyItem(at: device.directory, to: saved.appendingPathComponent(device.name))
        }
        return Checkpoint(objects: objects, libraries: libraries, directory: saved, now: inner.now)
    }

    func restore(_ checkpoint: Checkpoint) async throws {
        for key in inner.keys { inner.removeObject(key) }
        for (key, object) in checkpoint.objects {
            inner.setObject(object.data, at: key, metadata: object.metadata, lastModified: object.lastModified)
        }
        inner.now = checkpoint.now
        inner.clearCalls()
        for (device, state) in zip(devices, checkpoint.libraries) {
            await device.library.restore(state)
            device.faulting.reset()
            try? FileManager.default.removeItem(at: device.directory)
            let saved = checkpoint.directory.appendingPathComponent(device.name)
            if FileManager.default.fileExists(atPath: saved.path) {
                try FileManager.default.copyItem(at: saved, to: device.directory)
            }
            device.restart()
        }
    }

    /// Syncs every device, in an order from `rng`, until a whole pass changes nothing; then
    /// checks that all libraries are equal, valid and free of repeated paragraphs, and that one
    /// more round on each reads but writes nothing.
    func settle<G: RandomNumberGenerator>(_ rng: inout G, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await withClearBusy()
        var quiet = false
        for _ in 0..<10 where !quiet {
            quiet = true
            for device in devices.shuffled(using: &rng) {
                let report = try await device.sync()
                for failure in report.failures {
                    Issue.record("\(comment): \(device.name) failed \(failure.failure!.description)", sourceLocation: sourceLocation)
                }
                if report.changedAnything || report.isPending { quiet = false }
            }
        }
        #expect(quiet, "\(comment): never went quiet", sourceLocation: sourceLocation)
        try await expectEqualAndValid(comment, sourceLocation: sourceLocation)

        inner.clearCalls()
        for device in devices {
            let report = try await device.sync()
            #expect(!report.changedAnything && !report.isPending, "\(comment): \(device.name) not quiet", sourceLocation: sourceLocation)
        }
        let writes = inner.calls.filter { [.put, .upload, .delete].contains($0.operation) }
        #expect(writes.isEmpty, "\(comment): a settled round wrote \(writes.map(\.key))", sourceLocation: sourceLocation)
    }

    func withClearBusy() async {
        for device in devices { await device.library.clearBusy() }
    }

    func expectEqualAndValid(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let first = try await devices[0].content()
        for device in devices {
            let content = try await device.content()
            if content != first {
                let keys = Set(content.keys).union(first.keys).filter { content[$0] != first[$0] }
                let detail = keys.sorted().map { "\($0.prefix(8)):\n \(devices[0].name): \(first[$0].map(\.description) ?? "absent")\n \(device.name): \(content[$0].map(\.description) ?? "absent")" }
                Issue.record("\(comment): \(device.name) differs from \(devices[0].name)\n\(detail.joined(separator: "\n"))",
                             sourceLocation: sourceLocation)
            }
            let problems = await device.library.problems
            #expect(problems.isEmpty, "\(comment): \(device.name) \(problems)", sourceLocation: sourceLocation)
            for id in await device.library.bookIDs {
                guard let book = await device.library.book(id) else { continue }
                expectValid(book.archive, "\(comment): \(device.name)", sourceLocation: sourceLocation)
            }
        }
    }
}

/// Records pass `validateForReplacement()` and no note repeats a paragraph (every paragraph the
/// tests write is unique, so a repeat is one the merge made).
func expectValid(_ archive: BookArchive, _ comment: String, sourceLocation: SourceLocation = #_sourceLocation) {
    do { try archive.validateForReplacement() } catch { Issue.record("\(comment): \(error)", sourceLocation: sourceLocation) }
    for note in archive.notes {
        let paragraphs = NoteBandLayout.paragraphs(of: note.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if Set(paragraphs).count != paragraphs.count {
            Issue.record("\(comment): a note repeats a paragraph: \(paragraphs)", sourceLocation: sourceLocation)
        }
    }
}

// MARK: - Random edits

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let simulationEpoch = Date(timeIntervalSinceReferenceDate: 790_000_000)
let pdfChapter = HeadingAnchor(pdfPath: [2], pageIndex: 6, title: "3 Results")

/// Seeded edits as a reader makes them, every paragraph and stroke unique.
struct Editor {
    var rng: SeededGenerator
    var clock: Double = 0
    var counter = 0

    init(seed: UInt64) { rng = SeededGenerator(state: seed) }

    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func tick() -> Date { clock += Double(int(1...3)); return simulationEpoch.addingTimeInterval(clock) }
    mutating func token(_ prefix: String) -> String { counter += 1; return "\(prefix)\(counter)" }
    mutating func id() -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for k in 0..<16 { bytes[k] = UInt8.random(in: 0...255, using: &rng) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The PDFs devices import; a PDF imported on two devices is one book.
    static let pdfs: [Data] = (0..<6).map { Data("%PDF-1.7 simulated book \($0)\n%%EOF\n".utf8) }

    mutating func text() -> String {
        (0..<int(1...3)).map { _ in token("p") }.joined(separator: "\n")
    }

    mutating func edit(_ text: String) -> String {
        var paragraphs = NoteBandLayout.paragraphs(of: text)
        for _ in 0..<int(1...2) {
            switch int(0...3) {
            case 0: paragraphs.insert(token("p"), at: int(0...paragraphs.count))
            case 1: let k = int(0...paragraphs.count - 1); paragraphs[k] += " " + token("e")
            case 2: if paragraphs.count > 1 { paragraphs.remove(at: int(0...paragraphs.count - 1)) }
            default: paragraphs.append(token("p"))
            }
        }
        return paragraphs.joined(separator: "\n")
    }

    func targets(_ archive: BookArchive) -> [NoteTarget] {
        (0..<5).map { NoteTarget.page($0) } + archive.userHeadings.map { .heading($0.anchor) } + [.heading(pdfChapter)]
    }

    mutating func highlight(_ bookID: UUID) -> Highlight {
        let line = CGFloat(int(0...2))
        return Highlight(id: id(), bookID: bookID, pageIndex: int(0...4),
                         rects: [CGRect(x: 72, y: 700 - line * 14, width: 100 + line * 20, height: 12)],
                         color: HighlightColor.allCases[int(0...3)], text: ["matrix", "rank", "kernel"][Int(line)],
                         createdAt: tick())
    }

    mutating func heading(_ bookID: UUID, among existing: [UserHeading]) -> UserHeading {
        let parent: HeadingAnchor? = !existing.isEmpty && chance(0.3)
            ? existing[int(0...existing.count - 1)].anchor : (chance(0.5) ? pdfChapter : nil)
        return UserHeading(id: id(), bookID: bookID, title: ["Aside", "Proof", "Recap"][int(0...2)], pageIndex: int(0...4),
                           parent: parent, createdAt: tick())
    }

    /// A new book from PDF `index`, with a few records and files.
    mutating func newBook(pdf index: Int, prefix: String) -> (BookArchive, [SyncFileKey: Data]) {
        let id = id()
        let book = Book(id: id, title: "Book \(index)", fingerprint: "fp-\(index)", fileName: "\(index).pdf", pageCount: 10,
                        fileSize: 100, addedAt: tick(), lastOpenedAt: nil, lastReadPageIndex: 0)
        var book_ = (BookArchive(book: book), [SyncFileKey: Data]())
        for _ in 0..<int(0...2) { mutate(&book_.0, &book_.1, prefix: prefix) }
        return book_
    }

    /// One round of a reader's edits to a book (records and ink), offline.
    mutating func mutate(_ archive: inout BookArchive, _ files: inout [SyncFileKey: Data], prefix: String) {
        let bookID = archive.book.id
        // Headings: delete, rename, add.
        if !archive.userHeadings.isEmpty && chance(0.1) { archive.userHeadings.remove(at: int(0...archive.userHeadings.count - 1)) }
        for k in archive.userHeadings.indices where chance(0.1) {
            archive.userHeadings[k].title = ["Aside", "Proof", "Recap", "Summary"][int(0...3)]
        }
        if chance(0.3) { archive.userHeadings.append(heading(bookID, among: archive.userHeadings)) }

        // Notes: delete, edit text or ink, add.
        for note in archive.notes where chance(0.08) {
            archive.notes.removeAll { $0.id == note.id }
            files[.noteInk(note.id)] = nil
        }
        for k in archive.notes.indices where chance(0.35) {
            let id = archive.notes[k].id
            if chance(0.7) { archive.notes[k].text = edit(archive.notes[k].text) }
            if chance(0.4) {
                var tokens = TokenInk.decode(files[.noteInk(id)])
                if !tokens.isEmpty && chance(0.4) { tokens.remove(tokens.sorted()[int(0...tokens.count - 1)]) }
                else { tokens.insert(token("\(prefix)n")) }
                files[.noteInk(id)] = TokenInk.encode(tokens)
            }
            let inked = files[.noteInk(id)] != nil
            archive.notes[k].hasInk = inked
            archive.notes[k].bandLayout = inked ? testLayout : nil
            archive.notes[k].modifiedAt = tick()
        }
        archive.notes.removeAll(where: \.isEmpty)
        var taken = Set(archive.notes.map(\.target))
        for target in targets(archive) where !taken.contains(target) && chance(0.1) {
            let created = tick()
            var note = Note(id: id(), bookID: bookID, target: target, text: text(), createdAt: created, modifiedAt: created)
            if chance(0.3) {
                files[.noteInk(note.id)] = TokenInk.encode([token("\(prefix)n")])
                note.hasInk = true
                note.bandLayout = testLayout
            }
            archive.notes.append(note)
            taken.insert(target)
        }

        // Highlights: delete, recolour, add.
        archive.highlights.removeAll { _ in chance(0.08) }
        for k in archive.highlights.indices where chance(0.15) { archive.highlights[k].color = HighlightColor.allCases[int(0...3)] }
        if chance(0.4) {
            let new = highlight(bookID)
            if !archive.highlights.contains(where: { BookMerge.isDuplicate($0, new) }) { archive.highlights.append(new) }
        }

        // Bookmarks.
        for page in 0..<5 where chance(0.08) {
            if let index = archive.bookmarks.firstIndex(where: { $0.pageIndex == page }) {
                archive.bookmarks.remove(at: index)
            } else {
                archive.bookmarks.append(Bookmark(id: id(), bookID: bookID, pageIndex: page, createdAt: tick()))
            }
        }

        // Page ink: draw and erase strokes.
        for page in 0..<4 where chance(0.15) {
            var tokens = TokenInk.decode(files[.pageInk(page)])
            if !tokens.isEmpty && chance(0.4) { tokens.remove(tokens.sorted()[int(0...tokens.count - 1)]) }
            else { tokens.insert(token("\(prefix)s")) }
            files[.pageInk(page)] = TokenInk.encode(tokens)
        }

        // The book: rename, read on, a cover now and then.
        if chance(0.08) { archive.book.title = ["Linear Algebra", "LA", "Strang"][int(0...2)] }
        if chance(0.3) {
            archive.book.lastReadPageIndex = int(0...9)
            archive.book.lastOpenedAt = tick()
        }
        if chance(0.03) { files[.cover] = Data(token("cover").utf8) }
    }

    /// Random offline work on one device: edit some books, now and then import or delete one.
    mutating func work(on device: SimDevice) async throws {
        let library = device.library
        let ids = await library.bookIDs
        for id in ids where chance(0.5) {
            guard var book = await library.book(id) else { continue }
            mutate(&book.archive, &book.files, prefix: device.name)
            await library.put(id, book)
        }
        if !ids.isEmpty && chance(0.04) {
            await library.remove(ids[int(0...ids.count - 1)])
        }
        if chance(0.12) {
            let index = int(0...Self.pdfs.count - 1)
            let pdf = ContentDigest(of: Self.pdfs[index])
            var have = false
            for id in await library.bookIDs where await library.book(id)?.pdf == pdf { have = true }
            if !have {
                let (archive, files) = newBook(pdf: index, prefix: device.name)
                try await library.importBook(archive, pdf: Self.pdfs[index], files: files)
            }
        }
    }

    /// Marks a random note or page of a random book busy, and edits it while it is busy.
    mutating func busy(on device: SimDevice) async {
        let library = device.library
        let ids = await library.bookIDs
        guard !ids.isEmpty, var book = await library.book(ids[int(0...ids.count - 1)]) else { return }
        let id = book.archive.book.id
        if !book.archive.notes.isEmpty && chance(0.6) {
            let k = int(0...book.archive.notes.count - 1)
            book.archive.notes[k].text = edit(book.archive.notes[k].text)
            book.archive.notes[k].modifiedAt = tick()
            await library.put(id, book)
            await library.setBusy(id, [.note(book.archive.notes[k].id)])
        } else {
            let page = int(0...3)
            var tokens = TokenInk.decode(book.files[.pageInk(page)])
            tokens.insert(token("\(device.name)b"))
            book.files[.pageInk(page)] = TokenInk.encode(tokens)
            await library.put(id, book)
            await library.setBusy(id, [.page(page)])
        }
    }
}
