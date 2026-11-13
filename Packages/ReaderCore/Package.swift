// swift-tools-version: 6.0
import PackageDescription

// Pure-Swift core: outline engine, anchors, note targets, notebook tree, export.
// No PDFKit, SwiftData, UIKit or PencilKit imports are allowed in this package.
let package = Package(
    name: "ReaderCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReaderCore", targets: ["ReaderCore"])
    ],
    targets: [
        .target(name: "ReaderCore"),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"])
    ]
)
