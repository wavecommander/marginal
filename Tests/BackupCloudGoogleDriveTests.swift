import AuthenticationServices
import Foundation
import GoogleDriveKit
import ReaderBackup
import Testing
import UIKit
@testable import TactileTexts

/// Returns a chosen callback for Google's sign-in page instead of showing it.
@MainActor
final class BackupCloudFakeWebAuthentication: GoogleDriveWebAuthenticating {
    enum Outcome {
        /// Redirects with these query items; `state` is added from the request unless given.
        case redirect([String: String])
        case cancel
    }

    var outcome: Outcome = .redirect(["code": BackupCloudFakeGoogle.authorizationCode])
    private(set) var presented: [(url: URL, scheme: String)] = []

    func authenticate(url: URL, callbackScheme: String, anchor: ASPresentationAnchor) async throws -> URL {
        presented.append((url, callbackScheme))
        switch outcome {
        case .cancel:
            throw CancellationError()
        case .redirect(var items):
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
            if items["state"] == nil { items["state"] = state }
            var components = URLComponents()
            components.scheme = callbackScheme
            components.path = GoogleOAuthConfiguration.redirectPath
            components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return components.url!
        }
    }
}

/// A signed-in (or not) Google Drive destination against the fake Google.
@MainActor
struct BackupCloudGoogleHarness {
    static let clientID = "123456789012-abcdefghijklmnop.apps.googleusercontent.com"
    static let configuration = GoogleOAuthConfiguration(clientID: clientID)!

    let google = BackupCloudFakeGoogle()
    let store: InMemoryGoogleTokenStore
    let auth: GoogleAuthSession
    let web = BackupCloudFakeWebAuthentication()
    let account: GoogleDriveAccount
    let clock = BackupCloudLocked(BackupCloudFixtures.date)
    let destination: GoogleDriveBackupDestination

    /// - Parameter tokens: `.valid` (signed in), `.expired` (signed in, must refresh) or `nil`.
    init(tokens: GoogleTokenSet? = .backupCloudValid) {
        store = InMemoryGoogleTokenStore(tokens)
        let clock = clock
        auth = GoogleAuthSession(configuration: Self.configuration, tokenStore: store, urlSession: google.stub.session,
                                 now: { clock.value })
        account = GoogleDriveAccount(auth: auth, webAuthentication: web)
        destination = Self.destination(account: account, google: google, clock: clock)
    }

    func makeDestination() -> GoogleDriveBackupDestination {
        Self.destination(account: account, google: google, clock: clock)
    }

    static func destination(account: GoogleDriveAccount, google: BackupCloudFakeGoogle,
                            clock: BackupCloudLocked<Date>) -> GoogleDriveBackupDestination {
        GoogleDriveBackupDestination(account: account, urlSession: google.stub.session,
                                     retryPolicy: GoogleRetryPolicy(maxAttempts: 2, sleep: { _ in }, random: { 0 }),
                                     now: { clock.value })
    }
}

extension GoogleTokenSet {
    static let backupCloudValid = GoogleTokenSet(
        accessToken: BackupCloudFakeGoogle.accessToken, expiresAt: BackupCloudFixtures.date.addingTimeInterval(3600),
        refreshToken: BackupCloudFakeGoogle.refreshToken, grantedScopes: [GoogleDriveScope.driveFile])
    static let backupCloudExpired = GoogleTokenSet(
        accessToken: "ya29.OLD-ACCESS-TOKEN-must-not-leak", expiresAt: BackupCloudFixtures.date.addingTimeInterval(-60),
        refreshToken: BackupCloudFakeGoogle.refreshToken, grantedScopes: [GoogleDriveScope.driveFile])
}

/// Snapshot names used by both destinations' tests.
enum BackupCloudNames {
    static let older = SnapshotName.make(createdAt: Date(timeIntervalSince1970: 1_800_000_000), deviceName: "Ben’s iPad")
    static let newer = SnapshotName.make(createdAt: Date(timeIntervalSince1970: 1_800_086_400), deviceName: "Ben’s iPad")
}

/// `GoogleDriveBackupDestination`, `GoogleDriveAccount` and the Keychain token store, against a
/// fake Google behind a `URLProtocol` stub.
@MainActor
struct BackupCloudGoogleDriveTests {
    // MARK: Protocol through the adapter

    @Test func snapshotsRoundTripNewestFirstIgnoringForeignFiles() async throws {
        let h = BackupCloudGoogleHarness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let olderData = BackupCloudFixtures.bytes(3000, seed: 1), newerData = BackupCloudFixtures.bytes(5000, seed: 2)

        let progress = BackupCloudLocked<[Double]>([])
        let older = try await h.destination.uploadSnapshot(
            from: try BackupCloudFixtures.write(olderData, in: scratch), name: BackupCloudNames.older,
            progress: { value in progress.mutate { $0.append(value) } })
        #expect(progress.value.last == 1)
        let newer = try await h.destination.uploadSnapshot(
            from: try BackupCloudFixtures.write(newerData, in: scratch), name: BackupCloudNames.newer, progress: nil)
        #expect(older.name == BackupCloudNames.older && older.byteSize == 3000 && older.deviceName == "Ben’s iPad")
        #expect(newer.id.hasPrefix("file-"), "the id is the Drive file ID")

        // Foreign files in the Backups folder are ignored.
        let backups = try #require(h.google.folder(role: GoogleDriveBackupDestination.FolderRole.backups.rawValue))
        h.google.addFile(name: "notes.txt", parent: backups.id, content: Data("x".utf8))
        h.google.addFile(name: "2026-11-15 Ben.ttbackup", parent: backups.id, content: Data("x".utf8))
        h.google.addFile(name: ".hidden.ttbackup", parent: backups.id, content: Data("x".utf8))

        let listed = try await h.destination.listSnapshots()
        #expect(listed.map(\.name) == [BackupCloudNames.newer, BackupCloudNames.older])
        #expect(listed.map(\.id) == [newer.id, older.id])
        #expect(listed.first?.byteSize == 5000)

        let target = scratch.appendingPathComponent("downloaded.ttbackup")
        try await h.destination.downloadSnapshot(listed[0], to: target, progress: nil)
        #expect(try Data(contentsOf: target) == newerData)

        try await h.destination.deleteSnapshot(listed[0])
        try await h.destination.deleteSnapshot(listed[0])  // already gone: succeeds
        #expect(try await h.destination.listSnapshots().map(\.name) == [BackupCloudNames.older])
        await #expect(throws: BackupError.snapshotNotFound(name: newer.name)) {
            try await h.destination.downloadSnapshot(newer, to: target, progress: nil)
        }
    }

    @Test func snapshotNameWithSpacesAndApostropheRoundTrips() async throws {
        let h = BackupCloudGoogleHarness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let name = SnapshotName.make(createdAt: BackupCloudFixtures.date, deviceName: "Zoë’s  Reading iPad")
        #expect(name.contains(" ") && name.contains("’"))
        let data = BackupCloudFixtures.bytes(1234)
        try await h.destination.uploadSnapshot(from: try BackupCloudFixtures.write(data, in: scratch), name: name, progress: nil)
        let listed = try await h.destination.listSnapshots()
        #expect(listed.map(\.name) == [name])
        #expect(listed.first?.deviceName == "Zoë’s  Reading iPad")
        let target = scratch.appendingPathComponent("out")
        try await h.destination.downloadSnapshot(listed[0], to: target, progress: nil)
        #expect(try Data(contentsOf: target) == data)
        try await h.destination.deleteSnapshot(listed[0])
        #expect(try await h.destination.listSnapshots().isEmpty)
    }

    @Test func uploadingAnExistingNameReplacesIt() async throws {
        let h = BackupCloudGoogleHarness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let first = try await h.destination.uploadSnapshot(
            from: try BackupCloudFixtures.write(BackupCloudFixtures.bytes(10), in: scratch), name: BackupCloudNames.older, progress: nil)
        let second = try await h.destination.uploadSnapshot(
            from: try BackupCloudFixtures.write(BackupCloudFixtures.bytes(20), in: scratch), name: BackupCloudNames.older, progress: nil)
        let listed = try await h.destination.listSnapshots()
        #expect(listed.map(\.id) == [second.id])
        #expect(h.google.file(first.id) == nil)
    }

    @Test func invalidSnapshotNameIsRefusedWithoutARequest() async throws {
        let h = BackupCloudGoogleHarness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try BackupCloudFixtures.write(Data("x".utf8), in: scratch)
        await #expect(throws: BackupError.invalidSnapshotName(name: "notes.txt")) {
            try await h.destination.uploadSnapshot(from: file, name: "notes.txt", progress: nil)
        }
        #expect(h.google.stub.requests.isEmpty)
    }

    @Test func corruptedSnapshotDownloadIsRefused() async throws {
        let h = BackupCloudGoogleHarness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let info = try await h.destination.uploadSnapshot(
            from: try BackupCloudFixtures.write(BackupCloudFixtures.bytes(4000), in: scratch), name: BackupCloudNames.older, progress: nil)
        h.google.corruptDownloads = true
        let target = scratch.appendingPathComponent("out")
        await #expect(throws: BackupError.contentMismatch(name: info.name)) {
            try await h.destination.downloadSnapshot(info, to: target, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).count == 1, "no partial file left")
    }

    @Test func pdfsByHash() async throws {
        let h = BackupCloudGoogleHarness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let pdf = BackupCloudFixtures.bytes(7000, seed: 9)
        let hash = BackupCloudFixtures.sha256(pdf)
        let file = try BackupCloudFixtures.write(pdf, in: scratch)

        #expect(try await h.destination.hasPDF(sha256: hash, size: 7000) == false)
        await #expect(throws: BackupError.pdfNotAtDestination(sha256: hash)) {
            try await h.destination.downloadPDF(sha256: hash, to: scratch.appendingPathComponent("none.pdf"), progress: nil)
        }
        try await h.destination.uploadPDF(from: file, sha256: hash.uppercased(), size: 7000, progress: nil)
        #expect(try await h.destination.hasPDF(sha256: hash, size: 7000))
        #expect(try await h.destination.hasPDF(sha256: hash, size: 6999) == false, "wrong size")

        let pdfs = try #require(h.google.folder(role: GoogleDriveBackupDestination.FolderRole.pdfs.rawValue))
        #expect(h.google.children(of: pdfs.id).map(\.name) == ["\(hash).pdf"])
        #expect(h.google.children(of: pdfs.id).first?.mimeType == "application/pdf")

        // Uploading again is skipped.
        let uploadsBefore = h.google.stub.requests("POST", pathPrefix: "/upload/").count
        try await h.destination.uploadPDF(from: file, sha256: hash, size: 7000, progress: nil)
        #expect(h.google.stub.requests("POST", pathPrefix: "/upload/").count == uploadsBefore)

        let target = scratch.appendingPathComponent("restored.pdf")
        try await h.destination.downloadPDF(sha256: hash, to: target, progress: nil)
        #expect(try Data(contentsOf: target) == pdf)

        h.google.corruptDownloads = true
        let corrupt = scratch.appendingPathComponent("corrupt.pdf")
        await #expect(throws: BackupError.contentMismatch(name: "\(hash).pdf")) {
            try await h.destination.downloadPDF(sha256: hash, to: corrupt, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
    }

    @Test func pdfWhoseBytesDoNotMatchTheHashIsNotKept() async throws {
        let h = BackupCloudGoogleHarness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try BackupCloudFixtures.write(BackupCloudFixtures.bytes(500), in: scratch, name: "Book.pdf")
        let wrong = BackupCloudFixtures.sha256(Data("other".utf8))
        await #expect(throws: BackupError.contentMismatch(name: "\(wrong).pdf")) {
            try await h.destination.uploadPDF(from: file, sha256: wrong, size: 500, progress: nil)
        }
        let pdfs = try #require(h.google.folder(role: GoogleDriveBackupDestination.FolderRole.pdfs.rawValue))
        #expect(h.google.children(of: pdfs.id).isEmpty, "the mismatching upload was deleted")
    }

    @Test func pdfWithWrongSizeIsReplaced() async throws {
        let h = BackupCloudGoogleHarness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let pdf = BackupCloudFixtures.bytes(900)
        let hash = BackupCloudFixtures.sha256(pdf)
        _ = try await h.destination.listSnapshots()  // creates the folders
        let pdfs = try #require(h.google.folder(role: GoogleDriveBackupDestination.FolderRole.pdfs.rawValue))
        let stale = h.google.addFile(name: "\(hash).pdf", parent: pdfs.id, content: Data("truncated".utf8))
        #expect(try await h.destination.hasPDF(sha256: hash, size: 900) == false)
        try await h.destination.uploadPDF(from: try BackupCloudFixtures.write(pdf, in: scratch), sha256: hash, size: 900, progress: nil)
        #expect(h.google.file(stale) == nil)
        #expect(try await h.destination.hasPDF(sha256: hash, size: 900))
    }

    // MARK: Folders

    @Test func foldersAreCreatedOnFirstUseAndReusedAfterwards() async throws {
        let h = BackupCloudGoogleHarness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(try await h.destination.listSnapshots().isEmpty)

        let folders = h.google.folders()
        #expect(folders.map(\.name) == ["Tactile Texts Backups", "Backups", "PDFs"])
        let root = folders[0]
        #expect(root.appProperties["folderRole"] == GoogleDriveBackupDestination.FolderRole.root.rawValue)
        #expect(folders[1].parents == [root.id] && folders[2].parents == [root.id])
        #expect(Set(folders.compactMap { $0.appProperties["folderRole"] }).count == 3, "distinct role tags")
        let creations = h.google.stub.requests("POST", pathPrefix: "/drive/v3/files").count
        #expect(creations == 3)

        // The same object reuses its IDs: no more folder lookups or creations.
        let lookups = h.google.stub.requests.filter { ($0.query["q"] ?? "").contains("folderRole") }.count
        try await h.destination.uploadSnapshot(
            from: try BackupCloudFixtures.write(Data("a".utf8), in: scratch), name: BackupCloudNames.older, progress: nil)
        _ = try await h.destination.hasPDF(sha256: BackupCloudFixtures.sha256(Data()), size: 0)
        _ = try await h.destination.listSnapshots()
        #expect(h.google.stub.requests.filter { ($0.query["q"] ?? "").contains("folderRole") }.count == lookups)
        #expect(h.google.stub.requests("POST", pathPrefix: "/drive/v3/files").count == creations)

        // A new object (next launch) finds the existing folders instead of making more.
        let next = h.makeDestination()
        #expect(try await next.listSnapshots().map(\.name) == [BackupCloudNames.older])
        #expect(h.google.folders().count == 3)
    }

    @Test func aDeletedFolderIsRecreated() async throws {
        let h = BackupCloudGoogleHarness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try await h.destination.listSnapshots()
        let old = try #require(h.google.folder(role: GoogleDriveBackupDestination.FolderRole.backups.rawValue))
        h.google.remove(old.id)

        let info = try await h.destination.uploadSnapshot(
            from: try BackupCloudFixtures.write(Data("a".utf8), in: scratch), name: BackupCloudNames.older, progress: nil)
        let recreated = try #require(h.google.folder(role: GoogleDriveBackupDestination.FolderRole.backups.rawValue))
        #expect(recreated.id != old.id)
        #expect(h.google.children(of: recreated.id).map(\.id) == [info.id])
    }

    @Test func aTrashedFolderIsReplacedAfterTheRecheckInterval() async throws {
        let h = BackupCloudGoogleHarness()
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let pdf = BackupCloudFixtures.bytes(300)
        let hash = BackupCloudFixtures.sha256(pdf)
        _ = try await h.destination.listSnapshots()
        let trashed = try #require(h.google.folder(role: GoogleDriveBackupDestination.FolderRole.pdfs.rawValue))
        h.google.trash(trashed.id)
        h.clock.value = h.clock.value.addingTimeInterval(GoogleDriveBackupDestination.folderRecheckInterval + 1)

        try await h.destination.uploadPDF(from: try BackupCloudFixtures.write(pdf, in: scratch), sha256: hash, size: 300, progress: nil)
        let live = h.google.folders().filter {
            $0.appProperties["folderRole"] == GoogleDriveBackupDestination.FolderRole.pdfs.rawValue && !$0.trashed
        }
        #expect(live.count == 1 && live[0].id != trashed.id)
        #expect(h.google.children(of: live[0].id).map(\.name) == ["\(hash).pdf"])
        #expect(h.google.children(of: trashed.id).isEmpty)
    }

    // MARK: Availability

    @Test func availabilityInEachState() async throws {
        let notSetUp = GoogleDriveBackupDestination(account: GoogleDriveAccount(auth: nil))
        #expect(await notSetUp.availability() == .unavailable(reason: "Google Drive isn’t set up in this build of Tactile Texts."))
        #expect(notSetUp.id == "google-drive" && notSetUp.displayName == "Google Drive")
        await #expect(throws: CloudBackupError.notSetUp(destination: "Google Drive")) { try await notSetUp.listSnapshots() }

        let signedOut = BackupCloudGoogleHarness(tokens: nil)
        #expect(await signedOut.destination.availability() == .unavailable(reason: "Sign in to Google Drive to back up there."))
        await #expect(throws: CloudBackupError.notSignedIn) { try await signedOut.destination.listSnapshots() }

        let signedIn = BackupCloudGoogleHarness()
        #expect(await signedIn.destination.availability() == .available)
        #expect(signedIn.google.stub.requests.isEmpty, "availability makes no network call")

        let rejected = BackupCloudGoogleHarness(tokens: .backupCloudExpired)
        rejected.google.refresh = .invalidGrant
        await #expect(throws: CloudBackupError.needsSignInAgain) { try await rejected.destination.listSnapshots() }
        #expect(rejected.account.state == .needsSignInAgain)
        #expect(await rejected.destination.availability() == .unavailable(reason: "Google Drive needs you to sign in again."))
    }

    // MARK: Error mapping

    @Test func driveErrorsMapToReaderFacingErrors() async throws {
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try BackupCloudFixtures.write(Data("abc".utf8), in: scratch)

        let full = BackupCloudGoogleHarness()
        _ = try await full.destination.listSnapshots()
        full.google.driveOverride = .json(403, ["error": ["code": 403, "errors": [["reason": "storageQuotaExceeded"]]]])
        await #expect(throws: CloudBackupError.storageFull(destination: "Google Drive")) {
            try await full.destination.uploadSnapshot(from: file, name: BackupCloudNames.older, progress: nil)
        }

        let offline = BackupCloudGoogleHarness()
        offline.google.driveOverride = .fail(.notConnectedToInternet)
        await #expect(throws: CloudBackupError.noNetwork(destination: "Google Drive")) { try await offline.destination.listSnapshots() }

        let busy = BackupCloudGoogleHarness()
        busy.google.driveOverride = .json(429, ["error": ["code": 429, "errors": [["reason": "rateLimitExceeded"]]]])
        await #expect(throws: CloudBackupError.busy(destination: "Google Drive")) { try await busy.destination.listSnapshots() }

        let broken = BackupCloudGoogleHarness()
        broken.google.driveOverride = .json(500, ["error": ["code": 500, "errors": [["reason": "backendError"]]]])
        await #expect(throws: CloudBackupError.serviceError(destination: "Google Drive", diagnostic: "HTTP 500 backendError")) {
            try await broken.destination.listSnapshots()
        }

        let missing = BackupCloudGoogleHarness()
        let ghost = BackupSnapshotInfo(id: "gone", name: BackupCloudNames.older, createdAt: .now, deviceName: "iPad", byteSize: 1)
        await #expect(throws: BackupError.snapshotNotFound(name: BackupCloudNames.older)) {
            try await missing.destination.downloadSnapshot(ghost, to: scratch.appendingPathComponent("x"), progress: nil)
        }

        // The three the UI acts on stay distinguishable.
        let distinct: Set<CloudBackupError> = [.needsSignInAgain, .storageFull(destination: "Google Drive"),
                                                .noNetwork(destination: "Google Drive")]
        #expect(distinct.count == 3)
        #expect(Set(distinct.map(\.localizedDescription)).count == 3)
        #expect(CloudBackupError.needsSignInAgain.needsSignIn)
    }

    // MARK: Sign-in coordinator

    @Test func signInSucceeds() async throws {
        let h = BackupCloudGoogleHarness(tokens: nil)
        await h.account.refresh()
        #expect(h.account.state == .signedOut)
        #expect(try await h.account.signIn(anchor: UIWindow()))
        #expect(h.account.state == .signedIn && !h.account.isSigningIn)
        let presented = try #require(h.web.presented.first)
        #expect(presented.scheme == "com.googleusercontent.apps.123456789012-abcdefghijklmnop")
        let items = URLComponents(url: presented.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(presented.url.host() == "accounts.google.com")
        #expect(items.contains(URLQueryItem(name: "client_id", value: BackupCloudGoogleHarness.clientID)))
        #expect(items.contains(URLQueryItem(name: "scope", value: GoogleDriveScope.driveFile)))
        #expect(items.contains(URLQueryItem(name: "code_challenge_method", value: "S256")))
        #expect(await h.store.load()?.refreshToken == BackupCloudFakeGoogle.refreshToken)
        #expect(await h.destination.availability() == .available)
    }

    @Test func readerClosingTheSheetIsAQuietCancellation() async throws {
        let h = BackupCloudGoogleHarness(tokens: nil)
        h.web.outcome = .cancel
        #expect(try await h.account.signIn(anchor: UIWindow()) == false)
        #expect(h.account.state == .signedOut)
        // Declining on Google's page (error=access_denied) is the same.
        h.web.outcome = .redirect(["error": "access_denied"])
        #expect(try await h.account.signIn(anchor: UIWindow()) == false)
        #expect(h.account.state == .signedOut)
        #expect(await h.store.load() == nil)
        #expect(h.google.stub.requests.isEmpty, "no code exchange")
    }

    @Test func stateMismatchFails() async throws {
        let h = BackupCloudGoogleHarness(tokens: nil)
        h.web.outcome = .redirect(["code": BackupCloudFakeGoogle.authorizationCode, "state": "forged"])
        await #expect(throws: CloudBackupError.signInFailed) { try await h.account.signIn(anchor: UIWindow()) }
        #expect(h.account.state == .signedOut && !h.account.isSigningIn)
        #expect(h.google.stub.requests.isEmpty, "the code is never exchanged")
    }

    @Test func driveAccessNotGrantedFails() async throws {
        let h = BackupCloudGoogleHarness(tokens: nil)
        h.google.exchange = .grant(scope: "openid email")
        await #expect(throws: CloudBackupError.driveAccessNotGranted) { try await h.account.signIn(anchor: UIWindow()) }
        #expect(h.account.state == .signedOut)
        #expect(await h.store.load() == nil)
    }

    @Test func rejectedRefreshNeedsSignInAgainUntilSignedIn() async throws {
        let h = BackupCloudGoogleHarness(tokens: .backupCloudExpired)
        await h.account.refresh()
        #expect(h.account.state == .signedIn)
        h.google.refresh = .invalidGrant
        await #expect(throws: CloudBackupError.needsSignInAgain) { try await h.destination.listSnapshots() }
        #expect(h.account.state == .needsSignInAgain)
        await h.account.refresh()
        #expect(h.account.state == .needsSignInAgain, "stays until the reader signs in")
        #expect(await h.store.load() == nil)

        #expect(try await h.account.signIn(anchor: UIWindow()))
        #expect(h.account.state == .signedIn)
        #expect(try await h.destination.listSnapshots().isEmpty)
    }

    @Test func signOutForgetsAndRevokes() async throws {
        let h = BackupCloudGoogleHarness()
        await h.account.refresh()
        try await h.account.signOut()
        #expect(h.account.state == .signedOut)
        #expect(await h.store.load() == nil)
        let revoke = try #require(h.google.stub.requests.first { $0.path == "/revoke" })
        #expect(revoke.form["token"] == BackupCloudFakeGoogle.refreshToken)
        #expect(await h.destination.availability() == .unavailable(reason: "Sign in to Google Drive to back up there."))
    }

    @Test func notSetUpAccount() async throws {
        let account = GoogleDriveAccount(auth: nil, webAuthentication: BackupCloudFakeWebAuthentication())
        #expect(account.state == .notSetUp)
        await account.refresh()
        #expect(account.state == .notSetUp)
        await #expect(throws: CloudBackupError.notSetUp(destination: "Google Drive")) { try await account.signIn(anchor: UIWindow()) }
    }

    @Test func buildConfigurationReader() {
        #expect(GoogleDriveBuildConfiguration.oauthConfiguration(infoDictionary: nil) == nil)
        #expect(GoogleDriveBuildConfiguration.oauthConfiguration(infoDictionary: [:]) == nil)
        #expect(GoogleDriveBuildConfiguration.oauthConfiguration(infoDictionary: ["GoogleDriveClientID": ""]) == nil)
        #expect(GoogleDriveBuildConfiguration.oauthConfiguration(infoDictionary: ["GoogleDriveClientID": "$(GOOGLE_DRIVE_CLIENT_ID)"]) == nil)
        #expect(GoogleDriveBuildConfiguration.oauthConfiguration(infoDictionary: ["GoogleDriveClientID": 42]) == nil)
        let set = GoogleDriveBuildConfiguration.oauthConfiguration(infoDictionary: ["GoogleDriveClientID": BackupCloudGoogleHarness.clientID])
        #expect(set?.clientID == BackupCloudGoogleHarness.clientID)
        // This build is not set up.
        #expect(GoogleDriveBuildConfiguration.oauthConfiguration() == nil)
    }

    // MARK: Keychain

    /// The unsigned simulator test host (`CODE_SIGNING_ALLOWED = NO`: linker ad-hoc signature, no
    /// `application-identifier` entitlement) gets `errSecMissingEntitlement` (-34018) from every
    /// `SecItem` call, starting with the first `SecItemCopyMatching` in `load()`. That failure is
    /// recorded as a known issue (shown in the test output, not hidden); on a signed host the
    /// checks run in full and any other failure fails the test.
    private func withKeychain(_ body: () async throws -> Void) async throws {
        try await withKnownIssue("Unsigned simulator test host: Keychain returns errSecMissingEntitlement (-34018)",
                             isIntermittent: true) {
            try await body()
        } matching: { issue in
            (issue.error as? GoogleDriveKeychainTokenStore.KeychainError)?.status == errSecMissingEntitlement
        }
    }

    @Test func keychainStoreSavesLoadsAndClears() async throws {
        try await withKeychain { try await keychainRoundTrip() }
    }

    private func keychainRoundTrip() async throws {
        let store = GoogleDriveKeychainTokenStore(service: "software.tactile.texts.tests.\(UUID().uuidString)")
        defer { Task { try? await store.clear() } }
        #expect(try await store.load() == nil)
        try await store.save(.backupCloudValid)
        #expect(try await store.load() == .backupCloudValid)
        var replaced = GoogleTokenSet.backupCloudValid
        replaced.accessToken = "ya29.SECOND"
        try await store.save(replaced)
        #expect(try await store.load() == replaced)
        try await store.clear()
        #expect(try await store.load() == nil)
        try await store.clear()  // clearing nothing succeeds
    }

    @Test func keychainItemIsThisDeviceOnlyAfterFirstUnlockAndNotSynchronized() async throws {
        try await withKeychain { try await keychainAttributes() }
    }

    private func keychainAttributes() async throws {
        let service = "software.tactile.texts.tests.\(UUID().uuidString)"
        let store = GoogleDriveKeychainTokenStore(service: service)
        defer { Task { try? await store.clear() } }
        try await store.save(.backupCloudValid)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let items = try #require(result as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items[0][kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect((items[0][kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true)
        #expect(items[0][kSecAttrAccount as String] as? String == GoogleDriveKeychainTokenStore.account)
    }

    // MARK: Secrets

    @Test func noTokenAppearsInAnyMappedError() async throws {
        let secrets = [BackupCloudFakeGoogle.accessToken, BackupCloudFakeGoogle.refreshToken, BackupCloudFakeGoogle.authorizationCode,
                       GoogleTokenSet.backupCloudExpired.accessToken]
        var errors: [any Error] = []
        let scratch = try BackupCloudFixtures.scratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try BackupCloudFixtures.write(Data("abc".utf8), in: scratch)

        func capture(_ body: () async throws -> Void) async {
            do { try await body() } catch { errors.append(error) }
        }
        let rejected = BackupCloudGoogleHarness(tokens: .backupCloudExpired)
        rejected.google.refresh = .invalidGrant
        await capture { _ = try await rejected.destination.listSnapshots() }

        for reply: BackupCloudReply in [
            .json(403, ["error": ["code": 403, "errors": [["reason": "storageQuotaExceeded"]]]]),
            .json(500, ["error": ["code": 500, "message": "token \(BackupCloudFakeGoogle.accessToken)", "errors": [["reason": "backendError"]]]]),
            .json(401, ["error": ["code": 401, "errors": [["reason": "authError"]]]]),
            .json(404, ["error": ["code": 404, "errors": [["reason": "notFound"]]]]),
            .fail(.notConnectedToInternet),
            .fail(.badServerResponse),
        ] {
            let h = BackupCloudGoogleHarness()
            h.google.driveOverride = reply
            await capture { _ = try await h.destination.listSnapshots() }
            await capture { _ = try await h.destination.uploadSnapshot(from: file, name: BackupCloudNames.older, progress: nil) }
        }
        let corrupt = BackupCloudGoogleHarness()
        let hash = BackupCloudFixtures.sha256(Data("abc".utf8))
        try await corrupt.destination.uploadPDF(from: file, sha256: hash, size: 3, progress: nil)
        corrupt.google.corruptDownloads = true
        await capture { try await corrupt.destination.downloadPDF(sha256: hash, to: scratch.appendingPathComponent("p"), progress: nil) }

        for outcome: BackupCloudFakeWebAuthentication.Outcome in [
            .redirect(["code": BackupCloudFakeGoogle.authorizationCode, "state": "forged"]),
            .redirect(["error": "server_error"]),
        ] {
            let h = BackupCloudGoogleHarness(tokens: nil)
            h.web.outcome = outcome
            await capture { _ = try await h.account.signIn(anchor: UIWindow()) }
        }
        for exchange: BackupCloudFakeGoogle.TokenExchange in [.grant(scope: "openid"), .error("invalid_grant")] {
            let h = BackupCloudGoogleHarness(tokens: nil)
            h.google.exchange = exchange
            await capture { _ = try await h.account.signIn(anchor: UIWindow()) }
        }
        errors.append(GoogleDriveKeychainTokenStore.KeychainError(status: errSecMissingEntitlement))

        #expect(errors.count == 19)
        for error in errors {
            let texts = [error.localizedDescription, String(describing: error), String(reflecting: error)]
            for text in texts {
                for secret in secrets {
                    #expect(!text.contains(secret), "\(type(of: error)) shows a token")
                }
            }
            #expect(error is CloudBackupError || error is BackupError || error is GoogleDriveKeychainTokenStore.KeychainError,
                    "unmapped: \(type(of: error))")
        }
    }
}
