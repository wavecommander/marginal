import Foundation

extension GoogleDriveClient {
    /// Uploads a local file into a folder with Drive's resumable protocol, streaming it from disk
    /// one chunk at a time, and verifies the result.
    ///
    /// The session is started with `POST …/upload/drive/v3/files?uploadType=resumable` (metadata
    /// in the body, `X-Upload-Content-Type` and `X-Upload-Content-Length` headers); each chunk is a
    /// `PUT` to the session URI with `Content-Range: bytes first-last/total`, answered with
    /// `308` and a `Range: bytes=0-n` header until the last one returns the file. After a dropped
    /// connection or a 5xx the upload asks the server how much it has (`Content-Range: bytes */total`)
    /// and carries on from there; an expired session (404) starts a new one.
    ///
    /// - Parameters:
    ///   - chunkSize: Bytes per request, rounded down to a multiple of 256 KiB (at least 256 KiB).
    ///   - expectedSHA256: Lowercase hex SHA-256 of the file's content. When given, the upload is
    ///     accepted only if Drive's `sha256Checksum` (or, if Drive reports none, its `md5Checksum`
    ///     against the bytes actually sent) matches it.
    ///   - progress: Called with the bytes the server has confirmed.
    /// - Throws: ``GoogleDriveError/checksumMismatch(expected:actual:)`` after deleting the remote
    ///   copy when its size or checksum is wrong; `CancellationError` when the task is cancelled.
    @discardableResult
    public func uploadFile(
        at fileURL: URL,
        name: String,
        mimeType: String,
        inFolder folderID: String,
        appProperties: [String: String] = [:],
        expectedSHA256: String? = nil,
        chunkSize: Int = GoogleDriveClient.defaultChunkSize,
        progress: GoogleTransferProgressHandler? = nil
    ) async throws -> GoogleDriveFile {
        let size = try Self.fileSize(at: fileURL)
        let granularity = Self.chunkGranularity
        let chunk = Int64(max(granularity, chunkSize / granularity * granularity))
        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }

        struct Metadata: Encodable {
            let name: String
            let mimeType: String
            let parents: [String]
            let appProperties: [String: String]?
        }
        let metadata = try JSONEncoder().encode(Metadata(
            name: name, mimeType: mimeType, parents: [folderID],
            appProperties: appProperties.isEmpty ? nil : appProperties))

        var digest = StreamDigest()
        var session: URL?
        var offset: Int64 = 0
        var askStatus = false
        var failures = 0
        var restarts = 0
        var uploaded: GoogleDriveFile?

        while uploaded == nil {
            try Task.checkCancellation()
            if session == nil {
                session = try await startUploadSession(metadata: metadata, mimeType: mimeType, size: size)
                offset = 0
                askStatus = false
            }
            guard let sessionURL = session else { continue }

            let outcome: SessionOutcome
            do {
                if askStatus || offset >= size {
                    outcome = try await sessionPUT(sessionURL, contentRange: "bytes */\(size)", body: Data(), size: size)
                } else {
                    let length = min(chunk, size - offset)
                    let bytes = try Self.read(reader, offset: offset, length: length)
                    // Hash each byte once, the first time it is sent; resends start at or before it.
                    let hashedUpTo = digest.byteCount
                    if offset + length > hashedUpTo {
                        digest.update(bytes.subdata(in: Int(hashedUpTo - offset)..<bytes.count))
                    }
                    outcome = try await sessionPUT(
                        sessionURL, contentRange: "bytes \(offset)-\(offset + length - 1)/\(size)", body: bytes, size: size)
                }
            } catch let failure as AttemptFailure where failure.retryable {
                outcome = .retry(failure)
            }

            switch outcome {
            case .complete(let file):
                uploaded = file
                progress?(GoogleTransferProgress(completedBytes: size, totalBytes: size))
            case .incomplete(let received):
                if received > offset {
                    failures = 0
                } else if !askStatus {
                    // A chunk was sent and nothing more arrived: count it, so this cannot loop forever.
                    failures += 1
                    guard failures < retryPolicy.maxAttempts else {
                        throw GoogleDriveError.unexpectedResponse(status: 308, reason: "upload made no progress")
                    }
                }
                offset = received
                askStatus = false
                progress?(GoogleTransferProgress(completedBytes: received, totalBytes: size))
            case .expired:
                restarts += 1
                guard restarts <= retryPolicy.maxSessionRestarts else {
                    throw GoogleDriveError.unexpectedResponse(status: 404, reason: "upload session kept expiring")
                }
                session = nil
            case .retry(let failure):
                failures += 1
                guard failures < retryPolicy.maxAttempts else { throw failure.error }
                try await retryPolicy.backoff(beforeRetry: failures)
                askStatus = true
            case .fail(let error):
                throw error
            }
        }

        guard var file = uploaded else { throw GoogleDriveError.unexpectedResponse(status: nil, reason: nil) }
        if file.size == nil || (file.sha256Checksum == nil && file.md5Checksum == nil) {
            file = try await self.file(id: file.id)
        }
        let local = digest.finalize()
        if let problem = Self.verificationProblem(file: file, size: size, local: local, expectedSHA256: expectedSHA256) {
            try? await deleteFile(id: file.id)
            throw problem
        }
        return file
    }

    /// Why a finished upload cannot be trusted, or `nil` when it matches.
    static func verificationProblem(file: GoogleDriveFile, size: Int64, local: (sha256: String, md5: String),
                                    expectedSHA256: String?) -> GoogleDriveError? {
        guard file.size == size else {
            return .checksumMismatch(expected: "\(size) bytes", actual: file.size.map { "\($0) bytes" } ?? "no size")
        }
        if let expected = expectedSHA256?.lowercased(), expected != local.sha256 {
            // The file on disk is not the one the caller hashed.
            return .checksumMismatch(expected: expected, actual: local.sha256)
        }
        if let remote = file.sha256Checksum?.lowercased() {
            return remote == local.sha256 ? nil : .checksumMismatch(expected: local.sha256, actual: remote)
        }
        if let remote = file.md5Checksum?.lowercased() {
            return remote == local.md5 ? nil : .checksumMismatch(expected: local.md5, actual: remote)
        }
        return expectedSHA256 == nil ? nil : .unexpectedResponse(status: 200, reason: "no checksum reported")
    }

    enum SessionOutcome {
        case complete(GoogleDriveFile)
        case incomplete(received: Int64)
        case expired
        case retry(AttemptFailure)
        case fail(GoogleDriveError)
    }

    private func startUploadSession(metadata: Data, mimeType: String, size: Int64) async throws -> URL {
        let url = FormEncoding.url(Self.uploadEndpoint, [("uploadType", "resumable"), ("fields", GoogleDriveFile.fields)])
        let (_, response) = try await authorized { token in
            var request = URLRequest(method: "POST", url: url, accessToken: token)
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
            request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            request.httpBody = metadata
            return request
        }
        guard let location = HTTP.header("Location", in: response), let session = URL(string: location),
              session.scheme?.lowercased() == "https" else {
            throw GoogleDriveError.unexpectedResponse(status: response.statusCode, reason: "no upload session")
        }
        return session
    }

    /// One `PUT` to the session URI. The session URI identifies the upload by itself, so (as in
    /// Drive's samples) no `Authorization` header is sent; a 401 is treated like an expired session.
    private func sessionPUT(_ session: URL, contentRange: String, body: Data, size: Int64) async throws -> SessionOutcome {
        var request = URLRequest(method: "PUT", url: session)
        request.timeoutInterval = 300
        request.setValue(contentRange, forHTTPHeaderField: "Content-Range")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = body
        let (data, response) = try await HTTP.send(request, on: urlSession, followRedirects: false)
        switch response.statusCode {
        case 200, 201:
            return .complete(try Self.decode(data, response))
        case 308:
            // `Range: bytes=0-n` means bytes 0...n arrived; no header means none did.
            guard let range = HTTP.header("Range", in: response) else { return .incomplete(received: 0) }
            guard range.hasPrefix("bytes=0-"), let last = Int64(range.dropFirst("bytes=0-".count)),
                  last >= 0, last < size else {
                return .fail(.unexpectedResponse(status: 308, reason: "Range \(range)"))
            }
            return .incomplete(received: last + 1)
        case 401, 404, 410:
            return .expired
        default:
            let failure = HTTP.driveFailure(status: response.statusCode, data: data)
            return failure.retryable ? .retry(failure) : .fail(failure.error)
        }
    }

    static func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else { throw CocoaError(.fileReadUnknown) }
        return size
    }

    private static func read(_ handle: FileHandle, offset: Int64, length: Int64) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        // The file shrank while uploading.
        guard data.count == Int(length) else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}
