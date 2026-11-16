// swift-tools-version: 6.0
import PackageDescription

// Backup and restore core: the `.ttbackup` archive format (a stored ZIP with ZIP64), content
// hashing, the manifest, the folder layout shared by every folder-like destination, and the
// restore plan. Foundation, CryptoKit and zlib only: no SwiftData, UIKit, PDFKit or PencilKit,
// so everything here is testable with `swift test` on the Mac.
let package = Package(
    name: "ReaderBackup",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReaderBackup", targets: ["ReaderBackup"])
    ],
    dependencies: [
        .package(path: "../ReaderCore")
    ],
    targets: [
        .target(
            name: "ReaderBackup",
            dependencies: [.product(name: "ReaderCore", package: "ReaderCore")],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(
            name: "ReaderBackupTests",
            dependencies: ["ReaderBackup"],
            resources: [.copy("Fixtures")]
        )
    ]
)
