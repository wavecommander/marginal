import Foundation

/// Where an S3-compatible bucket is and how to sign requests to it.
///
/// The app builds this from its `Info.plist` (`S3Backup`, filled from `Config/Local.xcconfig` at
/// build time). **The credentials are therefore readable by anyone who has the built app**: use
/// a token limited to this one bucket, and do not distribute a build configured this way.
public struct S3Configuration: Hashable, Sendable {
    /// Endpoint host, without a scheme (`<account>.r2.cloudflarestorage.com`,
    /// `s3.eu-west-1.amazonaws.com`). Requests always use HTTPS and path-style addressing
    /// (`https://<host>/<bucket>/<key>`).
    public var host: String
    /// Signing region (`auto` for Cloudflare R2).
    public var region: String
    public var bucket: String
    public var accessKeyID: String
    public var secretAccessKey: String
    /// Key prefix every object is stored under, without leading or trailing slashes; empty for
    /// the bucket root.
    public var prefix: String

    /// `nil` unless host, region, bucket and both keys are non-empty after trimming whitespace
    /// (an unconfigured build leaves them empty). The host must not contain a scheme or a path.
    public init?(host: String, region: String, bucket: String, accessKeyID: String, secretAccessKey: String,
                 prefix: String = "") {
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let host = trimmed(host), region = trimmed(region), bucket = trimmed(bucket)
        let accessKeyID = trimmed(accessKeyID), secretAccessKey = trimmed(secretAccessKey)
        guard !host.isEmpty, !region.isEmpty, !bucket.isEmpty, !accessKeyID.isEmpty, !secretAccessKey.isEmpty,
              !host.contains("/"), !host.contains(" ") else { return nil }
        self.host = host
        self.region = region
        self.bucket = bucket
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.prefix = trimmed(prefix).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

extension S3Configuration: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Every field except the secret access key, which is always shown as `<redacted>`, so a
    /// configuration can be logged or interpolated without leaking it.
    public var description: String {
        "S3Configuration(host: \(host), region: \(region), bucket: \(bucket), accessKeyID: \(accessKeyID), "
            + "secretAccessKey: <redacted>, prefix: \(prefix.isEmpty ? "<none>" : prefix))"
    }

    public var debugDescription: String { description }

    /// `dump(_:)` and debugger summaries go through the mirror, so the secret is redacted there too.
    public var customMirror: Mirror {
        Mirror(self, children: ["host": host, "region": region, "bucket": bucket, "accessKeyID": accessKeyID,
                                "secretAccessKey": "<redacted>", "prefix": prefix], displayStyle: .struct)
    }
}
