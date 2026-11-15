import Foundation
import ReaderBackup

/// What iCloud reports about one item (`URLResourceValues`' ubiquitous-item keys).
nonisolated struct BackupUbiquitousItemStatus: Sendable {
    /// A local copy exists (`ubiquitousItemDownloadingStatus` is `.current` or `.downloaded`).
    var isDownloaded: Bool
    var isDownloading: Bool
    /// Why the last download failed, if it did (`ubiquitousItemDownloadingError`).
    var downloadingError: (any Error)?
    var isUploaded: Bool
    var isUploading: Bool
    /// Why the last upload failed, if it did (`ubiquitousItemUploadingError`).
    var uploadingError: (any Error)?

    init(isDownloaded: Bool, isDownloading: Bool = false, downloadingError: (any Error)? = nil,
         isUploaded: Bool = true, isUploading: Bool = false, uploadingError: (any Error)? = nil) {
        self.isDownloaded = isDownloaded
        self.isDownloading = isDownloading
        self.downloadingError = downloadingError
        self.isUploaded = isUploaded
        self.isUploading = isUploading
        self.uploadingError = uploadingError
    }
}

/// Asks iCloud about items and for downloads. Injected so tests can stand in for iCloud.
nonisolated protocol BackupUbiquitousItemControl: Sendable {
    /// The item's iCloud state, or `nil` when it is not an iCloud item (a local folder, or one
    /// the system cannot describe). `url` is the item's own name, never a placeholder's.
    func status(of url: URL) -> BackupUbiquitousItemStatus?
    /// `FileManager.startDownloadingUbiquitousItem(at:)`.
    func startDownloading(_ url: URL) throws
}

/// The system: `URL.resourceValues` and `FileManager.startDownloadingUbiquitousItem(at:)`.
nonisolated struct SystemUbiquitousItemControl: BackupUbiquitousItemControl {
    init() {}

    func status(of url: URL) -> BackupUbiquitousItemStatus? {
        // A fresh URL each time: resource values are cached on the URL object.
        let fresh = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadingErrorKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemUploadingErrorKey
        ]
        guard let values = try? fresh.resourceValues(forKeys: keys), values.isUbiquitousItem == true else { return nil }
        let downloaded = values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded
        return BackupUbiquitousItemStatus(
            isDownloaded: downloaded,
            isDownloading: values.ubiquitousItemIsDownloading ?? false,
            downloadingError: values.ubiquitousItemDownloadingError,
            isUploaded: values.ubiquitousItemIsUploaded ?? false,
            isUploading: values.ubiquitousItemIsUploading ?? false,
            uploadingError: values.ubiquitousItemUploadingError)
    }

    func startDownloading(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}

/// iCloud's placeholder files for items that are not downloaded: `.<name>.icloud`, a small
/// property list holding the item's name (`NSURLNameKey`) and size (`NSURLFileSizeKey`).
///
/// Which form a not-downloaded item takes is not stated in Apple's documentation for iOS: the
/// ubiquity container has historically used these placeholders, and iCloud Drive on File Provider
/// (macOS 14 and later) uses "dataless" files under the real name instead, which a directory
/// listing already shows with their full size. The destinations handle both: real names come
/// from the folder listing, placeholders are mapped back to the names they stand for.
nonisolated enum BackupICloudPlaceholder {
    static let suffix = ".icloud"

    /// `.<name>.icloud`
    static func placeholderName(for name: String) -> String { ".\(name)\(suffix)" }

    /// The name a placeholder stands for, or `nil` when `fileName` is not a placeholder name.
    static func itemName(forPlaceholder fileName: String) -> String? {
        guard fileName.hasPrefix("."), fileName.hasSuffix(suffix), fileName.count > 1 + suffix.count else { return nil }
        let name = String(fileName.dropFirst().dropLast(suffix.count))
        return name.isEmpty || name.hasPrefix(".") ? nil : name
    }

    /// The placeholder beside `url` for the item `url` names.
    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(placeholderName(for: url.lastPathComponent), isDirectory: false)
    }

    /// The size recorded in the placeholder at `url`, or `nil` when it is not a readable
    /// placeholder.
    static func recordedSize(at url: URL) -> Int64? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let size = plist["NSURLFileSizeKey"] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// A placeholder's contents, as iCloud writes them (for tests that simulate one).
    static func contents(name: String, size: Int64) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "NSURLNameKey": name,
            "NSURLFileSizeKey": NSNumber(value: size),
            "NSURLFileResourceTypeKey": URLFileResourceType.regular.rawValue
        ] as [String: Any], format: .binary, options: 0)
    }
}

/// How long to wait for iCloud to download an item before reading it.
nonisolated struct BackupDownloadWaitPolicy: Sendable {
    /// Time between status checks.
    var pollInterval: Duration
    /// The download must have started (or finished) by then; otherwise the device is taken to be
    /// offline.
    var startTimeout: Duration
    /// The download must have finished by then.
    var timeout: Duration
    /// Waits `pollInterval`; tests pass one that returns at once, so elapsed time is counted in
    /// polls, not read from a clock.
    var sleep: @Sendable (Duration) async throws -> Void

    init(pollInterval: Duration = .milliseconds(500), startTimeout: Duration = .seconds(60), timeout: Duration = .seconds(30 * 60),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.pollInterval = pollInterval
        self.startTimeout = startTimeout
        self.timeout = timeout
        self.sleep = sleep
    }

    static let standard = BackupDownloadWaitPolicy()
}

/// Whether a snapshot has reached iCloud (or the Files provider behind a picked folder).
nonisolated enum BackupUploadState: Hashable, Sendable {
    /// The provider reports the item uploaded.
    case uploaded
    /// The provider is uploading it now.
    case uploading
    /// The provider has not started uploading it yet.
    case waiting
    /// The last upload attempt failed; `reason` is reader-facing.
    case failed(reason: String)
    /// The item is not an iCloud item (a local folder), or is no longer there.
    case notTracked
}

/// Reader-facing download failures (all `BackupError.destinationUnavailable`, which is what they
/// mean to the engine: the destination cannot supply the item now).
nonisolated enum BackupDownloadFailure {
    static func notStarted(_ name: String) -> BackupError {
        .destinationUnavailable(reason: "“\(name)” is in iCloud but isn’t downloaded to this iPad, and the download didn’t start. Check that this iPad is connected to the internet, then try again.")
    }

    static func timedOut(_ name: String) -> BackupError {
        .destinationUnavailable(reason: "Downloading “\(name)” from iCloud is taking too long. Check the internet connection, then try again.")
    }

    static func failed(_ name: String) -> BackupError {
        .destinationUnavailable(reason: "“\(name)” couldn’t be downloaded from iCloud. Check that this iPad is connected to the internet, then try again.")
    }
}
