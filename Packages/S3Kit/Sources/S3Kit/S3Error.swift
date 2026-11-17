import Foundation

/// Everything S3Kit throws, apart from `CancellationError` when the calling task is cancelled
/// and whatever an `S3CredentialsProvider` throws, which is passed through unchanged.
///
/// Messages are plain language for the person using the app; the service's own error code,
/// message and HTTP status are kept in the associated values for diagnostics. No case ever holds
/// the secret access key or a session token (service messages are scrubbed of both before they
/// are stored).
///
/// Two outcomes of temporary credentials have their own reserved codes on existing cases (so
/// code that switches over every case keeps compiling), each with its own message:
/// `authenticationFailed(code: S3Error.temporaryCredentialsRejectedCode, …)` and
/// `accessDenied(code: S3Error.notAllowedByCredentialsCode)`; test for them with
/// `isTemporaryCredentialsRejected` and `isNotAllowedByCredentials`.
///
/// Two outcomes of the conditional and in-memory operations are reserved values of
/// `unexpectedResponse`, for the same reason: `S3Error.preconditionFailed` (HTTP 412 on a
/// conditional put; test with `isPreconditionFailed` or compare with `==`) and a small-object read
/// that is larger than the caller allowed (`objectTooLargeCode`; test with `isObjectTooLarge`).
public enum S3Error: Error, LocalizedError, Sendable, Equatable {
    /// The service rejected the access key or the request signature (`SignatureDoesNotMatch`,
    /// `InvalidAccessKeyId`, `AuthorizationHeaderMalformed`, R2's `Unauthorized`, ...).
    /// `clockSkewed` is true when it said the request time was too far from its own
    /// (`RequestTimeTooSkewed`, `RequestExpired`, R2's `ExpiredRequest`).
    ///
    /// With `temporaryCredentialsRejectedCode`: the service said the session token had expired
    /// or was invalid, fresh credentials were fetched, and it rejected those too.
    case authenticationFailed(code: String, clockSkewed: Bool)
    /// `NoSuchBucket`.
    case bucketNotFound(bucket: String)
    /// `AccessDenied` (or a bare 403): the key is valid but lacks permission for this bucket or object.
    ///
    /// With `notAllowedByCredentialsCode`: the request was made with temporary credentials, which
    /// don't cover this key or this action (outside their prefix, or a read-only credential
    /// asked to write). Not retried.
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
        case .authenticationFailed(Self.temporaryCredentialsRejectedCode, _):
            return "The storage service didn't accept this device's access, even after it was renewed. "
                + "Try again in a few minutes."
        case .accessDenied(Self.notAllowedByCredentialsCode):
            return "The storage service didn't allow this: the access this device was given doesn't cover this "
                + "file or this change. The backup may be read-only at the moment."
        case .unexpectedResponse(412, Self.preconditionFailedCode, _):
            return "Someone else changed the file in the storage bucket first. Try again."
        case .unexpectedResponse(_, Self.objectTooLargeCode, _):
            return "The file in the storage bucket is larger than expected, so it wasn't read."
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

    /// The code of `authenticationFailed` when temporary credentials were rejected again after
    /// being refreshed.
    public static let temporaryCredentialsRejectedCode = "TemporaryCredentialsRejected"
    /// The code of `accessDenied` when temporary credentials don't allow the key or the action.
    public static let notAllowedByCredentialsCode = "NotAllowedByCredentials"

    /// The code of `unexpectedResponse` for a conditional put the service refused with HTTP 412
    /// (`If-Match` named an ETag that is no longer the object's, or `If-None-Match: *` found an
    /// object already there).
    public static let preconditionFailedCode = "PreconditionFailed"
    /// What a conditional put refused with HTTP 412 throws, always exactly this value (the
    /// service's message is not kept), so callers can match it with `==` or `isPreconditionFailed`.
    public static let preconditionFailed = S3Error.unexpectedResponse(status: 412, code: preconditionFailedCode,
                                                                     message: nil)
    /// The code of `unexpectedResponse` (status 200) when a small-object read found more bytes
    /// than the caller's limit.
    public static let objectTooLargeCode = "ObjectTooLarge"

    /// A conditional put was refused because its condition did not hold (HTTP 412).
    public var isPreconditionFailed: Bool {
        if case .unexpectedResponse(412, Self.preconditionFailedCode, _) = self { return true }
        return false
    }

    /// A small-object read found more bytes than the caller's limit.
    public var isObjectTooLarge: Bool {
        if case .unexpectedResponse(_, Self.objectTooLargeCode, _) = self { return true }
        return false
    }

    /// Temporary credentials were rejected as expired or invalid, and so were fresh ones.
    public var isTemporaryCredentialsRejected: Bool {
        if case .authenticationFailed(Self.temporaryCredentialsRejectedCode, _) = self { return true }
        return false
    }

    /// Temporary credentials don't allow this key or action (for example, they are read-only).
    public var isNotAllowedByCredentials: Bool {
        if case .accessDenied(Self.notAllowedByCredentialsCode) = self { return true }
        return false
    }

    /// The service codes that, for a request carrying a session token, mean "the credentials may
    /// have expired or be invalid": refresh and retry once.
    /// - From the documentation: R2's `Unauthorized` (HTTP 401, "Missing or invalid
    ///   authentication credentials", whose documented fix includes checking they "have not
    ///   expired"), and Amazon S3's `ExpiredToken` and `InvalidToken` (HTTP 400).
    /// - Measured, not documented: on a real R2 bucket (15 November 2026) a request signed with a
    ///   temporary credential whose JWT `exp` had passed was refused with HTTP 403
    ///   `SignatureDoesNotMatch`. With a long-lived key it keeps meaning a wrong key or signature.
    /// A bodiless 401 (a HEAD response) counts too; a bodiless 403 is ambiguous (see `S3Client`).
    static let sessionTokenRejectedCodes: Set<String> = ["Unauthorized", "ExpiredToken", "InvalidToken",
                                                         "SignatureDoesNotMatch"]
    /// The codes that, for a request carrying a session token, mean "not allowed for this key or
    /// action": R2's `AccessDenied` (HTTP 403), which its temporary-credentials example shows for
    /// a key outside the credential's prefix (and which a real bucket returned for keys outside
    /// the prefix and actions outside the allowed ones). Never retried.
    static let notAllowedCodes: Set<String> = ["AccessDenied"]

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
        from(status: status, code: code, message: message, bucket: bucket, key: key, redacting: [secret])
    }

    /// `redacting`: every value (secret, session token) to scrub from a message kept.
    static func from(status: Int, code: String?, message: String?, bucket: String, key: String?,
                     redacting: [String]) -> S3Error {
        let message = message.map { message in
            redacting.filter { !$0.isEmpty }.reduce(message) { $0.replacingOccurrences(of: $1, with: "<redacted>") }
        }
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
