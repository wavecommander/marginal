import Foundation

/// A Drive file or folder's metadata (the subset this package requests with `fields`).
public struct GoogleDriveFile: Sendable, Hashable, Decodable {
    public static let folderMimeType = "application/vnd.google-apps.folder"
    /// The `fields` selector for one file.
    static let fields = "id,name,mimeType,size,md5Checksum,sha256Checksum,parents,appProperties,trashed,createdTime,modifiedTime"

    public let id: String
    public let name: String
    public let mimeType: String?
    /// Bytes of content; `nil` for folders.
    public let size: Int64?
    /// Lowercase hex; only for files with binary content stored in Drive.
    public let md5Checksum: String?
    /// Lowercase hex; only for files with binary content stored in Drive.
    public let sha256Checksum: String?
    public let parents: [String]
    /// Private key-value pairs visible only to this app.
    public let appProperties: [String: String]
    public let trashed: Bool
    public let createdTime: Date?
    public let modifiedTime: Date?

    public var isFolder: Bool { mimeType == Self.folderMimeType }

    public init(id: String, name: String, mimeType: String? = nil, size: Int64? = nil, md5Checksum: String? = nil,
                sha256Checksum: String? = nil, parents: [String] = [], appProperties: [String: String] = [:],
                trashed: Bool = false, createdTime: Date? = nil, modifiedTime: Date? = nil) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.md5Checksum = md5Checksum
        self.sha256Checksum = sha256Checksum
        self.parents = parents
        self.appProperties = appProperties
        self.trashed = trashed
        self.createdTime = createdTime
        self.modifiedTime = modifiedTime
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mimeType, size, md5Checksum, sha256Checksum, parents, appProperties, trashed, createdTime, modifiedTime
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        // Drive sends int64 values as JSON strings.
        size = try c.decodeIfPresent(String.self, forKey: .size).flatMap { Int64($0) }
        md5Checksum = try c.decodeIfPresent(String.self, forKey: .md5Checksum)
        sha256Checksum = try c.decodeIfPresent(String.self, forKey: .sha256Checksum)
        parents = try c.decodeIfPresent([String].self, forKey: .parents) ?? []
        appProperties = try c.decodeIfPresent([String: String].self, forKey: .appProperties) ?? [:]
        trashed = try c.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
        createdTime = try c.decodeIfPresent(String.self, forKey: .createdTime).flatMap(Self.date)
        modifiedTime = try c.decodeIfPresent(String.self, forKey: .modifiedTime).flatMap(Self.date)
    }

    /// RFC 3339, with or without fractional seconds.
    static func date(_ string: String) -> Date? {
        (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: Date.ISO8601FormatStyle()))
    }
}

/// One page of a folder listing.
public struct GoogleDriveFilePage: Sendable, Hashable {
    public let files: [GoogleDriveFile]
    /// Pass to the next call; `nil` on the last page.
    public let nextPageToken: String?

    public init(files: [GoogleDriveFile], nextPageToken: String?) {
        self.files = files
        self.nextPageToken = nextPageToken
    }
}

/// Bytes transferred so far.
public struct GoogleTransferProgress: Sendable, Hashable {
    public let completedBytes: Int64
    public let totalBytes: Int64

    public init(completedBytes: Int64, totalBytes: Int64) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double {
        totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1
    }
}

public typealias GoogleTransferProgressHandler = @Sendable (GoogleTransferProgress) -> Void
