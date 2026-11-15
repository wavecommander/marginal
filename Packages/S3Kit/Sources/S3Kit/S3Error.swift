import Foundation

/// Everything S3Kit throws, apart from `CancellationError` when the calling task is cancelled.
///
/// Messages are plain language for the person using the app; the service's own error code,
/// message and HTTP status are kept in the associated values for diagnostics. No case ever holds
/// the secret access key (service messages are scrubbed of it before they are stored).
public enum S3Error: Error, LocalizedError, Sendable, Equatable {
    /// The service rejected the access key or the request signature (`SignatureDoesNotMatch`,
    /// `InvalidAccessKeyId`, `AuthorizationHeaderMalformed`, R2's `Unauthorized`, ...).
    /// `clockSkewed` is true when it said the request time was too far from its own
    /// (`RequestTimeTooSkewed`, `RequestExpired`, R2's `ExpiredRequest`).
    case authenticationFailed(code: String, clockSkewed: Bool)
    /// `NoSuchBucket`.
    case bucketNotFound(bucket: String)
    /// `AccessDenied` (or a bare 403): the key is valid but lacks permission for this bucket or object.
    case accessDenied(code: String)
    /// `NoSuchKey` on a download.
    case objectNotFound(key: String)
    /// The request never got an answer: no connection, DNS failure, timeout, dropped connection.
    /// `urlErrorCode` is the `URLError.Code` raw value.
    case noNetwork(urlErrorCode: Int)
    /// A storage quota or account limit: `AccountProblem`, R2's `NotEntitled`, `EntityTooLarge`,
    /// `QuotaExceeded`, MinIO's `XMinioStorageFull`, HTTP 507, or a file beyond the multipart limits.
    case storageLimit(code: String)
    /// Downloaded or uploaded bytes do not have the expected SHA-256 (or the service reported
    /// `BadDigest` / `XAmzContentSHA256Mismatch`).
    case checksumMismatch(key: String)
    /// The object's size is not what was written or what the service announced.
    case sizeMismatch(key: String, expected: Int64, actual: Int64)
    /// The key is empty, longer than 1,024 bytes with the prefix, or has a `.`/`..` segment.
    case invalidKey(key: String)
    /// A user-metadata name is not a lowercase token, or a value is not printable ASCII.
    case invalidMetadata(name: String)
    /// A local file could not be read or written.
    case fileAccess(path: String, reason: String)
    /// Anything else. `code` and `message` are the service's (`nil` when the body carried none).
    case unexpectedResponse(status: Int, code: String?, message: String?)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed(_, true):
            return "The storage service rejected the request because this device's clock is too far from the "
                + "correct time. Turn on Set Automatically in Settings > General > Date & Time, then try again."
        case .authenticationFailed:
            return "The storage service rejected the credentials. Check the access key ID, secret access key "
                + "and region the app was built with."
        case .bucketNotFound(let bucket):
            return "The storage bucket “\(bucket)” doesn't exist. Check the bucket name and host the app was built with."
        case .accessDenied:
            return "The storage service denied access. The access key doesn't have permission to read and write "
                + "this bucket."
        case .objectNotFound:
            return "The file isn't in the storage bucket any more."
        case .noNetwork:
            return "Couldn't reach the storage service. Check the internet connection and try again."
        case .storageLimit:
            return "The storage service refused the file because a storage quota or account limit was reached."
        case .checksumMismatch:
            return "The file was damaged in transfer: its contents don't match the expected checksum."
        case .sizeMismatch(_, let expected, let actual):
            return "The file was damaged in transfer: it has \(actual) bytes instead of \(expected)."
        case .invalidKey(let key):
            return "“\(key)” can't be used as a file name in the storage bucket."
        case .invalidMetadata(let name):
            return "The file's metadata “\(name)” can't be stored in the bucket."
        case .fileAccess(_, let reason):
            return "Couldn't read or write the local file: \(reason)"
        case .unexpectedResponse(let status, let code, let message):
            var text = "The storage service returned an unexpected response (HTTP \(status)"
            if let code { text += ", \(code)" }
            text += ")."
            if let message, !message.isEmpty { text += " \(message)" }
            return text
        }
    }

    /// Whether repeating the same request may succeed: transport failures, HTTP 5xx and 429, and
    /// the service codes S3 and R2 document as transient.
    public var isTransient: Bool {
        switch self {
        case .noNetwork:
            return true
        case .unexpectedResponse(let status, let code, _):
            if let code, Self.transientCodes.contains(code) { return true }
            return status >= 500 || status == 429
        default:
            return false
        }
    }

    static let transientCodes: Set<String> = ["InternalError", "ServiceUnavailable", "SlowDown", "RequestTimeout",
                                              "TooManyRequests", "ClientDisconnect", "InternalErrors"]
    static let authenticationCodes: Set<String> = ["SignatureDoesNotMatch", "InvalidAccessKeyId", "Unauthorized",
                                                   "AuthorizationHeaderMalformed", "ExpiredToken", "InvalidToken",
                                                   "InvalidSecurity", "MissingSecurityHeader"]
    static let clockSkewCodes: Set<String> = ["RequestTimeTooSkewed", "RequestExpired", "ExpiredRequest"]
    static let accessCodes: Set<String> = ["AccessDenied", "AllAccessDisabled"]
    static let limitCodes: Set<String> = ["AccountProblem", "NotEntitled", "QuotaExceeded", "ServiceQuotaExceeded",
                                          "EntityTooLarge", "MetadataTooLarge", "XMinioStorageFull",
                                          "XMinioAdminBucketQuotaExceeded", "StorageQuotaExceeded"]
    static let checksumCodes: Set<String> = ["BadDigest", "XAmzContentSHA256Mismatch", "InvalidDigest"]

    /// Maps a failed response. `body` is the response body (an S3 `<Error>` document or nothing);
    /// `secret` is scrubbed from any message kept.
    static func from(status: Int, body: Data, bucket: String, key: String?, secret: String) -> S3Error {
        let service = S3XML.serviceError(from: body)
        return from(status: status, code: service?.code, message: service?.message, bucket: bucket, key: key,
                    secret: secret)
    }

    static func from(status: Int, code: String?, message: String?, bucket: String, key: String?,
                     secret: String) -> S3Error {
        let message = message.map { secret.isEmpty ? $0 : $0.replacingOccurrences(of: secret, with: "<redacted>") }
        if let code {
            if clockSkewCodes.contains(code) { return .authenticationFailed(code: code, clockSkewed: true) }
            if authenticationCodes.contains(code) { return .authenticationFailed(code: code, clockSkewed: false) }
            if code == "NoSuchBucket" { return .bucketNotFound(bucket: bucket) }
            if accessCodes.contains(code) { return .accessDenied(code: code) }
            if code == "NoSuchKey" { return .objectNotFound(key: key ?? "") }
            if limitCodes.contains(code) { return .storageLimit(code: code) }
            if checksumCodes.contains(code) { return .checksumMismatch(key: key ?? "") }
            return .unexpectedResponse(status: status, code: code, message: message)
        }
        switch status {
        case 401: return .authenticationFailed(code: "HTTP 401", clockSkewed: false)
        case 403: return .accessDenied(code: "HTTP 403")
        case 507: return .storageLimit(code: "HTTP 507")
        default: return .unexpectedResponse(status: status, code: nil, message: message)
        }
    }

    /// A transport error from `URLSession`, or `CancellationError` for a cancelled task.
    static func from(transport error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CancellationError() : S3Error.noNetwork(urlErrorCode: urlError.code.rawValue)
        }
        if let s3Error = error as? S3Error { return s3Error }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorCancelled ? CancellationError() : S3Error.noNetwork(urlErrorCode: nsError.code)
        }
        return error
    }
}
