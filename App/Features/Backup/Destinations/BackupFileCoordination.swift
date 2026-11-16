import FileProvider
import Foundation
import ReaderBackup

/// How one access of a file or folder at a backup destination is coordinated.
nonisolated enum BackupFileCoordination: Hashable, Sendable {
    /// Reads a file's contents or lists a folder. For an iCloud or File Provider item that is not
    /// on the device yet, a coordinated read waits for it to download (Apple: "If the device has
    /// not yet downloaded the file at the given URL, this method blocks (potentially for a long
    /// time)"), which is why downloads are requested and awaited first
    /// (`CoordinatedBackupFolder.ensureDownloaded`).
    case reading
    /// Inspects an item's immediately available metadata (existence, size) without its contents
    /// (`.immediatelyAvailableMetadataOnly`): granted without waiting for a download.
    case readingMetadataOnly
    /// Creates a folder (no options).
    case writing
    /// Creates or replaces a file (`.forReplacing`).
    case writingForReplacing
    /// Deletes an item (`.forDeleting`).
    case deleting
}

/// Runs one file access under file coordination. `body` receives the URL to use (the
/// coordinator may hand back a different one) and runs at most once; when coordination itself
/// fails it does not run and the coordinator's error is thrown, translated
/// (`BackupFileCoordinationError`). Errors thrown by `body` are rethrown unchanged.
///
/// Blocking: a call can wait on other processes and on downloads. Callers run it off the main
/// actor (every destination method is `@concurrent`).
nonisolated protocol BackupFileCoordinating: Sendable {
    func coordinate(_ url: URL, _ kind: BackupFileCoordination, _ body: (URL) throws -> Void) throws
}

/// `NSFileCoordinator`, one new coordinator per access (Apple: "Each file coordinator object you
/// create should be used on a single thread only").
nonisolated struct SystemFileCoordinator: BackupFileCoordinating {
    init() {}

    func coordinate(_ url: URL, _ kind: BackupFileCoordination, _ body: (URL) throws -> Void) throws {
        try withoutActuallyEscaping(body) { body in
            try coordinate(url, kind, escapingBody: body)
        }
    }

    private func coordinate(_ url: URL, _ kind: BackupFileCoordination, escapingBody body: @escaping (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var bodyError: (any Error)?
        var ran = false
        let accessor: (URL) -> Void = { granted in
            ran = true
            do { try body(granted) } catch { bodyError = error }
        }
        switch kind {
        case .reading:
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor)
        case .readingMetadataOnly:
            coordinator.coordinate(readingItemAt: url, options: .immediatelyAvailableMetadataOnly,
                                   error: &coordinationError, byAccessor: accessor)
        case .writing:
            coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor)
        case .writingForReplacing:
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError, byAccessor: accessor)
        case .deleting:
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError, byAccessor: accessor)
        }
        if let bodyError { throw bodyError }
        if let coordinationError { throw BackupFileCoordinationError.translate(coordinationError, url: url) }
        if !ran { throw BackupError.fileAccessFailed(name: url.lastPathComponent, code: Int(EIO)) }
    }
}

/// Translates errors from file coordination and from Foundation file calls into the
/// `BackupError` cases the engine shows, keeping the original code where there is no closer case.
nonisolated enum BackupFileCoordinationError {
    /// Shown when iCloud or a Files provider cannot be reached for an item.
    static func offlineReason(_ name: String) -> String {
        "“\(name)” can’t be reached right now. Check that this iPad is connected to the internet, then try again."
    }

    /// `BackupError` and `CancellationError` pass through; a coordination that was cancelled
    /// because the app was suspended (`NSUserCancelledError`) becomes `CancellationError`, which
    /// the engine treats as "stopped", not failed.
    static func translate(_ error: any Error, url: URL) -> any Error {
        if error is BackupError || error is CancellationError { return error }
        let name = url.lastPathComponent
        let ns = error as NSError
        switch ns.domain {
        case NSCocoaErrorDomain:
            switch ns.code {
            case NSUserCancelledError:
                return CancellationError()
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return BackupError.fileNotFound(name: name)
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
                return BackupError.permissionDenied(name: name)
            case NSFileWriteOutOfSpaceError:
                return BackupError.notEnoughSpace
            case NSUbiquitousFileUnavailableError, NSUbiquitousFileUbiquityServerNotAvailable:
                return BackupError.destinationUnavailable(reason: offlineReason(name))
            case NSUbiquitousFileNotUploadedDueToQuotaError:
                return BackupError.destinationUnavailable(
                    reason: "Your iCloud storage is full, so “\(name)” can’t be uploaded. Free up iCloud storage and try again.")
            default:
                if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                    return posix(Int32(underlying.code), name: name)
                }
                return BackupError.fileAccessFailed(name: name, code: ns.code)
            }
        case NSFileProviderErrorDomain:
            switch NSFileProviderError.Code(rawValue: ns.code) {
            case .notAuthenticated?:
                return BackupError.destinationUnavailable(
                    reason: "The app that stores “\(name)” needs you to sign in. Open it, sign in, then try again.")
            case .serverUnreachable?:
                return BackupError.destinationUnavailable(reason: offlineReason(name))
            case .insufficientQuota?:
                return BackupError.notEnoughSpace
            case .noSuchItem?:
                return BackupError.fileNotFound(name: name)
            default:
                return BackupError.fileAccessFailed(name: name, code: ns.code)
            }
        case NSPOSIXErrorDomain:
            return posix(Int32(ns.code), name: name)
        default:
            return BackupError.fileAccessFailed(name: name, code: ns.code)
        }
    }

    static func posix(_ code: Int32, name: String) -> BackupError {
        switch code {
        case ENOENT, ENOTDIR: .fileNotFound(name: name)
        case EACCES, EPERM, EROFS: .permissionDenied(name: name)
        case ENOSPC, EDQUOT: .notEnoughSpace
        default: .fileAccessFailed(name: name, code: Int(code))
        }
    }

    /// Runs a Foundation file call, translating what it throws.
    static func mapping<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw translate(error, url: url) }
    }
}
