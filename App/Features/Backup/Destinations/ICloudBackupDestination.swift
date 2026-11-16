import Foundation
import MachO
import ReaderBackup

/// Backups in the app's own iCloud container, at `<container>/Documents` (which Files shows as
/// "Tactile Texts"), in the folder layout, through the same coordinated access as the picked
/// folder (`CoordinatedBackupFolder`), including items that are in iCloud but not downloaded.
///
/// The container needs the iCloud entitlement, which builds only have once a paid developer
/// team exists (`TACTILE_ENTITLEMENTS`); until then this destination reports itself
/// unavailable. The container lookup (`FileManager.url(forUbiquityContainerIdentifier:)`, which
/// Apple says must not run on the main thread) is injected, so tests use a temporary directory.
///
/// Telling "no entitlement" from "not signed in": neither `ubiquityIdentityToken` ("nil if iCloud
/// is unavailable or there is no logged-in user") nor the container lookup says which. The reason
/// shown is therefore chosen with `ICloudEntitlementProbe`, which looks at what the build was
/// signed with; the probe only picks the wording, never availability itself.
nonisolated struct ICloudBackupDestination: BackupDestination {
    static let destinationID = "icloud"
    static let containerIdentifier = "iCloud.software.tactile.texts"
    /// Folder inside the container that Files shows.
    static let documentsDirectory = "Documents"

    enum Reason {
        static let notInBuild = "iCloud isn’t available in this build."
        static let notSignedIn = "Sign in to iCloud and turn on iCloud Drive in Settings to back up to iCloud."
        static let containerUnavailable = "iCloud isn’t available right now. Check that iCloud Drive is turned on for Tactile Texts in Settings, then try again."
        static let unknown = "iCloud isn’t available. Check that this iPad is signed in to iCloud with iCloud Drive turned on in Settings."
    }

    private let containerURL: @Sendable () async -> URL?
    private let isSignedIn: @Sendable () -> Bool
    private let buildHasICloud: @Sendable () -> Bool?
    private let coordinator: any BackupFileCoordinating
    private let ubiquity: any BackupUbiquitousItemControl
    private let downloadWait: BackupDownloadWaitPolicy

    /// - Parameters:
    ///   - containerURL: the ubiquity container, or `nil` when iCloud is unavailable; called
    ///     for every operation, off the main actor.
    ///   - isSignedIn: whether an iCloud account is signed in (`ubiquityIdentityToken != nil`).
    ///   - buildHasICloud: whether the build has the container entitlement (`nil`: can't tell).
    init(containerURL: @escaping @Sendable () async -> URL? = { await ICloudBackupDestination.systemContainerURL() },
         isSignedIn: @escaping @Sendable () -> Bool = { FileManager.default.ubiquityIdentityToken != nil },
         buildHasICloud: @escaping @Sendable () -> Bool? = { ICloudEntitlementProbe.hasContainerEntitlement() },
         coordinator: any BackupFileCoordinating = SystemFileCoordinator(),
         ubiquity: any BackupUbiquitousItemControl = SystemUbiquitousItemControl(),
         downloadWait: BackupDownloadWaitPolicy = .standard) {
        self.containerURL = containerURL
        self.isSignedIn = isSignedIn
        self.buildHasICloud = buildHasICloud
        self.coordinator = coordinator
        self.ubiquity = ubiquity
        self.downloadWait = downloadWait
    }

    var id: String { Self.destinationID }
    var displayName: String { "iCloud" }

    /// `FileManager.url(forUbiquityContainerIdentifier:)`, run on the cooperative pool.
    @concurrent
    static func systemContainerURL() async -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)
    }

    @concurrent
    func availability() async -> BackupDestinationAvailability {
        switch await resolveRoot() {
        case .failure(let error): .unavailable(reason: error.localizedDescription)
        case .success(let folder): await folder.availability()
        }
    }

    @concurrent
    func listSnapshots() async throws -> [BackupSnapshotInfo] {
        try await withRoot { try await $0.listSnapshots() }
    }

    @concurrent
    @discardableResult
    func uploadSnapshot(from file: URL, name: String, progress: BackupProgress?) async throws -> BackupSnapshotInfo {
        try await withRoot { try await $0.uploadSnapshot(from: file, name: name, progress: progress) }
    }

    @concurrent
    func downloadSnapshot(_ snapshot: BackupSnapshotInfo, to file: URL, progress: BackupProgress?) async throws {
        try await withRoot { try await $0.downloadSnapshot(snapshot, to: file, progress: progress) }
    }

    @concurrent
    func deleteSnapshot(_ snapshot: BackupSnapshotInfo) async throws {
        try await withRoot { try await $0.deleteSnapshot(snapshot) }
    }

    @concurrent
    func hasPDF(sha256: String, size: Int64) async throws -> Bool {
        try await withRoot { try await $0.hasPDF(sha256: sha256, size: size) }
    }

    @concurrent
    func uploadPDF(from file: URL, sha256: String, size: Int64, progress: BackupProgress?) async throws {
        try await withRoot { try await $0.uploadPDF(from: file, sha256: sha256, size: size, progress: progress) }
    }

    @concurrent
    func downloadPDF(sha256: String, to file: URL, progress: BackupProgress?) async throws {
        try await withRoot { try await $0.downloadPDF(sha256: sha256, to: file, progress: progress) }
    }

    /// Whether `snapshot` has finished uploading to iCloud (`ubiquitousItemIsUploaded`).
    @concurrent
    func uploadState(of snapshot: BackupSnapshotInfo) async -> BackupUploadState {
        (try? await withRoot { $0.uploadState(of: snapshot) }) ?? .notTracked
    }

    // MARK: - Internals

    private func withRoot<T>(_ body: (CoordinatedBackupFolder) async throws -> T) async throws -> T {
        switch await resolveRoot() {
        case .failure(let error): throw error
        case .success(let folder): return try await body(folder)
        }
    }

    /// The container's `Documents` folder (created when missing, so it shows in Files), or why
    /// iCloud can't be used.
    private func resolveRoot() async -> Result<CoordinatedBackupFolder, BackupError> {
        let signedIn = isSignedIn()
        let container = signedIn ? await containerURL() : nil
        guard let container else {
            let reason = switch (buildHasICloud(), signedIn) {
            case (false?, _): Reason.notInBuild
            case (true?, false): Reason.notSignedIn
            case (_, true): Reason.containerUnavailable
            case (nil, false): Reason.unknown
            }
            return .failure(.destinationUnavailable(reason: reason))
        }
        let root = container.appendingPathComponent(Self.documentsDirectory, isDirectory: true)
        do {
            try coordinator.coordinate(root, .writing) { granted in
                var isDirectory: ObjCBool = false
                guard !(FileManager.default.fileExists(atPath: granted.path, isDirectory: &isDirectory) && isDirectory.boolValue) else { return }
                try BackupFileCoordinationError.mapping(granted) {
                    try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
                }
            }
        } catch let error as BackupError {
            return .failure(error)
        } catch {
            return .failure(.fileAccessFailed(name: Self.documentsDirectory, code: (error as NSError).code))
        }
        return .success(CoordinatedBackupFolder(root: root, id: id, displayName: displayName, coordinator: coordinator,
                                                ubiquity: ubiquity, downloadWait: downloadWait))
    }
}

/// Whether this build was signed with the iCloud container entitlement, read from what the
/// system installed: on a device, the embedded provisioning profile's `Entitlements`; in the
/// simulator, the entitlements Xcode links into the executable's `__TEXT,__entitlements` section
/// when it signs a simulator build (an unsigned build has none). `nil` when it can't tell (an
/// App Store or TestFlight build has no embedded profile).
nonisolated enum ICloudEntitlementProbe {
    static let containerKey = "com.apple.developer.ubiquity-container-identifiers"

    static func hasContainerEntitlement() -> Bool? {
        #if targetEnvironment(simulator)
        guard let entitlements = simulatorEntitlements() else { return false }
        return lists(entitlements)
        #else
        guard let entitlements = provisioningProfileEntitlements() else { return nil }
        return lists(entitlements)
        #endif
    }

    /// `true` when `entitlements` lists the app's container.
    static func lists(_ entitlements: [String: Any]) -> Bool {
        (entitlements[containerKey] as? [String] ?? []).contains(ICloudBackupDestination.containerIdentifier)
    }

    /// The property list inside a provisioning profile (a signed message that holds it as XML).
    static func profileEntitlements(_ data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["Entitlements"] as? [String: Any]
    }

    private static func provisioningProfileEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return profileEntitlements(data)
    }

    private static func simulatorEntitlements() -> [String: Any]? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var size: UInt = 0
        let bytes = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
            getsectiondata($0, "__TEXT", "__entitlements", &size)
        }
        guard let bytes, size > 0 else { return nil }
        let data = Data(bytes: bytes, count: Int(size))
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
