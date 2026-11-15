import Foundation
import GoogleDriveKit
import ReaderBackup
import S3Kit

/// Failures of the cloud backup destinations (Google Drive, S3-compatible storage) that
/// `BackupError` has no case for. `errorDescription` is reader-facing and can be shown as is.
///
/// The destinations throw:
/// - `CancellationError` when the calling task is cancelled;
/// - `BackupError` for what every destination shares (a snapshot or PDF that is not there,
///   content that does not match its hash, an invalid snapshot name, local file failures);
/// - `CloudBackupError` for the rest: signing in, the account's storage, the network, the
///   service's configuration. The cases the UI acts on differently stay distinct:
///   `needsSignInAgain` (offer Sign In), `storageFull` (free up space), `noNetwork` (try later).
///
/// No case holds a token, key or secret: `diagnostic` carries only HTTP statuses and the
/// service's error codes (for logs), never a message body.
nonisolated enum CloudBackupError: LocalizedError, Hashable, Sendable {
    /// This build has no credentials for the service (`destination` is its display name).
    case notSetUp(destination: String)
    /// No Google account is connected.
    case notSignedIn
    /// Google no longer accepts the saved sign-in; the reader must sign in again.
    case needsSignInAgain
    /// Google's sign-in could not be completed (a bad redirect, a state mismatch, a refused code).
    case signInFailed
    /// The reader signed in but did not allow access to the files this app creates.
    case driveAccessNotGranted
    /// The account or bucket has no room left (or hit a quota).
    case storageFull(destination: String)
    /// The service could not be reached.
    case noNetwork(destination: String)
    /// The service asked the app to slow down and kept doing so.
    case busy(destination: String)
    /// The storage service rejected the build's credentials.
    case credentialsRejected(destination: String)
    /// The storage service rejected the request because the device clock is wrong.
    case clockWrong(destination: String)
    /// The credentials are valid but not allowed to use the bucket.
    case accessDenied(destination: String)
    /// The bucket the build names does not exist.
    case bucketNotFound(destination: String)
    /// The service answered in a way the app does not handle. `diagnostic` is for logs (an HTTP
    /// status and the service's error code), not shown to the reader.
    case serviceError(destination: String, diagnostic: String?)

    var errorDescription: String? {
        switch self {
        case .notSetUp(let destination):
            "\(destination) isn’t set up in this build of Tactile Texts."
        case .notSignedIn:
            "Sign in to Google Drive to back up there."
        case .needsSignInAgain:
            "Google Drive needs you to sign in again."
        case .signInFailed:
            "Google sign-in didn’t finish. Try signing in again."
        case .driveAccessNotGranted:
            "Tactile Texts wasn’t allowed to use Google Drive. Sign in again and allow access to the files Tactile Texts creates."
        case .storageFull(let destination):
            "There isn’t enough space in \(destination). Free up space or add storage, then try again."
        case .noNetwork(let destination):
            "Couldn’t reach \(destination). Check your internet connection and try again."
        case .busy(let destination):
            "\(destination) is busy right now. Try again in a few minutes."
        case .credentialsRejected(let destination):
            "\(destination) didn’t accept the credentials this build of Tactile Texts was made with."
        case .clockWrong(let destination):
            "\(destination) refused the request because this iPad’s clock is wrong. Turn on Set Automatically in Settings > General > Date & Time, then try again."
        case .accessDenied(let destination):
            "\(destination) didn’t allow Tactile Texts to read and write its backups."
        case .bucketNotFound(let destination):
            "The storage that this build of Tactile Texts uses for \(destination) doesn’t exist."
        case .serviceError(let destination, _):
            "\(destination) gave an unexpected response. Try again later."
        }
    }

    /// `true` for the cases the reader fixes by signing in to Google again.
    var needsSignIn: Bool {
        switch self {
        case .notSignedIn, .needsSignInAgain, .driveAccessNotGranted, .signInFailed: true
        default: false
        }
    }
}

// MARK: - Mapping

/// What a failed destination call was about, so "not found" becomes the right `BackupError`.
nonisolated enum CloudErrorSubject: Sendable {
    case snapshot(name: String)
    case pdf(sha256: String)
    case other

    var fileName: String {
        switch self {
        case .snapshot(let name): name
        case .pdf(let sha256): BackupFolderLayout.pdfFileName(sha256: sha256)
        case .other: ""
        }
    }
}

nonisolated extension CloudBackupError {
    /// Maps anything a Google Drive call threw. `BackupError`, `CloudBackupError` and
    /// `CancellationError` pass through.
    static func mapping(google error: any Error, subject: CloudErrorSubject) -> any Error {
        let destination = GoogleDriveBackupDestination.name
        guard let drive = error as? GoogleDriveError else { return mapping(other: error, subject: subject) }
        switch drive {
        case .notSignedIn: return CloudBackupError.notSignedIn
        case .needsSignInAgain: return CloudBackupError.needsSignInAgain
        case .signInCancelled, .signInFailed: return CloudBackupError.signInFailed
        case .driveAccessNotGranted: return CloudBackupError.driveAccessNotGranted
        case .noNetwork: return CloudBackupError.noNetwork(destination: destination)
        case .storageFull: return CloudBackupError.storageFull(destination: destination)
        case .rateLimited: return CloudBackupError.busy(destination: destination)
        case .notFound: return notFound(subject, destination: destination)
        case .checksumMismatch: return BackupError.contentMismatch(name: subject.fileName)
        case .unexpectedResponse(let status, let reason):
            return CloudBackupError.serviceError(destination: destination,
                                                 diagnostic: diagnostic(status: status, code: reason))
        }
    }

    /// Maps anything an S3 call threw, for the destination named `destination`.
    static func mapping(s3 error: any Error, subject: CloudErrorSubject, destination: String) -> any Error {
        guard let s3 = error as? S3Error else { return mapping(other: error, subject: subject) }
        switch s3 {
        case .authenticationFailed(_, let clockSkewed):
            return clockSkewed ? CloudBackupError.clockWrong(destination: destination)
                : CloudBackupError.credentialsRejected(destination: destination)
        case .bucketNotFound: return CloudBackupError.bucketNotFound(destination: destination)
        case .accessDenied: return CloudBackupError.accessDenied(destination: destination)
        case .objectNotFound: return notFound(subject, destination: destination)
        case .noNetwork: return CloudBackupError.noNetwork(destination: destination)
        case .storageLimit: return CloudBackupError.storageFull(destination: destination)
        case .checksumMismatch, .sizeMismatch: return BackupError.contentMismatch(name: subject.fileName)
        case .invalidKey:
            if case .snapshot(let name) = subject { return BackupError.invalidSnapshotName(name: name) }
            return CloudBackupError.serviceError(destination: destination, diagnostic: "invalid key")
        case .invalidMetadata:
            return CloudBackupError.serviceError(destination: destination, diagnostic: "invalid metadata")
        case .fileAccess(let path, _):
            return BackupError.fileAccessFailed(name: URL(fileURLWithPath: path).lastPathComponent, code: Int(EIO))
        case .unexpectedResponse(let status, let code, _):
            // The service's message is left out: it is free text from the server.
            return CloudBackupError.serviceError(destination: destination, diagnostic: diagnostic(status: status, code: code))
        }
    }

    private static func notFound(_ subject: CloudErrorSubject, destination: String) -> any Error {
        switch subject {
        case .snapshot(let name): BackupError.snapshotNotFound(name: name)
        case .pdf(let sha256): BackupError.pdfNotAtDestination(sha256: sha256)
        case .other: CloudBackupError.serviceError(destination: destination, diagnostic: "not found")
        }
    }

    /// Local file errors (from reading the upload source or writing the download target).
    private static func mapping(other error: any Error, subject: CloudErrorSubject) -> any Error {
        if error is BackupError || error is CloudBackupError || error is CancellationError { return error }
        let name = subject.fileName
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileNoSuchFile, .fileReadNoSuchFile: return BackupError.fileNotFound(name: name)
            case .fileReadNoPermission, .fileWriteNoPermission, .fileWriteVolumeReadOnly:
                return BackupError.permissionDenied(name: name)
            case .fileWriteOutOfSpace: return BackupError.notEnoughSpace
            default: return BackupError.fileAccessFailed(name: name, code: cocoa.code.rawValue)
            }
        }
        if let posix = error as? POSIXError {
            return posix.code == .ENOSPC ? BackupError.notEnoughSpace
                : BackupError.fileAccessFailed(name: name, code: Int(posix.code.rawValue))
        }
        return BackupError.fileAccessFailed(name: name, code: (error as NSError).code)
    }

    private static func diagnostic(status: Int?, code: String?) -> String? {
        switch (status, code) {
        case let (status?, code?): "HTTP \(status) \(code)"
        case let (status?, nil): "HTTP \(status)"
        case let (nil, code?): code
        case (nil, nil): nil
        }
    }
}
