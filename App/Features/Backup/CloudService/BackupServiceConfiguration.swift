import Foundation
import S3Kit

/// Where this build's Tactile Texts backup service is, and which App Store subscriptions buy it,
/// read from the `BackupService` dictionary in `Info.plist` (filled from `BACKUP_SERVICE_HOST`
/// and `BACKUP_PRODUCT_IDS` in `Config/Signing.xcconfig`, overridden by `Config/Local.xcconfig`).
///
/// Neither value is a secret. Both are empty by default, and then there is no configuration and
/// the cloud backup service is absent from the app, exactly as before it existed.
///
/// - `BACKUP_SERVICE_HOST`: the service's host, without a scheme (`//` starts a comment in an
///   xcconfig file), optionally with a port: `backup.example.com`, `localhost:8787`. A loopback
///   host (`localhost`, `127.0.0.1`, `[::1]`) is reached over plain HTTP, for `wrangler dev`;
///   every other host over HTTPS.
/// - `BACKUP_PRODUCT_IDS`: the subscription product IDs, separated by commas
///   (`software.tactile.texts.backup.standard`).
/// - `BACKUP_SERVICE_ATTEST_BYPASS` (optional, **development only**): the `dev` Worker's
///   `APP_ATTEST_BYPASS_SECRET`, sent as `X-App-Attest-Bypass` where App Attest is not
///   supported (the simulator). Only debug builds read it; it ends up in the built app's
///   Info.plist, so it is for development builds against the `dev` Worker only, never for a
///   build that leaves the developer's hands. The production Worker ignores the header.
nonisolated struct BackupServiceConfiguration: Hashable, Sendable, CustomStringConvertible {
    static let infoKey = "BackupService"
    static let hostKey = "Host"
    static let productIDsKey = "ProductIDs"
    static let attestBypassKey = "AttestBypass"
    static let appleSignInKey = "AppleSignIn"
    static let googleClientIDKey = "GoogleClientID"
    static let devSignInKey = "DevSignIn"

    /// `https://<host>[:<port>]`, or `http://` for a loopback host. No path, no trailing slash.
    let baseURL: URL
    /// The host name as written (an IPv6 loopback as `[::1]`), without the port.
    let host: String
    /// `nil` for the scheme's default port.
    let port: Int?
    /// The subscription product IDs, in the order given, without repeats.
    let productIDs: [String]
    /// The development Worker's App Attest bypass secret, or `nil` (always `nil` outside debug
    /// builds). Never described.
    let attestBypassSecret: String?
    /// Sign in with Apple is offered (`SIGN_IN_WITH_APPLE` is `YES`, set together with the
    /// entitlements file that holds the Sign in with Apple entitlement).
    var signInWithApple = false
    /// The Google OAuth client ID (iOS) for Sign in with Google, or `nil` (no Google button).
    var googleClientID: String?
    /// The `dev` Worker's test issuer secret (`BACKUP_SERVICE_DEV_SIGNIN`), or `nil`. Debug
    /// builds only; when set, both sign-in buttons use the test issuer. Never described.
    var devSignInSecret: String?

    /// Whether the service is reached over plain HTTP on this machine (local development).
    var isLoopback: Bool { baseURL.scheme == "http" }

    var description: String {
        "BackupServiceConfiguration(\(baseURL.absoluteString), products: \(productIDs.joined(separator: ", "))"
            + (attestBypassSecret == nil ? "" : ", attest bypass: <redacted>")
            + (signInWithApple ? ", Sign in with Apple" : "") + (googleClientID == nil ? "" : ", Sign in with Google")
            + (devSignInSecret == nil ? ")" : ", dev sign-in: <redacted>)")
    }

    /// The configuration, or `nil` unless the host is a usable host (and port) and at least one
    /// product ID is given. A value that is missing, empty, not a string, or an unexpanded build
    /// setting such as `$(BACKUP_SERVICE_HOST)` counts as not set.
    static func fromInfoDictionary(_ infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> BackupServiceConfiguration? {
        guard let values = infoDictionary?[infoKey] as? [String: Any],
              let hostValue = (values[hostKey] as? String).flatMap(setting),
              let idsValue = (values[productIDsKey] as? String).flatMap(setting) else { return nil }
        guard var configuration = BackupServiceConfiguration(host: hostValue, productIDs: idsValue,
                                                             attestBypass: values[attestBypassKey] as? String ?? "") else { return nil }
        configuration.signInWithApple = (values[appleSignInKey] as? String).flatMap(setting)?.uppercased() == "YES"
        configuration.googleClientID = (values[googleClientIDKey] as? String).flatMap(setting)
        #if DEBUG
        configuration.devSignInSecret = (values[devSignInKey] as? String).flatMap(setting)
        #endif
        return configuration
    }

    /// Parses the settings as written in the xcconfig. `nil` unless host and product IDs are
    /// usable. An empty or unexpanded bypass setting means none; outside debug builds it is
    /// always ignored.
    init?(host hostSetting: String, productIDs productIDsSetting: String, attestBypass: String = "") {
        let ids = Self.parseProductIDs(productIDsSetting)
        guard !ids.isEmpty, let (host, port) = Self.parseHost(hostSetting) else { return nil }
        let scheme = S3Endpoint.loopbackHosts.contains(host.lowercased()) ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")") else { return nil }
        self.baseURL = url
        self.host = host
        self.port = port
        self.productIDs = ids
        #if DEBUG
        self.attestBypassSecret = Self.setting(attestBypass)
        #else
        self.attestBypassSecret = nil
        #endif
    }

    // MARK: Parsing

    /// `raw` trimmed, or `nil` when it is empty or still holds a `$(…)` build-setting reference.
    static func setting(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    /// Comma-separated IDs: trimmed, empty entries and repeats dropped. An entry with a space,
    /// a control character, or a character a product ID cannot hold makes the whole list unusable
    /// (rather than silently selling a different set of products).
    static func parseProductIDs(_ raw: String) -> [String] {
        guard let raw = setting(raw) else { return [] }
        var result: [String] = []
        for part in raw.split(separator: ",") {
            let id = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { continue }
            guard id.unicodeScalars.allSatisfy(isProductIDCharacter) else { return [] }
            if !result.contains(id) { result.append(id) }
        }
        return result
    }

    /// App Store Connect product IDs are alphanumeric with periods, underscores (and, in practice,
    /// hyphens).
    private static func isProductIDCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-")
    }

    /// `host[:port]` with no scheme, path, query, user or spaces; the IPv6 loopback must be
    /// bracketed (`[::1]` or `[::1]:8787`).
    static func parseHost(_ raw: String) -> (host: String, port: Int?)? {
        guard let raw = setting(raw) else { return nil }
        let forbidden = CharacterSet(charactersIn: "/?#@\\% ").union(.whitespacesAndNewlines).union(.controlCharacters)
        guard raw.rangeOfCharacter(from: forbidden) == nil else { return nil }
        var host = raw
        var port: Int?
        if raw.hasPrefix("[") {
            guard let close = raw.firstIndex(of: "]") else { return nil }
            host = String(raw[...close])
            let rest = raw[raw.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let number = Int(rest.dropFirst()) else { return nil }
                port = number
            }
            guard host.lowercased() == "[::1]" else { return nil }
        } else if let colon = raw.firstIndex(of: ":") {
            host = String(raw[..<colon])
            guard let number = Int(raw[raw.index(after: colon)...]) else { return nil }
            port = number
        }
        if let port, !(1...65_535).contains(port) { return nil }
        guard !host.isEmpty, !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
              host.hasPrefix("[") || host.unicodeScalars.allSatisfy({
                  $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-")
              }) else { return nil }
        return (host, port)
    }
}
