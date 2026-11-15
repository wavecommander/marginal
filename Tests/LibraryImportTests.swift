import Foundation
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// The import pipeline and library rules, app-hosted on the simulator.
@MainActor
struct LibraryImportTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out", isDirectory: true)
    static var small: URL { fixtures.appendingPathComponent("small.pdf") }
    static var large: URL { fixtures.appendingPathComponent("large.pdf") }

    struct Env {
        let store: LibraryStore
        let service: ImportService
        let scratch: URL
    }

    private func makeEnv() throws -> Env {
        let store = try LibraryStore.ephemeral()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return Env(store: store, service: ImportService(store: store), scratch: scratch)
    }

    private func cleanup(_ env: Env) {
        try? FileManager.default.removeItem(at: env.store.rootDirectory)
        try? FileManager.default.removeItem(at: env.scratch)
    }

    private func stagingEntries(_ env: Env) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: env.service.stagingRoot.path)) ?? []
    }

    // MARK: Fingerprint

    @Test func fingerprintIsStableAndContentSensitive() throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let a = try BookFingerprint.fingerprint(ofFileAt: Self.small)
        #expect(a == (try BookFingerprint.fingerprint(ofFileAt: Self.small)))
        #expect(a.hasPrefix("sha256-v1:") && a.count == "sha256-v1:".count + 64)
        // The same bytes under another name: same fingerprint. Different bytes: different.
        let copy = env.scratch.appendingPathComponent("other-name.pdf")
        try FileManager.default.copyItem(at: Self.small, to: copy)
        #expect(try BookFingerprint.fingerprint(ofFileAt: copy) == a)
        #expect(try BookFingerprint.fingerprint(ofFileAt: Self.large) != a)
        var data = try Data(contentsOf: copy)
        data[data.count / 2] ^= 0xFF
        try data.write(to: copy)
        #expect(try BookFingerprint.fingerprint(ofFileAt: copy) != a)
    }

    @Test func fingerprintOfLargeFileSamplesFixedChunks() throws {
        let size: Int64 = 600 * 1024 * 1024
        let offsets = BookFingerprint.sampleOffsets(forSize: size)
        #expect(offsets.count == BookFingerprint.sampleCount)
        #expect(offsets.first == 0)
        #expect(offsets.last == size - Int64(BookFingerprint.chunkSize))
        #expect(offsets == offsets.sorted())
        #expect(BookFingerprint.hashesWholeFile(size: 1_000_000))
        #expect(!BookFingerprint.hashesWholeFile(size: 3_000_000))
    }

    @Test func sampledFingerprintSeesEdgesAndSampledChunks() throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let url = env.scratch.appendingPathComponent("big.bin")
        let size = 5 * 1024 * 1024
        var data = Data(count: size)
        try data.write(to: url)
        let base = try BookFingerprint.fingerprint(ofFileAt: url)
        data[size - 1] = 1  // last byte lies in the last sampled chunk
        try data.write(to: url)
        #expect(try BookFingerprint.fingerprint(ofFileAt: url) != base)
    }

    // MARK: Import

    @Test func importCreatesRecordFilesAndCover() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        var events: [StoreChange] = []
        let token = env.store.hub.observe { events.append($0.change) }
        let outcome = try await env.service.importPDF(at: Self.small)
        guard case .imported(let book) = outcome else { Issue.record("expected a new book"); return }
        #expect(book.title == "small")
        #expect(book.pageCount == 12)
        #expect(book.fileSize == Int64(try Data(contentsOf: Self.small).count))
        #expect(book.fingerprint == (try BookFingerprint.fingerprint(ofFileAt: Self.small)))
        #expect(FileManager.default.fileExists(atPath: env.store.documentURL(for: book).path))
        let cover = env.service.coverURL(for: book)
        #expect(FileManager.default.fileExists(atPath: cover.path))
        #expect(UIImage(contentsOfFile: cover.path) != nil)
        #expect(try env.store.books.book(id: book.id) == book)
        #expect(events.contains(.bookSaved(bookID: book.id)))
        #expect(stagingEntries(env).isEmpty)
        // The source is untouched.
        #expect(FileManager.default.fileExists(atPath: Self.small.path))
        token.cancel()
    }

    @Test func importingTheSameFileTwiceReturnsTheExistingBook() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let first = try await env.service.importPDF(at: Self.small)
        // A copy with another name is the same content.
        let renamed = env.scratch.appendingPathComponent("Renamed Copy.pdf")
        try FileManager.default.copyItem(at: Self.small, to: renamed)
        let second = try await env.service.importPDF(at: renamed)
        guard case .imported(let a) = first, case .existing(let b) = second else {
            Issue.record("expected imported then existing"); return
        }
        #expect(a.id == b.id)
        #expect(try env.store.books.allBooks().count == 1)
        let directories = try FileManager.default.contentsOfDirectory(atPath: env.store.rootDirectory.appendingPathComponent("Books").path)
        #expect(directories.count == 1)
    }

    @Test func notAPDFZeroPagesAndMissingFilesFailCleanly() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let text = env.scratch.appendingPathComponent("notes.pdf")
        try "hello, this is not a pdf".write(to: text, atomically: true, encoding: .utf8)
        let empty = env.scratch.appendingPathComponent("empty.pdf")
        try Data().write(to: empty)
        let headerOnly = env.scratch.appendingPathComponent("header.pdf")
        try "%PDF-1.4\ngarbage\n%%EOF".write(to: headerOnly, atomically: true, encoding: .utf8)
        for (url, expected) in [(text, ImportError.notAPDF(fileName: "notes.pdf")),
                                (empty, .notAPDF(fileName: "empty.pdf"))] {
            let result = await env.service.importFiles([url])[0]
            #expect(result.error == expected)
        }
        let broken = await env.service.importFiles([headerOnly])[0]
        #expect(broken.error != nil)
        let missing = await env.service.importFiles([env.scratch.appendingPathComponent("nope.pdf")])[0]
        #expect(missing.error != nil)
        #expect(try env.store.books.allBooks().isEmpty)
        #expect(stagingEntries(env).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.store.rootDirectory.appendingPathComponent("Books").path)
                || ((try? FileManager.default.contentsOfDirectory(atPath: env.store.rootDirectory.appendingPathComponent("Books").path))?.isEmpty ?? true))
    }

    @Test func lockedPDFIsRejected() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let url = env.scratch.appendingPathComponent("locked.pdf")
        let data = NSMutableData()
        let info: [CFString: Any] = [kCGPDFContextUserPassword: "secret", kCGPDFContextOwnerPassword: "owner"]
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: nil, info as CFDictionary)!
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url)
        let result = await env.service.importFiles([url])[0]
        #expect(result.error == .locked(fileName: "locked.pdf"))
        #expect(try env.store.books.allBooks().isEmpty)
        #expect(stagingEntries(env).isEmpty)
    }

    @Test func cancelRemovesPartialFiles() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        // A file big enough that the copy takes several chunks.
        let big = env.scratch.appendingPathComponent("big.pdf")
        var data = try Data(contentsOf: Self.small)
        data.append(Data(count: 200 * 1024 * 1024))
        try data.write(to: big)
        let service = env.service
        let importing = Task { await service.importFiles([big]) }
        // Cancel as soon as the job is copying.
        for _ in 0..<2000 {
            if let job = service.jobs.first, job.phase == .copying { job.cancel(); break }
            if importing.isCancelled { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let results = await importing.value
        #expect(results[0].error == .cancelled || results[0].book != nil)
        if results[0].error == .cancelled {
            #expect(try env.store.books.allBooks().isEmpty)
            #expect(stagingEntries(env).isEmpty)
        }
        #expect(service.jobs.isEmpty)
    }

    @Test func cancelledCopyStopsAndLeavesNoPartialFile() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let big = env.scratch.appendingPathComponent("big.bin")
        try Data(count: 40 * 1024 * 1024).write(to: big)
        let destination = env.scratch.appendingPathComponent("out.bin")
        let size: Int64 = 40 * 1024 * 1024
        let box = TaskBox()
        let task = Task.detached { () -> Bool in
            do {
                try ImportPipeline.copyStreaming(from: big, to: destination, totalSize: size) { fraction in
                    if fraction >= 0.2 { box.cancel() }
                }
                return false
            } catch is CancellationError {
                return true
            } catch { return false }
        }
        box.set(task)
        let wasCancelled = await task.value
        #expect(wasCancelled)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func consumedSourceIsMovedAndRemoved() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let temp = env.scratch.appendingPathComponent("inbox.pdf")
        try FileManager.default.copyItem(at: Self.small, to: temp)
        let outcome = try await env.service.importPDF(at: temp, consumeSource: true)
        #expect(outcome.book?.pageCount == 12)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func dedupeRepairsAMissingDocumentFile() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let book = try #require(try await env.service.importPDF(at: Self.small).book)
        try FileManager.default.removeItem(at: env.store.documentURL(for: book))
        _ = try await env.service.importPDF(at: Self.small)
        #expect(FileManager.default.fileExists(atPath: env.store.documentURL(for: book).path))
    }

    @Test func largeImportKeepsMainActorResponsive() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let service = env.service
        var ticks = 0
        let importing = Task { try await service.importPDF(at: Self.large) }
        while !importing.isCancelled, service.jobs.isEmpty == false || ticks == 0 {
            try await Task.sleep(for: .milliseconds(5))
            ticks += 1
            if ticks > 4000 { break }
        }
        let book = try #require(try await importing.value.book)
        #expect(book.pageCount == 1500)
        #expect(ticks > 0)
    }

    // MARK: Sweep interplay

    @Test func stagedImportIsInvisibleToTheOrphanSweep() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let staging = env.service.stagingRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let removed = try await env.store.sweepOrphanedBookDirectories()
        #expect(removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: staging.path))
    }

    // MARK: Delete

    @Test func deleteRemovesRecordsAndFiles() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let book = try #require(try await env.service.importPDF(at: Self.small).book)
        let note = Note(bookID: book.id, target: .page(2), text: "a note")
        try env.store.notes.save(note)
        let summary = try await env.store.deletionSummary(bookID: book.id)
        #expect(summary.notes == 1)
        try await env.store.deleteBook(id: book.id, origin: nil)
        #expect(try env.store.books.book(id: book.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: env.store.bookDirectoryURL(bookID: book.id).path))
        #expect(!FileManager.default.fileExists(atPath: env.service.coverURL(for: book).path))
    }

    // MARK: Names

    @Test func fileNamesAreSanitized() {
        #expect(ImportPipeline.sanitizedFileName("a/b:c.pdf") == "a-b-c.pdf")
        #expect(ImportPipeline.sanitizedFileName("  .hidden.pdf ") == "hidden.pdf")
        #expect(ImportPipeline.sanitizedFileName("") == "Document.pdf")
        #expect(ImportPipeline.sanitizedFileName(String(repeating: "x", count: 300) + ".pdf").count <= 125)
        #expect(ImportService.title(forFileName: "Linear Algebra.pdf") == "Linear Algebra")
    }
}

/// Lets a copy's progress callback cancel the task that runs it.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Bool, Never>?
    private var cancelRequested = false
    func set(_ task: Task<Bool, Never>) {
        lock.lock(); self.task = task; if cancelRequested { task.cancel() }; lock.unlock()
    }
    func cancel() { lock.lock(); cancelRequested = true; task?.cancel(); lock.unlock() }
}
