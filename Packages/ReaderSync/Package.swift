// swift-tools-version: 6.0
import PackageDescription

// Sync: the `Sync/v1` formats (heads, blobs, history), the encrypted object store over a plain
// object store with conditional writes, the version rules, rollback refusal, the per-book base
// store, and the sync engine (`SyncEngine`) with its seams to the app's library and ink merge
// (`SyncLibrary`, `SyncInkMerger`). Foundation and CryptoKit only (on ReaderCore and ReaderBackup),
// with no S3Kit dependency: the S3 adapter lives in the app. Testable with `swift test` on the Mac.
let package = Package(
    name: "ReaderSync",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReaderSync", targets: ["ReaderSync"])
    ],
    dependencies: [
        .package(path: "../ReaderCore"),
        .package(path: "../ReaderBackup")
    ],
    targets: [
        .target(
            name: "ReaderSync",
            dependencies: [
                .product(name: "ReaderCore", package: "ReaderCore"),
                .product(name: "ReaderBackup", package: "ReaderBackup")
            ]
        ),
        .testTarget(
            name: "ReaderSyncTests",
            dependencies: ["ReaderSync"],
            resources: [.copy("Fixtures")]
        )
    ]
)
