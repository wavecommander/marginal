import CryptoKit
import Foundation

extension S3Client {
    /// Downloads an object to `destination`, streamed to disk in the chunks the network delivers.
    ///
    /// The bytes go to a temporary file beside `destination`, which replaces `destination` only
    /// once everything has arrived and checked out. When the connection drops (or the service
    /// answers 5xx/429), the download resumes from the last byte written with a `Range` request
    /// pinned to the first response's ETag (`If-Match`), so a changed object restarts the download
    /// rather than mixing versions; `retryPolicy` bounds consecutive failures that make no progress.
    /// With `expectedSHA256`, the bytes are hashed as they are written and a mismatch throws
    /// `checksumMismatch`. On any failure or cancellation the partial file is removed and
    /// `destination` is left as it was.
    ///
    /// - Returns: the object's size in bytes.
    @discardableResult
    public func download(key: String, to destination: URL, expectedSHA256: String? = nil,
                         progress: S3Progress? = nil) async throws -> Int64 {
        let fullKey = try fullKey(for: key)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).s3partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partial) else {
            throw S3Error.fileAccess(path: destination.path, reason: "The file couldn't be created.")
        }
        let state = DownloadState(handle: handle, hashing: expectedSHA256 != nil, progress: progress)
        do {
            try await receive(fullKey: fullKey, key: key, into: state)
            try handle.synchronize()
            try handle.close()
            let snapshot = state.snapshot()
            if let expected = expectedSHA256, snapshot.sha256?.lowercased() != expected.lowercased() {
                throw S3Error.checksumMismatch(key: key)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: destination)
            }
            return snapshot.written
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            if error is S3Error || error is CancellationError { throw error }
            throw S3Error.fileAccess(path: destination.path, reason: error.localizedDescription)
        }
    }

    /// Requests until the whole object has been written to `state`.
    private func receive(fullKey: String, key: String, into state: DownloadState) async throws {
        var failures = 0
        while true {
            try Task.checkCancellation()
            let before = state.snapshot()
            if let total = before.total, before.written == total, before.started { return }

            var request = Request(method: "GET", key: fullKey)
            if before.written > 0 {
                request.signedHeaders["Range"] = "bytes=\(before.written)-"
                if let eTag = before.eTag { request.signedHeaders["If-Match"] = eTag }
            }
            let outcome = await runDownloadTask(try urlRequest(for: request), state: state)
            let after = state.snapshot()
            let lastError: S3Error
            switch outcome {
            case .finished:
                guard let total = after.total, after.written != total else { return }
                // The body ended early without a transport error: treat it like a dropped connection.
                lastError = after.written > total
                    ? .sizeMismatch(key: key, expected: total, actual: after.written)
                    : .noNetwork(urlErrorCode: URLError.networkConnectionLost.rawValue)
                guard after.written < total else { throw lastError }
                failures = after.written > before.written ? 0 : failures + 1
            case .httpError(let status, let body):
                let error = S3Error.from(status: status, body: body, bucket: configuration.bucket, key: key,
                                         secret: configuration.secretAccessKey)
                if status == 412 || (status == 416 && before.written > 0) {
                    // The object changed since the download started, or the range no longer fits: start over.
                    try state.restart()
                } else if !error.isTransient {
                    throw error
                }
                lastError = error
                failures += 1
            case .failed(let error):
                let mapped = S3Error.from(transport: error)
                guard let s3Error = mapped as? S3Error, s3Error.isTransient else { throw mapped }
                lastError = s3Error
                failures = after.written > before.written ? 0 : failures + 1
            }
            guard failures < retryPolicy.maxAttempts else { throw lastError }
            try await retryPolicy.sleep(retryPolicy.delay(beforeRetry: max(1, failures)))
        }
    }

    private func runDownloadTask(_ request: URLRequest, state: DownloadState) async -> DownloadOutcome {
        let task = session.dataTask(with: request)
        let receiver = DownloadReceiver(state: state, offset: state.snapshot().written)
        task.delegate = receiver
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                receiver.setContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

enum DownloadOutcome: Sendable {
    case finished
    case httpError(status: Int, body: Data)
    case failed(any Error)
}

/// What has been written so far, shared by the attempts of one download.
final class DownloadState: @unchecked Sendable {
    struct Snapshot {
        var written: Int64
        var total: Int64?
        var eTag: String?
        var started: Bool
        var sha256: String?
    }

    private let lock = NSLock()
    private let handle: FileHandle
    private let hashing: Bool
    private let progress: S3Progress?
    private var hasher = SHA256()
    private var written: Int64 = 0
    private var total: Int64?
    private var eTag: String?
    private var started = false

    init(handle: FileHandle, hashing: Bool, progress: S3Progress?) {
        self.handle = handle
        self.hashing = hashing
        self.progress = progress
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(written: written, total: total, eTag: eTag, started: started,
                     sha256: hashing ? S3Signer.hex(hasher.finalize()) : nil)
        }
    }

    /// Accepts a response for a request that started at `offset`; returns false (and the
    /// receiver fails the attempt) when its range doesn't continue the file.
    func begin(status: Int, headers: [String: String], offset: Int64) throws {
        try lock.withLock {
            if status == 200 {
                // A full body, whether asked for or not (a service may ignore Range): start over.
                if written > 0 { try resetLocked() }
                total = headers["content-length"].flatMap { Int64($0) }
            } else {
                guard let range = headers["content-range"].flatMap(Self.parseContentRange), range.start == written,
                      range.start == offset else {
                    throw S3Error.unexpectedResponse(status: status, code: nil,
                                                     message: "The service resumed the download at the wrong place.")
                }
                total = range.total
            }
            if eTag == nil { eTag = headers["etag"] }
            started = true
        }
    }

    func append(_ data: Data) throws {
        let (done, total) = try lock.withLock { () throws -> (Int64, Int64?) in
            try handle.write(contentsOf: data)
            if hashing { hasher.update(data: data) }
            written += Int64(data.count)
            return (written, self.total)
        }
        progress?(done, total ?? done)
    }

    func restart() throws {
        try lock.withLock { try resetLocked() }
    }

    private func resetLocked() throws {
        try handle.truncate(atOffset: 0)
        hasher = SHA256()
        written = 0
        total = nil
        eTag = nil
        started = false
    }

    /// `bytes <start>-<end>/<total>`.
    static func parseContentRange(_ value: String) -> (start: Int64, total: Int64?)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = trimmed.dropFirst("bytes ".count)
        let halves = spec.split(separator: "/", maxSplits: 1)
        guard let range = halves.first, let start = range.split(separator: "-").first.flatMap({ Int64($0) }) else {
            return nil
        }
        let total = halves.count > 1 ? Int64(halves[1]) : nil
        return (start, total)
    }
}

/// The delegate of one download request: writes 2xx bodies to the state as they arrive and
/// collects error bodies; reports the outcome once.
final class DownloadReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let state: DownloadState
    private let offset: Int64
    private var continuation: CheckedContinuation<DownloadOutcome, Never>?
    private var pendingOutcome: DownloadOutcome?
    private var errorStatus: Int?
    private var errorBody = Data()
    private var failure: (any Error)?

    init(state: DownloadState, offset: Int64) {
        self.state = state
        self.offset = offset
    }

    func setContinuation(_ continuation: CheckedContinuation<DownloadOutcome, Never>) {
        let pending: DownloadOutcome? = lock.withLock {
            if let pendingOutcome { return pendingOutcome }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(returning: pending) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        completionHandler(disposition(for: response))
    }

    private func disposition(for response: URLResponse) -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            lock.withLock { failure = S3Error.unexpectedResponse(status: 0, code: nil, message: "The response wasn't HTTP.") }
            return .cancel
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            lock.withLock { errorStatus = http.statusCode }
            return .allow
        }
        do {
            try state.begin(status: http.statusCode, headers: S3Client.lowercasedHeaders(http), offset: offset)
            return .allow
        } catch {
            lock.withLock { failure = error }
            return .cancel
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let collectingError = lock.withLock { () -> Bool in
            if errorStatus != nil { errorBody.append(data); return true }
            return failure != nil
        }
        guard !collectingError else { return }
        do {
            try state.append(data)
        } catch {
            lock.withLock { failure = S3Error.fileAccess(path: "", reason: error.localizedDescription) }
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let outcome: DownloadOutcome = lock.withLock {
            if let failure { return .failed(failure) }
            if let errorStatus { return .httpError(status: errorStatus, body: errorBody) }
            if let error { return .failed(error) }
            return .finished
        }
        let continuation: CheckedContinuation<DownloadOutcome, Never>? = lock.withLock {
            guard let continuation = self.continuation else { pendingOutcome = outcome; return nil }
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: outcome)
    }
}
