import Foundation
import PDFKit
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import Marginal

/// The import flow for files that are converted to PDF (F3): preflight, the conversion request
/// behind the Convert to PDF sheet, Convert and Cancel, and what ends up on disk. Uses
/// `StubDocumentConverter`; the fixtures are `Tests/Fixtures/f3-*`.
@MainActor
@Suite(.serialized)
struct ConversionImportTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static var smallPDF: URL { repo.appendingPathComponent("Fixtures/out/small.pdf") }
    static var epub: URL { repo.appendingPathComponent("Tests/Fixtures/f3-small.epub") }
    static var protectedEPUB: URL { repo.appendingPathComponent("Tests/Fixtures/f3-protected.epub") }
    static var markdown: URL { repo.appendingPathComponent("Tests/Fixtures/f3-notes.md") }

    static let convertedFormats = Set(ImportFormat.allCases.filter(\.isConverted))
    static func stubs(_ stub: StubDocumentConverter = StubDocumentConverter()) -> ConverterRegistry {
        var stub = stub
        stub.formats = convertedFormats
        return ConverterRegistry([stub])
    }

    @MainActor struct Env {
        let store: LibraryStore
        let service: ImportService
        let scratch: URL
        var books: URL { store.rootDirectory.appendingPathComponent("Books", isDirectory: true) }
    }

    private func makeEnv(_ converters: ConverterRegistry = stubs()) throws -> Env {
        let store = try LibraryStore.ephemeral()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ConversionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return Env(store: store, service: ImportService(store: store, converters: converters), scratch: scratch)
    }

    private func cleanup(_ env: Env) {
        try? FileManager.default.removeItem(at: env.store.rootDirectory)
        try? FileManager.default.removeItem(at: env.scratch)
    }

    /// Every path under the store's root with its size (directories as "-1").
    private func tree(_ env: Env) -> [String: Int64] {
        var result: [String: Int64] = [:]
        let root = env.store.rootDirectory.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(at: env.store.rootDirectory,
                                                              includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])
        else { return result }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(root.count))
            result[path] = values?.isDirectory == true ? -1 : Int64(values?.fileSize ?? 0)
        }
        return result
    }

    private func entries(of directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private func copy(_ source: URL, to directory: URL, as name: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name ?? source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Fixtures

    @Test func fixturesAreDetectedAsExpected() throws {
        #expect(try ImportFormatDetector.detect(fileAt: Self.epub) == .supported(.epub))
        #expect(try ImportFormatDetector.detect(fileAt: Self.protectedEPUB) == .unsupported(.protectedEPUB))
        #expect(try ImportFormatDetector.detect(fileAt: Self.markdown) == .supported(.markdown))
        #expect(try ImportFormatDetector.detect(fileAt: Self.smallPDF) == .supported(.pdf))
    }

    // MARK: Done when: the sheet, and nothing on disk until Convert

    @Test func anEPUBWaitsForTheSheetAndNothingIsWrittenUnderBooks() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let context = WindowContext(kind: .library)
        let other = WindowContext(kind: .library)
        let window = ObjectIdentifier(context)
        let results = await env.service.importFiles([Self.epub], requester: window)
        let requestID = try #require(results[0].conversionRequestID)
        let request = try #require(env.service.conversionRequest(for: window))
        #expect(request.id == requestID)
        #expect(request.items.map(\.fileName) == ["f3-small.epub"])
        #expect(request.items.map(\.format) == [.epub])
        #expect(request.groups == [.epub])
        #expect(request.offersTextSizeChoice)
        #expect(request.rejected.isEmpty)
        #expect(request.items[0].probe.fingerprint == (try BookFingerprint.fingerprint(ofFileAt: Self.epub)))
        // Nothing in the Library, nothing under Books/ or in staging, no job left.
        #expect(try env.store.books.allBooks().isEmpty)
        #expect(entries(of: env.books).isEmpty)
        #expect(entries(of: env.service.stagingRoot).isEmpty)
        #expect(env.service.jobs.isEmpty)
        // A request for another window is not this window's.
        #expect(env.service.conversionRequest(for: ObjectIdentifier(other)) == nil)
        withExtendedLifetime((context, other)) {}
    }

    @Test func comicsAndDocumentsHaveNoTextSizeChoice() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let window = ObjectIdentifier(env.service)
        let png = env.scratch.appendingPathComponent("page.png")
        try #require(UIImage(systemName: "star")?.pngData()).write(to: png)
        _ = await env.service.importFiles([png], requester: window)
        let request = try #require(env.service.conversionRequest(for: window))
        #expect(request.groups == [.comicsAndImages])
        #expect(!request.offersTextSizeChoice)
    }

    // MARK: Done when: Cancel leaves everything as it was

    @Test func cancelLeavesTheLibraryAndTheDiskAsTheyWere() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        // A Library with one book in it.
        _ = try await env.service.importPDF(at: Self.smallPDF)
        let picked = try copy(Self.epub, to: env.scratch)
        let before = tree(env)
        let booksBefore = try env.store.books.allBooks()

        let window = ObjectIdentifier(env.service)
        _ = await env.service.importFiles([picked], requester: window)
        let request = try #require(env.service.conversionRequest(for: window))
        await env.service.discard(request.id)

        #expect(env.service.conversionRequests.isEmpty)
        #expect(try env.store.books.allBooks() == booksBefore)
        #expect(tree(env) == before)
        // A picked file is the reader's: it is left alone.
        #expect(FileManager.default.fileExists(atPath: picked.path))
    }

    @Test func cancelDeletesAdoptedFiles() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let before = tree(env)
        // A drop lands in Imports/drop-…/; "Open in" in Documents/Inbox/.
        let dropped = try ImportPipeline.adoptDroppedFile(try copy(Self.epub, to: env.scratch.appendingPathComponent("tmp")),
                                                          suggestedName: "Dropped.epub", into: env.service.stagingRoot)
        let inbox = try copy(Self.epub, to: env.scratch.appendingPathComponent("Inbox"), as: "Inbox Copy.epub")
        let window = ObjectIdentifier(env.service)
        _ = await env.service.importFiles([dropped], consumeSources: true, requester: window)
        let first = try #require(env.service.conversionRequest(for: window))
        await env.service.discard(first.id)
        _ = await env.service.importFiles([inbox], consumeSources: true, requester: window)
        let second = try #require(env.service.conversionRequest(for: window))
        await env.service.discard(second.id)

        #expect(!FileManager.default.fileExists(atPath: dropped.path))
        #expect(!FileManager.default.fileExists(atPath: dropped.deletingLastPathComponent().path))
        #expect(!FileManager.default.fileExists(atPath: inbox.path))
        #expect(try env.store.books.allBooks().isEmpty)
        // Only the (now empty) drop landing area is left.
        #expect(tree(env).filter { $0.key != "/Imports" } == before)
        #expect(entries(of: env.service.stagingRoot).isEmpty)
    }

    // MARK: Done when: PDFs never wait for the sheet

    @Test func aPDFInTheSameBatchIsImportedWithoutWaitingForTheSheet() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let window = ObjectIdentifier(env.service)
        // `importFiles` returns while the request is still unanswered.
        let results = await env.service.importFiles([Self.smallPDF, Self.epub], requester: window)
        guard case .success(.imported(let book)) = results[0].result else {
            Issue.record("the PDF was not imported: \(results[0].result)"); return
        }
        #expect(book.pageCount == 12)
        #expect(book.sourceFormat == nil && book.originalFileName == nil && book.converterVersion == nil)
        #expect(results[1].conversionRequestID != nil)
        #expect(env.service.conversionRequest(for: window)?.items.map(\.fileName) == ["f3-small.epub"])
        #expect(try env.store.books.allBooks().map(\.id) == [book.id])
        #expect(entries(of: env.books) == [book.id.uuidString])
    }

    // MARK: Done when: a protected EPUB is listed as not importable

    @Test func aProtectedEPUBIsListedInTheSheet() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let window = ObjectIdentifier(env.service)
        let results = await env.service.importFiles([Self.epub, Self.protectedEPUB], requester: window)
        let request = try #require(env.service.conversionRequest(for: window))
        #expect(request.items.map(\.fileName) == ["f3-small.epub"])
        #expect(request.rejected.map(\.error) == [.protected(fileName: "f3-protected.epub")])
        #expect(request.rejected.map(\.fileName) == ["f3-protected.epub"])
        #expect(results[1].error == .protected(fileName: "f3-protected.epub"))
        #expect(results[1].isListedInSheet)
        #expect(results[1].alertError == nil)  // no alert on top of the sheet
    }

    @Test func aBatchWithNothingToConvertShowsAlertsNotASheet() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let window = ObjectIdentifier(env.service)
        let mobi = env.scratch.appendingPathComponent("Book.mobi")
        var data = Data(count: 60)
        data.append(Data("BOOKMOBI".utf8))
        data.append(Data(count: 200))
        try data.write(to: mobi)
        let results = await env.service.importFiles([Self.protectedEPUB, mobi], requester: window)
        #expect(env.service.conversionRequests.isEmpty)
        #expect(results.map(\.alertError) == [.protected(fileName: "f3-protected.epub"),
                                              .unsupportedFormat(fileName: "Book.mobi", kind: .kindle)])
        #expect(entries(of: env.service.stagingRoot).isEmpty)
    }

    @Test func aFormatWithNoConverterCannotBeImported() async throws {
        let env = try makeEnv(ConverterRegistry()); defer { cleanup(env) }
        let results = await env.service.importFiles([Self.epub], requester: ObjectIdentifier(env.service))
        #expect(results[0].alertError == .unsupportedFormat(fileName: "f3-small.epub", kind: nil))
        #expect(env.service.conversionRequests.isEmpty)
    }

    // MARK: Done when: a drop and an "Open in" show the same sheet

    @Test func aDropAndAnOpenInMakeTheSameRequest() async throws {
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        var options = LaunchOptions()
        options.stubConverters = true
        let environment = AppEnvironment(store: store, launchOptions: options)
        let service = await environment.readyImportService()
        let window = WindowContext(kind: .library)
        let key = ObjectIdentifier(window)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ConversionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        // A drop: the item provider's file is adopted, then imported as the Library does.
        let provider = try #require(NSItemProvider(contentsOf: try copy(Self.epub, to: scratch.appendingPathComponent("drag"))))
        #expect(DropImport.acceptedProviders([provider]).count == 1)
        let adopted = await DropImport.adopt([provider], into: service.stagingRoot)
        #expect(adopted.count == 1)
        _ = await service.importFiles(adopted, consumeSources: true, requester: key)
        let dropped = try #require(service.conversionRequest(for: key))
        await service.discard(dropped.id)
        #expect(adopted.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        // "Open in": the system's Inbox copy, through the handler every window's `.onOpenURL` uses.
        let inbox = try copy(Self.epub, to: scratch.appendingPathComponent("Inbox"))
        window.path = [.reader(bookID: UUID())]
        IncomingDocumentHandler.handle(inbox, environment: environment, window: window)
        try await waitUntil { service.conversionRequest(for: key) != nil && window.path.isEmpty }
        let opened = try #require(service.conversionRequest(for: key))

        // The names come from different places (the drag's suggested name, the Inbox copy).
        #expect(opened.items.map(\.fileName) == ["f3-small.epub"])
        #expect(dropped.items.allSatisfy { $0.fileName.hasSuffix(".epub") }, "\(dropped.items.map(\.fileName))")
        #expect(opened.items.map(\.format) == dropped.items.map(\.format))
        #expect(opened.items.map(\.probe) == dropped.items.map(\.probe))
        #expect(opened.groups == dropped.groups)
        #expect(opened.offersTextSizeChoice == dropped.offersTextSizeChoice)
        #expect(opened.rejected == dropped.rejected)
        #expect(opened.items.allSatisfy(\.consumeSource) && dropped.items.allSatisfy(\.consumeSource))
        #expect(opened.opensBookWhenDone && !dropped.opensBookWhenDone)
        await service.discard(opened.id)
        #expect(!FileManager.default.fileExists(atPath: inbox.path))
    }

    // MARK: Done when: Convert makes the book, with the original and options beside it

    @Test func convertMakesABookWithTheOriginalAndOptionsBesideIt() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let window = ObjectIdentifier(env.service)
        _ = await env.service.importFiles([Self.epub], requester: window)
        let request = try #require(env.service.conversionRequest(for: window))
        var options = ConversionOptions()
        options.textSize = .large
        let results = await env.service.convert(request.id, options: options)
        #expect(env.service.conversionRequests.isEmpty)
        #expect(env.service.jobs.isEmpty)
        guard case .success(.imported(let book)) = results.first?.result else {
            Issue.record("expected a new book: \(String(describing: results.first?.result))"); return
        }
        #expect(book.sourceFormat == .epub)
        #expect(book.originalFileName == "f3-small.epub")
        #expect(book.converterVersion == 7)
        #expect(book.fingerprint == (try BookFingerprint.fingerprint(ofFileAt: Self.epub)))
        #expect(book.title == "Stub Title")
        #expect(book.fileName == "f3-small.pdf")
        #expect(book.pageCount == 3)
        #expect(try env.store.books.book(id: book.id) == book)

        let directory = env.store.bookDirectoryURL(bookID: book.id)
        let pdf = env.store.documentURL(for: book)
        let original = env.store.url(forRelativePath: BookStorageLayout.originalPath(bookID: book.id, extension: "epub"))
        let record = directory.appendingPathComponent(ImportPipeline.conversionRecordFileName)
        #expect(Set(entries(of: directory)) == ["f3-small.pdf", "original.epub", "cover.jpg", "conversion.json"])
        #expect(PDFDocument(url: pdf)?.pageCount == 3)
        #expect(try Data(contentsOf: original) == (try Data(contentsOf: Self.epub)))
        let stored = try JSONDecoder().decode(ConversionRecord.self, from: Data(contentsOf: record))
        #expect(stored.textSize == .large && stored.sourceFormat == .epub && stored.converterVersion == 7)
        // The book's size is the PDF plus the kept original.
        let pdfSize = Int64(try pdf.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let originalSize = Int64(try Data(contentsOf: Self.epub).count)
        #expect(book.fileSize == pdfSize + originalSize)
        #expect(entries(of: env.service.stagingRoot).isEmpty)
        // The source is untouched.
        #expect(FileManager.default.fileExists(atPath: Self.epub.path))

        // Importing the same EPUB again finds the book before any conversion.
        let again = await env.service.importFiles([Self.epub], requester: window)
        #expect(again[0].result == .success(.existing(book)))
        #expect(env.service.conversionRequests.isEmpty)

        // Deleting the book removes the PDF, the original and the options with it.
        try await env.store.deleteBook(id: book.id, origin: nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    @Test func aConverterWithoutATitleLeavesTheFileName() async throws {
        let env = try makeEnv(Self.stubs(StubDocumentConverter(title: nil))); defer { cleanup(env) }
        let book = try await env.service.importPDF(at: Self.markdown, convertWithoutAsking: ConversionOptions()).book
        #expect(book?.title == "f3-notes")
        #expect(book?.sourceFormat == .markdown)
        #expect(book?.fileName == "f3-notes.pdf")
    }

    @Test func confirmConversionsConvertsWithoutARequest() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let outcome = try await env.service.importPDF(at: Self.epub, convertWithoutAsking: ConversionOptions())
        guard case .imported(let book) = outcome else { Issue.record("expected a new book: \(outcome)"); return }
        #expect(env.service.conversionRequests.isEmpty)
        let record = try JSONDecoder().decode(ConversionRecord.self, from: Data(contentsOf:
            env.store.bookDirectoryURL(bookID: book.id).appendingPathComponent(ImportPipeline.conversionRecordFileName)))
        #expect(record.textSize == .medium)
    }

    @Test func aFixtureWaitsInAnUnaddressedRequestUntilAWindowTakesIt() async throws {
        let store = try LibraryStore.ephemeral()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let importer = FixtureImporter(service: ImportService(store: store, converters: Self.stubs()))
        let result = await importer.importFixture(at: Self.epub, confirmConversions: false)
        let id = try #require(result.conversionRequestID)
        #expect(importer.service.conversionRequests.map(\.windowKey) == [nil])
        let context = WindowContext(kind: .library)
        let window = ObjectIdentifier(context)
        importer.service.address([id], to: window)
        #expect(importer.service.conversionRequest(for: window)?.id == id)
        withExtendedLifetime(context) {}
        let confirmed = await importer.importFixture(at: Self.markdown, confirmConversions: true)
        #expect(confirmed.book?.sourceFormat == .markdown)
    }

    // MARK: Done when: cancelling mid-conversion leaves nothing behind

    @Test func cancelDuringConversionLeavesNothingBehind() async throws {
        let env = try makeEnv(Self.stubs(StubDocumentConverter(pageCount: 200, pageDelay: .milliseconds(20))))
        defer { cleanup(env) }
        let window = ObjectIdentifier(env.service)
        let dropped = try ImportPipeline.adoptDroppedFile(try copy(Self.epub, to: env.scratch.appendingPathComponent("tmp")),
                                                          suggestedName: nil, into: env.service.stagingRoot)
        _ = await env.service.importFiles([dropped], consumeSources: true, requester: window)
        let request = try #require(env.service.conversionRequest(for: window))
        let service = env.service
        let converting = Task { await service.convert(request.id, options: ConversionOptions()) }
        try await waitUntil {
            guard let job = service.jobs.first else { return false }
            return job.phase == .converting && job.fraction > 0
        }
        // Mid-conversion, a staging directory holds the original and the partial PDF.
        #expect(entries(of: env.service.stagingRoot).contains { UUID(uuidString: $0) != nil })
        service.jobs.first?.cancel()
        let results = await converting.value
        #expect(results.map(\.error) == [.cancelled])
        #expect(service.jobs.isEmpty)
        #expect(try env.store.books.allBooks().isEmpty)
        #expect(entries(of: env.books).isEmpty)
        #expect(entries(of: env.service.stagingRoot).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dropped.path))
    }

    // MARK: Conversion failures

    @Test func conversionErrorsBecomeImportErrorsAndLeaveNothing() async throws {
        let cases: [(ConversionError, ImportError)] = [
            (.protected, .protected(fileName: "f3-small.epub")),
            (.unsupported(reason: "fixed layout"), .unsupportedFormat(fileName: "f3-small.epub", kind: nil)),
            (.failed(reason: "bad chapter"), .conversionFailed(fileName: "f3-small.epub", reason: "bad chapter")),
        ]
        for (conversionError, expected) in cases {
            let env = try makeEnv(Self.stubs(StubDocumentConverter(failure: conversionError))); defer { cleanup(env) }
            let result = await env.service.importFiles([Self.epub], convertWithoutAsking: ConversionOptions())[0]
            #expect(result.error == expected)
            #expect(result.alertError == expected)
            #expect(try env.store.books.allBooks().isEmpty)
            #expect(entries(of: env.service.stagingRoot).isEmpty)
            #expect(entries(of: env.books).isEmpty)
        }
    }

    @Test func theStageChecksRunOnTheConvertersOutput() async throws {
        let cases: [(BadOutputConverter.Mode, ImportError)] = [
            (.garbage, .conversionFailed(fileName: "f3-small.epub", reason: "the converted PDF could not be opened")),
            (.elsewhere, .conversionFailed(fileName: "f3-small.epub", reason: "the PDF was not written to the staging directory")),
        ]
        for (mode, expected) in cases {
            let env = try makeEnv(ConverterRegistry([BadOutputConverter(mode: mode)])); defer { cleanup(env) }
            let result = await env.service.importFiles([Self.epub], convertWithoutAsking: ConversionOptions())[0]
            #expect(result.error == expected)
            #expect(try env.store.books.allBooks().isEmpty)
            #expect(entries(of: env.service.stagingRoot).isEmpty)
            #expect(entries(of: env.books).isEmpty)
        }
    }

    // MARK: Re-conversion

    @Test func aMissingConvertedPDFIsMadeAgainWithTheStoredTextSize() async throws {
        let log = TextSizeLog()
        let env = try makeEnv(ConverterRegistry([RecordingConverter(log: log)])); defer { cleanup(env) }
        var large = ConversionOptions()
        large.textSize = .large
        let book = try #require(try await env.service.importPDF(at: Self.epub, convertWithoutAsking: large).book)
        let pdf = env.store.documentURL(for: book)
        let original = env.store.url(forRelativePath: BookStorageLayout.originalPath(bookID: book.id, extension: "epub"))
        try FileManager.default.removeItem(at: pdf)
        try FileManager.default.removeItem(at: original)

        let again = await env.service.importFiles([Self.epub], requester: ObjectIdentifier(env.service))
        #expect(again[0].result == .success(.existing(book)))
        #expect(env.service.conversionRequests.isEmpty)
        #expect(PDFDocument(url: pdf)?.pageCount == 3)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(log.values == [.large, .large])
        #expect(entries(of: env.service.stagingRoot).isEmpty)
    }

    // MARK: Detection is the single source of truth

    @Test func aZIPWithAPDFHeaderInItsFirstKiBIsNotImportedAsAPDF() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let url = env.scratch.appendingPathComponent("zipped.pdf")
        var data = Data([0x50, 0x4B, 0x03, 0x04])
        data.append(try Data(contentsOf: Self.smallPDF))
        try data.write(to: url)
        let result = await env.service.importFiles([url])[0]
        #expect(result.error == .notAPDF(fileName: "zipped.pdf"))
        #expect(try env.store.books.allBooks().isEmpty)
    }

    @Test func aPDFWithLeadingJunkIsStillAPDF() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let url = env.scratch.appendingPathComponent("junk-first.pdf")
        var data = Data(repeating: 0x20, count: 100)
        data.append(try Data(contentsOf: Self.smallPDF))
        try data.write(to: url)
        let outcome = try await env.service.importPDF(at: url)
        #expect(outcome.book?.pageCount == 12)
        #expect(outcome.book?.sourceFormat == nil)
    }

    // MARK: Drops

    @Test func aNamelessDropGetsItsTypesExtension() throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let temp = try copy(Self.epub, to: env.scratch.appendingPathComponent("tmp"), as: "noext")
        let adopted = try ImportPipeline.adoptDroppedFile(temp, suggestedName: "My Book", typeIdentifier: "org.idpf.epub-container",
                                                          into: env.service.stagingRoot)
        #expect(adopted.lastPathComponent == "My Book.epub")
        #expect(adopted.deletingLastPathComponent().lastPathComponent.hasPrefix("drop-"))
        #expect(ImportContentTypes.loadableTypeIdentifier(among: ["org.idpf.epub-container"]) != nil)
        #expect(ImportContentTypes.loadableTypeIdentifier(among: ["com.adobe.pdf"]) != nil)
        #expect(ImportContentTypes.loadableTypeIdentifier(among: ["public.vcard"]) == nil)
    }

    // MARK: Words

    @Test func everyLimitationGroupAndErrorHasWords() {
        let texts = ConversionLimitation.allCases.map(\.text)
        #expect(texts.allSatisfy { !$0.isEmpty })
        #expect(Set(texts).count == texts.count)
        #expect(LimitationGroup.allCases.allSatisfy { !$0.sheetTitle.isEmpty })
        #expect(ConversionTextSize.allCases.map(\.label) == ["Small", "Medium", "Large"])
        let errors: [ImportError] = [
            .notAPDF(fileName: "a"), .locked(fileName: "a"), .noPages(fileName: "a"),
            .unreadable(fileName: "a", reason: "r"), .storage(fileName: "a", reason: "r"), .protected(fileName: "a"),
            .conversionFailed(fileName: "a", reason: "r"), .unsupportedFormat(fileName: "a", kind: nil), .cancelled,
        ] + UnsupportedImportFormat.allCases.map { .unsupportedFormat(fileName: "a", kind: $0) }
        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty)
            #expect(!error.alertTitle.isEmpty)
            #expect(!error.shortReason.isEmpty)
        }
        #expect(ConversionLimitation.common.map(\.text).first?.hasPrefix("The pages are fixed") == true)
    }
}

/// Records the text size of each conversion; converts like the stub.
nonisolated struct RecordingConverter: DocumentConverter {
    let log: TextSizeLog
    var version: Int { 7 }
    var formats: Set<ImportFormat> { [.epub] }

    func convert(_ input: ConversionInput, progress: @escaping @Sendable (Double) -> Void) async throws -> ConvertedDocument {
        log.append(input.options.textSize)
        return try await StubDocumentConverter().convert(input, progress: progress)
    }
}

/// Writes something that is not a PDF, or a PDF outside the staging directory.
nonisolated struct BadOutputConverter: DocumentConverter {
    enum Mode: Sendable { case garbage, elsewhere }
    let mode: Mode
    var version: Int { 1 }
    var formats: Set<ImportFormat> { [.epub] }

    func convert(_ input: ConversionInput, progress: @escaping @Sendable (Double) -> Void) async throws -> ConvertedDocument {
        switch mode {
        case .garbage:
            try Data("not a pdf".utf8).write(to: input.outputURL)
            return ConvertedDocument(pdf: input.outputURL, pageCount: 1, title: nil, coverImage: nil)
        case .elsewhere:
            let elsewhere = input.directory.deletingLastPathComponent()
                .appendingPathComponent("elsewhere-\(UUID().uuidString)").appendingPathComponent("out.pdf")
            var stub = StubDocumentConverter()
            stub.formats = [.epub]
            let made = try await stub.convert(input, progress: progress)
            return ConvertedDocument(pdf: elsewhere, pageCount: made.pageCount, title: nil, coverImage: nil)
        }
    }
}

nonisolated final class TextSizeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ConversionTextSize] = []
    func append(_ value: ConversionTextSize) { lock.withLock { stored.append(value) } }
    var values: [ConversionTextSize] { lock.withLock { stored } }
}
