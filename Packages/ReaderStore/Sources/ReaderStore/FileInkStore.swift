import Foundation
import ReaderCore

/// `InkStore` over plain files laid out by `BookStorageLayout` under a root directory.
///
/// An actor, so every read and write runs off the main thread and calls are serialised. Writes
/// are atomic (`Data.write(options: .atomic)`: temp file then rename). Presence means ink, so
/// saving empty `Data` removes the file instead of storing it, and a zero-length file reads as
/// "no ink". Deletes are idempotent.
public actor FileInkStore: InkStore {
    private let root: URL
    private let fileManager = FileManager()

    public init(rootDirectory: URL) {
        self.root = rootDirectory
    }

    private func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
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
        guard !data.isEmpty else { return try remove(url) }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func remove(_ url: URL) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch where Self.isMissing(error) {
            return
        }
    }

    public func pageInk(bookID: UUID, pageIndex: Int) async throws -> Data? {
        try read(url(BookStorageLayout.pageInkPath(bookID: bookID, pageIndex: pageIndex)))
    }

    public func savePageInk(_ data: Data, bookID: UUID, pageIndex: Int) async throws {
        try write(data, to: url(BookStorageLayout.pageInkPath(bookID: bookID, pageIndex: pageIndex)))
    }

    public func deletePageInk(bookID: UUID, pageIndex: Int) async throws {
        try remove(url(BookStorageLayout.pageInkPath(bookID: bookID, pageIndex: pageIndex)))
    }

    public func inkedPageIndices(bookID: UUID) async throws -> [Int] {
        let directory = root.appendingPathComponent(BookStorageLayout.pageInkDirectory(bookID: bookID), isDirectory: true)
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory.path)
        } catch where Self.isMissing(error) {
            return []
        }
        return names.compactMap(BookStorageLayout.pageIndex(fromPageInkFileName:)).sorted()
    }

    public func noteInk(bookID: UUID, noteID: UUID) async throws -> Data? {
        try read(url(BookStorageLayout.noteInkPath(bookID: bookID, noteID: noteID)))
    }

    public func saveNoteInk(_ data: Data, bookID: UUID, noteID: UUID) async throws {
        try write(data, to: url(BookStorageLayout.noteInkPath(bookID: bookID, noteID: noteID)))
    }

    public func deleteNoteInk(bookID: UUID, noteID: UUID) async throws {
        try remove(url(BookStorageLayout.noteInkPath(bookID: bookID, noteID: noteID)))
    }

    public func removeBook(bookID: UUID) async throws {
        try remove(root.appendingPathComponent(BookStorageLayout.bookDirectory(bookID: bookID), isDirectory: true))
    }
}
