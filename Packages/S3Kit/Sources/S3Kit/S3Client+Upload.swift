import CryptoKit
import Foundation

extension S3Client {
    /// The part size used for a file of `fileSize` bytes: `preferred` clamped to the 5 MiB minimum
    /// and raised, in whole MiB, until the file fits in 10,000 parts.
    ///
    /// - Throws: `S3Error.storageLimit` when even the largest part size can't fit the file.
    public static func partSize(forFileSize fileSize: Int64, preferred: Int64 = defaultPartSize) throws -> Int64 {
        let mebibyte: Int64 = 1024 * 1024
        var size = min(max(preferred, minimumPartSize), maximumPartSize)
        if (fileSize + size - 1) / size > maximumPartCount {
            let needed = (fileSize + maximumPartCount - 1) / maximumPartCount
            size = (needed + mebibyte - 1) / mebibyte * mebibyte
        }
        guard size <= maximumPartSize else { throw S3Error.storageLimit(code: "TooManyParts") }
        return size
    }

    /// Uploads a file, streamed from disk, replacing any object with that key.
    ///
    /// A file no larger than one part goes up in a single `PutObject`. A larger one is a multipart
    /// upload of equal parts (the last shorter), as R2 requires, uploaded **one after another**:
    /// each part is copied to a temporary file while its SHA-256 is computed (so memory stays at a
    /// 1 MiB buffer whatever the part size), signed with that hash, and retried on its own on
    /// transport errors, HTTP 5xx and 429 under `retryPolicy`. If anything fails, or the task is
    /// cancelled, the upload is aborted (`AbortMultipartUpload`) so no parts are left stored and
    /// billed. Once completed, the object's size is checked with `head(key:)`. (One gap remains: if
    /// the connection fails after the service has created the upload but before its ID arrives, the
    /// ID is unknown and can't be aborted; R2 expires such uploads after 7 days by default, Amazon S3
    /// only under a bucket lifecycle rule.)
    ///
    /// - Parameters:
    ///   - partSize: preferred part size (default 16 MiB); see `partSize(forFileSize:preferred:)`.
    ///   - progress: called with bytes uploaded so far after each part (and at the start and end).
    public func upload(fileAt fileURL: URL, key: String, metadata: [String: String] = [:],
                       partSize: Int64 = defaultPartSize, progress: S3Progress? = nil) async throws {
        let fullKey = try fullKey(for: key)
        let metadataHeaders = try Self.metadataHeaders(metadata)
        let fileSize = try Self.fileSize(of: fileURL)
        let partSize = try Self.partSize(forFileSize: fileSize, preferred: partSize)
        progress?(0, fileSize)

        if fileSize <= partSize {
            let hash = try Self.sha256(of: fileURL, offset: 0, length: fileSize, copyingTo: nil)
            var request = Request(method: "PUT", key: fullKey, signedHeaders: metadataHeaders, body: .file(fileURL),
                                  payloadSHA256: hash)
            request.otherHeaders["Content-Type"] = "application/octet-stream"
            _ = try await send(request, key: key)
            progress?(fileSize, fileSize)
            return
        }

        var create = Request(method: "POST", key: fullKey, query: [("uploads", nil)], signedHeaders: metadataHeaders)
        create.otherHeaders["Content-Type"] = "application/octet-stream"
        let (created, _) = try await send(create, key: key, retrying: false)
        let uploadID: String
        do { uploadID = try S3XML.uploadID(from: created) } catch {
            throw S3Error.unexpectedResponse(status: 200, code: nil, message: "The upload couldn't be started.")
        }

        do {
            var parts: [(number: Int, eTag: String)] = []
            let partCount = Int((fileSize + partSize - 1) / partSize)
            for number in 1...partCount {
                try Task.checkCancellation()
                let offset = Int64(number - 1) * partSize
                let length = min(partSize, fileSize - offset)
                let eTag = try await uploadPart(number: number, of: fileURL, offset: offset, length: length,
                                                fullKey: fullKey, key: key, uploadID: uploadID)
                parts.append((number, eTag))
                progress?(offset + length, fileSize)
            }
            try await completeMultipartUpload(fullKey: fullKey, key: key, uploadID: uploadID, parts: parts)
        } catch {
            // Not cancelled with the caller: the abort must get through even when the task was.
            let client = self
            await Task.detached { await client.abortMultipartUpload(fullKey: fullKey, key: key, uploadID: uploadID) }.value
            throw error
        }

        guard let stored = try await head(key: key) else {
            throw S3Error.sizeMismatch(key: key, expected: fileSize, actual: 0)
        }
        guard stored.size == fileSize else {
            throw S3Error.sizeMismatch(key: key, expected: fileSize, actual: stored.size)
        }
    }

    /// Uploads one part from a temporary copy (made once, reused by every retry); returns its ETag.
    func uploadPart(number: Int, of fileURL: URL, offset: Int64, length: Int64, fullKey: String, key: String,
                    uploadID: String) async throws -> String {
        let partFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("S3Kit-part-\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: partFile) }
        let hash = try Self.sha256(of: fileURL, offset: offset, length: length, copyingTo: partFile)
        let request = Request(method: "PUT", key: fullKey,
                              query: [("partNumber", String(number)), ("uploadId", uploadID)],
                              body: .file(partFile), payloadSHA256: hash)
        return try await withRetries {
            try await withCredentials { credentials in
                let (data, response) = try await perform(request, credentials: credentials)
                guard (200..<300).contains(response.statusCode) else {
                    throw failure(status: response.statusCode, body: data, key: key, credentials: credentials)
                }
                guard let eTag = Self.lowercasedHeaders(response)["etag"], !eTag.isEmpty else {
                    throw S3Error.unexpectedResponse(status: response.statusCode, code: nil,
                                                     message: "Part \(number) was stored without an ETag.")
                }
                return eTag
            }
        }
    }

    /// `CompleteMultipartUpload`, treating an `<Error>` body as a failure even with HTTP 200.
    /// `NoSuchUpload` after an earlier attempt that may have reached the service means that
    /// attempt completed it; `head` then confirms. (An attempt refused for its session token
    /// did nothing, so it doesn't count.)
    func completeMultipartUpload(fullKey: String, key: String, uploadID: String,
                                 parts: [(number: Int, eTag: String)]) async throws {
        let body = S3XML.completeBody(parts: parts)
        var request = Request(method: "POST", key: fullKey, query: [("uploadId", uploadID)], body: .data(body),
                              payloadSHA256: S3Signer.hex(SHA256.hash(data: body)))
        request.otherHeaders["Content-Type"] = "application/xml"
        var earlierAttempts = 0
        try await withRetries {
            try await withCredentials { credentials in
                let mayHaveCompleted = earlierAttempts > 0
                earlierAttempts += 1
                let (data, response) = try await perform(request, credentials: credentials)
                let error: any Error
                if (200..<300).contains(response.statusCode) {
                    let result: S3XML.CompleteResult
                    do { result = try S3XML.completeResult(from: data) } catch {
                        throw S3Error.unexpectedResponse(status: response.statusCode, code: nil,
                                                         message: "The upload's completion couldn't be confirmed.")
                    }
                    guard case .failed(let serviceError) = result else { return }
                    error = failure(status: response.statusCode, code: serviceError.code,
                                    message: serviceError.message, key: key, credentials: credentials)
                } else {
                    error = failure(status: response.statusCode, body: data, key: key, credentials: credentials)
                }
                if mayHaveCompleted, case S3Error.unexpectedResponse(_, "NoSuchUpload", _) = error { return }
                if error is SessionTokenRejected { earlierAttempts -= 1 }
                throw error
            }
        }
    }

    /// `AbortMultipartUpload`, retried on transient failures and signed, like every request, with
    /// the provider's credentials of the moment; failures are otherwise ignored (the caller is
    /// already throwing, and the service expires stale uploads in the end).
    func abortMultipartUpload(fullKey: String, key: String, uploadID: String) async {
        let request = Request(method: "DELETE", key: fullKey, query: [("uploadId", uploadID)])
        _ = try? await send(request, key: key, accepting: [404])
    }

    // MARK: Files

    static func fileSize(of url: URL) throws -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw S3Error.fileAccess(path: url.path, reason: "Its size couldn't be read.")
            }
            return size.int64Value
        } catch let error as S3Error {
            throw error
        } catch {
            throw S3Error.fileAccess(path: url.path, reason: error.localizedDescription)
        }
    }

    /// The hex SHA-256 of `length` bytes of `url` from `offset`, read 1 MiB at a time, copying
    /// them to `copy` when given.
    static func sha256(of url: URL, offset: Int64, length: Int64, copyingTo copy: URL?) throws -> String {
        do {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            try input.seek(toOffset: UInt64(offset))
            var output: FileHandle?
            if let copy {
                guard FileManager.default.createFile(atPath: copy.path, contents: nil) else {
                    throw S3Error.fileAccess(path: copy.path, reason: "A temporary file couldn't be created.")
                }
                output = try FileHandle(forWritingTo: copy)
            }
            defer { try? output?.close() }
            var hasher = SHA256()
            var remaining = length
            while remaining > 0 {
                let chunk = try autoreleasepool { () throws -> Data? in
                    try input.read(upToCount: Int(min(remaining, 1024 * 1024)))
                }
                guard let chunk, !chunk.isEmpty else {
                    throw S3Error.fileAccess(path: url.path, reason: "The file got shorter while it was being uploaded.")
                }
                hasher.update(data: chunk)
                try output?.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
            return S3Signer.hex(hasher.finalize())
        } catch let error as S3Error {
            throw error
        } catch {
            throw S3Error.fileAccess(path: url.path, reason: error.localizedDescription)
        }
    }
}
