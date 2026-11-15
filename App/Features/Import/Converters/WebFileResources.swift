import Foundation

/// Serves a fixed set of documents to the web renderer: generated HTML held in memory, or a file
/// on disk streamed in chunks (an Office document handed to WebKit's own converter). Nothing
/// else can be reached through it.
///
/// Immutable after `init`, apart from the lock-guarded table, so it can be read on the scheme
/// handler's queue.
nonisolated final class WebFileResources: WebResourceProvider, @unchecked Sendable {
    enum Source: Sendable {
        case data(Data)
        case file(URL)
    }

    struct Entry: Sendable {
        var source: Source
        var mimeType: String
        /// `nil` to let WebKit work the encoding out.
        var textEncodingName: String?
    }

    static let chunkSize = 256 << 10
    private let lock = NSLock()
    private var entries: [String: Entry]

    init(_ entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    func set(_ path: String, _ entry: Entry) {
        lock.withLock { entries[path] = entry }
    }

    func resource(at path: String) throws -> WebResource? {
        guard let entry = lock.withLock({ entries[path] }) else { return nil }
        switch entry.source {
        case let .data(data):
            return .data(data, mimeType: entry.mimeType, textEncodingName: entry.textEncodingName)
        case let .file(url):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            return WebResource(mimeType: entry.mimeType, textEncodingName: entry.textEncodingName, expectedLength: size) { body in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                    try body(chunk)
                }
            }
        }
    }
}
