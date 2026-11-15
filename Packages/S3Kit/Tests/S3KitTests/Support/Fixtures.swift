import CryptoKit
import Foundation
import Testing
@testable import S3Kit

enum Fixtures {
    static let signingDate = "20260101T000000Z"

    static func sha256(_ data: Data) -> String { S3Signer.hex(SHA256.hash(data: data)) }

    /// Checks a received request is signed for exactly what arrived: re-signs its URL and the
    /// headers its `Authorization` names, with the stub's credentials, and compares.
    static func expectSigned(_ request: RecordedRequest, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let authorization = request.headers["authorization"] else {
            Issue.record("No Authorization header", sourceLocation: sourceLocation)
            return
        }
        #expect(authorization.hasPrefix(
            "AWS4-HMAC-SHA256 Credential=\(StubServer.accessKeyID)/20260101/auto/s3/aws4_request,SignedHeaders="),
            sourceLocation: sourceLocation)
        #expect(request.headers["x-amz-date"] == signingDate, sourceLocation: sourceLocation)
        guard let signedList = authorization.components(separatedBy: "SignedHeaders=").last?
            .components(separatedBy: ",").first else { return }
        let names = signedList.split(separator: ";").map(String.init)
        #expect(names.contains("host") && names.contains("x-amz-date") && names.contains("x-amz-content-sha256"),
                sourceLocation: sourceLocation)
        var headers: [String: String] = [:]
        for name in names where !["host", "x-amz-date", "x-amz-content-sha256"].contains(name) {
            headers[name] = request.headers[name]
        }
        let signer = S3Signer(accessKeyID: StubServer.accessKeyID, secretAccessKey: StubServer.secret, region: "auto")
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let expected = signer.sign(method: request.method, url: request.url, headers: headers,
                                   payloadSHA256: request.headers["x-amz-content-sha256"] ?? "", date: date)
        #expect(expected["Authorization"] == authorization, sourceLocation: sourceLocation)
        // What was sent is exactly what was signed: the path is already in canonical form.
        #expect(S3Signer.canonicalURI(for: request.url) == request.url.path(percentEncoded: true),
                sourceLocation: sourceLocation)
    }

    /// A temporary file of `size` bytes whose content is a repeating, position-dependent pattern.
    static func file(size: Int, name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("S3KitTests-\(name)")
        // 4 KiB blocks, each stamped with its own index, so any misplaced range changes the bytes.
        let block = (0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        var data = Data(capacity: size)
        var index = 0
        while data.count < size {
            var stamped = block
            withUnsafeBytes(of: UInt32(index).bigEndian) { stamped.replaceSubrange(0..<4, with: $0) }
            data.append(contentsOf: stamped.prefix(size - data.count))
            index += 1
        }
        try data.write(to: url)
        return url
    }

    static func temporaryURL(_ name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("S3KitTests-\(name)")
    }

    /// Files left in `directory` by S3Kit (partial downloads, part copies).
    static func leftovers(in directory: URL, containing marker: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.contains(marker) }
    }
}

/// A thread-safe box for values tests collect from `@Sendable` callbacks.
final class Collected<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}
