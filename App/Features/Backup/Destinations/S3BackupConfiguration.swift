import Foundation
import S3Kit

/// The S3-compatible bucket this build backs up to, read from the `S3Backup` dictionary in
/// `Info.plist` (filled from `S3_BACKUP_*` in `Config/Local.xcconfig`).
///
/// **The keys are build-time secrets and readable by anyone holding the built app** (see
/// `Config/Signing.xcconfig`); use a token limited to object read and write on one bucket and
/// never distribute a build configured this way. `description`, `debugDescription` and the
/// mirror never show the secret access key.
nonisolated struct S3BackupConfiguration: Hashable, Sendable {
    static let infoKey = "S3Backup"
    static let defaultDisplayName = "S3 Storage"

    let s3: S3Configuration
    /// The name shown in the destination list (`S3_BACKUP_NAME`, default "S3 Storage").
    let displayName: String

    init(s3: S3Configuration, displayName: String? = nil) {
        self.s3 = s3
        let name = displayName.flatMap(Self.setting) ?? ""
        self.displayName = name.isEmpty ? Self.defaultDisplayName : name
    }

    /// The configuration, or `nil` unless host, region, bucket and both keys are all set. A value
    /// that is missing, empty, not a string, or an unexpanded build setting such as
    /// `$(S3_BACKUP_HOST)` counts as not set.
    static func fromInfoDictionary(_ infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> S3BackupConfiguration? {
        guard let values = infoDictionary?[infoKey] as? [String: Any] else { return nil }
        func value(_ key: String) -> String { (values[key] as? String).flatMap(setting) ?? "" }
        guard let s3 = S3Configuration(host: value("Host"), region: value("Region"), bucket: value("Bucket"),
                                       accessKeyID: value("AccessKeyID"), secretAccessKey: value("SecretAccessKey"),
                                       prefix: value("Prefix")) else { return nil }
        return S3BackupConfiguration(s3: s3, displayName: value("DisplayName"))
    }

    /// `raw` trimmed, or `nil` when it is empty or still holds a `$(…)` build-setting reference.
    private static func setting(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }
}

nonisolated extension S3BackupConfiguration: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// `S3Configuration`'s own redacted description, plus the display name.
    var description: String { "S3BackupConfiguration(\(s3.description), displayName: \(displayName))" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["s3": s3, "displayName": displayName], displayStyle: .struct)
    }
}
