import Foundation
import ReaderCore

/// `RecognisedTextStore` over plain files laid out by `BookStorageLayout` under a root directory:
/// one JSON file per recognised page in `Books/<bookID>/text/`, and the state sidecar
/// `Books/<bookID>/recognition.json` beside the book. Both live in the book's directory, so
/// removing the directory with the book (`FileInkStore.removeBook`) removes them too.
///
/// Synchronous and thread-safe (see the protocol): it holds no mutable state, and every write is
/// atomic (`Data.write(options: .atomic)`: temp file then rename), so concurrent readers see the
/// old file or the new one. Removals are idempotent. A file that cannot be decoded throws
/// `ReaderStoreError.corruptRecord`; a zero-length file reads as absent.
public final class FileRecognisedTextStore: RecognisedTextStore {
    private let root: URL

    public init(rootDirectory: URL) {
        self.root = rootDirectory
    }

    private func url(_ relativePath: String, isDirectory: Bool = false) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: isDirectory)
    }

    private static func isMissing(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            return ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError
        }
        if ns.domain == NSPOSIXErrorDomain {
            return ns.code == Int(ENOENT) || ns.code == Int(ENOTDIR)
        }
        return false
    }

    private func read(_ url: URL) throws -> Data? {
        do {
            let data = try Data(contentsOf: url)
            return data.isEmpty ? nil : data
        } catch where Self.isMissing(error) {
            return nil
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager().createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func remove(_ url: URL) throws {
        do {
            try FileManager().removeItem(at: url)
        } catch where Self.isMissing(error) {
            return
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ReaderStoreError.corruptRecord("\(what): \(error)")
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    // MARK: Pages

    public func recognisedPage(bookID: UUID, pageIndex: Int) throws -> RecognisedPage? {
        guard let data = try read(url(BookStorageLayout.recognisedPagePath(bookID: bookID, pageIndex: pageIndex))) else { return nil }
        let page = try Self.decode(RecognisedPage.self, from: data, what: "recognised page \(pageIndex) of \(bookID)")
        guard page.pageIndex == pageIndex else {
            throw ReaderStoreError.corruptRecord("recognised page \(pageIndex) of \(bookID) holds page \(page.pageIndex)")
        }
        return page
    }

    public func saveRecognisedPage(_ page: RecognisedPage, bookID: UUID) throws {
        let data = try Self.encoder().encode(page)
        try write(data, to: url(BookStorageLayout.recognisedPagePath(bookID: bookID, pageIndex: page.pageIndex)))
    }

    public func recognisedPageIndices(bookID: UUID) throws -> [Int] {
        let directory = url(BookStorageLayout.recognisedTextDirectory(bookID: bookID), isDirectory: true)
        let names: [String]
        do {
            names = try FileManager().contentsOfDirectory(atPath: directory.path)
        } catch where Self.isMissing(error) {
            return []
        }
        return names.compactMap(BookStorageLayout.pageIndex(fromRecognisedPageFileName:)).sorted()
    }

    public func removeRecognisedText(bookID: UUID) throws {
        try remove(url(BookStorageLayout.recognisedTextDirectory(bookID: bookID), isDirectory: true))
    }

    // MARK: State

    public func recognitionState(bookID: UUID) throws -> RecognitionState? {
        guard let data = try read(url(BookStorageLayout.recognitionStatePath(bookID: bookID))) else { return nil }
        return try Self.decode(RecognitionState.self, from: data, what: "recognition state of \(bookID)")
    }

    public func saveRecognitionState(_ state: RecognitionState?, bookID: UUID) throws {
        let target = url(BookStorageLayout.recognitionStatePath(bookID: bookID))
        guard let state else { return try remove(target) }
        try write(try Self.encoder().encode(state), to: target)
    }

    // MARK: Book

    public func removeBook(bookID: UUID) throws {
        try removeRecognisedText(bookID: bookID)
        try remove(url(BookStorageLayout.recognitionStatePath(bookID: bookID)))
    }
}
