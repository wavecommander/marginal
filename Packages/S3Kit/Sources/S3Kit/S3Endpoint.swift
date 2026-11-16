import Foundation

/// Where a bucket is: the service's address, signing region, bucket and key prefix. Who is asking
/// (the credentials) is separate: see `S3CredentialsProvider`.
///
/// Requests use path-style addressing, `<scheme>://<host>[:<port>]<basePath>/<bucket>/<key>`.
/// In production the scheme is always HTTPS with no base path. For development only, a
/// **loopback** host (`localhost`, `127.0.0.1` or `[::1]`) may also use plain `http` and a base
/// path, so the client can be pointed at Cloudflare's local development server
/// (`http://localhost:8787/cdn-cgi/local/r2/s3`; see `localR2(bucket:port:prefix:)`). Any other
/// host asking for `http` or a base path is refused.
public struct S3Endpoint: Hashable, Sendable {
    /// The hosts a development endpoint may use.
    public static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]"]

    /// `https`, or `http` for a loopback host.
    public let scheme: String
    /// The host name, without scheme, port or path; the IPv6 loopback is written `[::1]`.
    public let host: String
    /// `nil` for the scheme's default port.
    public let port: Int?
    /// Path segments before the bucket, with a leading and no trailing slash
    /// (`/cdn-cgi/local/r2/s3`); empty for none. Loopback hosts only.
    public let basePath: String
    /// Signing region (`auto` for Cloudflare R2).
    public let region: String
    public let bucket: String
    /// Key prefix every object is stored under, without leading or trailing slashes; empty for
    /// the bucket root.
    public let prefix: String

    /// A production endpoint: HTTPS, no base path.
    ///
    /// `nil` unless host, region and bucket are non-empty after trimming whitespace and the host
    /// carries no scheme, port, path or spaces.
    public init?(host: String, region: String, bucket: String, prefix: String = "") {
        self.init(scheme: "https", host: host, port: nil, basePath: "", region: region, bucket: bucket, prefix: prefix)
    }

    /// Any endpoint, development ones included.
    ///
    /// `nil` when host, region or bucket is empty or malformed (the host takes no scheme, port,
    /// path or spaces; the bucket no `/`), the scheme is neither `https` nor `http`, the port is
    /// outside 1...65535, a base-path segment is `.` or `..` or has spaces or control characters,
    /// or `http` or a base path is asked for with a host that isn't loopback. The base path may
    /// be given with or without its outer slashes.
    public init?(scheme: String, host: String, port: Int? = nil, basePath: String = "", region: String,
                 bucket: String, prefix: String = "") {
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let scheme = trimmed(scheme).lowercased(), region = trimmed(region), bucket = trimmed(bucket)
        var host = trimmed(host)
        if host == "::1" { host = "[::1]" }
        let isLoopback = Self.loopbackHosts.contains(host.lowercased())
        let forbidden = CharacterSet(charactersIn: "/?#@ \\%").union(.controlCharacters)
        guard !host.isEmpty, !region.isEmpty, !bucket.isEmpty, !bucket.contains("/"),
              host.rangeOfCharacter(from: forbidden) == nil, isLoopback || !host.contains(":"),
              scheme == "https" || (scheme == "http" && isLoopback) else { return nil }
        if let port, !(1...65_535).contains(port) { return nil }
        let path = trimmed(basePath).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = path.isEmpty ? [] : path.split(separator: "/", omittingEmptySubsequences: false)
        if !segments.isEmpty {
            let badSegment = segments.contains { segment in
                segment.isEmpty || segment == "." || segment == ".."
                    || segment.unicodeScalars.contains { $0.value <= 0x20 || $0.value == 0x7F }
            }
            guard isLoopback, !badSegment else { return nil }
        }
        self.init(scheme: scheme, host: host, port: port, basePath: segments.isEmpty ? "" : "/" + path,
                  region: region, bucket: bucket,
                  prefix: trimmed(prefix).trimmingCharacters(in: CharacterSet(charactersIn: "/")), checked: ())
    }

    /// Stores the values as given.
    private init(scheme: String, host: String, port: Int?, basePath: String, region: String, bucket: String,
                 prefix: String, checked: Void) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.basePath = basePath
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
    }

    /// Cloudflare's local development server (`wrangler dev`), which serves a bucket over the S3
    /// API at `http://localhost:<port>/cdn-cgi/local/r2/s3`, path-style, with region `auto` and
    /// the static credentials set in the bucket binding's `local_dev.experimental_s3_credentials`.
    public static func localR2(bucket: String, port: Int = 8787, prefix: String = "") -> S3Endpoint? {
        S3Endpoint(scheme: "http", host: "localhost", port: port, basePath: "/cdn-cgi/local/r2/s3", region: "auto",
                   bucket: bucket, prefix: prefix)
    }

    /// Whether this is a development endpoint on this machine.
    public var isLoopback: Bool { Self.loopbackHosts.contains(host.lowercased()) }

    /// `<scheme>://<host>[:<port>]`.
    var origin: String { "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")" }

    /// The endpoint an `S3Configuration` has always meant: HTTPS to its host. A `host:port` host
    /// (which the configuration has always accepted) becomes host and port. A host this type
    /// would refuse is kept as it is, so it fails when the first request's URL is built, as it
    /// always has.
    init(configuration c: S3Configuration) {
        var host = c.host, port: Int?
        if !host.hasPrefix("["), let colon = host.lastIndex(of: ":"), let number = Int(host[host.index(after: colon)...]) {
            port = number
            host = String(host[..<colon])
        }
        self = S3Endpoint(scheme: "https", host: host, port: port, region: c.region, bucket: c.bucket, prefix: c.prefix)
            ?? S3Endpoint(scheme: "https", host: c.host, port: nil, basePath: "", region: c.region, bucket: c.bucket,
                          prefix: c.prefix, checked: ())
    }
}

extension S3Endpoint: CustomStringConvertible {
    public var description: String {
        "S3Endpoint(\(origin)\(basePath)/\(bucket), region: \(region), prefix: \(prefix.isEmpty ? "<none>" : prefix))"
    }
}
