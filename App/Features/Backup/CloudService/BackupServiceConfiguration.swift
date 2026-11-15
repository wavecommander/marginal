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
///   (`software.tactile.marginal.backup.standard`).
nonisolated struct BackupServiceConfiguration: Hashable, Sendable, CustomStringConvertible {
    static let infoKey = "BackupService"
    static let hostKey = "Host"
    static let productIDsKey = "ProductIDs"

    /// `https://<host>[:<port>]`, or `http://` for a loopback host. No path, no trailing slash.
    let baseURL: URL
    /// The host name as written (an IPv6 loopback as `[::1]`), without the port.
    let host: String
    /// `nil` for the scheme's default port.
    let port: Int?
    /// The subscription product IDs, in the order given, without repeats.
    let productIDs: [String]

    /// Whether the service is reached over plain HTTP on this machine (local development).
    var isLoopback: Bool { baseURL.scheme == "http" }

    var description: String {
        "BackupServiceConfiguration(\(baseURL.absoluteString), products: \(productIDs.joined(separator: ", ")))"
    }

    /// The configuration, or `nil` unless the host is a usable host (and port) and at least one
    /// product ID is given. A value that is missing, empty, not a string, or an unexpanded build
    /// setting such as `$(BACKUP_SERVICE_HOST)` counts as not set.
    static func fromInfoDictionary(_ infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> BackupServiceConfiguration? {
        guard let values = infoDictionary?[infoKey] as? [String: Any],
              let hostValue = (values[hostKey] as? String).flatMap(setting),
              let idsValue = (values[productIDsKey] as? String).flatMap(setting) else { return nil }
        return BackupServiceConfiguration(host: hostValue, productIDs: idsValue)
    }

    /// Parses the two settings as written in the xcconfig. `nil` unless both are usable.
    init?(host hostSetting: String, productIDs productIDsSetting: String) {
        let ids = Self.parseProductIDs(productIDsSetting)
        guard !ids.isEmpty, let (host, port) = Self.parseHost(hostSetting) else { return nil }
        let scheme = S3Endpoint.loopbackHosts.contains(host.lowercased()) ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")") else { return nil }
        self.baseURL = url
        self.host = host
        self.port = port
        self.productIDs = ids
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
