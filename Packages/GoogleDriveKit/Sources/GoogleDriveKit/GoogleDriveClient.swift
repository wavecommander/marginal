import Foundation

/// Drive REST v3 calls for a backup destination, under the `drive.file` scope (only files and
/// folders this app created are visible to it).
///
/// Every request carries a fresh access token from ``auth``. A 401 triggers one token refresh and
/// one retry; 429, 5xx, 403 rate-limit reasons and dropped connections are retried with
/// exponential backoff per ``retryPolicy``. Task cancellation throws `CancellationError`.
public struct GoogleDriveClient: Sendable {
    /// The default upload chunk: 8 MiB.
    public static let defaultChunkSize = 8 * 1024 * 1024
    /// Upload chunks must be a multiple of 256 KiB (except the last).
    public static let chunkGranularity = 256 * 1024
    /// The `appProperties` key that tags folders this app created with their role, so lookups
    /// survive the reader renaming them.
    public static let folderRoleKey = "folderRole"

    static let filesEndpoint = "https://www.googleapis.com/drive/v3/files"
    static let uploadEndpoint = "https://www.googleapis.com/upload/drive/v3/files"

    public let auth: GoogleAuthSession
    public let retryPolicy: GoogleRetryPolicy
    let urlSession: URLSession

    public init(auth: GoogleAuthSession, urlSession: URLSession = .shared, retryPolicy: GoogleRetryPolicy = .default) {
        self.auth = auth
        self.urlSession = urlSession
        self.retryPolicy = retryPolicy
    }

    // MARK: - Folders

    /// Finds this app's folder with `role` (tagged in `appProperties`), or creates it.
    ///
    /// - Parameters:
    ///   - name: The display name for a new folder. Lookups ignore it, so a renamed folder is
    ///     still found.
    ///   - role: A stable tag, for example `"root"`, `"backups"`, `"pdfs"`.
    ///   - parentID: The parent folder's ID. `nil` finds the folder anywhere in the reader's Drive
    ///     (so moving it does not matter) and creates it in My Drive.
    /// - Returns: The oldest matching folder that is not in the trash. A trashed folder is ignored
    ///   and a new one is created; when several exist (two devices created one at the same time),
    ///   the oldest wins on every device, and a folder this call just created is removed again if an
    ///   older one turns up.
    public func findOrCreateFolder(named name: String, role: String, inParent parentID: String?) async throws -> GoogleDriveFile {
        var query = "mimeType = \(driveQueryLiteral(GoogleDriveFile.folderMimeType)) and trashed = false"
            + " and appProperties has { key=\(driveQueryLiteral(Self.folderRoleKey)) and value=\(driveQueryLiteral(role)) }"
        if let parentID { query += " and \(driveQueryLiteral(parentID)) in parents" }

        if let existing = Self.oldestFolder(try await allFiles(matching: query)) { return existing }

        struct NewFolder: Encodable {
            let name: String
            let mimeType: String
            let parents: [String]?
            let appProperties: [String: String]
        }
        let body = try JSONEncoder().encode(NewFolder(
            name: name, mimeType: GoogleDriveFile.folderMimeType,
            parents: parentID.map { [$0] }, appProperties: [Self.folderRoleKey: role]))
        let (data, response) = try await authorized { token in
            var request = URLRequest(method: "POST", url: FormEncoding.url(Self.filesEndpoint, [("fields", GoogleDriveFile.fields)]),
                                     accessToken: token)
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        let created: GoogleDriveFile = try Self.decode(data, response)

        // Another device may have created one at the same moment: converge on the oldest.
        if let found = try? await allFiles(matching: query), let oldest = Self.oldestFolder(found), oldest.id != created.id {
            try? await deleteFile(id: created.id)
            return oldest
        }
        return created
    }

    static func oldestFolder(_ files: [GoogleDriveFile]) -> GoogleDriveFile? {
        files.filter { $0.isFolder && !$0.trashed }
            .min { ($0.createdTime ?? .distantFuture, $0.id) < ($1.createdTime ?? .distantFuture, $1.id) }
    }

    // MARK: - Listing and metadata

    /// One page of the files (not in the trash) directly inside a folder, oldest first.
    public func listFilesPage(inFolder folderID: String, pageToken: String? = nil, pageSize: Int = 1000) async throws -> GoogleDriveFilePage {
        try await page(matching: "\(driveQueryLiteral(folderID)) in parents and trashed = false",
                       pageToken: pageToken, pageSize: pageSize)
    }

    /// All files (not in the trash) directly inside a folder, following every page.
    public func listFiles(inFolder folderID: String) async throws -> [GoogleDriveFile] {
        try await allFiles(matching: "\(driveQueryLiteral(folderID)) in parents and trashed = false")
    }

    /// The oldest file (not in the trash) with exactly this name directly inside a folder.
    public func file(named name: String, inFolder folderID: String) async throws -> GoogleDriveFile? {
        let query = "name = \(driveQueryLiteral(name)) and \(driveQueryLiteral(folderID)) in parents and trashed = false"
        return try await page(matching: query, pageToken: nil, pageSize: 10).files.first { !$0.trashed }
    }

    /// A file's metadata by ID. Throws ``GoogleDriveError/notFound`` when it is gone.
    public func file(id: String) async throws -> GoogleDriveFile {
        let url = FormEncoding.url("\(Self.filesEndpoint)/\(FormEncoding.encode(id))", [("fields", GoogleDriveFile.fields)])
        let (data, response) = try await authorized { URLRequest(method: "GET", url: url, accessToken: $0) }
        return try Self.decode(data, response)
    }

    /// Permanently deletes a file this app created (it does not go to the trash).
    public func deleteFile(id: String) async throws {
        let url = URL(string: "\(Self.filesEndpoint)/\(FormEncoding.encode(id))")!
        _ = try await authorized { URLRequest(method: "DELETE", url: url, accessToken: $0) }
    }

    func page(matching query: String, pageToken: String?, pageSize: Int) async throws -> GoogleDriveFilePage {
        var items: [(String, String)] = [
            ("q", query),
            ("fields", "nextPageToken,files(\(GoogleDriveFile.fields))"),
            ("pageSize", String(min(max(pageSize, 1), 1000))),
            ("orderBy", "createdTime"),
        ]
        if let pageToken { items.append(("pageToken", pageToken)) }
        let url = FormEncoding.url(Self.filesEndpoint, items)
        let (data, response) = try await authorized { URLRequest(method: "GET", url: url, accessToken: $0) }
        struct FileList: Decodable {
            let files: [GoogleDriveFile]?
            let nextPageToken: String?
        }
        let list: FileList = try Self.decode(data, response)
        let next = list.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        return GoogleDriveFilePage(files: list.files ?? [], nextPageToken: next)
    }

    func allFiles(matching query: String) async throws -> [GoogleDriveFile] {
        var files: [GoogleDriveFile] = []
        var token: String?
        var seen: Set<String> = []
        repeat {
            let page = try await page(matching: query, pageToken: token, pageSize: 1000)
            files += page.files
            token = page.nextPageToken
            if let token, !seen.insert(token).inserted {
                throw GoogleDriveError.unexpectedResponse(status: 200, reason: "repeated page token")
            }
        } while token != nil
        return files
    }

    // MARK: - Requests

    /// Sends an authorised request with the retry rules above; returns only 2xx responses.
    func authorized(_ makeRequest: (String) throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var failures = 0
        var refreshed = false
        while true {
            try Task.checkCancellation()
            let failure: AttemptFailure
            do {
                let token = try await auth.validAccessToken()
                let (data, response) = try await HTTP.send(try makeRequest(token), on: urlSession)
                if (200...299).contains(response.statusCode) { return (data, response) }
                if response.statusCode == 401, !refreshed {
                    refreshed = true
                    _ = try await auth.accessToken(replacingRejected: token)
                    continue
                }
                failure = HTTP.driveFailure(status: response.statusCode, data: data)
            } catch let attempt as AttemptFailure {
                failure = attempt
            } catch let error as GoogleDriveError where error.isTransient {
                failure = AttemptFailure(error: error, retryable: true)
            }
            failures += 1
            guard failure.retryable, failures < retryPolicy.maxAttempts else { throw failure.error }
            try await retryPolicy.backoff(beforeRetry: failures)
        }
    }

    static func decode<T: Decodable>(_ data: Data, _ response: HTTPURLResponse) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GoogleDriveError.unexpectedResponse(status: response.statusCode, reason: "unreadable response")
        }
    }
}

extension GoogleDriveError {
    /// Errors from the token endpoint that are worth retrying.
    var isTransient: Bool {
        switch self {
        case .noNetwork: true
        case .unexpectedResponse(let status?, _): (500...599).contains(status)
        default: false
        }
    }
}
