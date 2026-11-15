#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import S3Kit

/// The client against a **real** R2 development bucket, with credentials minted the way the
/// backup service's Worker mints them (short-lived, limited to one user's folder).
///
/// Off unless `S3KIT_LIVE_MINT` names the Worker project directory, which must hold a filled-in
/// `.dev.vars` for a development bucket:
///
///     S3KIT_LIVE_MINT=$PWD/Backend/backup-worker swift test --package-path Packages/S3Kit --filter LiveR2Tests
///
/// Each run works in its own throwaway folder `users/<random>/` and removes what it wrote.
/// Everything else in this package is tested against a stub; this is the check that R2 itself
/// accepts these signatures and answers as the client expects.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["S3KIT_LIVE_MINT"] != nil), .serialized)
struct LiveR2Tests {
    struct Minted: Decodable {
        var host: String
        var region: String
        var bucket: String
        var prefix: String
        var accessKeyId: String
        var secretAccessKey: String
        var sessionToken: String
        var expiresAt: String

        var credentials: S3Credentials {
            S3Credentials(accessKeyID: accessKeyId, secretAccessKey: secretAccessKey, sessionToken: sessionToken,
                          expiration: ISO8601DateFormatter.fractional.date(from: expiresAt))
        }
    }

    static func randomUser() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Runs the Worker project's minting script (the same code the Worker runs).
    static func mint(user: String, mode: String = "read-write", expired: Bool = false) throws -> Minted {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["S3KIT_LIVE_MINT"]!, isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = directory
        process.arguments = ["node", "scripts/mint-dev-credentials.ts", "--user", user, "--mode", mode] + (expired ? ["--expired"] : [])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return try JSONDecoder().decode(Minted.self, from: data)
    }

    static func endpoint(_ minted: Minted, user: String? = nil) throws -> S3Endpoint {
        let prefix = user.map { "users/\($0)" } ?? minted.prefix
        return try #require(S3Endpoint(host: minted.host, region: minted.region, bucket: minted.bucket, prefix: prefix))
    }

    static func temporaryFile(bytes: Int) throws -> (url: URL, sha256: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).bin")
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: buffer.count, by: 4096) { buffer[index] = UInt8(truncatingIfNeeded: index / 4096) }
        }
        try data.write(to: url)
        return (url, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    @Test func aBackupGoesUpAndComesBackWithScopedCredentialsThatExpireOnTheWay() async throws {
        let user = Self.randomUser()
        let first = try Self.mint(user: user, expired: true)
        // The first credential handed out is already expired, as one would be late in a long
        // transfer: the client must notice (R2 answers 403 SignatureDoesNotMatch), fetch a
        // fresh one and carry on.
        let handedOut = Counter()
        let provider = S3RefreshingCredentialsProvider {
            let count = await handedOut.next()
            return count == 1 ? first.credentials : try Self.mint(user: user).credentials
        }
        let client = S3Client(endpoint: try Self.endpoint(first), credentialsProvider: provider)

        // A snapshot name as the app makes them: a space and a typographic apostrophe.
        let snapshot = "Backups/2026-11-15T12-00-00Z Ben’s iPad.ttbackup"
        try await client.put(data: Data("snapshot".utf8), key: snapshot)
        #expect(await provider.fetches == 2, "one expired credential, then one refresh")

        // A file of three parts, the way a large PDF goes up.
        let file = try Self.temporaryFile(bytes: 12 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file.url) }
        let pdf = "PDFs/\(file.sha256).pdf"
        try await client.upload(fileAt: file.url, key: pdf, metadata: ["sha256": file.sha256], partSize: S3Client.minimumPartSize)

        let listed = try await client.list()
        #expect(Set(listed.map(\.key)) == [snapshot.precomposedStringWithCanonicalMapping, pdf])
        let listedSize = listed.first(where: { $0.key == pdf })?.size
        #expect(listedSize == Int64(12 * 1024 * 1024))
        let head = try #require(try await client.head(key: pdf))
        #expect(head.size == 12 * 1024 * 1024)
        #expect(head.metadata["sha256"] == file.sha256)
        #expect(try await client.head(key: "PDFs/absent.pdf") == nil)

        let downloaded = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let size = try await client.download(key: pdf, to: downloaded, expectedSHA256: file.sha256)
        #expect(size == 12 * 1024 * 1024)
        #expect(try Data(contentsOf: downloaded) == Data(contentsOf: file.url))

        try await client.delete(key: snapshot)
        try await client.delete(key: pdf)
        try await client.delete(key: pdf)  // already gone is success
        #expect(try await client.list().isEmpty)
    }

    @Test func aCredentialForOneFolderIsRefusedInAnother() async throws {
        let user = Self.randomUser()
        let minted = try Self.mint(user: user)
        // The client is pointed at someone else's folder but holds only its own credential.
        let trespasser = S3Client(endpoint: try Self.endpoint(minted, user: Self.randomUser()),
                                  credentialsProvider: S3StaticCredentialsProvider(minted.credentials))
        await #expect { try await trespasser.put(data: Data("x".utf8), key: "Backups/x.ttbackup") } throws: { error in
            (error as? S3Error)?.isNotAllowedByCredentials == true
        }
        await #expect { _ = try await trespasser.list() } throws: { error in
            (error as? S3Error)?.isNotAllowedByCredentials == true
        }
    }

    @Test func aReadOnlyCredentialCanRestoreButNotUpload() async throws {
        let user = Self.randomUser()
        let writer = try Self.mint(user: user)
        let writing = S3Client(endpoint: try Self.endpoint(writer), credentialsProvider: S3StaticCredentialsProvider(writer.credentials))
        try await writing.put(data: Data("kept".utf8), key: "Backups/kept.ttbackup")

        let reader = try Self.mint(user: user, mode: "read-only")
        let reading = S3Client(endpoint: try Self.endpoint(reader), credentialsProvider: S3StaticCredentialsProvider(reader.credentials))
        #expect(try await reading.list().map(\.key) == ["Backups/kept.ttbackup"])
        await #expect { try await reading.put(data: Data("no".utf8), key: "Backups/no.ttbackup") } throws: { error in
            (error as? S3Error)?.isNotAllowedByCredentials == true
        }
        await #expect { try await reading.delete(key: "Backups/kept.ttbackup") } throws: { error in
            (error as? S3Error)?.isNotAllowedByCredentials == true
        }

        try await writing.delete(key: "Backups/kept.ttbackup")
        #expect(try await writing.list().isEmpty)
    }
}

private actor Counter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
#endif
