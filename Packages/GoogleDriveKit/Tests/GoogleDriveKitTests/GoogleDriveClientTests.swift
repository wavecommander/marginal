import Foundation
import Testing
@testable import GoogleDriveKit

private let folderMime = "application/vnd.google-apps.folder"
private let fileFields = "id,name,mimeType,size,md5Checksum,sha256Checksum,parents,appProperties,trashed,createdTime,modifiedTime"

private func folder(_ id: String, role: String = "root", trashed: Bool = false, created: String = "2026-11-01T10:00:00.000Z") -> [String: Any] {
    driveFileJSON(id: id, name: "Tactile Texts Backups", mimeType: folderMime, parents: ["root-id"],
                  appProperties: ["folderRole": role], trashed: trashed, createdTime: created)
}

private func list(_ files: [[String: Any]], next: String? = nil) -> StubServer.Reply {
    var body: [String: Any] = ["files": files]
    if let next { body["nextPageToken"] = next }
    return .http(200, headers: ["Content-Type": "application/json"], body: json(body))
}

struct GoogleDriveFolderTests {
    @Test func findsTheExistingTaggedFolder() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)?", list([folder("f1")]))

        let found = try await harness.client.findOrCreateFolder(named: "Tactile Texts Backups", role: "root", inParent: nil)

        #expect(found.id == "f1")
        #expect(found.isFolder)
        let request = try #require(harness.server.requests.first)
        #expect(request.urlWithoutQuery == filesURL)
        #expect(request.header("Authorization") == "Bearer access-1")
        #expect(request.query == [
            "q": "mimeType = 'application/vnd.google-apps.folder' and trashed = false and appProperties has { key='folderRole' and value='root' }",
            "fields": "nextPageToken,files(\(fileFields))",
            "pageSize": "1000",
            "orderBy": "createdTime",
        ])
        harness.server.verify()
    }

    @Test func createsAMissingFolderTaggedWithItsRole() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)?", list([]))
        harness.server.expect("POST", "\(filesURL)?", .http(200, body: json(folder("new", role: "pdfs"))))
        harness.server.expect("GET", "\(filesURL)?", list([folder("new", role: "pdfs")]))

        let created = try await harness.client.findOrCreateFolder(named: "PDFs", role: "pdfs", inParent: "parent-1")

        #expect(created.id == "new")
        let lookup = harness.server.requests[0]
        #expect(lookup.query["q"] == "mimeType = 'application/vnd.google-apps.folder' and trashed = false and appProperties has { key='folderRole' and value='pdfs' } and 'parent-1' in parents")
        let create = harness.server.requests[1]
        #expect(create.urlWithoutQuery == filesURL)
        #expect(create.query == ["fields": fileFields])
        #expect(create.header("Content-Type") == "application/json; charset=UTF-8")
        #expect(create.header("Authorization") == "Bearer access-1")
        #expect(create.json["name"] as? String == "PDFs")
        #expect(create.json["mimeType"] as? String == folderMime)
        #expect(create.json["parents"] as? [String] == ["parent-1"])
        #expect(create.json["appProperties"] as? [String: String] == ["folderRole": "pdfs"])
        harness.server.verify()
    }

    @Test func picksTheOldestOfDuplicates() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)?", list([
            folder("newer", created: "2026-11-03T10:00:00.000Z"),
            folder("oldest", created: "2026-11-01T09:00:00Z"),
            folder("middle", created: "2026-11-02T10:00:00.000Z"),
        ]))
        let found = try await harness.client.findOrCreateFolder(named: "Tactile Texts Backups", role: "root", inParent: nil)
        #expect(found.id == "oldest")
        harness.server.verify()
    }

    @Test func ignoresATrashedFolderAndCreatesANewOne() async throws {
        let harness = Harness()
        // The query excludes trashed folders; a trashed one in the reply is still ignored.
        harness.server.expect("GET", "\(filesURL)?", list([folder("trashed", trashed: true)]))
        harness.server.expect("POST", "\(filesURL)?", .http(200, body: json(folder("fresh"))))
        harness.server.expect("GET", "\(filesURL)?", list([folder("fresh")]))

        let found = try await harness.client.findOrCreateFolder(named: "Tactile Texts Backups", role: "root", inParent: nil)

        #expect(found.id == "fresh")
        #expect(harness.server.requests[1].json["parents"] == nil)
        harness.server.verify()
    }

    @Test func convergesOnAnOlderFolderCreatedAtTheSameTime() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)?", list([]))
        harness.server.expect("POST", "\(filesURL)?", .http(200, body: json(folder("mine", created: "2026-11-05T10:00:00.000Z"))))
        harness.server.expect("GET", "\(filesURL)?", list([
            folder("theirs", created: "2026-11-05T09:59:59.000Z"), folder("mine", created: "2026-11-05T10:00:00.000Z"),
        ]))
        harness.server.expect("DELETE", "\(filesURL)/mine", .http(204))

        let found = try await harness.client.findOrCreateFolder(named: "Tactile Texts Backups", role: "root", inParent: nil)

        #expect(found.id == "theirs")
        harness.server.verify()
    }
}

struct GoogleDriveListingTests {
    @Test func followsEveryPage() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)?", list([driveFileJSON(id: "a", name: "a.pdf", size: 1)], next: "page-2"))
        harness.server.expect("GET", "\(filesURL)?", list([driveFileJSON(id: "b", name: "b.pdf", size: 2),
                                                           driveFileJSON(id: "c", name: "c.pdf", size: 3)]))

        let files = try await harness.client.listFiles(inFolder: "folder-1")

        #expect(files.map(\.id) == ["a", "b", "c"])
        #expect(files.map(\.size) == [1, 2, 3])
        let first = harness.server.requests[0].query
        #expect(first["q"] == "'folder-1' in parents and trashed = false")
        #expect(first["pageToken"] == nil)
        #expect(first["pageSize"] == "1000")
        let second = harness.server.requests[1].query
        #expect(second["pageToken"] == "page-2")
        #expect(second["q"] == first["q"])
        harness.server.verify()
    }

    @Test func returnsOnePage() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)?", list([driveFileJSON(id: "a", name: "a")], next: "t2"))
        let page = try await harness.client.listFilesPage(inFolder: "f", pageToken: "t1", pageSize: 50)
        #expect(page.files.map(\.id) == ["a"])
        #expect(page.nextPageToken == "t2")
        #expect(harness.server.requests[0].query["pageToken"] == "t1")
        #expect(harness.server.requests[0].query["pageSize"] == "50")
        harness.server.verify()
    }

    @Test func findsAFileByNameWithEscaping() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)?", list([driveFileJSON(id: "x", name: "it's a+b\\c.ttbackup",
                                                                         size: 10, sha256: "abc", appProperties: ["k": "v"])]))
        let file = try #require(try await harness.client.file(named: "it's a+b\\c.ttbackup", inFolder: "f"))
        #expect(file.id == "x")
        #expect(file.sha256Checksum == "abc")
        #expect(file.appProperties == ["k": "v"])
        #expect(file.createdTime == ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z"))
        let request = harness.server.requests[0]
        #expect(request.query["q"] == "name = 'it\\'s a+b\\\\c.ttbackup' and 'f' in parents and trashed = false")
        // A literal "+" would be read as a space by the server.
        #expect(request.url.absoluteString.contains("a%2Bb"))
        harness.server.verify()
    }

    @Test func missingFileByNameIsNil() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)?", list([]))
        #expect(try await harness.client.file(named: "nope", inFolder: "f") == nil)
        harness.server.verify()
    }

    @Test func deletesAFile() async throws {
        let harness = Harness()
        harness.server.expect("DELETE", "\(filesURL)/file-9", .http(204))
        try await harness.client.deleteFile(id: "file-9")
        #expect(harness.server.requests[0].url.absoluteString == "\(filesURL)/file-9")
        #expect(harness.server.requests[0].header("Authorization") == "Bearer access-1")
        harness.server.verify()
    }
}

struct StubServerTests {
    @Test func flagsRequestsOutOfScript() async throws {
        let server = StubServer()
        server.expect("GET", "https://example.com/a", .http(204))
        let (_, response) = try await server.session.data(from: URL(string: "https://example.com/b")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 599)
        #expect(server.unexpectedCount == 1)
        // The scripted request is still waiting, so verify() would fail this test.
        _ = try await server.session.data(from: URL(string: "https://example.com/a")!)
        #expect(server.unexpectedCount == 1)
    }
}

struct GoogleDriveRequestTests {
    @Test func a401RefreshesOnceAndRetries() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)/f1?", .http(401, body: driveError(401, reason: "authError")))
        harness.server.expect("POST", tokenURL, tokenResponse("access-2"))
        harness.server.expect("GET", "\(filesURL)/f1?", .http(200, body: json(driveFileJSON(id: "f1", name: "x"))))

        let file = try await harness.client.file(id: "f1")

        #expect(file.id == "f1")
        #expect(harness.server.requests[0].header("Authorization") == "Bearer access-1")
        #expect(harness.server.requests[2].header("Authorization") == "Bearer access-2")
        #expect(harness.server.requests[0].query == ["fields": fileFields])
        harness.server.verify()
    }

    @Test func aSecond401NeedsSignInAgain() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)/f1?", .http(401, body: driveError(401, reason: "authError")))
        harness.server.expect("POST", tokenURL, tokenResponse("access-2"))
        harness.server.expect("GET", "\(filesURL)/f1?", .http(401, body: driveError(401, reason: "authError")))
        await #expect(throws: GoogleDriveError.needsSignInAgain) { try await harness.client.file(id: "f1") }
        harness.server.verify()
    }

    @Test func notFoundIsMapped() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)/gone?", .http(404, body: driveError(404, reason: "notFound", message: "File not found: gone.")))
        await #expect(throws: GoogleDriveError.notFound) { try await harness.client.file(id: "gone") }
        #expect(harness.sleeps.value.isEmpty)
        harness.server.verify()
    }

    @Test func storageQuotaIsStorageFullWithoutRetrying() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)?", list([]))
        harness.server.expect("POST", "\(filesURL)?", .http(403, body: driveError(403, reason: "storageQuotaExceeded")))
        await #expect(throws: GoogleDriveError.storageFull) {
            try await harness.client.findOrCreateFolder(named: "x", role: "root", inParent: nil)
        }
        #expect(harness.sleeps.value.isEmpty)
        harness.server.verify()
    }

    @Test func rateLimitBacksOffForABoundedNumberOfAttempts() async throws {
        let harness = Harness(maxAttempts: 3)
        harness.server.expect("GET", "\(filesURL)/f?", .http(429, body: driveError(429, reason: "rateLimitExceeded")))
        harness.server.expect("GET", "\(filesURL)/f?", .http(403, body: driveError(403, reason: "userRateLimitExceeded")))
        harness.server.expect("GET", "\(filesURL)/f?", .http(429, body: driveError(429, reason: "rateLimitExceeded")))

        await #expect(throws: GoogleDriveError.rateLimited) { try await harness.client.file(id: "f") }

        // min(1s · 2^n + 0.5 · 1s, 32s)
        #expect(harness.sleeps.value == [.milliseconds(1500), .milliseconds(2500)])
        harness.server.verify()
    }

    @Test func serverErrorsAreRetriedThenSucceed() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)/f?", .http(503))
        harness.server.expect("GET", "\(filesURL)/f?", .drop(.networkConnectionLost))
        harness.server.expect("GET", "\(filesURL)/f?", .http(200, body: json(driveFileJSON(id: "f", name: "f"))))
        #expect(try await harness.client.file(id: "f").id == "f")
        #expect(harness.sleeps.value.count == 2)
        harness.server.verify()
    }

    @Test func offlineBecomesNoNetwork() async throws {
        let harness = Harness(maxAttempts: 2)
        harness.server.expect("GET", "\(filesURL)/f?", .drop(.notConnectedToInternet))
        harness.server.expect("GET", "\(filesURL)/f?", .drop(.notConnectedToInternet))
        await #expect(throws: GoogleDriveError.noNetwork) { try await harness.client.file(id: "f") }
        harness.server.verify()
    }

    @Test func otherErrorsKeepStatusAndReason() async throws {
        let harness = Harness()
        harness.server.expect("GET", "\(filesURL)/f?", .http(400, body: driveError(400, reason: "invalid")))
        await #expect(throws: GoogleDriveError.unexpectedResponse(status: 400, reason: "invalid")) {
            try await harness.client.file(id: "f")
        }
        harness.server.verify()
    }

    @Test func errorsReadPlainly() {
        #expect(GoogleDriveError.storageFull.localizedDescription == "Your Google storage is full. Free up space or add storage, then try again.")
        #expect(GoogleDriveError.unexpectedResponse(status: 500, reason: "backendError").localizedDescription
                == "Google Drive gave an unexpected response (500 backendError).")
        #expect(GoogleDriveError.needsSignInAgain.localizedDescription == "Google Drive needs you to sign in again.")
    }
}
