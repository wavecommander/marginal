// swift-tools-version: 6.0
import PackageDescription

// The direct Google Drive integration's network side: OAuth 2.0 for an installed app (PKCE,
// token exchange and refresh) and the Drive REST v3 calls the backup destination needs.
// Foundation and CryptoKit only, with the URLSession and the token store injected, so every
// request and response is testable with `swift test` on the Mac against a URLProtocol stub.
// No UI, no Keychain and no ASWebAuthenticationSession here: the app supplies those.
let package = Package(
    name: "GoogleDriveKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GoogleDriveKit", targets: ["GoogleDriveKit"])
    ],
    targets: [
        .target(name: "GoogleDriveKit"),
        .testTarget(name: "GoogleDriveKitTests", dependencies: ["GoogleDriveKit"])
    ]
)
