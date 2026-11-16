// swift-tools-version: 6.0
import PackageDescription

// Persistence layer (SwiftData models, ink files).
let package = Package(
    name: "ReaderStore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReaderStore", targets: ["ReaderStore"])
    ],
    dependencies: [
        .package(path: "../ReaderCore")
    ],
    targets: [
        .target(
            name: "ReaderStore",
            dependencies: [.product(name: "ReaderCore", package: "ReaderCore")]
        ),
        .testTarget(name: "ReaderStoreTests", dependencies: ["ReaderStore"])
    ]
)
