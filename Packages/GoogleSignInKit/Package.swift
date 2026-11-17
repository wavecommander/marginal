// swift-tools-version: 6.0
import PackageDescription

// Sign in with Google, sign-in only: builds the OAuth 2.0 authorisation request (authorisation
// code with PKCE S256, `state` and the caller's `nonce`, scopes `openid email`), validates
// Google's redirect and makes the one code exchange that returns the ID token. The app opens the
// URL in `ASWebAuthenticationSession` itself and passes the ID token to its server, which
// verifies it; nothing here verifies signatures, refreshes or stores tokens. Foundation and
// CryptoKit only, with the URLSession injected, so the exchange is testable with `swift test`
// on the Mac against a URLProtocol stub.
let package = Package(
    name: "GoogleSignInKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GoogleSignInKit", targets: ["GoogleSignInKit"])
    ],
    targets: [
        .target(name: "GoogleSignInKit"),
        .testTarget(name: "GoogleSignInKitTests", dependencies: ["GoogleSignInKit"])
    ]
)
