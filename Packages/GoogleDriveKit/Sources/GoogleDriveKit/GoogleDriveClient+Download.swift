import Foundation

extension GoogleDriveClient {
    /// Downloads a file's content (`GET …/files/{id}?alt=media`) to `destination`, streamed to disk.
    ///
    /// The bytes go to `destination` + `.partial` first. After an interrupted connection, a 5xx or
    /// a 429 the download carries on from the bytes already written with `Range: bytes=n-`. The
    /// result is checked against Drive's size and checksum (`sha256Checksum`, or `md5Checksum`
    /// when Drive has no SHA-256) and, when given, `expectedSHA256`; only then is it moved to
    /// `destination` (replacing any file there). On any failure, cancellation included, the partial
    /// file is removed.
    ///
    /// - Returns: The file's metadata.
    @discardableResult
    public func downloadFile(
        id: String,
        to destination: URL,
        expectedSHA256: String? = nil,
        progress: GoogleTransferProgressHandler? = nil
    ) async throws -> GoogleDriveFile {
        let file = try await self.file(id: id)
        guard let total = file.size, !file.isFolder else {
            throw GoogleDriveError.unexpectedResponse(status: 200, reason: "file has no downloadable content")
        }
        let expected = expectedSHA256?.lowercased()
        if let expected, let remote = file.sha256Checksum?.lowercased(), remote != expected {
            // No point downloading what is already known to be the wrong content.
            throw GoogleDriveError.checksumMismatch(expected: expected, actual: remote)
        }

        let partial = destination.appendingPathExtension("partial")
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: partial)
        guard fileManager.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let writer: FileHandle
        do {
            writer = try FileHandle(forWritingTo: partial)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }

        do {
            let digest = try await receive(id: id, total: total, into: writer, progress: progress)
            try writer.close()
            let local = digest.finalize()
            if let expected, expected != local.sha256 {
                throw GoogleDriveError.checksumMismatch(expected: expected, actual: local.sha256)
            }
            if let remote = file.sha256Checksum?.lowercased(), remote != local.sha256 {
                throw GoogleDriveError.checksumMismatch(expected: remote, actual: local.sha256)
            }
            if file.sha256Checksum == nil, let remote = file.md5Checksum?.lowercased(), remote != local.md5 {
                throw GoogleDriveError.checksumMismatch(expected: remote, actual: local.md5)
            }
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
            return file
        } catch {
            try? writer.close()
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private static let writeBufferSize = 1024 * 1024

    private func receive(id: String, total: Int64, into writer: FileHandle,
                         progress: GoogleTransferProgressHandler?) async throws -> StreamDigest {
        let url = FormEncoding.url("\(Self.filesEndpoint)/\(FormEncoding.encode(id))", [("alt", "media")])
        var digest = StreamDigest()
        var failures = 0
        var refreshed = false

        while digest.byteCount < total {
            try Task.checkCancellation()
            let start = digest.byteCount
            do {
                let token = try await auth.validAccessToken()
                var request = URLRequest(method: "GET", url: url, accessToken: token)
                request.timeoutInterval = 120
                if start > 0 { request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range") }
                let (bytes, response) = try await urlSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw GoogleDriveError.unexpectedResponse(status: nil, reason: "not an HTTP response")
                }
                switch http.statusCode {
                case 200:
                    if start > 0 {
                        // The server ignored the range and is sending the whole file again.
                        try writer.truncate(atOffset: 0)
                        try writer.seek(toOffset: 0)
                        digest = StreamDigest()
                    }
                case 206:
                    guard HTTP.header("Content-Range", in: http)?.hasPrefix("bytes \(start)-") == true else {
                        throw GoogleDriveError.unexpectedResponse(status: 206, reason: "unexpected Content-Range")
                    }
                case 401 where !refreshed:
                    refreshed = true
                    _ = try await auth.accessToken(replacingRejected: token)
                    continue
                default:
                    throw HTTP.driveFailure(status: http.statusCode, data: try await Self.collect(bytes, limit: 64 * 1024))
                }
                try await Self.stream(bytes, into: writer, digest: &digest, total: total, progress: progress)
                if digest.byteCount < total {
                    // The connection closed early without an error.
                    throw AttemptFailure(error: .noNetwork, retryable: true)
                }
            } catch {
                let failure: AttemptFailure
                switch error {
                case let attempt as AttemptFailure:
                    failure = attempt
                case let drive as GoogleDriveError:
                    failure = AttemptFailure(error: drive, retryable: drive.isTransient)
                case is URLError:
                    let mapped = HTTP.transportFailure(error)
                    guard let attempt = mapped as? AttemptFailure else { throw mapped }
                    failure = attempt
                default:
                    // Cancellation, disk errors.
                    throw error
                }
                failures = digest.byteCount > start ? 1 : failures + 1
                guard failure.retryable, failures < retryPolicy.maxAttempts else { throw failure.error }
                try await retryPolicy.backoff(beforeRetry: failures)
            }
        }
        return digest
    }

    private static func stream(_ bytes: URLSession.AsyncBytes, into writer: FileHandle, digest: inout StreamDigest,
                               total: Int64, progress: GoogleTransferProgressHandler?) async throws {
        var buffer = Data()
        buffer.reserveCapacity(writeBufferSize)
        func flush() throws {
            guard !buffer.isEmpty else { return }
            guard digest.byteCount + Int64(buffer.count) <= total else {
                throw GoogleDriveError.unexpectedResponse(status: nil, reason: "more data than the file's size")
            }
            try writer.write(contentsOf: buffer)
            digest.update(buffer)
            buffer.removeAll(keepingCapacity: true)
            progress?(GoogleTransferProgress(completedBytes: digest.byteCount, totalBytes: total))
        }
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= writeBufferSize {
                    try flush()
                    try Task.checkCancellation()
                }
            }
        } catch {
            // Keep what arrived before the connection dropped; the next request asks for the rest.
            try flush()
            throw error
        }
        try flush()
    }

    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }
}
