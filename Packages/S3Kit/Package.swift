// swift-tools-version: 6.0
import PackageDescription

// A small client for S3-compatible object storage (Amazon S3, Cloudflare R2, MinIO and the
// like): AWS Signature Version 4 request signing and the handful of object operations the
// backup destination needs. Foundation and CryptoKit only, with the URLSession injected, so
// every request is testable with `swift test` on the Mac against a URLProtocol stub and the
// published signing test vectors.
let package = Package(
    name: "S3Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "S3Kit", targets: ["S3Kit"])
    ],
    targets: [
        .target(name: "S3Kit"),
        .testTarget(name: "S3KitTests", dependencies: ["S3Kit"])
    ]
)
